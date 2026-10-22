import AppKit
import MonitorToolsCore
import CoreVideo
import Observation
import UniformTypeIdentifiers

struct InputDevice: Identifiable {
  let id: String
  let name: String
}

@MainActor protocol AppVirtualCameraRegistryPublishing {
  func publish(_ snapshot: VirtualCameraRegistrySnapshot)
}

extension VirtualCameraRegistryPublisher: AppVirtualCameraRegistryPublishing {}

/// AppModel's paths to the DeckLink driver and the per-camera extension
/// streams. Tools that build a real model, such as ui-verify, pass `.offline`
/// so they can never open the user's capture device or send to their camera.
/// The Program stream connects only behind a running camera, which `.offline`
/// can't start.
@MainActor struct AppHardware {
  var captureServices: (FeedID) -> CaptureServices
  var devices: () throws -> [InputDevice]
  var driverWarning: () -> String?
  var observeDevices: (@escaping @MainActor @Sendable ([InputDevice]) -> Void) -> Any?
  var diagnostics: (String) -> UltracamDeviceDiagnostics?

  static let live = AppHardware(
    captureServices: { .live(feedID: $0) },
    devices: { try UltracamBackend.devices().map { InputDevice(id: $0.identifier, name: $0.name) } },
    driverWarning: { UltracamBackend.driverInfo().message },
    observeDevices: { handler in
      UltracamBackend.addDeviceListObserver { list in
        handler(list.map { InputDevice(id: $0.identifier, name: $0.name) })
      }
    },
    diagnostics: { UltracamBackend.diagnostics(deviceID: $0) })

  /// No devices; starting a camera fails with an error and nothing is sent.
  static let offline = AppHardware(
    captureServices: { _ in
      CaptureServices(
        start: { _, _, _, _ in throw CocoaError(.featureUnsupported) },
        stop: {}, connect: { _, _ in }, disconnect: {}, send: { _ in false })
    },
    devices: { [] }, driverWarning: { nil }, observeDevices: { _ in nil }, diagnostics: { _ in nil })
}

@MainActor @Observable
final class AppModel {
  private let registryPublisher: any AppVirtualCameraRegistryPublishing
  @ObservationIgnored private let hardware: AppHardware
  var hideFromDock = false {
    didSet {
      guard hideFromDock != oldValue else { return }
      settingsStore.hideFromDock = hideFromDock
      NSApplication.shared.setActivationPolicy(hideFromDock ? .accessory : .regular)
    }
  }
  var devices: [InputDevice] = [] { didSet { expireResolvedStartRefusals() } }
  /// Set when Desktop Video is missing or older than 16.0, whose drivers
  /// reject the SDK 16 interfaces and would otherwise list no inputs.
  var driverWarning: String?
  @ObservationIgnored private var deviceListObserver: Any?
  /// Descriptors and selection are coordinated as a collection. The selected
  /// session still follows the established one-feed capture path.
  var feedDescriptors: [FeedDescriptor] { feedCoordinator.descriptors }
  var selectedFeedID: FeedID { feedCoordinator.selectedFeedID }

  /// The virtual-camera topology is a persisted app setting. UI callers use
  /// this property instead of reaching into FeedCoordinator so that changing
  /// the output route always updates the shared registry and preferences.
  var outputMode: FeedOutputMode {
    get { feedCoordinator.outputMode }
    set { setOutputMode(newValue) }
  }

  /// Switcher state is kept on the same coordinator that consumes frames. The
  /// value is exposed as a snapshot for SwiftUI bindings; mutations should go
  /// through `updateSwitcher` to keep the frame route and disk state aligned.
  var switcherSettings: SwitcherSettings { feedCoordinator.switcher }
  var switcherSelectedFeedID: FeedID? { feedCoordinator.switcher.selectedFeedID }
  var switcherPendingFeedID: FeedID? { feedCoordinator.programOutput.pendingFeedID }
  var switcherStatus: String { feedCoordinator.switcherCoordinator.statusMessage }

  var naturalTalkingHeadEnabled: Bool {
    get { feedCoordinator.switcher.naturalTalkingHead.enabled }
    set {
      guard !newValue || !running || outputMode == .program else { return }
      var settings = feedCoordinator.switcher
      if newValue, outputMode != .program { setOutputMode(.program) }
      settings.automatic = newValue
      settings.strategy = newValue ? .naturalTalkingHead : .manual
      settings.naturalTalkingHead.enabled = newValue
      updateSwitcher(settings)
    }
  }

  var naturalAnchorFeedID: FeedID? {
    get { feedCoordinator.switcher.naturalTalkingHead.anchorFeedID }
    set {
      var settings = feedCoordinator.switcher
      settings.naturalTalkingHead.anchorFeedID = newValue
      updateSwitcher(settings)
    }
  }

  var naturalEmphasisFeedID: FeedID? {
    get { feedCoordinator.switcher.naturalTalkingHead.emphasisFeedID }
    set {
      var settings = feedCoordinator.switcher
      settings.naturalTalkingHead.emphasisFeedID = newValue
      updateSwitcher(settings)
    }
  }

  var naturalDirectorStatus: String {
    if !naturalTalkingHeadEnabled { return "Disabled" }
    if autoSwitcherBridge != nil { return "Active · Rust director" }
    return running ? "Waiting for two enabled cameras" : "Starts with Program output"
  }

  var canEditFeedTopology: Bool {
    FeedLifecycleDemandPolicy.canEditTopology(loading: !lutLoadingFeeds.isEmpty,
      sourceActive: feedDescriptors.contains {
        feedCoordinator.isFeedRunning($0.id) ||
          feedCoordinator.capturePool.existingController(for: $0.id)?.hasActiveFeed == true
      }, recordingActive: recordingModel.feeds.contains { $0.isActive })
  }
  var selectedFeedName: String {
    feedCoordinator.selectedDescriptor.name
  }

  var selectedDevice = "" { didSet { if selectedDevice != oldValue { saveSettings() } } }
  var configuration = PipelineConfiguration() {
    didSet {
      guard configuration != oldValue, !restoringSettings else { return }
      if lutLoaded || lutBookmark == nil { rememberedLUTEnabled = configuration.applyLUT }
      saveSettings()
      if running { reconfigure() }
    }
  }
  var gamut = "S-Gamut3.Cine / S-Log3" { didSet { if gamut != oldValue { saveSettings() } } }
  var pipelineEnabled = true {
    didSet {
      guard pipelineEnabled != oldValue, !restoringSettings else { return }
      saveSettings()
      if running { reconfigure() }
    }
  }
  var previewEnabled = true {
    didSet {
      guard previewEnabled != oldValue else { return }
      saveSettings()
      if !previewEnabled { previewReady = false }
      capture.setPreviewEnabled(previewEnabled)
      if !restoringSettings { reconcileAutomaticFeed() }
    }
  }
  var automaticFeedEnabled = false {
    didSet {
      guard automaticFeedEnabled != oldValue, !restoringSettings else { return }
      if !automaticFeedEnabled { demandStartedFeeds.remove(selectedFeedID) }
      saveSettings()
      // A live feed stays up under manual Start/Stop. Only the demand monitor
      // changes, so closing the camera app no longer stops a feed the user
      // has taken back.
      installAutomaticFeedMonitor()
    }
  }
  private(set) var cameraDemandError: String?
  var lutTitle = "No LUT loaded"
  private(set) var lutFileName: String?
  private(set) var lutError: String?
  var lutLoaded = false
  var running = false
  var previewReady = false
  /// The selected camera's LUT is loading. Another camera's load doesn't block it.
  var loading: Bool { lutLoadingFeeds.contains(selectedFeedID) }
  var update = CaptureUpdate(message: "Select the UltraStudio input and start the camera. LUT loading is optional.")
  let installer: ExtensionInstaller
  let previewRenderer: VideoPreviewRenderer
  let miniPreviewRenderer: VideoPreviewRenderer
  // The selected feed owns the capture controller used by the app-level
  // controls. This used to be permanently bound to the primary controller,
  // which left selection changes publishing frames from the wrong feed.
  private var capture: CaptureController
  let monitorCoordinator: MonitorCoordinator
  private var monitorDemand: Set<MonitorTargetID> = []
  private var feedPolicies: [FeedID: AutomaticFeedPolicy] = [:]
  private var routeDemand: [String: Bool] = [:]
  private var demandStartedFeeds: Set<FeedID> = []
  private var manuallyStoppedFeeds: Set<FeedID> = []
  private var refusedStarts: Set<FeedID> = []
  private var programTransportRequired = false
  private var programTransportConfiguration: PipelineConfiguration?
  private var detectedInputCadence: [FeedID: Bool] = [:]
  /// The latest status from every camera, not just the selected one. The new
  /// interface shows live state for each camera's strip.
  private(set) var cameraUpdates: [FeedID: CaptureUpdate] = [:]
  /// Program cuts applied this session, newest first (bounded).
  private(set) var recentCuts: [UICutRecord] = []
  /// When the camera now on Program went on air.
  private(set) var programShotStartedAt: Date?
  /// Bumped whenever any camera starts or stops, so observers refresh even when
  /// the change happened in the (non-observable) capture coordinator.
  private(set) var cameraStateRevision = 0
  /// Set by `resetAllSettings()`; no further saves happen before the app quits.
  private(set) var settingsResetPending = false
  let recordingModel: RecordingModel
  private let feedCoordinator: FeedCoordinator
  private let settingsStore: AppSettingsStore
  private let virtualCameraRegistryStore: VirtualCameraRegistryStore
  private let lutLoader: LUTFileLoader
  private var restoringSettings = true
  private var lutBookmark: Data?
  private var rememberedLUTEnabled = false
  // LUT parsing and GPU uploads are asynchronous. Invalidate an operation
  // whenever a newer load for the same camera starts, so an old completion
  // cannot overwrite it. Each camera counts its own loads.
  private var lutLoadGenerations: [FeedID: UInt64] = [:]
  private var lutLoadingFeeds: Set<FeedID> = [] { didSet { expireResolvedStartRefusals() } }
  private let demandMonitor = CameraDemandMonitor()
  private var automaticPolicy = AutomaticFeedPolicy()
  private var persistedSnapshot = AppSettingsSnapshot()
  private var autoSwitcherBridge: AutoSwitcherBridge?
  private var autoSwitcherTimeline: AutoSwitcherTimelineRecorder?
  private var recordingTimelines: [FeedID: AutoSwitcherTimelineRecorder] = [:]
  private var pendingAutoDecisionID: UUID?
  private var pendingAutoTargetFeedID: FeedID?
  private var programMonitorTap: ProgramMonitorTap?
  /// A requested cut that did not land; cleared by the next cut.
  private var programCutIssue: String?
  /// Program frames dropped or not converted; cleared when the Program
  /// camera reconnects.
  private var programOutputIssue: String?
  /// Shown as the status warning in Program mode until cleared.
  var programIssue: String? { programCutIssue ?? programOutputIssue }
  /// Bumped when an asynchronous Program camera connect is superseded.
  private var programTransportRequestID: UInt64 = 0
  /// The camera on air when the Program client connected; its format is the
  /// session's contract.
  private var programContractOwner: FeedID?

