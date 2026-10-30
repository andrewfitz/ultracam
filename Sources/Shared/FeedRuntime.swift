import CoreMedia
import CoreVideo
import Foundation

/// The lifecycle owned by one configured feed. Capture and camera transport
/// are deliberately outside this contract for now; they advance this state
/// through the coordinator while retaining their existing single-feed path.
enum FeedSessionState: Equatable, Sendable {
  case idle
  case running
  case unavailable(String)
  case failed(String)
}

/// Runtime state and output ownership for one feed descriptor.
///
/// A session owns its fan-out instance so stopping one feed drains only that
/// feed's pending leases. The capture implementation can publish processed
/// frames here when the descriptor-driven output routes are integrated.
@MainActor
final class FeedSession: Identifiable {
  let id: FeedID
  private(set) var descriptor: FeedDescriptor
  private(set) var state: FeedSessionState = .idle
  private(set) var generation: UInt64 = 0
  let frameFanOut: FrameFanOut<CVPixelBuffer>

  var isRunning: Bool { state == .running }

  init(descriptor: FeedDescriptor,
       frameFanOut: FrameFanOut<CVPixelBuffer> = FrameFanOut()) {
    id = descriptor.id
    self.descriptor = descriptor
    self.frameFanOut = frameFanOut
  }

  func update(descriptor: FeedDescriptor) {
    guard descriptor.id == id else { return }
    self.descriptor = descriptor
    if !descriptor.enabled, isRunning { stop() }
  }

  /// Starts a configured feed and returns false when the descriptor is
  /// disabled or the session is already active.
  @discardableResult
  func start() -> Bool {
    guard descriptor.enabled else {
      state = .unavailable("Feed is disabled")
      return false
    }
    guard !isRunning else { return false }
    generation &+= 1
    state = .running
    return true
  }

  /// Stops this feed and drains queued route leases while leaving route
  /// registration intact for a later start.
  func stop() {
    guard state != .idle else { return }
    generation &+= 1
    frameFanOut.drain()
    state = .idle
  }

  func fail(_ message: String) {
    generation &+= 1
    frameFanOut.drain()
    state = .failed(message)
  }

  func publish(_ frame: ProcessedFrame<CVPixelBuffer>) -> FrameFanOutReport {
    guard isRunning else {
      return FrameFanOutReport(outcomes: [:], routerClosed: false)
    }
    return frameFanOut.publish(frame)
  }

  func addRoute(id: String, capacity: Int,
                policy: FrameQueueOverflowPolicy) throws -> FrameRoute<CVPixelBuffer> {
    try frameFanOut.addRoute(id: id, capacity: capacity, policy: policy)
  }
}

/// Main-actor collection of stable feed descriptors, runtime sessions, and
/// capture owners. Persisted ordering remains the source of truth for the
/// collection; sessions and controllers are created only for descriptors that
/// are accessed. Each controller owns an independent capture session.
@MainActor
final class FeedCoordinator {
  private(set) var descriptors: [FeedDescriptor]
  private(set) var selectedFeedID: FeedID
  private(set) var outputMode: FeedOutputMode
  /// Live switcher state, read from the route that ingests frames. There is
  /// no second copy that could disagree with what is on air.
  var switcher: SwitcherSettings { programOutput.switcher.settings }
  private(set) var virtualCameraRegistryVersion: Int
  var switcherCoordinator: SwitcherCoordinator { programOutput.switcher }
  private(set) var virtualCameraRegistrySnapshot: VirtualCameraRegistrySnapshot
  private let registryStore: VirtualCameraRegistryStore?
  var syncCameras = false
  var programMonitor: MonitorFeedPreferences
  var monitorWorkspace: MonitorWorkspacePreferences
  private var sessions: [FeedID: FeedSession] = [:]
  let capturePool: FeedCapturePool
  let programOutput: ProgramOutputRoute
  private var programBridge: ProgramOutputBridge?
  private var demandCoordinator: RouteDemandCoordinator
  private var programConsumerActive = false
  private let programNormalizer = ProgramNormalizerLoader()
  var onProgramCutApplied: ((FeedID, CMTime, CMTime) -> Void)?
  /// A requested cut that will not land: the target failed to start, stopped,
  /// or never produced a qualifying frame. The selection did not change.
  var onProgramCutAbandoned: ((FeedID, ProgramCutAbandonReason) -> Void)?
  var onProgramOutputError: ((String) -> Void)?