  init(settingsStore: AppSettingsStore? = nil, lutLoader: LUTFileLoader = LUTFileLoader(),
       registryStore: VirtualCameraRegistryStore? = nil,
       registryPublisher: (any AppVirtualCameraRegistryPublishing)? = nil,
       recordingFolderStore: RecordingFolderStore? = nil, installer: ExtensionInstaller? = nil,
       hardware: AppHardware = .live) {
    self.hardware = hardware
    self.installer = installer ?? ExtensionInstaller()
    let store = settingsStore ?? AppSettingsStore()
    self.settingsStore = store
    self.registryPublisher = registryPublisher ?? VirtualCameraRegistryPublisher()
    hideFromDock = store.hideFromDock
    self.virtualCameraRegistryStore = registryStore ?? VirtualCameraRegistryStore()
    let snapshot = store.loadSnapshot()
    persistedSnapshot = snapshot
    monitorCoordinator = MonitorCoordinator(feeds: snapshot.feeds, program: snapshot.programMonitor,
      workspace: snapshot.monitorWorkspacePreferences)

    let renderer = VideoPreviewRenderer()
    let miniRenderer = VideoPreviewRenderer()
    let initialFeedID = snapshot.feeds.first(where: { $0.id == snapshot.selectedFeedID && $0.enabled })?.id
      ?? snapshot.feeds.first(where: \.enabled)?.id
      ?? snapshot.feeds[0].id
    let primaryCapture = CaptureController(services: hardware.captureServices(initialFeedID),
      previewRenderer: renderer, additionalPreviewRenderers: [miniRenderer])
    let capturePool = FeedCapturePool(initial: [initialFeedID: primaryCapture], factory: { feedID in
      let controller = CaptureController(services: hardware.captureServices(feedID), previewRenderer: renderer,
        additionalPreviewRenderers: [miniRenderer])
      controller.setLegacyPreviewOwnership(false)
      return controller
    })
    feedCoordinator = FeedCoordinator(snapshot: snapshot, capturePool: capturePool)
    let coordinator = feedCoordinator
    previewRenderer = renderer
    miniPreviewRenderer = miniRenderer
    renderer.bindSource(initialFeedID.rawValue)
    miniRenderer.bindSource(initialFeedID.rawValue)
    capture = primaryCapture
    recordingModel = RecordingModel(
      feeds: feedCoordinator.descriptors.map { RecordingFeedDescriptor(id: $0.id, name: $0.name) },
      driver: NativeRecordingSessionDriver(capture: primaryCapture, rawAudioCallbackAvailable: true,
        captureForFeed: { id in coordinator.capture(for: id) }),
      folderStore: recordingFolderStore ?? RecordingFolderStore())
    self.lutLoader = lutLoader
    monitorCoordinator.onConfigurationChange = { [weak self] target, configuration in
      guard let self else { return }
      // Merged, so MonitorKit settings the configuration cannot carry survive.
      if target.rawValue == "program" {
        self.feedCoordinator.programMonitor.merge(configuration)
      } else if var descriptor = self.feedDescriptors.first(where: { $0.id.rawValue == target.rawValue }) {
        descriptor.monitor.merge(configuration)
        self.feedCoordinator.update(descriptor)
      }
      self.saveSettings()
    }
    monitorCoordinator.onResetSettings = { [weak self] target in
      self?.replaceMonitorPreferences(of: target) { $0.resetTools() }
    }
    monitorCoordinator.onCopySettings = { [weak self] source, destination in
      guard let self, let tools = self.monitorPreferences(of: source) else { return nil }
      return self.replaceMonitorPreferences(of: destination) { $0.copyTools(from: tools) }
    }
    monitorCoordinator.onWorkspaceChange = { [weak self] workspace in
      guard let self else { return }
      self.feedCoordinator.monitorWorkspace = workspace
      self.saveSettings()
    }
    monitorCoordinator.onDemandChange = { [weak self] targets in
      guard let self else { return }
      self.monitorDemand = targets
      self.reconcileAutomaticFeed()
    }
    monitorCoordinator.onPreviewEnabledChange = { [weak self] target, enabled in
      guard let self else { return }
      if target.rawValue == self.selectedFeedID.rawValue {
        self.previewEnabled = enabled
      } else if var descriptor = self.feedDescriptors.first(where: { $0.id.rawValue == target.rawValue }) {
        descriptor.previewEnabled = enabled
        self.feedCoordinator.update(descriptor)
        self.saveSettings()
      }
    }
    // The Program route publishes from capture delivery threads; feed the
    // Program monitor from there too, never through the main actor.
    let programMonitorTap = ProgramMonitorTap(sink: monitorCoordinator.captureSink(for: MonitorTargetID("program")))
    self.programMonitorTap = programMonitorTap
    feedCoordinator.programOutput.onMonitorFrame = { _, frame, sourcePTS, _, cutApplied in
      programMonitorTap.offer(frame: frame, sourcePTS: sourcePTS, cutApplied: cutApplied)
    }
    monitorCoordinator.updateTargets(feeds: feedCoordinator.descriptors, programAvailable: snapshot.outputMode == .program)
    recordingModel.onOutputFolderChanged = { [weak self] folder in
      self?.autoSwitcherTimeline?.setOutputFolder(folder)
    }
    recordingModel.onRecordingStarted = { [weak self] feedID, url in
      guard let self else { return }
      self.reconcileAutomaticFeed()
      guard let timeline = self.autoSwitcherTimeline else { return }
      self.recordingTimelines[feedID] = timeline
      timeline.recordingStarted(feedID: feedID, url: url, mediaStart: self.update.mediaTime)
    }
    recordingModel.onRecordingFinished = { [weak self] feedID, url in
      guard let self else { return }
      self.reconcileAutomaticFeed()
      guard let timeline = self.recordingTimelines.removeValue(forKey: feedID) else { return }
      timeline.recordingFinished(feedID: feedID, url: url, mediaEnd: self.update.mediaTime)
    }
    feedCoordinator.onProgramCutAbandoned = { [weak self] feedID, reason in
      self?.programCutAbandoned(feedID, reason: reason)
    }
    feedCoordinator.onProgramOutputError = { [weak self] message in
      self?.programOutputIssue = message
      self?.update.message = message
    }
    feedCoordinator.onProgramCutApplied = { [weak self] feedID, sourceTime, programTime in
      self?.programCutIssue = nil
      self?.reconcileProgramTransportDemand()
      // The saved selection follows what is on air. Persist only the
      // snapshot: a cut changes no device, so the camera registry is untouched.
      self?.persistProgramSelection()
      if let self {
        let automatic = self.pendingAutoDecisionID != nil && self.pendingAutoTargetFeedID == feedID
        let name = self.feedDescriptors.first { $0.id == feedID }?.name ?? feedID.rawValue
        self.recentCuts.insert(UICutRecord(at: Date(), cameraID: feedID.rawValue, cameraName: name,
          automatic: automatic), at: 0)
        if self.recentCuts.count > 20 { self.recentCuts.removeLast(self.recentCuts.count - 20) }
        self.programShotStartedAt = Date()
      }
      guard let self, let decisionID = self.pendingAutoDecisionID,
        self.pendingAutoTargetFeedID == feedID else { return }
      self.pendingAutoDecisionID = nil
      self.pendingAutoTargetFeedID = nil
      self.autoSwitcherTimeline?.recordApplied(decisionID: decisionID, target: feedID,
        sourceTime: sourceTime, programTime: programTime)
      // The director clock is the selected input's audio time. The frame that
      // landed the cut has a different source's video PTS, so acknowledging
      // with that PTS moves the director onto the wrong timeline. Nil keeps
      // the shot start on the decision's own cut time.
      self.autoSwitcherBridge?.acknowledge(decisionID: decisionID, appliedAt: nil)
    }
    let savedFeed = snapshot.feeds.first(where: { $0.id == initialFeedID }) ?? FeedDescriptor()
    selectedDevice = savedFeed.selectedDevice
    configuration = savedFeed.configuration
    rememberedLUTEnabled = savedFeed.applyLUT
    // Saved intent is restored only after the file and GPU upload succeed.
    configuration.applyLUT = false
    gamut = savedFeed.gamut
    pipelineEnabled = savedFeed.pipelineEnabled
    previewEnabled = savedFeed.previewEnabled
    automaticFeedEnabled = savedFeed.automaticFeed
    lutBookmark = savedFeed.lutBookmark
    restoringSettings = false
    publishVirtualCameraRegistry(snapshot)
    capture.setPreviewEnabled(previewEnabled)
    demandMonitor.setRoutes(feedCoordinator.virtualCameraDescriptors)
    feedCoordinator.setCameraOutputEnabled(feedID: initialFeedID,
      enabled: snapshot.outputMode != .program)
    installProcessedFrameHandler(for: initialFeedID)
    installCaptureUpdateHandler(for: initialFeedID)
    let previewVisibilityChanged: () -> Void = { [weak self] in
      // Native visibility changes can arrive during SwiftUI layout. Read both
      // surfaces on the next main turn so replacing a view cannot stop a feed.
      Task { @MainActor [weak self] in self?.reconcileAutomaticFeed() }
    }
    previewRenderer.onVisibilityChange = previewVisibilityChanged
    miniPreviewRenderer.onVisibilityChange = previewVisibilityChanged
    refresh()
    // Hot-plug: arrivals and removals update the list without a manual refresh.
    deviceListObserver = hardware.observeDevices { [weak self] list in
      self?.applyDevices(list, fromDiscovery: true)
    }
    if let bookmark = lutBookmark { restoreLUT(bookmark: bookmark) }
    demandMonitor.onRouteChange = { [weak self] change in
      guard let self else { return }
      self.routeDemand[change.route.id] = change.requested == true
      if change.route.id == self.automaticDemandRouteID {
        self.cameraDemandError = change.error
        self.automaticPolicy.demand(change.requested == true)
      }
      self.reconcileAutomaticFeed()
    }
    if outputMode == .program || feedDescriptors.contains(where: \.automaticFeed) { demandMonitor.start() }
  }

  func refresh() {
    driverWarning = hardware.driverWarning()
    do {
      applyDevices(try hardware.devices(), fromDiscovery: false)
    } catch {
      applyDevices([], fromDiscovery: false)
      update.message = error.localizedDescription
    }
  }

  private func applyDevices(_ next: [InputDevice], fromDiscovery: Bool) {
    // Discovery reports every arrival, including devices already listed.
    if fromDiscovery, next.map(\.id) == devices.map(\.id), next.map(\.name) == devices.map(\.name) { return }
    devices = next
    // Discovery publishes after each arrival or removal, so its list can be
    // partial; it only fills an empty assignment and never moves one.
    if !running, !capture.hasActiveFeed, let first = devices.first,
      !fromDiscovery || selectedDevice.isEmpty,
      !devices.contains(where: { $0.id == selectedDevice }) {
      selectedDevice = first.id
    }
    if feedDescriptors.contains(where: \.automaticFeed), !restoringSettings {
      demandMonitor.refresh()
      reconcileAutomaticFeed()
    }
  }

  func chooseLUT(feedID: FeedID? = nil) {
    let feedID = feedID ?? selectedFeedID
    guard descriptor(for: feedID) != nil else { return }
    let panel = NSOpenPanel()
    panel.title = "Choose a LUT"
    panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    loadLUT(url: url, feedID: feedID)
  }

  /// Loads a chosen .cube file into one camera. Separate from the panel for tests.
  func loadLUT(url: URL, feedID: FeedID) {
    if feedID == selectedFeedID { lutError = nil }
    let loadGeneration = beginLUTLoad(feedID)
    Task { [weak self, lutLoader] in
      do {
        let loaded = try await lutLoader.load(url: url)
        self?.uploadLUT(loaded, enable: true, generation: loadGeneration, feedID: feedID)
      } catch { self?.lutLoadFailed(error, restoring: false, generation: loadGeneration, feedID: feedID) }
    }
  }

  private func restoreLUT(bookmark: Data) {
    lutError = nil
    update.message = "Restoring saved LUT…"
    let feedID = selectedFeedID
    let loadGeneration = beginLUTLoad(feedID)
    Task { [weak self, lutLoader] in
      do {
        let loaded = try await lutLoader.restore(bookmark: bookmark)
        guard let self else { return }
        self.uploadLUT(loaded, enable: self.descriptor(for: feedID)?.applyLUT == true, restoring: true,
          generation: loadGeneration, feedID: feedID)
      } catch { self?.lutLoadFailed(error, restoring: true, generation: loadGeneration, feedID: feedID) }
    }
  }

  /// Starts a LUT load for one camera and returns its generation. A newer load
  /// for the same camera supersedes it; other cameras' loads are unaffected.
  private func beginLUTLoad(_ feedID: FeedID) -> UInt64 {
    let generation = (lutLoadGenerations[feedID] ?? 0) &+ 1
    lutLoadGenerations[feedID] = generation
    lutLoadingFeeds.insert(feedID)
    return generation
  }

  /// Drops a camera's in-flight LUT load, if any.
  private func cancelLUTLoad(_ feedID: FeedID) {
    lutLoadGenerations[feedID] = (lutLoadGenerations[feedID] ?? 0) &+ 1
    lutLoadingFeeds.remove(feedID)
  }

  private func uploadLUT(_ loaded: LoadedLUT, enable: Bool, restoring: Bool = false,
                         generation: UInt64, feedID: FeedID) {
    let controller = feedCoordinator.capture(for: feedID)
    let controllerGeneration = controller.generationToken
    guard generation == lutLoadGenerations[feedID] else { return }
    // One MonitorLUT per load, on the shared device: the controller burns it in
    // and the monitor's feed shows the output stage with the same object.
    let lut: MonitorLUT
    do { lut = try LUTProcessor.makeLUT(loaded.cube) } catch {
      lutLoadFailed(error, restoring: restoring, generation: generation, feedID: feedID)
      return
    }
    controller.load(lut, expectedGeneration: controllerGeneration) { [weak self] result in
      MainActor.assumeIsolated {
        guard let self else { return }
        guard generation == self.lutLoadGenerations[feedID] else { return }
        switch result {
        case .success:
          self.lutLoadingFeeds.remove(feedID)
          let enable = restoring ? self.descriptor(for: feedID)?.applyLUT == true : enable
          guard feedID == self.selectedFeedID else {
            self.updateCamera(feedID) { descriptor in
              descriptor.lutBookmark = loaded.bookmark
              descriptor.applyLUT = enable
            }
            self.reconcileAutomaticFeed()
            return
          }
          self.lutError = nil
          self.lutLoaded = true
          self.lutBookmark = loaded.bookmark
          self.rememberedLUTEnabled = enable
          self.configuration.applyLUT = enable
          self.lutTitle = "\(loaded.cube.title) · \(loaded.cube.sizeDescription)"
          self.lutFileName = loaded.fileName
          self.saveSettings()
          self.update.message = "LUT loaded. Confirm it expects \(self.gamut) and outputs Rec.709."
          self.reconcileAutomaticFeed()
        case .failure(let error):
          self.lutLoadFailed(error, restoring: restoring, generation: generation, feedID: feedID)
        }
      }
    }
  }

  private func lutLoadFailed(_ error: Error, restoring: Bool, generation: UInt64, feedID: FeedID) {
    guard generation == lutLoadGenerations[feedID] else { return }
    lutLoadingFeeds.remove(feedID)
    let message = "\(restoring ? "Saved LUT could not be restored" : "LUT was not changed"): \(error.localizedDescription)"
    guard feedID == selectedFeedID else {
      var cameraUpdate = cameraUpdates[feedID] ?? CaptureUpdate(message: message)
      cameraUpdate.message = message
      cameraUpdates[feedID] = cameraUpdate
      reconcileAutomaticFeed()
      return
    }
    // Keep the last saved bookmark and an already-loaded LUT. A missing moved
    // file is recoverable by choosing it again; it does not erase preferences.
    if restoring { lutTitle = "Saved LUT unavailable" }
    // Selected mid-load, so selection skipped its restore and nothing is
    // applied; bring the saved LUT back rather than run without one.
    if !restoring, !lutLoaded, let bookmark = lutBookmark { restoreLUT(bookmark: bookmark) }
    lutError = message
    update.message = message
    reconcileAutomaticFeed()
  }

  /// Selects a feed and loads its persisted controls into the app-level
  /// bindings. Selection is a state transition, so pending edits on the
  /// previous feed are committed before the new descriptor is applied.
  @discardableResult
  func selectFeed(_ id: FeedID) -> Bool {
    guard feedCoordinator.descriptors.contains(where: { $0.id == id }) else { return false }
    saveSettings()
    guard feedCoordinator.select(id) else { return false }
    capture.setLegacyPreviewOwnership(false)
    capture = feedCoordinator.capture(for: id)
    previewRenderer.bindSource(id.rawValue)
    miniPreviewRenderer.bindSource(id.rawValue)
    capture.setLegacyPreviewOwnership(true)
    running = feedCoordinator.isFeedRunning(id)
    let descriptor = feedCoordinator.selectedDescriptor
    applySelectedDescriptor(descriptor)
    persistedSnapshot = feedCoordinator.snapshot
    settingsStore.saveSnapshot(persistedSnapshot)
    installCaptureUpdateHandler(for: id)
    installProcessedFrameHandler(for: id)
    return true
  }