  init(snapshot: AppSettingsSnapshot = AppSettingsSnapshot(),
       capturePool: FeedCapturePool = FeedCapturePool(),
       registryStore: VirtualCameraRegistryStore? = nil) {
    let safe = snapshot.validated() ?? AppSettingsSnapshot()
    syncCameras = safe.syncCameras
    programMonitor = safe.programMonitor
    monitorWorkspace = safe.monitorWorkspacePreferences
    descriptors = safe.feeds
    // A persisted selection can point at a disabled descriptor. Keep the
    // collection and the live Program route on the same usable source so a
    // restart cannot select a feed that `start` is guaranteed to reject.
    selectedFeedID = safe.feeds.first(where: { $0.id == safe.selectedFeedID && $0.enabled })?.id
      ?? safe.feeds.first(where: \.enabled)?.id
      ?? safe.feeds[0].id
    outputMode = safe.outputMode
    virtualCameraRegistryVersion = safe.virtualCameraRegistryVersion
    programOutput = ProgramOutputRoute(settings: safe.switcher,
      feedIDs: safe.feeds.filter(\.enabled).map(\.id))
    demandCoordinator = RouteDemandCoordinator()
    self.registryStore = registryStore
    self.capturePool = capturePool
    let initialDevices = Self.registryDevices(for: safe.outputMode, feeds: safe.feeds)
    let stored = registryStore?.load()
    let generation = max(stored?.generation ?? 0, UInt64(max(1, safe.virtualCameraRegistryVersion)))
    // The registry store can be pointed at a test or staging app group. Keep
    // the in-memory baseline on that same suite when it has no valid slots;
    // otherwise the first publication would fail the store's app-group fence.
    let registryGroup = registryStore?.groupIdentifier
      ?? VirtualCameraRegistrySnapshot.defaultAppGroupIdentifier
    virtualCameraRegistrySnapshot = VirtualCameraRegistrySnapshot(generation: generation,
      appGroupIdentifier: registryGroup, devices: initialDevices)
    if registryStore != nil { publishVirtualCameraRegistry() }
    let loader = programNormalizer
    // Never compiles: the route calls this under its lock on a capture
    // delivery thread. The converter is built in the background (`warm`).
    programOutput.setNormalizerProvider { loader.loadedNormalizer }
    if outputMode == .program { loader.warm() }
    programOutput.setAcceptingCapture(outputMode == .program)
    programOutput.onEvent = { [weak self] event in
      // State changes only; frames never take this hop.
      Task { @MainActor [weak self] in self?.handleProgramEvent(event) }
    }
  }

  private func handleProgramEvent(_ event: ProgramRouteEvent) {
    switch event {
    case let .cutApplied(feedID, sourceTime, programTime):
      // Program routing selection is owned by ProgramOutputRoute. Keep the
      // app's selected feed/UI editing identity stable across an automatic
      // A→B cut; changing it here makes status callbacks and persisted device
      // settings switch to the wrong source.
      if programConsumerActive, outputMode == .program {
        demandCoordinator.selectProgram(feedID: feedID.rawValue)
        _ = demandCoordinator.drainTransitions()
      }
      onProgramCutApplied?(feedID, sourceTime, programTime)
    case let .cutAbandoned(feedID, reason):
      onProgramCutAbandoned?(feedID, reason)
    case let .outputError(message):
      onProgramOutputError?(message)
    }
  }

  var selectedDescriptor: FeedDescriptor {
    descriptors.first(where: { $0.id == selectedFeedID }) ?? descriptors[0]
  }

  var orderedSessions: [FeedSession] {
    descriptors.filter(\.enabled).compactMap { sessions[$0.id] }
  }

  var selectedSession: FeedSession { session(for: selectedFeedID) }

  /// Stable capture owner for one feed.  Calling this for one feed never
  /// changes or reuses another feed's UltracamBackend.
  func capture(for id: FeedID) -> CaptureController {
    capturePool.controller(for: id)
  }

  func isFeedRunning(_ id: FeedID) -> Bool {
    sessions[id]?.isRunning == true
  }

  /// Installs the single consumer for the Program CMIO stream. The route is
  /// persistent across demand transitions so queued leases can be drained and
  /// reused without recreating a fan-out while a source callback is active.
  func prepareProgramOutputBridge() throws {
    guard programBridge == nil else { return }
    let route = try programOutput.addConsumerRoute(id: "program-camera",
      capacity: ProgramOutputRoute.consumerCapacity, policy: .reject, compactRepeats: true)
    let bridge = ProgramOutputBridge(route: route, paced: true)
    attachProgramBridge(bridge)
  }

  /// Wires a bridge to the route: the bridge's negotiated contract becomes the
  /// route's conversion target, and every publication pumps the bridge from
  /// the publishing thread (never the main actor).
  func attachProgramBridge(_ bridge: ProgramOutputBridge) {
    programBridge = bridge
    bridge.enforceContract = true
    let route = programOutput
    // Nothing is offered to the camera route until a client is connected.
    route.setOutput(contract: nil, active: false)
    bridge.onContractChange = { contract in
      route.setOutput(contract: contract, active: contract != nil)
    }
    route.onPublished = { [weak bridge] in bridge?.schedulePump() }
    programNormalizer.warm()
  }

  /// Connects or closes the Program camera on the bridge's control queue so
  /// CMIO discovery (up to 3 s) never blocks the main actor. `completion`
  /// runs on the main actor.
  func requestProgramOutputDemand(_ active: Bool, configuration: PipelineConfiguration,
                                  passthroughFormat: OSType, renegotiate: Bool = false,
                                  completion: @escaping @MainActor @Sendable (Error?) -> Void) {
    do { try prepareProgramOutputBridge() } catch { completion(error); return }
    programBridge?.requestDemand(active, configuration: configuration,
      passthroughFormat: passthroughFormat, renegotiate: renegotiate) { error in
      Task { @MainActor in completion(error) }
    }
  }

  var programOutputStatistics: ProgramOutputBridge.Statistics {
    programBridge?.currentStatistics ?? .init()
  }

  var programRouteStatistics: ProgramRouteStatistics { programOutput.statistics }

  var programNormalizerStatistics: ProgramNormalizer.Statistics? {
    programNormalizer.loadedNormalizer?.currentStatistics
  }

  /// Connects one feed's processed frames to the Program route. The capture
  /// delivery thread ingests directly: no main-actor hop, no latest-frame
  /// slot, nothing dropped on the way. The capture generation token fences out
  /// a callback already in flight from a previous start.
  func installProgramFrameDelivery(feedID: FeedID) {
    let controller = capture(for: feedID)
    let route = programOutput
    controller.onProcessedFrame = { [weak controller] frame, generation in
      guard let controller, controller.isAccepting(feedID: feedID),
        controller.generationToken == generation else { return }
      route.ingest(fromCapture: feedID, frame: frame)
    }
  }

  func setCameraOutputEnabled(feedID: FeedID, enabled: Bool) {
    capture(for: feedID).setCameraOutputEnabled(enabled)
  }

  /// Every running camera whose virtual camera isn't connected tries again now: CMIO's
  /// cameras changed, so the camera extension may have just started.
  func requestCameraReconnects() {
    for descriptor in descriptors where isFeedRunning(descriptor.id) {
      capture(for: descriptor.id).requestCameraReconnect()
    }
  }

  /// Updates the live Program scheduler. Capture failure of one source must
  /// not leave that source eligible for the next cut.
  func setProgramSourceHealth(_ feedID: FeedID, healthy: Bool) {
    guard descriptors.contains(where: { $0.id == feedID }) else { return }
    programOutput.setSourceHealth(feedID, healthy: healthy)
  }

  /// Lazily creates a session while preserving descriptor ordering.
  func session(for id: FeedID) -> FeedSession {
    if let session = sessions[id] { return session }
    let descriptor = descriptors.first(where: { $0.id == id }) ?? FeedDescriptor(id: id)
    if !descriptors.contains(where: { $0.id == id }) { descriptors.append(descriptor) }
    let session = FeedSession(descriptor: descriptor)
    sessions[id] = session
    return session
  }

  @discardableResult
  func select(_ id: FeedID) -> Bool {
    guard descriptors.contains(where: { $0.id == id && $0.enabled }) else { return false }
    selectedFeedID = id
    if programOutput.selectedFeedID == nil { programOutput.select(id) }
    return true
  }