  /// Adds an idle feed, persists the new topology, and selects it so the UI
  /// immediately edits the new feed's independent settings.
  @discardableResult
  func addFeed(name: String? = nil) -> FeedID? {
    guard canEditFeedTopology else { return nil }
    saveSettings()
    let id = feedCoordinator.add(name: name)
    syncRecordingFeeds()
    guard selectFeed(id) else { return nil }
    saveSettings()
    return id
  }

  /// Removes an idle feed and selects the first remaining descriptor when the
  /// removed feed was active. The coordinator owns the running/removal guard.
  @discardableResult
  func removeFeed(_ id: FeedID) -> Bool {
    guard canEditFeedTopology else { return false }
    let wasSelected = id == selectedFeedID
    saveSettings()
    guard feedCoordinator.remove(id) else { return false }
    syncRecordingFeeds()
    if wasSelected {
      capture.setLegacyPreviewOwnership(false)
      capture = feedCoordinator.capture(for: feedCoordinator.selectedFeedID)
      previewRenderer.bindSource(feedCoordinator.selectedFeedID.rawValue)
      miniPreviewRenderer.bindSource(feedCoordinator.selectedFeedID.rawValue)
      capture.setLegacyPreviewOwnership(true)
      applySelectedDescriptor(feedCoordinator.selectedDescriptor)
      installCaptureUpdateHandler(for: feedCoordinator.selectedFeedID)
      installProcessedFrameHandler(for: feedCoordinator.selectedFeedID)
    }
    persistedSnapshot = feedCoordinator.snapshot
    settingsStore.saveSnapshot(persistedSnapshot)
    demandMonitor.setRoutes(feedCoordinator.virtualCameraDescriptors)
    publishVirtualCameraRegistry(persistedSnapshot)
    monitorCoordinator.updateTargets(feeds: feedDescriptors, programAvailable: outputMode == .program)
    return true
  }

  @discardableResult
  func renameFeed(_ id: FeedID, name: String) -> Bool {
    guard canEditFeedTopology,
      let existing = feedCoordinator.descriptors.first(where: { $0.id == id }) else { return false }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    var updated = existing
    updated.name = trimmed
    feedCoordinator.update(updated)
    syncRecordingFeeds()
    saveSettings()
    return true
  }

  func setOutputMode(_ mode: FeedOutputMode) {
    guard canEditFeedTopology, feedCoordinator.outputMode != mode else { return }
    saveSettings()
    feedCoordinator.setOutputMode(mode)
    programCutIssue = nil
    if mode == .program { programMonitorTap?.restart() }
    saveSettings()
    installAutomaticFeedMonitor()
    reconcileAutoSwitcher()
  }

  /// Applies switcher controls atomically to the live Program route and its
  /// persisted snapshot. Invalid feed IDs are normalized by the coordinator.
  func updateSwitcher(_ settings: SwitcherSettings) {
    guard !restoringSettings else { return }
    // The Rust bridge is configured immutably at creation time. Recreate it
    // when a live setting changes so camera identities and timing thresholds
    // cannot diverge from the UI's persisted policy.
    if autoSwitcherBridge != nil { stopAutoSwitcher() }
    feedCoordinator.setSwitcher(settings)
    saveSettings()
    reconcileAutoSwitcher()
  }

  @discardableResult
  func requestProgramCut(to feedID: FeedID) -> ProgramCutRequestResult<FeedID> {
    let oldDecisionID = pendingAutoDecisionID
    let result = feedCoordinator.requestProgramCut(to: feedID)
    if case .rejectedMissingSource = result { return result }
    if let oldDecisionID {
      pendingAutoDecisionID = nil
      pendingAutoTargetFeedID = nil
      autoSwitcherTimeline?.recordRejected(decisionID: oldDecisionID)
      autoSwitcherBridge?.reject(decisionID: oldDecisionID)
    }
    switch result {
    case .queued, .coalesced, .selectedImmediately:
      autoSwitcherBridge?.manualOverride(cameraID: feedID, at: directorClock())
    case .ignoredSameSource, .rejectedMissingSource:
      break
    }
    saveSettings()
    return result
  }

  /// A requested cut that will not land. The selection never changed, so the
  /// UI already shows what is on air; say why the requested camera did not
  /// take, and release the director's decision so it can decide again.
  private func programCutAbandoned(_ feedID: FeedID, reason: ProgramCutAbandonReason) {
    let name = feedDescriptors.first { $0.id == feedID }?.name ?? feedID.rawValue
    let message: String
    switch reason {
    case .targetUnavailable:
      message = "Couldn't cut to \(name): it stopped or failed to start. Program stays on the current camera."
    case .expired:
      // Also a camera that opened but has no signal (bounded starting wait).
      message = "Couldn't cut to \(name): it sent no usable frame in time. Check its signal. Program stays on the current camera."
    }
    programCutIssue = message
    update.message = message
    if let decisionID = pendingAutoDecisionID, pendingAutoTargetFeedID == feedID {
      pendingAutoDecisionID = nil
      pendingAutoTargetFeedID = nil
      if reason == .expired { autoSwitcherTimeline?.recordExpired(decisionID: decisionID) }
      else { autoSwitcherTimeline?.recordRejected(decisionID: decisionID) }
      autoSwitcherBridge?.reject(decisionID: decisionID)
    }
  }

  private func persistProgramSelection() {
    guard !restoringSettings, !settingsResetPending else { return }
    persistedSnapshot = feedCoordinator.snapshot
    settingsStore.saveSnapshot(persistedSnapshot)
  }

  /// Audio packet time from the selected input. That is the clock the Rust
  /// director ticks, so manual cuts have to be expressed on it.
  private func directorClock() -> CMTime {
    update.audioPacketTime ?? update.mediaTime ?? .zero
  }

  private func applySelectedDescriptor(_ descriptor: FeedDescriptor) {
    restoringSettings = true
    selectedDevice = descriptor.selectedDevice
    configuration = descriptor.configuration
    rememberedLUTEnabled = descriptor.applyLUT
    configuration.applyLUT = false
    gamut = descriptor.gamut
    pipelineEnabled = descriptor.pipelineEnabled
    previewEnabled = descriptor.previewEnabled
    automaticFeedEnabled = descriptor.automaticFeed
    lutBookmark = descriptor.lutBookmark
    lutLoaded = false
    lutTitle = "No LUT loaded"
    lutFileName = nil
    lutError = nil
    restoringSettings = false
    // Assignments above ran while restoring, so the automatic-feed didSet
    // did not retarget the demand monitor. Do that after the new descriptor
    // is in place, then restore this feed's LUT, unless a load for it is
    // already in flight.
    if let bookmark = lutBookmark, !lutLoadingFeeds.contains(descriptor.id) { restoreLUT(bookmark: bookmark) }
    installAutomaticFeedMonitor()
    capture.setPreviewEnabled(previewEnabled)
  }

  /// Retargets camera demand and applies the selected feed's automatic mode.
  /// A visible preview also keeps capture alive in automatic mode.
  private func installAutomaticFeedMonitor() {
    cameraDemandError = nil
    demandMonitor.setRoutes(feedCoordinator.virtualCameraDescriptors)
    if outputMode == .program || feedDescriptors.contains(where: \.automaticFeed) { demandMonitor.start() }
    else { demandMonitor.stop() }
    reconcileAutomaticFeed()
  }

  func saveSettings() {
    guard !restoringSettings, !settingsResetPending else { return }
    let oldName = feedCoordinator.selectedDescriptor.name
    var monitor = feedCoordinator.selectedDescriptor.monitor
    if feedCoordinator.selectedDescriptor.selectedDevice != selectedDevice { monitor.forgetCameraCalibration() }
    let descriptor = FeedDescriptor(id: selectedFeedID, name: oldName, selectedDevice: selectedDevice,
      applyLUT: lutLoaded ? configuration.applyLUT : rememberedLUTEnabled,
      downscale: configuration.downscale, convertTo420: configuration.convertTo420,
      reduceFrameRate: configuration.reduceFrameRate, gamut: gamut,
      pipelineEnabled: pipelineEnabled, previewEnabled: previewEnabled, lutBookmark: lutBookmark,
      automaticFeed: automaticFeedEnabled, enabled: feedCoordinator.selectedDescriptor.enabled,
      monitor: monitor,
      legacyMonitorConfiguration: feedCoordinator.selectedDescriptor.legacyMonitorConfiguration)
    feedCoordinator.update(descriptor)
    persistedSnapshot = feedCoordinator.snapshot
    settingsStore.saveSnapshot(persistedSnapshot)
    demandMonitor.setRoutes(feedCoordinator.virtualCameraDescriptors)
    publishVirtualCameraRegistry(persistedSnapshot)
    monitorCoordinator.updateTargets(feeds: feedDescriptors, programAvailable: outputMode == .program)
  }