  func update(_ descriptor: FeedDescriptor) {
    guard let index = descriptors.firstIndex(where: { $0.id == descriptor.id }) else {
      descriptors.append(descriptor)
      if !descriptor.enabled {
        capturePool.stop(descriptor.id)
      }
      programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
        publishVirtualCameraRegistry()
      return
    }
    descriptors[index] = descriptor
    // A descriptor can be disabled while its session is idle (for example,
    // when a capture owner was started directly by a camera demand callback).
    // Stopping only the FeedSession in that case leaves the native capture
    // owner active and allows late frames to outlive the descriptor.
    if !descriptor.enabled {
      capturePool.stop(descriptor.id)
      if selectedFeedID == descriptor.id {
        selectedFeedID = descriptors.first(where: \.enabled)?.id ?? descriptor.id
      }
    }
    sessions[descriptor.id]?.update(descriptor: descriptor)
    programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
    if programConsumerActive {
      let selected = outputMode == .program ? programOutput.selectedFeedID?.rawValue : nil
      demandCoordinator.selectProgram(feedID: selected)
      _ = demandCoordinator.drainTransitions()
    }
    publishVirtualCameraRegistry()
  }

  @discardableResult
  func add(name: String? = nil) -> FeedID {
    var id = FeedID(uuid: UUID())
    while descriptors.contains(where: { $0.id == id }) { id = FeedID(uuid: UUID()) }
    let descriptor = FeedDescriptor(id: id, name: name ?? "Camera \(descriptors.count + 1)")
    descriptors.append(descriptor)
    programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
    publishVirtualCameraRegistry()
    return id
  }

  /// Removes an idle feed. A running feed remains configured until its owner
  /// explicitly stops it, preventing a dangling route or camera client.
  @discardableResult
  func remove(_ id: FeedID) -> Bool {
    guard descriptors.count > 1, let index = descriptors.firstIndex(where: { $0.id == id }) else {
      return false
    }
    guard sessions[id]?.isRunning != true else { return false }
    // Dedicated/manual consumers represent external owners of this feed. A
    // topology removal must wait until those owners release their demand;
    // otherwise the demand coordinator retains an orphaned source ID.
    let demand = demandCoordinator.snapshot(for: id.rawValue)
    guard !demand.dedicatedCamera, !demand.manualOutput else { return false }
    guard capturePool.remove(id) else { return false }
    sessions.removeValue(forKey: id)?.stop()
    descriptors.remove(at: index)
    if selectedFeedID == id {
      selectedFeedID = descriptors.first(where: \.enabled)?.id ?? descriptors[0].id
    }
    programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
    if programConsumerActive {
      demandCoordinator.selectProgram(feedID: programOutput.selectedFeedID?.rawValue)
      _ = demandCoordinator.drainTransitions()
    }
    publishVirtualCameraRegistry()
    return true
  }

  @discardableResult
  func start(_ id: FeedID) -> Bool {
    guard descriptors.contains(where: { $0.id == id }) else { return false }
    let started = session(for: id).start()
    if started {
      // Starting until its first frame: a cut to it waits for that frame.
      programOutput.setSourceLive(id, live: true)
      programOutput.setSourceHealth(id, healthy: true)
    }
    return started
  }

  func stop(_ id: FeedID) {
    guard descriptors.contains(where: { $0.id == id }) else { return }
    retireProgramSource(id)
    capturePool.stop(id)
    session(for: id).stop()
  }

  /// Starts the session and its independent native capture owner as one
  /// operation. The native controller reports asynchronous signal failures in
  /// its update stream, matching the established single-feed behavior.
  @discardableResult
  func startCapture(feedID: FeedID, deviceID: String, configuration: PipelineConfiguration,
                    pipelineEnabled: Bool = true) -> Bool {
    guard start(feedID) else { return false }
    capture(for: feedID).start(feedID: feedID, deviceID: deviceID,
      configuration: configuration, pipelineEnabled: pipelineEnabled)
    return true
  }

  /// A stopped source takes no new frames and can't be cut to; a pending cut
  /// to it is abandoned and reported.
  private func retireProgramSource(_ id: FeedID) {
    programOutput.setSourceLive(id, live: false)
    programOutput.setSourceHealth(id, healthy: false)
  }

  func stopCapture(feedID: FeedID) {
    guard descriptors.contains(where: { $0.id == feedID }) else { return }
    retireProgramSource(feedID)
    capturePool.stop(feedID)
    session(for: feedID).stop()
  }

  func reconfigureCapture(feedID: FeedID, configuration: PipelineConfiguration,
                          pipelineEnabled: Bool) {
    capture(for: feedID).reconfigure(configuration: configuration, pipelineEnabled: pipelineEnabled)
  }

  func setRecordingCallbacks(feedID: FeedID,
                             callbacks: SourceRecordingCallbackAdapter.Callbacks?) {
    capture(for: feedID).setRecordingCallbacks(feedID: feedID, callbacks: callbacks)
  }

  func addOutputRoute(feedID: FeedID, routeID: String, capacity: Int,
                      policy: FrameQueueOverflowPolicy) throws -> FrameRoute<CVPixelBuffer> {
    try session(for: feedID).addRoute(id: routeID, capacity: capacity, policy: policy)
  }

  func publish(_ frame: ProcessedFrame<CVPixelBuffer>, to feedID: FeedID)
    -> FrameFanOutReport {
    let feedSession = session(for: feedID)
    let report = feedSession.publish(frame)
    if feedSession.isRunning { _ = ingestProgramFrame(feedID: feedID, frame: frame) }
    return report
  }

  func setOutputMode(_ mode: FeedOutputMode) {
    guard outputMode != mode else { return }
    outputMode = mode
    // Keep the Program scheduler aligned with the persisted selection when the
    // program route is enabled. A feed can be selected while operating in
    // separate-camera mode, so the live scheduler may still point at an older
    // source when the mode changes.
    programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
    // Nothing is on air until a source delivers a frame in the new mode.
    programOutput.markSourcesIdle()
    programOutput.setAcceptingCapture(mode == .program)
    if mode == .program { programNormalizer.warm() }
    // A Program consumer is a source-demand route. Release it when leaving
    // Program mode and rebind it to the live scheduler when entering Program
    // mode, so a mode toggle cannot leave a removed/old feed running.
    if programConsumerActive {
      let selected = mode == .program ? programOutput.selectedFeedID?.rawValue : nil
      demandCoordinator.selectProgram(feedID: selected)
      _ = demandCoordinator.drainTransitions()
    }
    publishVirtualCameraRegistry()
  }

  func setSwitcher(_ settings: SwitcherSettings) {
    let requested = settings.selectedFeedID.flatMap { candidate in
      descriptors.contains(where: { $0.id == candidate && $0.enabled }) ? candidate : nil
    } ?? selectedFeedID
    // Policy first; the selection changes only through a cut (or at once when
    // nothing is on air), so the saved value always names the on-air source.
    programOutput.updateSettings(settings)
    if programOutput.selectedFeedID != requested { _ = requestProgramSelection(requested) }
    publishVirtualCameraRegistry()
  }

  /// A cut when something is on air in Program mode; otherwise the selection
  /// just changes, since there is no picture to cut away from.
  private func requestProgramSelection(_ feedID: FeedID,
                                       noEarlierThan: CMTime? = nil) -> ProgramCutRequestResult<FeedID> {
    guard descriptors.contains(where: { $0.id == feedID && $0.enabled }) else {
      return .rejectedMissingSource
    }
    return programOutput.requestSelection(feedID, noEarlierThan: noEarlierThan,
      cutsAllowed: outputMode == .program)
  }

  /// Requests a frame-boundary Program cut. The selection changes when the
  /// target's first valid frame lands; a target that is still starting keeps
  /// the cut pending until then, or until it fails (`onProgramCutAbandoned`).
  @discardableResult
  func requestProgramCut(to feedID: FeedID) -> ProgramCutRequestResult<FeedID> {
    requestProgramSelection(feedID)
  }

  @discardableResult
  func requestProgramCut(to feedID: FeedID, noEarlierThan: CMTime?)
    -> ProgramCutRequestResult<FeedID> {
    requestProgramSelection(feedID, noEarlierThan: noEarlierThan)
  }

  func cancelProgramCut() {
    programOutput.cancelPendingCut()
  }

  @discardableResult
  func evaluateSwitcher(at mediaTime: CMTime) -> SwitcherEvaluation {
    programOutput.evaluate(at: mediaTime)
  }