  /// The monitor preferences of a feed or Program, nil for an unknown target.
  private func monitorPreferences(of target: MonitorTargetID) -> MonitorFeedPreferences? {
    if target.rawValue == "program" { return feedCoordinator.programMonitor }
    return feedDescriptors.first(where: { $0.id.rawValue == target.rawValue })?.monitor
  }

  /// Changes a target's whole monitor preferences (reset, copy), saves them and
  /// returns what its monitors now show; nil for an unknown target.
  private func replaceMonitorPreferences(
    of target: MonitorTargetID, _ change: (inout MonitorFeedPreferences) -> Void
  ) -> LegacyMonitorConfiguration? {
    if target.rawValue == "program" {
      change(&feedCoordinator.programMonitor)
    } else if var descriptor = feedDescriptors.first(where: { $0.id.rawValue == target.rawValue }) {
      change(&descriptor.monitor)
      feedCoordinator.update(descriptor)
    } else {
      return nil
    }
    saveSettings()
    return monitorPreferences(of: target)?.legacyConfiguration
  }

  private func syncRecordingFeeds() {
    recordingModel.updateFeeds(feedCoordinator.descriptors.map {
      RecordingFeedDescriptor(id: $0.id, name: $0.name)
    })
  }

  /// Publishes the complete feed topology in one transaction. The camera
  /// extension receives it through CMIO and retains existing devices until
  /// their clients release them during reconciliation.
  private func publishVirtualCameraRegistry(_ snapshot: AppSettingsSnapshot) {
    let previous = virtualCameraRegistryStore.load()
    let candidate = VirtualCameraRegistrySnapshot.forFeeds(snapshot.feeds,
      outputMode: snapshot.outputMode, previous: previous)
    do {
      try virtualCameraRegistryStore.save(candidate)
      registryPublisher.publish(candidate)
    } catch {
      update.message = "Virtual cameras could not be updated: \(error.localizedDescription)"
    }
  }

  private var effectiveConfiguration: PipelineConfiguration {
    var snapshot = configuration
    snapshot.applyLUT = snapshot.applyLUT && lutLoaded
    return snapshot
  }

  private func reconfigure() {
    update.pipelineEnabledApplied = nil
    update.output = ""
    capture.reconfigure(configuration: effectiveConfiguration, pipelineEnabled: pipelineEnabled)
    reconcileProgramTransportDemand()
  }

  var canStartFeed: Bool {
    !running && !loading && devices.contains { $0.id == selectedDevice }
  }

  func start() {
    manuallyStoppedFeeds.remove(selectedFeedID)
    if automaticFeedEnabled { retryAutomaticFeed() } else { startFeed() }
    noteStartAttempt(selectedFeedID, started: running)
  }

  /// Remembers a Start that didn't start the camera, so its strip can say why
  /// instead of doing nothing. Starting or stopping the camera clears it.
  private func noteStartAttempt(_ id: FeedID, started: Bool) {
    if started { refusedStarts.remove(id) } else if refusedStarts.insert(id).inserted { cameraStateRevision &+= 1 }
  }

  /// A refusal whose cause has gone stays gone; a later, unrelated outage
  /// must not show "Couldn't start" for a Start pressed long before.
  private func expireResolvedStartRefusals() {
    let resolved = refusedStarts.filter { startRefusal($0) == nil }
    guard !resolved.isEmpty else { return }
    refusedStarts.subtract(resolved)
    cameraStateRevision &+= 1
  }

  /// Why the camera's last Start didn't start it, while that still holds.
  func startRefusal(_ id: FeedID) -> String? {
    guard refusedStarts.contains(id), let descriptor = descriptor(for: id), !feedCoordinator.isFeedRunning(id) else { return nil }
    if id == selectedFeedID && automaticFeedEnabled { return automaticFeedStatus }
    if id == selectedFeedID && loading { return "Its LUT is still loading. Start it again in a moment." }
    if !devices.contains(where: { $0.id == descriptor.selectedDevice }) { return driverWarning ?? "Connect the UltraStudio." }
    return nil
  }

  private func startFeed() {
    guard canStartFeed else { return }
    if feedCoordinator.outputMode == .program {
      // Start every configured source that has a device assignment. The
      // selected feed keeps the existing preview controller; additional
      // sources run headless and publish only into the Program route.
      for descriptor in feedCoordinator.descriptors where descriptor.enabled &&
        descriptor.id != selectedFeedID && !descriptor.selectedDevice.isEmpty &&
        !manuallyStoppedFeeds.contains(descriptor.id) &&
        (!automaticFeedEnabled || descriptor.automaticFeed) {
        if automaticFeedEnabled { demandStartedFeeds.insert(descriptor.id) }
        installCaptureUpdateHandler(for: descriptor.id)
        installProcessedFrameHandler(for: descriptor.id)
        feedCoordinator.setProgramSourceHealth(descriptor.id, healthy: true)
        feedCoordinator.setCameraOutputEnabled(feedID: descriptor.id, enabled: false)
        // Apply LUT stays off until this controller has its own cube. The
        // saved flag alone makes the first frame fail with "Load a LUT".
        var headlessConfiguration = descriptor.configuration
        let applySavedLUT = headlessConfiguration.applyLUT
        headlessConfiguration.applyLUT = false
        detectedInputCadence[descriptor.id] = nil
        _ = feedCoordinator.startCapture(feedID: descriptor.id,
          deviceID: descriptor.selectedDevice, configuration: headlessConfiguration,
          pipelineEnabled: descriptor.pipelineEnabled, previewEnabled: false)
        if applySavedLUT, let bookmark = descriptor.lutBookmark {
          restoreHeadlessLUT(feedID: descriptor.id, bookmark: bookmark,
            pipelineEnabled: descriptor.pipelineEnabled)
        }
      }
    }
    guard feedCoordinator.start(selectedFeedID) else { return }
    running = true
    previewReady = false
    update = CaptureUpdate(message: "Opening UltraStudio…")
    if feedCoordinator.outputMode == .program {
      feedCoordinator.setProgramSourceHealth(selectedFeedID, healthy: true)
      feedCoordinator.setCameraOutputEnabled(feedID: selectedFeedID, enabled: false)
      reconcileAutoSwitcher()
    } else {
      feedCoordinator.setCameraOutputEnabled(feedID: selectedFeedID, enabled: true)
    }
    detectedInputCadence[selectedFeedID] = nil
    capture.start(feedID: selectedFeedID, deviceID: selectedDevice, configuration: effectiveConfiguration,
      pipelineEnabled: pipelineEnabled, previewEnabled: previewEnabled)
    reconcileProgramTransportDemand()
  }

  func stop() {
    manuallyStoppedFeeds.insert(selectedFeedID)
    refusedStarts.remove(selectedFeedID)
    running = false
    previewReady = false
    feedCoordinator.stop(selectedFeedID)
    demandStartedFeeds.remove(selectedFeedID)
    recordingModel.stop(feedID: selectedFeedID)
    reconcileProgramTransportDemand()
    stopAutoSwitcher()
  }

  private func reconcileAutoSwitcher() {
    guard feedCoordinator.outputMode == .program,
      running,
      feedCoordinator.switcherCoordinator.settings.naturalTalkingHead.enabled,
      feedCoordinator.switcherCoordinator.settings.automatic,
      feedCoordinator.switcherCoordinator.settings.strategy == .naturalTalkingHead else {
      stopAutoSwitcher()
      return
    }
    var settings = feedCoordinator.switcherCoordinator.settings.naturalTalkingHead
    settings.normalizeForRuntime()
    let feeds = feedCoordinator.descriptors.filter {
      $0.enabled && !$0.selectedDevice.isEmpty && feedCoordinator.isFeedRunning($0.id)
    }
    let enabledIDs = Set(feeds.map(\.id))
    let anchor = settings.anchorFeedID.flatMap { enabledIDs.contains($0) ? $0 : nil }
      ?? feeds.first?.id
    let emphasis = settings.emphasisFeedID.flatMap { enabledIDs.contains($0) ? $0 : nil }
      ?? feeds.first(where: { $0.id != anchor })?.id
    guard let anchor, let emphasis, anchor != emphasis else {
      stopAutoSwitcher()
      return
    }
    if autoSwitcherBridge != nil { return }
    guard let bridge = AutoSwitcherBridge(settings: settings, anchor: anchor, emphasis: emphasis) else {
      update.message = "Natural Talking Head could not start its Rust director."
      return
    }
    autoSwitcherTimeline = AutoSwitcherTimelineRecorder(settings: settings, anchor: anchor,
      emphasis: emphasis, outputFolder: recordingModel.outputFolder)
    guard let timeline = autoSwitcherTimeline else { return }
    timeline.onError = { [weak self] message in
      self?.update.message = "Auto-switcher timeline: \(message)"
    }
    bridge.onAudioCue = { [weak self, weak timeline, weak bridge] cue in
      Task { @MainActor in
        guard let self, let bridge, self.autoSwitcherBridge === bridge else { return }
        timeline?.recordAudioCue(cue)
      }
    }
    bridge.onTranscriptCue = { [weak self, weak timeline, weak bridge] cue in
      Task { @MainActor in
        guard let self, let bridge, self.autoSwitcherBridge === bridge else { return }
        timeline?.recordTranscript(cue)
      }
    }
    bridge.onInstruction = { [weak self, weak bridge] instruction in
      Task { @MainActor [weak self] in
        guard let self, self.autoSwitcherBridge === bridge, self.running,
          self.feedCoordinator.outputMode == .program else { return }
        self.autoSwitcherTimeline?.recordInstruction(instruction,
          from: self.switcherSelectedFeedID)
        // `cutTime` is on the director's audio clock, not on the target
        // camera's video PTS. Using it as a frame bound waits for a timestamp
        // the target will never reach and drops the current program source.
        let result = self.feedCoordinator.requestProgramCut(to: instruction.targetCameraID,
          noEarlierThan: nil)
        switch result {
        case .queued, .coalesced:
          self.pendingAutoDecisionID = instruction.decisionID
          self.pendingAutoTargetFeedID = instruction.targetCameraID
        case .ignoredSameSource, .rejectedMissingSource, .selectedImmediately:
          self.autoSwitcherTimeline?.recordRejected(decisionID: instruction.decisionID)
          bridge?.reject(decisionID: instruction.decisionID)
        }
      }
    }
    bridge.onError = { [weak self, weak bridge] message in
      Task { @MainActor [weak self] in
        guard let self, let bridge, self.autoSwitcherBridge === bridge else { return }
        self.autoSwitcherTimeline?.recordError(message)
        self.update.message = "Auto director: \(message)"
      }
    }
    bridge.onDecisionExpired = { [weak self, weak bridge] decisionID in
      Task { @MainActor [weak self] in
        guard let self, let bridge, self.autoSwitcherBridge === bridge,
          self.pendingAutoDecisionID == decisionID else { return }
        self.pendingAutoDecisionID = nil
        self.pendingAutoTargetFeedID = nil
        self.autoSwitcherTimeline?.recordExpired(decisionID: decisionID)
        self.feedCoordinator.cancelProgramCut()
      }
    }
    autoSwitcherBridge = bridge
    if let current = feedCoordinator.programOutput.selectedFeedID,
      (current == anchor || current == emphasis) {
      bridge.manualOverride(cameraID: current, at: update.mediaTime ?? .zero)
    }
  }

  private func stopAutoSwitcher() {
    pendingAutoDecisionID = nil
    pendingAutoTargetFeedID = nil
    // Stopping or reconfiguring the director must not leave its queued target
    // in the Program scheduler to switch after the UI has disabled automation.
    feedCoordinator.cancelProgramCut()
    autoSwitcherBridge?.stop()
    autoSwitcherBridge = nil
    autoSwitcherTimeline?.finish()
    autoSwitcherTimeline = nil
  }

  private func feedAutoSwitcherAudio(_ update: CaptureUpdate) {
    guard feedCoordinator.outputMode == .program,
      let time = update.mediaTime ?? update.audioPacketTime else { return }
    if autoSwitcherBridge == nil {
      _ = feedCoordinator.evaluateSwitcher(at: time)
      return
    }
    if update.audioPresent {
      autoSwitcherBridge?.ingestAudio(time: update.audioPacketTime ?? time,
        rms: Float(max(update.audioRMSLeft, update.audioRMSRight)),
        peak: Float(max(update.audioPeakLeft, update.audioPeakRight)),
        present: true)
    } else {
      autoSwitcherTimeline?.recordTick(time: time)
      autoSwitcherBridge?.tick(time: time)
    }
  }

  /// Delivers a timestamped ASR boundary to the active transcript-assisted
  /// director.  The app currently has no built-in speech recognizer, so an
  /// ASR adapter can call this entry point from its own callback pipeline.
  /// Validation and queue handoff are owned by `AutoSwitcherBridge`.
  @MainActor
  func ingestAutoSwitcherTranscript(segmentID: String, revision: UInt32,
                                    start: CMTime, end: CMTime, kind: String,
                                    confidence: Float, isFinal: Bool) {
    guard feedCoordinator.outputMode == .program, running,
      let bridge = autoSwitcherBridge else { return }
    bridge.ingestTranscript(segmentID: segmentID, revision: revision, start: start,
      end: end, kind: kind, confidence: confidence, isFinal: isFinal)
  }

  /// Routes status updates from the currently selected controller into the
  /// app model. Controllers can outlive a selection change while their stop
  /// work drains, so stale updates are ignored by feed identity.
  private func installCaptureUpdateHandler(for feedID: FeedID) {
    let controller = feedCoordinator.capture(for: feedID)
    controller.setLegacyPreviewOwnership(feedID == selectedFeedID)
    controller.setMonitorSink(monitorCoordinator.captureSink(for: MonitorTargetID(feedID.rawValue)))
    controller.onUpdate = { [weak self] update in
      MainActor.assumeIsolated {
        guard let self, self.feedDescriptors.contains(where: { $0.id == feedID }) else { return }
        self.cameraUpdates[feedID] = update
        if update.stopped {
          self.cameraStateRevision &+= 1
          self.monitorCoordinator.sourceStateChanged(target: MonitorTargetID(feedID.rawValue), running: false, message: update.message)
          self.detectedInputCadence[feedID] = nil
          self.feedCoordinator.stopCapture(feedID: feedID)
          if self.selectedFeedID == feedID {
            self.recordingModel.stop(feedID: feedID)
            self.retireProgramSource(feedID)
            self.running = false
            self.previewReady = false
            self.stopAutoSwitcher()
          } else {
            // A headless Program source can fail independently. Stop only its
            // recording; stopping the director here would take the surviving
            // cameras off automatic cuts while they are still live.
            self.recordingModel.stop(feedID: feedID)
            self.retireProgramSource(feedID)
          }
          self.reconcileProgramTransportDemand()
          return
        }
        if let inputFast = update.inputFast, self.detectedInputCadence[feedID] != inputFast {
          self.detectedInputCadence[feedID] = inputFast
          self.reconcileProgramTransportDemand()
        }
        guard self.selectedFeedID == feedID else { return }
        self.update = update
        self.feedAutoSwitcherAudio(update)
        let previewReady = self.previewEnabled && update.previewDelivered
        if self.previewReady != previewReady { self.previewReady = previewReady }
        if let inputFast = update.inputFast, self.configuration.inputFast != inputFast {
          self.restoringSettings = true
          self.configuration.inputFast = inputFast
          self.restoringSettings = false
        }
      }
    }
  }

  /// Loads one non-selected feed's saved LUT into that feed's controller, then
  /// enables Apply LUT. The camera is already running without the LUT.
  private func restoreHeadlessLUT(feedID: FeedID, bookmark: Data, pipelineEnabled: Bool) {
    let controller = feedCoordinator.capture(for: feedID)
    let generation = controller.generationToken
    Task { [weak self, lutLoader] in
      let loaded: LoadedLUT
      do { loaded = try await lutLoader.restore(bookmark: bookmark) }
      catch {
        await MainActor.run { [weak self] in
          self?.headlessLUTRestoreFailed(error, feedID: feedID, bookmark: bookmark, generation: generation)
        }
        return
      }
      await MainActor.run { [weak self] in
        guard let self, self.feedCoordinator.isFeedRunning(feedID),
          controller.generationToken == generation,
          let descriptor = self.feedCoordinator.descriptors.first(where: { $0.id == feedID }),
          descriptor.lutBookmark == bookmark, descriptor.applyLUT else { return }
        // One MonitorLUT per load, on the shared device (see uploadLUT).
        let lut: MonitorLUT
        do { lut = try LUTProcessor.makeLUT(loaded.cube) } catch {
          self.headlessLUTRestoreFailed(error, feedID: feedID, bookmark: bookmark, generation: generation)
          return
        }
        controller.load(lut, expectedGeneration: generation) { [weak self] result in
          MainActor.assumeIsolated {
            guard let self else { return }
            if case .failure(let error) = result {
              self.headlessLUTRestoreFailed(error, feedID: feedID, bookmark: bookmark, generation: generation)
              return
            }
            guard self.feedCoordinator.isFeedRunning(feedID),
              controller.generationToken == generation,
              let descriptor = self.feedCoordinator.descriptors.first(where: { $0.id == feedID }),
              descriptor.lutBookmark == bookmark, descriptor.applyLUT else { return }
            var configuration = descriptor.configuration
            if let detected = self.detectedInputCadence[feedID] { configuration.inputFast = detected }
            configuration.applyLUT = true
            self.feedCoordinator.reconfigureCapture(feedID: feedID,
              configuration: configuration, pipelineEnabled: descriptor.pipelineEnabled)
          }
        }
      }
    }
  }

  private func headlessLUTRestoreFailed(_ error: Error, feedID: FeedID, bookmark: Data, generation: UInt64) {
    guard feedCoordinator.isFeedRunning(feedID),
      feedCoordinator.capture(for: feedID).generationToken == generation,
      let descriptor = descriptor(for: feedID),
      descriptor.lutBookmark == bookmark, descriptor.applyLUT else { return }
    updateCamera(feedID) { $0.applyLUT = false }
    let message = "Saved LUT could not be restored: \(error.localizedDescription)"
    var cameraUpdate = cameraUpdates[feedID] ?? CaptureUpdate(message: message)
    cameraUpdate.message = message
    cameraUpdates[feedID] = cameraUpdate
    if feedID == selectedFeedID {
      lutError = message
      update.message = message
    }
  }

  /// Removes one failed source from Program eligibility without ending the
  /// session. The director hears the same health change on its next tick.
  private func retireProgramSource(_ feedID: FeedID) {
    feedCoordinator.setProgramSourceHealth(feedID, healthy: false)
    // `self.update` is the selected input, which owns the director clock.
    // The stopped source's own timestamps are cleared and must not be used.
    // A zero sample still records health without moving that clock backward.
    autoSwitcherBridge?.setCameraHealth(cameraID: feedID, healthy: false, at: directorClock())
  }