  /// Publishes a processed frame to the Program route when Program mode is
  /// active. Separate-camera mode leaves the frame on its feed route only.
  /// Test entry point; the app ingests through `installProgramFrameDelivery`.
  /// Cut events reach the main actor through
  /// `ProgramOutputRoute.onEvent`.
  @discardableResult
  func ingestProgramFrame(feedID: FeedID, frame: ProcessedFrame<CVPixelBuffer>)
    -> ProgramRouteResult? {
    guard outputMode == .program, descriptors.contains(where: { $0.id == feedID && $0.enabled }) else {
      return nil
    }
    return programOutput.ingest(feedID: feedID, frame: frame)
  }

  @discardableResult
  func addProgramOutputRoute(id: String = "program-camera", capacity: Int = ProgramOutputRoute.stageCapacity,
                             policy: FrameQueueOverflowPolicy = .reject)
    throws -> FrameRoute<CVPixelBuffer> {
    try programOutput.addConsumerRoute(id: id, capacity: capacity, policy: policy)
  }

  /// Ties source demand to the Program camera's consumer lifecycle. The
  /// caller executes returned start/stop transitions against its capture pool.
  @discardableResult
  func setProgramConsumer(_ active: Bool, at time: TimeInterval? = nil)
    -> [SourceDemandTransition] {
    programConsumerActive = active
    let selected = active && outputMode == .program
      ? programOutput.selectedFeedID?.rawValue : nil
    demandCoordinator.selectProgram(feedID: selected,
      at: time)
    return demandCoordinator.drainTransitions()
  }

  @discardableResult
  func setDedicatedCameraConsumer(feedID: FeedID, active: Bool,
                                  ownerID: String? = nil, at time: TimeInterval? = nil)
    -> [SourceDemandTransition] {
    // Releases must remain possible after a descriptor is disabled so an
    // existing consumer can relinquish its lease before topology removal.
    let known = descriptors.contains(where: { $0.id == feedID })
    guard known && (!active || descriptors.contains(where: { $0.id == feedID && $0.enabled })) else {
      return []
    }
    if active {
      _ = demandCoordinator.acquire(feedID: feedID.rawValue, route: .dedicatedCamera,
        ownerID: ownerID, at: time)
    } else {
      _ = demandCoordinator.release(feedID: feedID.rawValue, route: .dedicatedCamera,
        ownerID: ownerID, at: time)
    }
    return demandCoordinator.drainTransitions()
  }

  /// Feed IDs that currently keep a source capture demanded. Preview-only
  /// leases are intentionally omitted from this runtime-facing view.
  var activeDemandFeedIDs: Set<String> { demandCoordinator.activeSourceFeedIDs }

  /// Complete registry state published to the camera extension. Separate
  /// mode exposes one stable device per enabled feed; Program mode exposes one
  /// Program device while feed captures remain internal sources.
  var virtualCameraDescriptors: [VirtualCameraDescriptor] {
    Self.registryDevices(for: outputMode, feeds: descriptors)
  }

  var snapshot: AppSettingsSnapshot {
    AppSettingsSnapshot(feeds: descriptors, selectedFeedID: selectedFeedID,
      outputMode: outputMode, switcher: switcher,
      virtualCameraRegistryVersion: virtualCameraRegistryVersion,
      programMonitor: programMonitor,
      monitorWorkspace: monitorWorkspace, syncCameras: syncCameras)
  }

  @discardableResult
  private func publishVirtualCameraRegistry() -> Bool {
    let devices = virtualCameraDescriptors
    let next: VirtualCameraRegistrySnapshot
    if let current = registryStore?.load() {
      next = current.advancing(to: devices)
    } else {
      let generation = virtualCameraRegistrySnapshot.generation == UInt64.max
        ? UInt64.max
        : max(virtualCameraRegistrySnapshot.generation + 1, 1)
      next = VirtualCameraRegistrySnapshot(generation: generation, devices: devices)
    }
    virtualCameraRegistrySnapshot = next
    virtualCameraRegistryVersion = Int(min(next.generation, UInt64(Int.max)))
    guard let registryStore else { return true }
    do {
      try registryStore.save(next)
      return true
    } catch {
      return false
    }
  }

  private static func registryDevices(for mode: FeedOutputMode,
                                      feeds: [FeedDescriptor]) -> [VirtualCameraDescriptor] {
    switch mode {
    case .separateCameras:
      return feeds.filter(\.enabled).map { feed in
        VirtualCameraDescriptor.feed(feedID: feed.id.rawValue, displayName: "Ultracam · \(feed.name)")
      }
    case .program:
      return [VirtualCameraDescriptor.program()]
    }
  }
}