  private func installProcessedFrameHandler(for feedID: FeedID) {
    // Frames go from the capture delivery thread straight into the Program
    // route (and from there to the Program camera); none pass through here.
    feedCoordinator.installProgramFrameDelivery(feedID: feedID)
  }

  var cameraRequested: Bool { automaticPolicy.requested }
  var automaticCaptureRequested: Bool { automaticPolicy.captureRequested }

  private var automaticDemandRouteID: String {
    if feedCoordinator.outputMode == .program {
      return VirtualCameraDescriptor.program().id
    }
    return VirtualCameraDescriptor.feed(feedID: selectedFeedID.rawValue).id
  }

  var automaticFeedStatus: String {
    if running {
      if !demandStartedFeeds.contains(selectedFeedID) { return "Camera is running. It stays up until Stop." }
      return cameraRequested
        ? "Camera in use. Hide preview without interrupting camera output."
        : "Preview is live. Hide it to stop capture until a camera app needs it."
    }
    if let cameraDemandError { return cameraDemandError }
    if !automaticCaptureRequested { return "Waiting for a camera app or visible preview. Capture and video processing are off." }
    if loading { return "Restoring your LUT…" }
    if !devices.contains(where: { $0.id == selectedDevice }) { return driverWarning ?? "Connect the UltraStudio." }
    return "Camera stopped. Retry to resume preview or camera output."
  }

  func retryAutomaticFeed(feedID: FeedID? = nil) {
    let id = feedID ?? selectedFeedID
    manuallyStoppedFeeds.remove(id)
    var policy = feedPolicies[id] ?? AutomaticFeedPolicy()
    policy.retry()
    feedPolicies[id] = policy
    if id == selectedFeedID { automaticPolicy = policy }
    programTransportRequired = false
    programTransportConfiguration = nil
    // `start()` is idempotent while the monitor is healthy, and retries the
    // listener registration after an initial setup failure. `refresh()` alone
    // is a no-op in that failed state because the monitor is disabled there.
    demandMonitor.start()
    demandMonitor.refresh()
    reconcileAutomaticFeed()
  }

  private func reconcileAutomaticFeed() {
    let programRequested = monitorDemand.contains(MonitorTargetID("program")) ||
      routeDemand[VirtualCameraDescriptor.program().id] == true ||
      (outputMode == .program && previewEnabled &&
        (previewRenderer.isPresented || miniPreviewRenderer.isPresented)) ||
      (outputMode == .program && running && !demandStartedFeeds.contains(selectedFeedID))
    for descriptor in feedDescriptors where descriptor.enabled {
      let id = descriptor.id
      if !FeedLifecycleDemandPolicy.retainsAutomaticOwnership(automaticEnabled: descriptor.automaticFeed,
        wasAutomaticallyStarted: demandStartedFeeds.contains(id)) {
        demandStartedFeeds.remove(id)
      }
      let recording = recordingModel.feeds.contains {
        $0.id == id && ($0.status == .recording || $0.status == .paused)
      }
      var policy = feedPolicies[id] ?? AutomaticFeedPolicy()
      let camera = routeDemand[VirtualCameraDescriptor.feed(feedID: id.rawValue).id] == true
      policy.demand(camera || (outputMode == .program && programRequested) || recording)
      let legacyVisible = id == selectedFeedID && descriptor.previewEnabled &&
        (previewRenderer.isPresented || miniPreviewRenderer.isPresented)
      policy.previewDemand(legacyVisible || (descriptor.previewEnabled && monitorDemand.contains(MonitorTargetID(id.rawValue))))
      let isRunning = feedCoordinator.isFeedRunning(id)
      let ready = FeedLifecycleDemandPolicy.canStartSource(automaticEnabled: descriptor.automaticFeed,
        manuallyStopped: manuallyStoppedFeeds.contains(id),
        deviceAvailable: devices.contains { $0.id == descriptor.selectedDevice },
        loading: id == selectedFeedID && loading)
      let action = policy.action(ready: ready && (id != selectedFeedID || canStartFeed), running: isRunning)
      feedPolicies[id] = policy
      if id == selectedFeedID { automaticPolicy = policy }
      switch action {
      case .start:
        demandStartedFeeds.insert(id)
        refusedStarts.remove(id)
        if id == selectedFeedID { startFeed() }
        else {
          installCaptureUpdateHandler(for: id)
          installProcessedFrameHandler(for: id)
          feedCoordinator.setProgramSourceHealth(id, healthy: true)
          feedCoordinator.setCameraOutputEnabled(feedID: id, enabled: outputMode != .program)
          var configuration = descriptor.configuration
          configuration.applyLUT = false
          detectedInputCadence[id] = nil
          _ = feedCoordinator.startCapture(feedID: id, deviceID: descriptor.selectedDevice,
            configuration: configuration, pipelineEnabled: descriptor.pipelineEnabled, previewEnabled: false)
          if descriptor.applyLUT, let bookmark = descriptor.lutBookmark {
            restoreHeadlessLUT(feedID: id, bookmark: bookmark, pipelineEnabled: descriptor.pipelineEnabled)
          }
        }
      case .stop:
        guard demandStartedFeeds.contains(id), !recording else { continue }
        demandStartedFeeds.remove(id)
        feedCoordinator.stopCapture(feedID: id)
        monitorCoordinator.sourceStateChanged(target: MonitorTargetID(id.rawValue), running: false, message: "Waiting for demand")
        if id == selectedFeedID {
          running = false; previewReady = false
          if outputMode == .program { stopAutoSwitcher() }
        }
      case nil: break
      }
    }
    reconcileProgramTransportDemand()
  }

  /// Program transport follows its camera clients and the actual on-air source,
  /// which can be a headless feed while another feed owns the settings controls.
  private func reconcileProgramTransportDemand() {
    let producerID = feedCoordinator.programOutput.selectedFeedID
    let producer = feedDescriptors.first { $0.id == producerID && $0.enabled }
    let required = FeedLifecycleDemandPolicy.programTransportRequired(
      programMode: outputMode == .program,
      cameraRequested: routeDemand[VirtualCameraDescriptor.program().id] == true,
      onAirProducerRunning: producer.map { feedCoordinator.isFeedRunning($0.id) } ?? false)
    let sourceConfiguration = producerID == selectedFeedID ? effectiveConfiguration :
      (producer?.configuration ?? effectiveConfiguration)
    let contract = FeedLifecycleDemandPolicy.programContract(configuration: sourceConfiguration,
      pipelineEnabled: producer?.pipelineEnabled ?? pipelineEnabled,
      detectedInputFast: producerID.flatMap { detectedInputCadence[$0] })
    // One contract per client session: the format of the camera on air when
    // the client connected (its "owner"). Cuts never renegotiate; frames from
    // cameras with other settings are converted on the GPU. Only the owner's
    // own changes (input cadence detected after connect, or its settings
    // edited) renegotiate, as before. The cadence update reaches the main
    // actor after the first frame may already have been sent, so the bridge
    // honours `renegotiate` even after delivery.
    let renegotiate: Bool
    if required != programTransportRequired {
      renegotiate = false
      // A new client session: report the next Program output failure afresh.
      programOutputIssue = nil
      feedCoordinator.programOutput.acknowledgeOutputError()
      programContractOwner = required ? producerID : nil
    } else if required, producerID == programContractOwner, contract != programTransportConfiguration {
      renegotiate = true
    } else {
      return
    }
    programTransportRequired = required
    programTransportConfiguration = required ? contract : nil
    programTransportRequestID &+= 1
    let requestID = programTransportRequestID
    // CMIO discovery can take seconds: connect on the bridge's control queue.
    feedCoordinator.requestProgramOutputDemand(required, configuration: contract,
      passthroughFormat: kCVPixelFormatType_422YpCbCr10, renegotiate: renegotiate) { [weak self] error in
      guard let self, let error, requestID == self.programTransportRequestID else { return }
      // Let the next reconcile retry the connection.
      self.programTransportRequired = false
      self.programTransportConfiguration = nil
      self.programContractOwner = nil
      self.update.message = "Program camera unavailable: \(error.localizedDescription)"
    }
  }

  /// Program output counters for diagnostics: route, GPU conversion, camera.
  var programOutputDiagnostics: (route: ProgramRouteStatistics, camera: ProgramOutputBridge.Statistics,
                                 gpu: ProgramNormalizer.Statistics?, contract: ProgramOutputFormat?) {
    (feedCoordinator.programRouteStatistics, feedCoordinator.programOutputStatistics,
     feedCoordinator.programNormalizerStatistics, feedCoordinator.programOutput.contract)
  }

  func resetPreview() {
    previewRenderer.flush()
    miniPreviewRenderer.flush()
  }

  // MARK: - Per-camera control (new interface)

  func descriptor(for id: FeedID) -> FeedDescriptor? { feedDescriptors.first { $0.id == id } }

  /// Automatic mode asked this camera to run and it isn't running: its start failed.
  /// The interface offers Retry (one attempt per camera session, no background loop).
  func automaticStartFailed(_ id: FeedID) -> Bool {
    if startRefusal(id) != nil { return true }
    guard let descriptor = descriptor(for: id), descriptor.automaticFeed, !feedCoordinator.isFeedRunning(id) else { return false }
    return feedPolicies[id]?.captureRequested == true || (id == selectedFeedID && automaticCaptureRequested && !running)
  }

  func isCameraRunning(_ id: FeedID) -> Bool { feedCoordinator.isFeedRunning(id) }

  /// Cached device facts and live counters for the camera's input; never
  /// calls into the driver.
  func deviceDiagnostics(_ id: FeedID) -> UltracamDeviceDiagnostics? {
    guard let deviceID = descriptor(for: id)?.selectedDevice, !deviceID.isEmpty else { return nil }
    return hardware.diagnostics(deviceID)
  }

  /// The latest status for any camera. The selected camera uses the app's live `update`.
  func cameraUpdate(_ id: FeedID) -> CaptureUpdate? { id == selectedFeedID && running ? update : cameraUpdates[id] }

  /// Program mode: the "Ultracam · Program" virtual camera has at least one client.
  var programInUse: Bool { routeDemand[VirtualCameraDescriptor.program().id] == true }

  /// Separate mode: this camera's virtual camera has at least one client.
  func cameraInUse(_ id: FeedID) -> Bool {
    routeDemand[VirtualCameraDescriptor.feed(feedID: id.rawValue).id] == true
  }

  /// Starts one camera without changing the selection. The selected camera
  /// uses the established path; others start headless, like Program sources.
  func startCamera(_ id: FeedID) {
    guard let descriptor = descriptor(for: id), descriptor.enabled else { return }
    if id == selectedFeedID { start(); return }
    guard !feedCoordinator.isFeedRunning(id) else { return }
    guard devices.contains(where: { $0.id == descriptor.selectedDevice }) else {
      noteStartAttempt(id, started: false)
      return
    }
    noteStartAttempt(id, started: true)
    manuallyStoppedFeeds.remove(id)
    installCaptureUpdateHandler(for: id)
    installProcessedFrameHandler(for: id)
    feedCoordinator.setProgramSourceHealth(id, healthy: true)
    feedCoordinator.setCameraOutputEnabled(feedID: id, enabled: outputMode != .program)
    var configuration = descriptor.configuration
    configuration.applyLUT = false
    detectedInputCadence[id] = nil
    _ = feedCoordinator.startCapture(feedID: id, deviceID: descriptor.selectedDevice,
      configuration: configuration, pipelineEnabled: descriptor.pipelineEnabled, previewEnabled: false)
    if descriptor.applyLUT, let bookmark = descriptor.lutBookmark {
      restoreHeadlessLUT(feedID: id, bookmark: bookmark, pipelineEnabled: descriptor.pipelineEnabled)
    }
    cameraStateRevision &+= 1
    reconcileProgramTransportDemand()
  }

  /// Stops one camera: capture, its output and its recording. Other cameras keep running.
  func stopCamera(_ id: FeedID) {
    if id == selectedFeedID { stop(); return }
    refusedStarts.remove(id)
    guard feedCoordinator.isFeedRunning(id) else { return }
    manuallyStoppedFeeds.insert(id)
    demandStartedFeeds.remove(id)
    recordingModel.stop(feedID: id)
    feedCoordinator.stopCapture(feedID: id)
    if outputMode == .program { retireProgramSource(id) }
    monitorCoordinator.sourceStateChanged(target: MonitorTargetID(id.rawValue), running: false, message: "Camera stopped")
    cameraUpdates[id] = nil
    cameraStateRevision &+= 1
    reconcileProgramTransportDemand()
  }

  func startAllCameras() {
    if !running { start() }
    for descriptor in feedDescriptors where descriptor.enabled && descriptor.id != selectedFeedID &&
      !descriptor.selectedDevice.isEmpty {
      startCamera(descriptor.id)
    }
  }

  func stopAllCameras() {
    for descriptor in feedDescriptors where descriptor.id != selectedFeedID && feedCoordinator.isFeedRunning(descriptor.id) {
      stopCamera(descriptor.id)
    }
    if running { stop() }
  }

  /// Edits one camera's saved settings and applies them to its running
  /// capture, without changing the selection. The selected camera goes
  /// through the existing bindings so their side effects still run.
  func updateCamera(_ id: FeedID, _ mutate: (inout FeedDescriptor) -> Void) {
    guard var descriptor = descriptor(for: id) else { return }
    let before = descriptor
    mutate(&descriptor)
    guard descriptor != before else { return }
    if id == selectedFeedID {
      if descriptor.applyLUT != before.applyLUT { rememberedLUTEnabled = descriptor.applyLUT }
      if descriptor.configuration.downscale != configuration.downscale ||
        descriptor.configuration.convertTo420 != configuration.convertTo420 ||
        descriptor.configuration.reduceFrameRate != configuration.reduceFrameRate ||
        descriptor.applyLUT != before.applyLUT {
        var next = configuration
        next.downscale = descriptor.configuration.downscale
        next.convertTo420 = descriptor.configuration.convertTo420
        next.reduceFrameRate = descriptor.configuration.reduceFrameRate
        if descriptor.applyLUT != before.applyLUT {
          if !descriptor.applyLUT { next.applyLUT = false }
          else if lutLoaded { next.applyLUT = true }
        }
        configuration = next
      }
      if descriptor.pipelineEnabled != pipelineEnabled { pipelineEnabled = descriptor.pipelineEnabled }
      if descriptor.gamut != gamut { gamut = descriptor.gamut }
      if descriptor.previewEnabled != previewEnabled { previewEnabled = descriptor.previewEnabled }
      if descriptor.automaticFeed != automaticFeedEnabled { automaticFeedEnabled = descriptor.automaticFeed }
      if descriptor.selectedDevice != selectedDevice, !running { selectedDevice = descriptor.selectedDevice }
      if descriptor.applyLUT != before.applyLUT { saveSettings() }
      return
    }
    if feedCoordinator.isFeedRunning(id) && descriptor.selectedDevice != before.selectedDevice {
      descriptor.selectedDevice = before.selectedDevice
    }
    feedCoordinator.update(descriptor)
    persistedSnapshot = feedCoordinator.snapshot
    settingsStore.saveSnapshot(persistedSnapshot)
    publishVirtualCameraRegistry(persistedSnapshot)
    if descriptor.previewEnabled != before.previewEnabled {
      monitorCoordinator.setPreviewEnabled(descriptor.previewEnabled, for: MonitorTargetID(id.rawValue))
    }
    if descriptor.automaticFeed != before.automaticFeed { installAutomaticFeedMonitor() }
    if feedCoordinator.isFeedRunning(id),
      descriptor.configuration != before.configuration || descriptor.pipelineEnabled != before.pipelineEnabled {
      var configuration = descriptor.configuration
      if let detected = detectedInputCadence[id] { configuration.inputFast = detected }
      // A headless camera's LUT is applied only once its file is loaded.
      configuration.applyLUT = false
      cameraUpdates[id]?.pipelineEnabledApplied = nil
      feedCoordinator.reconfigureCapture(feedID: id, configuration: configuration,
        pipelineEnabled: descriptor.pipelineEnabled)
      if descriptor.applyLUT, let bookmark = descriptor.lutBookmark {
        restoreHeadlessLUT(feedID: id, bookmark: bookmark, pipelineEnabled: descriptor.pipelineEnabled)
      }
      reconcileProgramTransportDemand()
    }
  }

  /// Forgets one camera's saved LUT bookmark and turns its LUT effect off.
  func forgetLUT(_ id: FeedID) {
    cancelLUTLoad(id)
    if id == selectedFeedID {
      lutBookmark = nil
      lutLoaded = false
      lutFileName = nil
      lutError = nil
      lutTitle = "No LUT loaded"
      rememberedLUTEnabled = false
      if configuration.applyLUT { configuration.applyLUT = false } else { saveSettings() }
      return
    }
    updateCamera(id) { descriptor in
      descriptor.lutBookmark = nil
      descriptor.applyLUT = false
    }
  }

  /// Clears every saved preference. Only allowed while no camera runs or records;
  /// the app should quit afterwards so nothing writes the old state back.
  @discardableResult
  func resetAllSettings() -> Bool {
    guard canEditFeedTopology else { return false }
    settingsResetPending = true
    settingsStore.resetAll()
    return true
  }

  /// Holds the current Program shot: automatic switching stays on but makes no cuts.
  func setAutoHold(_ hold: Bool) {
    var settings = switcherSettings
    guard settings.naturalTalkingHead.manualHold != hold else { return }
    settings.naturalTalkingHead.manualHold = hold
    updateSwitcher(settings)
  }

  /// True when running Program sources deliver different camera formats. Cuts
  /// between them no longer renegotiate the Program camera: frames that don't
  /// match its format are converted on the GPU.
  var programFormatMismatch: Bool {
    guard outputMode == .program else { return false }
    // The LUT changes pixel values, not the camera format, so it is ignored here.
    let contracts = feedDescriptors.filter { $0.enabled && feedCoordinator.isFeedRunning($0.id) }.map { descriptor in
      var contract = FeedLifecycleDemandPolicy.programContract(
        configuration: descriptor.id == selectedFeedID ? effectiveConfiguration : descriptor.configuration,
        pipelineEnabled: descriptor.id == selectedFeedID ? pipelineEnabled : descriptor.pipelineEnabled,
        detectedInputFast: detectedInputCadence[descriptor.id])
      contract.applyLUT = false
      return contract
    }
    guard let first = contracts.first else { return false }
    return contracts.contains { $0 != first }
  }
}
