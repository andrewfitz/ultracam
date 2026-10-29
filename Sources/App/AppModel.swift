import AppKit
import CoreVideo
import Observation
import os
import UniformTypeIdentifiers

/// One camera's burn-in LUT as its own controller holds it. Runtime state:
/// the saved choice is the descriptor's `lutBookmark` and `applyLUT`.
struct CameraLUTState: Equatable, Sendable {
  /// "Title · size" of the LUT in this camera's pipeline; nil while none is.
  var title: String?
  var fileName: String?
  /// The bookmark the loaded LUT was read from.
  var bookmark: Data?
  /// Why this camera's last load or restore failed; nil after a success.
  var error: String?
  /// The saved LUT could not be read back.
  var savedUnavailable = false

  var loaded: Bool { title != nil }
  var displayTitle: String { title ?? (savedUnavailable ? "Saved LUT unavailable" : "No LUT loaded") }
}

/// The app's cameras. Every camera runs the same pipeline, keyed by its
/// `FeedID`: its own controller, LUT restore and apply, start and stop,
/// monitor sink and burn-in source, recording and virtual camera output.
/// The selection is a UI concept only (what the inspector edits, the default
/// target of shortcuts); it never changes how a camera is wired.
@MainActor @Observable
final class AppModel {
  private let registryPublisher: any AppVirtualCameraRegistryPublishing
  @ObservationIgnored private let hardware: AppHardware
  var hideFromDock = false {
    didSet {
      guard hideFromDock != oldValue else { return }
      settingsStore.hideFromDock = hideFromDock
      UIDockPresence.update(hideFromDock: hideFromDock)
    }
  }
  /// Changes the next session/take only; admitted requests hold value snapshots.
  var allowCPUConversion = false {
    didSet {
      guard allowCPUConversion != oldValue else { return }
      settingsStore.allowCPUConversion = allowCPUConversion
      recordingModel.compatibilityPolicy = sampledRecordingCompatibilityPolicy
      hardware.setCompatibilityPolicy(sampledRecordingCompatibilityPolicy)
    }
  }
  var sampledRecordingCompatibilityPolicy: RecordingCompatibilityPolicy {
    RecordingCompatibilityPolicy(allowCPUConversion: allowCPUConversion)
  }
  var devices: [InputDevice] = [] { didSet { expireResolvedStartRefusals() } }
  /// Set when Desktop Video is missing or older than 16.0, whose drivers
  /// reject the SDK 16 interfaces and would otherwise list no inputs.
  var driverWarning: String?
  @ObservationIgnored private var deviceListObserver: Any?
  @ObservationIgnored private var virtualCameraObserver: Any?
  var feedDescriptors: [FeedDescriptor] { feedCoordinator.descriptors }
  /// The LUT a camera burns into its output now (nil when none): what its
  /// virtual camera, recording, Program and monitor Output stage get. Never
  /// creates a capture controller.
  func burnInLUT(for id: FeedID) -> MonitorLUT? {
    feedCoordinator.capturePool.existingController(for: id)?.burnInLUT
  }
  /// A camera's broadcast audio meters; never creates a capture controller.
  /// Names the camera in the tap's over log as it hands the tap out (a lock
  /// and a compare when unchanged), so a rename reaches the log.
  func audioMeterTap(for id: FeedID) -> AudioMeterTap? {
    guard let tap = feedCoordinator.capturePool.existingController(for: id)?.audioMeterTap else { return nil }
    tap.setCameraName(feedCoordinator.descriptors.first { $0.id == id }?.name)
    return tap
  }
  /// The camera the inspector edits and shortcuts target. UI state only.
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

  /// At least one camera is capturing.
  var running: Bool {
    _ = cameraStateRevision
    return feedDescriptors.contains { feedCoordinator.isFeedRunning($0.id) }
  }
  var syncCameras: Bool { feedCoordinator.syncCameras }
  private var synchronizingCameras = false

  func setSyncCameras(_ enabled: Bool) {
    guard enabled != syncCameras else { return }
    feedCoordinator.syncCameras = enabled
    if enabled {
      synchronizeProcessing(from: feedCoordinator.selectedDescriptor)
      synchronizeMonitoring(from: MonitorTargetID(selectedFeedID.rawValue), preferences: feedCoordinator.selectedDescriptor.monitor)
    }
    saveSettings()
  }

  private func synchronizeProcessing(from source: FeedDescriptor) {
    guard syncCameras, source.enabled, !synchronizingCameras else { return }
    synchronizingCameras = true
    defer { synchronizingCameras = false }
    for camera in feedDescriptors where camera.enabled && camera.id != source.id {
      // The shared edit supersedes an older file choice, even if the saved
      // descriptors already match. Its asynchronous upload must not win later.
      let supersededLoad = lutLoadingFeeds.contains(camera.id)
      if supersededLoad { cancelLUTLoad(camera.id) }
      updateCamera(camera.id) {
        $0.applyLUT = source.applyLUT
        $0.lutBookmark = source.lutBookmark
        $0.downscale = source.downscale
        $0.convertTo420 = source.convertTo420
        $0.reduceFrameRate = source.reduceFrameRate
        $0.resizeTarget = source.resizeTarget
        $0.colorTarget = source.colorTarget
        $0.frameRateTarget = source.frameRateTarget
        $0.scalingMode = source.scalingMode
        $0.pipelineEnabled = source.pipelineEnabled
        $0.setSourceProfile(source.sourceProfileID)
        $0.lutInputSpaceID = source.lutInputSpaceID
        $0.lutOutputSpaceID = source.lutOutputSpaceID
        $0.programColorSpaceID = source.programColorSpaceID
        $0.previewEnabled = source.previewEnabled
      }
      // Upload may already have reached the capture queue before its main-actor
      // completion was cancelled. Invalidate that runtime LUT and restore the
      // winning choice, including when its saved descriptor never changed.
      if supersededLoad, !lutLoadingFeeds.contains(camera.id), descriptor(for: camera.id)?.lutBookmark != nil {
        cameraLUTs[camera.id] = nil
        applyPipeline(camera.id)
        restoreLUT(camera.id)
      }
    }
  }

  private func synchronizeMonitoring(from target: MonitorTargetID, preferences: MonitorFeedPreferences,
    previous: MonitorFeedPreferences? = nil) {
    guard syncCameras, !target.isProgram, !synchronizingCameras,
      feedDescriptors.contains(where: { $0.id.rawValue == target.rawValue && $0.enabled }) else { return }
    synchronizingCameras = true
    defer { synchronizingCameras = false }
    for camera in feedDescriptors where camera.enabled && camera.id.rawValue != target.rawValue {
      var value = camera.monitor
      value.copyTools(from: preferences)
      // A synchronized false-color choice is a shared monitor choice. Keep it
      // selected even when the destination's signal declaration is not yet
      // compatible; MonitorKit will report it as unavailable until that camera
      // is declared. The declaration itself remains camera-specific.
      if preferences.state.falseColor.mode != .off {
        value.state.falseColor.mode = preferences.state.falseColor.mode
      }
      // Editing another tool there must not erase a destination's own
      // false-color choice when the source false-color setting did not change.
      if let previous, previous.state.falseColor == preferences.state.falseColor {
        value.state.falseColor = camera.monitor.state.falseColor
      }
      value.monitorLUT = preferences.monitorLUT
      value.monitorLUTEnabled = preferences.monitorLUTEnabled
      monitorCoordinator.setPreferences(value, for: MonitorTargetID(camera.id.rawValue))
    }
  }

  /// Each camera's burn-in LUT as its controller holds it.
  private(set) var cameraLUTs: [FeedID: CameraLUTState] = [:]
  func lutState(_ id: FeedID) -> CameraLUTState { cameraLUTs[id] ?? CameraLUTState() }
  /// The camera's LUT is loading. One camera's load never blocks another's.
  func isLUTLoading(_ id: FeedID) -> Bool { lutLoadingFeeds.contains(id) }
  /// LUT file reads (loads and restores) per camera since launch, logged with
  /// each read: an edit reads each affected camera's file once, and nothing
  /// reads while the user does nothing.
  private(set) var lutReads: [FeedID: Int] = [:]
  /// The file each bookmark seen this session resolved to, so bookmarks with
  /// different bytes for one file count as the same saved LUT.
  @ObservationIgnored private var lutFiles: [Data: String] = [:]

  /// Whether two saved bookmarks name the same LUT file.
  private func sameLUTFile(_ a: Data?, _ b: Data?) -> Bool {
    guard let a, let b else { return a == b }
    if a == b { return true }
    guard let fileA = lutFiles[a], let fileB = lutFiles[b] else { return false }
    return fileA == fileB
  }
  let installer: ExtensionInstaller
  let monitorCoordinator: MonitorCoordinator
  private var monitorDemand: Set<MonitorTargetID> = []
  private var feedPolicies: [FeedID: AutomaticFeedPolicy] = [:]
  private var routeDemand: [String: Bool] = [:]
  /// The demand monitor's error for a virtual camera route, by route ID.
  private var routeErrors: [String: String] = [:]
  private var demandStartedFeeds: Set<FeedID> = []
  private var manuallyStoppedFeeds: Set<FeedID> = []
  /// Each camera's virtual-camera route ID. It depends only on the feed ID, and
  /// building a descriptor hex-encodes four identities, which the interface
  /// snapshot did on every animation frame.
  @ObservationIgnored private var feedRouteIDs: [FeedID: String] = [:]
  private var refusedStarts: Set<FeedID> = []
  /// Cameras whose input is None by choice. Discovery never fills them (`applyDevices`).
  @ObservationIgnored private var inputsClearedByChoice: Set<FeedID> = []
  /// The name of every input seen this session, so an unplugged one keeps its name.
  @ObservationIgnored private var lastInputNames: [String: String] = [:]
  private var programTransportRequired = false
  private var programTransportConfiguration: PipelineConfiguration?
  /// The input cadence each camera detected in its current run.
  @ObservationIgnored private var detectedSourceDurations: [FeedID: CMTime] = [:]
  /// The last cadence each camera detected, kept across stops: the
  /// provisional rate its next start warms up for.
  @ObservationIgnored private var lastSourceDurations: [FeedID: CMTime] = [:]
  /// What each running camera's controller was last told (start or
  /// reconfigure), cadence aside, so an unchanged edit reconfigures nothing.
  @ObservationIgnored private var appliedPipelines: [FeedID: AppliedPipeline] = [:]
  private struct AppliedPipeline: Equatable {
    var configuration: PipelineConfiguration
    var pipelineEnabled: Bool
  }
  /// The latest status from every camera. Observers are told only when its state changes
  /// (`CaptureUpdateState`); the values that change with every update are telemetry
  /// (`telemetry`, `liveCameraUpdate`), so the window isn't rebuilt 4 times a second per camera.
  private(set) var cameraUpdates: [FeedID: CaptureUpdate] = [:]
  /// Fast-changing camera and take values, for the views that show them (see UILiveTelemetry.swift).
  var telemetry: UITelemetryStore { recordingModel.telemetry }
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
  let vendorSettings: VendorSettingsStore
  let cameraControls: CameraControlStore
  var controlViewFactories: [String: ControlViewFactory] { hardware.controlViewFactories() }
  func captureVendor(for deviceID: String) -> VendorDescriptor? { hardware.captureDescriptor(deviceID) }
  private let virtualCameraRegistryStore: VirtualCameraRegistryStore
  private let lutLoader: LUTFileLoader
  private var launching = true
  // LUT parsing and GPU uploads are asynchronous. Invalidate an operation
  // whenever a newer load for the same camera starts, so an old completion
  // cannot overwrite it. Each camera counts its own loads.
  private var lutLoadGenerations: [FeedID: UInt64] = [:]
  private var lutLoadingFeeds: Set<FeedID> = [] { didSet { expireResolvedStartRefusals() } }
  private let demandMonitor = CameraDemandMonitor()
  private var persistedSnapshot = AppSettingsSnapshot()
  private var autoSwitcherBridge: AutoSwitcherBridge?
  private var autoSwitcherTimeline: AutoSwitcherTimelineRecorder?
  private var recordingTimelines: [FeedID: AutoSwitcherTimelineRecorder] = [:]
  /// The tap each running take measures its audio on: the one it started on,
  /// so a capture replaced mid-take still gets its take ended (and its viewer released).
  @ObservationIgnored private var takeTaps: [FeedID: AudioMeterTap] = [:]
  /// Each camera's last finished take's audio: integrated loudness, Max TP, overs.
  private(set) var takeAudio: [FeedID: AudioTakeSummary] = [:]
  /// The running take's audio so far; nil without a take on a meter.
  func takeAudioSoFar(_ id: FeedID) -> AudioTakeSummary? { takeTaps[id]?.takeSummarySoFar() }
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
    self.vendorSettings = VendorSettingsStore(plugins: Dictionary(uniqueKeysWithValues: hardware.settingsPlugins().map { ($0.descriptor.id, $0) }),
      persistence: VendorSettingsPreferences(defaults: store.preferenceDefaults))
    self.cameraControls = CameraControlStore(plugins: Dictionary(uniqueKeysWithValues: hardware.controlPlugins().map { ($0.descriptor.id, $0) }),
      persistence: CameraControlPreferences(defaults: store.preferenceDefaults))
    self.registryPublisher = registryPublisher ?? VirtualCameraRegistryPublisher()
    hideFromDock = store.hideFromDock
    self.virtualCameraRegistryStore = registryStore ?? VirtualCameraRegistryStore()
    let snapshot = store.loadSnapshot()
    persistedSnapshot = snapshot
    // Saved without an input beside cameras that have one: that camera was set to None.
    // Only a fresh setup, where no camera has an input yet, is filled in on its own.
    if snapshot.feeds.contains(where: { !$0.selectedDevice.isEmpty }) {
      inputsClearedByChoice = Set(snapshot.feeds.filter { $0.selectedDevice.isEmpty }.map(\.id))
    }
    monitorCoordinator = MonitorCoordinator(feeds: snapshot.feeds, program: snapshot.programMonitor,
      workspace: snapshot.monitorWorkspacePreferences)
    let capturePool = FeedCapturePool(factory: { feedID in
      CaptureController(services: hardware.captureServices(feedID))
    })
    feedCoordinator = FeedCoordinator(snapshot: snapshot, capturePool: capturePool)
    let coordinator = feedCoordinator
    recordingModel = RecordingModel(
      feeds: feedCoordinator.descriptors.map { RecordingFeedDescriptor(id: $0.id, name: $0.name, recordingConstantFrameRate: $0.recordingConstantFrameRate) },
      driver: NativeRecordingSessionDriver(captureForFeed: { id in coordinator.capture(for: id) },
        rawAudioCallbackAvailable: true),
      folderStore: recordingFolderStore ?? RecordingFolderStore())
    self.lutLoader = lutLoader
    allowCPUConversion = store.allowCPUConversion
    recordingModel.compatibilityPolicy = sampledRecordingCompatibilityPolicy
    hardware.setCompatibilityPolicy(sampledRecordingCompatibilityPolicy)
    monitorCoordinator.onConfigurationChange = { [weak self] target, configuration in
      guard let self else { return }
      // The coordinator reports a target's whole preferences: they replace the saved ones.
      let previous = self.monitorPreferences(of: target)
      if target.rawValue == "program" {
        self.feedCoordinator.programMonitor = configuration
      } else if var descriptor = self.feedDescriptors.first(where: { $0.id.rawValue == target.rawValue }) {
        descriptor.monitor = configuration
        self.feedCoordinator.update(descriptor)
      }
      self.synchronizeMonitoring(from: target, preferences: configuration, previous: previous)
      self.saveSettings()
    }
    monitorCoordinator.onResetSettings = { [weak self] target in
      self?.replaceMonitorPreferences(of: target) { $0.resetTools() } ?? false
    }
    monitorCoordinator.onCopySettings = { [weak self] source, destination in
      guard let self, let tools = self.monitorPreferences(of: source) else { return false }
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
      guard let self, let descriptor = self.feedDescriptors.first(where: { $0.id.rawValue == target.rawValue }) else { return }
      self.updateCamera(descriptor.id) { $0.previewEnabled = enabled }
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
      self.beginTakeAudio(feedID)
      self.reconcileAutomaticFeed()
      guard let timeline = self.autoSwitcherTimeline else { return }
      self.recordingTimelines[feedID] = timeline
      timeline.recordingStarted(feedID: feedID, url: url, mediaStart: self.directorUpdate?.mediaTime)
    }
    recordingModel.onRecordingFinished = { [weak self] feedID, url in
      guard let self else { return }
      self.endTakeAudio(feedID)
      self.reconcileAutomaticFeed()
      guard let timeline = self.recordingTimelines.removeValue(forKey: feedID) else { return }
      timeline.recordingFinished(feedID: feedID, url: url, mediaEnd: self.directorUpdate?.mediaTime)
    }
    recordingModel.onRecordingPaused = { [weak self] feedID, paused in
      self?.takeTaps[feedID]?.pauseTake(paused)
    }
    feedCoordinator.onProgramCutAbandoned = { [weak self] feedID, reason in
      self?.programCutAbandoned(feedID, reason: reason)
    }
    feedCoordinator.onProgramOutputError = { [weak self] message in
      self?.programOutputIssue = message
      self?.showStatus(message)
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
    launching = false
    publishVirtualCameraRegistry(snapshot, reason: "launch")
    demandMonitor.setRoutes(feedCoordinator.virtualCameraDescriptors)
    // Every camera is wired the same way, and every saved LUT is restored
    // into its own camera's pipeline.
    for descriptor in feedCoordinator.descriptors {
      wireCamera(descriptor.id)
      if descriptor.lutBookmark != nil { restoreLUT(descriptor.id) }
    }
    refresh()
    // Hot-plug: arrivals and removals update the list without a manual refresh.
    deviceListObserver = hardware.observeDevices { [weak self] list in
      self?.driverWarning = hardware.driverWarning()
      self?.applyDevices(list, fromDiscovery: true)
    }
    // The camera extension can start after a camera does (installed, approved or updated while
    // the app runs): when its cameras appear, every running camera whose virtual camera isn't
    // connected connects, without a restart or a change of settings.
    virtualCameraObserver = hardware.observeVirtualCameras { [weak self] in
      self?.feedCoordinator.requestCameraReconnects()
    }
    demandMonitor.onRouteChange = { [weak self] change in
      guard let self else { return }
      self.routeDemand[change.route.id] = change.requested == true
      self.routeErrors[change.route.id] = change.error
      self.reconcileAutomaticFeed()
    }
    if outputMode == .program || feedDescriptors.contains(where: \.automaticFeed) { demandMonitor.start() }
  }

  func refresh() {
    do {
      applyDevices(try hardware.devices(), fromDiscovery: false)
    } catch {
      applyDevices([], fromDiscovery: false)
      showStatus(error.localizedDescription)
    }
    driverWarning = hardware.driverWarning()
  }

  private func applyDevices(_ next: [InputDevice], fromDiscovery: Bool) {
    // Discovery reports every arrival, including devices already listed.
    if fromDiscovery, next.map(\.id) == devices.map(\.id), next.map(\.name) == devices.map(\.name),
      next.map(\.shareable) == devices.map(\.shareable),
      next.map(\.mayPause) == devices.map(\.mayPause) { return }
    for device in next { lastInputNames[device.id] = device.name }
    devices = next
    for device in next {
      guard let pluginID = try? VendorRegistry.pluginID(for: device.id) else { continue }
      Task { await vendorSettings.restore(deviceID: device.id, pluginID: pluginID) }
    }
    // Lists can be partial (discovery publishes after each arrival), and a saved
    // input names one unit, so an assignment is never moved: an unplugged input
    // stays the camera's until the user picks another. Only a camera that never
    // had an input takes the first free one, in camera order; None by choice
    // stays None.
    for descriptor in feedDescriptors where descriptor.enabled && descriptor.selectedDevice.isEmpty &&
      !inputsClearedByChoice.contains(descriptor.id) && !cameraActive(descriptor.id) {
      guard let free = devices.first(where: { inputHolder($0.id, excluding: descriptor.id) == nil }) else { break }
      updateCamera(descriptor.id) { $0.selectedDevice = free.id }
    }
    if feedDescriptors.contains(where: \.automaticFeed) {
      demandMonitor.refresh()
      reconcileAutomaticFeed()
    }
  }

  /// Running, or its controller still owns the device while a stop drains.
  private func cameraActive(_ id: FeedID) -> Bool {
    feedCoordinator.isFeedRunning(id) || feedCoordinator.capturePool.existingController(for: id)?.hasActiveFeed == true
  }

  // MARK: - LUTs (one path for every camera)

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

  /// Loads a chosen .cube file into one camera and turns its Apply LUT on.
  /// Separate from the panel for tests.
  func loadLUT(url: URL, feedID: FeedID) {
    guard descriptor(for: feedID) != nil else { return }
    cameraLUTs[feedID, default: CameraLUTState()].error = nil
    let generation = beginLUTLoad(feedID)
    lutLog.notice("LUT load started: \(feedID.rawValue, privacy: .public) (read \(self.lutReads[feedID] ?? 0, privacy: .public))")
    Task { [weak self, lutLoader] in
      do {
        let loaded = try await lutLoader.load(url: url)
        let lut = try await Self.makeMonitorLUT(loaded.cube)
        self?.installLUT(loaded, lut: lut, requested: nil, generation: generation, feedID: feedID)
      } catch { self?.lutLoadFailed(error, restoring: false, generation: generation, feedID: feedID) }
    }
  }

  /// Reads a camera's saved LUT back into its pipeline: at launch, when its
  /// saved LUT changes, and when Apply LUT is turned on with none in memory.
  /// Whether the camera runs, or is selected, makes no difference.
  private func restoreLUT(_ feedID: FeedID) {
    guard let bookmark = descriptor(for: feedID)?.lutBookmark else { return }
    cameraLUTs[feedID, default: CameraLUTState()].error = nil
    let generation = beginLUTLoad(feedID)
    lutLog.notice("LUT restore started: \(feedID.rawValue, privacy: .public) (read \(self.lutReads[feedID] ?? 0, privacy: .public))")
    Task { [weak self, lutLoader] in
      do {
        let loaded = try await lutLoader.restore(bookmark: bookmark)
        let lut = try await Self.makeMonitorLUT(loaded.cube)
        self?.installLUT(loaded, lut: lut, requested: bookmark, generation: generation, feedID: feedID)
      } catch { self?.lutLoadFailed(error, restoring: true, generation: generation, feedID: feedID) }
    }
  }

  /// One MonitorLUT per load, on the shared device: the controller burns it in and
  /// the monitor's feed shows the output stage with the same object. Built off the
  /// main actor (the 3D texture upload is megabytes for a 65³ lattice).
  nonisolated private static func makeMonitorLUT(_ cube: CubeLUT) async throws -> MonitorLUT {
    try LUTProcessor.makeLUT(cube)
  }

  /// Starts a LUT load for one camera and returns its generation. A newer load
  /// for the same camera supersedes it; other cameras' loads are unaffected.
  private func beginLUTLoad(_ feedID: FeedID) -> UInt64 {
    lutReads[feedID, default: 0] += 1
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

  /// Puts a read LUT into the camera's own controller. It stays there across
  /// stops and starts; Apply LUT decides whether frames burn it in.
  /// `requested` is the saved bookmark a restore read; nil for a chosen file.
  private func installLUT(_ loaded: LoadedLUT, lut: MonitorLUT, requested: Data?, generation: UInt64,
                          feedID: FeedID) {
    guard generation == lutLoadGenerations[feedID], descriptor(for: feedID) != nil else { return }
    lutFiles[loaded.bookmark] = loaded.path
    if let requested { lutFiles[requested] = loaded.path }
    let restoring = requested != nil
    let colorSpace: LUTColorSpaceContract
    do {
      guard let declaration = descriptor(for: feedID) else { return }
      colorSpace = try declaration.lutColorSpaceContract()
    } catch {
      lutLoadFailed(error, restoring: restoring, generation: generation, feedID: feedID)
      return
    }
    feedCoordinator.capture(for: feedID).load(lut, colorSpace: colorSpace) { [weak self] result in
      MainActor.assumeIsolated {
        guard let self, generation == self.lutLoadGenerations[feedID] else { return }
        switch result {
        case .success: self.lutInstalled(loaded, requested: requested, feedID: feedID)
        case .failure(let error): self.lutLoadFailed(error, restoring: restoring, generation: generation, feedID: feedID)
        }
      }
    }
  }

  private func lutInstalled(_ loaded: LoadedLUT, requested: Data?, feedID: FeedID) {
    let restoring = requested != nil
    lutLoadingFeeds.remove(feedID)
    cameraLUTs[feedID] = CameraLUTState(title: "\(loaded.cube.title) · \(loaded.cube.sizeDescription)",
      fileName: loaded.fileName, bookmark: loaded.bookmark)
    if restoring {
      // A restore keeps the saved choice. A refreshed bookmark for the same
      // file is saved quietly: it is no edit, so it reads nothing anywhere.
      if var descriptor = descriptor(for: feedID), descriptor.lutBookmark != loaded.bookmark,
        sameLUTFile(descriptor.lutBookmark, loaded.bookmark) {
        descriptor.lutBookmark = loaded.bookmark
        feedCoordinator.update(descriptor)
        saveSettings(reason: "LUT bookmark refreshed")
      }
    } else {
      // A chosen file becomes the camera's saved LUT and turns Apply LUT on.
      updateCamera(feedID) { descriptor in
        descriptor.lutBookmark = loaded.bookmark
        descriptor.applyLUT = true
      }
    }
    let apply = descriptor(for: feedID)?.applyLUT == true
    lutLog.notice("LUT \(restoring ? "restored" : "loaded", privacy: .public): \(feedID.rawValue, privacy: .public), \"\(loaded.cube.title, privacy: .public)\" (\(loaded.fileName, privacy: .public)), Apply LUT \(apply ? "on" : "off", privacy: .public)")
    if apply {
      lutLog.notice("LUT applied: \(feedID.rawValue, privacy: .public), burned into its output and monitor (\(self.feedCoordinator.isFeedRunning(feedID) ? "running: reconfigured now" : "applied when it starts", privacy: .public))")
    }
    applyPipeline(feedID)
    reconcileAutomaticFeed()
  }

  private func lutLoadFailed(_ error: Error, restoring: Bool, generation: UInt64, feedID: FeedID) {
    guard generation == lutLoadGenerations[feedID] else { return }
    lutLoadingFeeds.remove(feedID)
    let message = "\(restoring ? "Saved LUT could not be restored" : "LUT was not changed"): \(error.localizedDescription)"
    lutLog.error("LUT \(restoring ? "restore" : "load", privacy: .public) failed: \(feedID.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
    // Keep the saved bookmark, Apply LUT and an already-loaded LUT. A missing
    // moved file is recoverable by choosing it again or turning Apply LUT
    // back on; it does not erase preferences.
    var state = lutState(feedID)
    state.error = message
    if restoring { state.savedUnavailable = true }
    cameraLUTs[feedID] = state
    if var cameraUpdate = cameraUpdates[feedID] {
      cameraUpdate.message = message
      cameraUpdates[feedID] = cameraUpdate
    }
    // A chosen file failed with nothing loaded: bring the saved LUT back
    // rather than run without one.
    if !restoring, !state.loaded, descriptor(for: feedID)?.lutBookmark != nil { restoreLUT(feedID) }
    reconcileAutomaticFeed()
  }

  /// Forgets one camera's saved LUT bookmark and turns its LUT effect off.
  func forgetLUT(_ id: FeedID) {
    cancelLUTLoad(id)
    cameraLUTs[id] = nil
    updateCamera(id) { descriptor in
      descriptor.lutBookmark = nil
      descriptor.applyLUT = false
    }
    applyPipeline(id)
  }

  // MARK: - Selection and topology

  /// Selects the camera the inspector edits and shortcuts target. It changes
  /// nothing about any camera's pipeline.
  @discardableResult
  func selectFeed(_ id: FeedID) -> Bool {
    let previous = selectedFeedID
    guard feedCoordinator.select(id) else { return false }
    captureLog.notice("Selection: \(previous.rawValue, privacy: .public) → \(id.rawValue, privacy: .public)")
    persistProgramSelection()
    return true
  }

  /// Adds an idle feed, persists the new topology, and selects it so the UI
  /// immediately edits the new feed's independent settings.
  @discardableResult
  func addFeed(name: String? = nil) -> FeedID? {
    guard canEditFeedTopology else { return nil }
    let source = feedCoordinator.selectedDescriptor
    let id = feedCoordinator.add(name: name)
    wireCamera(id)
    synchronizeProcessing(from: source)
    synchronizeMonitoring(from: MonitorTargetID(source.id.rawValue), preferences: source.monitor)
    syncRecordingFeeds()
    guard selectFeed(id) else { return nil }
    saveSettings()
    return id
  }

  /// A take started recording: its audio is measured on the camera's tap
  /// from here, on a meter of its own (see `AudioMeterTap.beginTake`).
  private func beginTakeAudio(_ id: FeedID) {
    takeAudio[id] = nil
    // A take never ended (no finish callback) must not keep a viewer.
    _ = takeTaps.removeValue(forKey: id)?.endTake()
    guard let tap = audioMeterTap(for: id) else { return }
    takeTaps[id] = tap
    tap.beginTake()
  }

  /// A take finished (saved, failed or stopped while starting): keep its audio for the strip, and log it.
  private func endTakeAudio(_ id: FeedID) {
    guard let summary = takeTaps.removeValue(forKey: id)?.endTake() else { return }
    takeAudio[id] = summary
    let name = feedDescriptors.first { $0.id == id }?.name ?? id.rawValue
    audioLog.notice("Take on \(name, privacy: .public): \(summary.note, privacy: .public), \(String(format: "%.1f", summary.duration), privacy: .public) s measured")
  }

  /// Removes an idle feed. The coordinator owns the running/removal guard and
  /// moves the selection to the first remaining camera.
  @discardableResult
  func removeFeed(_ id: FeedID) -> Bool {
    guard canEditFeedTopology else { return false }
    guard feedCoordinator.remove(id) else { return false }
    cancelLUTLoad(id)
    takeAudio[id] = nil
    Task { await cameraControls.removeFeed(id.rawValue) }
    cameraLUTs[id] = nil
    cameraUpdates[id] = nil
    feedPolicies[id] = nil
    detectedSourceDurations[id] = nil
    lastSourceDurations[id] = nil
    appliedPipelines[id] = nil
    monitorCoordinator.setBurnInLUTSource(for: MonitorTargetID(id.rawValue), nil)
    syncRecordingFeeds()
    saveSettings(reason: "camera removed")
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
    guard !launching else { return }
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
    showStatus(message)
    if let decisionID = pendingAutoDecisionID, pendingAutoTargetFeedID == feedID {
      pendingAutoDecisionID = nil
      pendingAutoTargetFeedID = nil
      if reason == .expired { autoSwitcherTimeline?.recordExpired(decisionID: decisionID) }
      else { autoSwitcherTimeline?.recordRejected(decisionID: decisionID) }
      autoSwitcherBridge?.reject(decisionID: decisionID)
    }
  }

  /// Saves the snapshot alone (selection, what is on air): no device or
  /// topology changed, so the camera registry is untouched.
  private func persistProgramSelection() {
    guard !launching, !settingsResetPending else { return }
    persistedSnapshot = feedCoordinator.snapshot
    settingsStore.saveSnapshot(persistedSnapshot)
  }

  /// The director's clock source: the selected input's status. Program's
  /// Rust director ticks on one camera's audio; which one is the selection,
  /// a UI choice. No camera's pipeline depends on it.
  private var directorUpdate: CaptureUpdate? { cameraUpdates[selectedFeedID] }

  /// Audio packet time from the selected input. That is the clock the Rust
  /// director ticks, so manual cuts have to be expressed on it.
  private func directorClock() -> CMTime {
    directorUpdate?.audioPacketTime ?? directorUpdate?.mediaTime ?? .zero
  }
  private func reconcileAutoSwitcher() {
    // The director ticks on the selected input's audio (`directorClock`), so
    // it runs while that camera does.
    guard feedCoordinator.outputMode == .program,
      feedCoordinator.isFeedRunning(selectedFeedID),
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
      showStatus("Natural Talking Head could not start its Rust director.")
      return
    }
    autoSwitcherTimeline = AutoSwitcherTimelineRecorder(settings: settings, anchor: anchor,
      emphasis: emphasis, outputFolder: recordingModel.outputFolder)
    guard let timeline = autoSwitcherTimeline else { return }
    timeline.onError = { [weak self] message in
      self?.showStatus("Auto-switcher timeline: \(message)")
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
        guard let self, self.autoSwitcherBridge === bridge,
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
        self.showStatus("Auto director: \(message)")
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
      bridge.manualOverride(cameraID: current, at: directorUpdate?.mediaTime ?? .zero)
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
        // Activity includes every declared source channel, including speech
        // arriving beyond the stereo meter pair.
        rms: update.audioActivityRMS,
        peak: update.audioActivityPeak,
        present: true)
    } else {
      autoSwitcherTimeline?.recordTick(time: time)
      autoSwitcherBridge?.tick(time: time)
    }
  }

  /// Shows an app-level message in the status of the camera the user is
  /// looking at (the selection). Display only.
  private func showStatus(_ message: String) {
    var status = cameraUpdates[selectedFeedID] ?? CaptureUpdate(message: message)
    status.message = message
    cameraUpdates[selectedFeedID] = status
  }

  /// Retargets camera demand to the current routes and starts or stops the
  /// demand monitor.
  private func installAutomaticFeedMonitor() {
    demandMonitor.setRoutes(feedCoordinator.virtualCameraDescriptors)
    if outputMode == .program || feedDescriptors.contains(where: \.automaticFeed) { demandMonitor.start() }
    else { demandMonitor.stop() }
    reconcileAutomaticFeed()
  }

  /// Saves every camera's settings and publishes the topology they describe.
  func saveSettings() { saveSettings(reason: "settings saved") }

  private func saveSettings(reason: String) {
    guard !launching, !settingsResetPending else { return }
    persistedSnapshot = feedCoordinator.snapshot
    settingsStore.saveSnapshot(persistedSnapshot)
    demandMonitor.setRoutes(feedCoordinator.virtualCameraDescriptors)
    publishVirtualCameraRegistry(persistedSnapshot, reason: reason)
    monitorCoordinator.updateTargets(feeds: feedDescriptors, programAvailable: outputMode == .program)
  }

  /// The monitor preferences of a feed or Program, nil for an unknown target.
  private func monitorPreferences(of target: MonitorTargetID) -> MonitorFeedPreferences? {
    if target.rawValue == "program" { return feedCoordinator.programMonitor }
    return feedDescriptors.first(where: { $0.id.rawValue == target.rawValue })?.monitor
  }

  /// Changes a target's whole monitor preferences (reset, copy) and saves them;
  /// false for an unknown target.
  private func replaceMonitorPreferences(
    of target: MonitorTargetID, _ change: (inout MonitorFeedPreferences) -> Void
  ) -> Bool {
    if target.rawValue == "program" {
      change(&feedCoordinator.programMonitor)
    } else if var descriptor = feedDescriptors.first(where: { $0.id.rawValue == target.rawValue }) {
      change(&descriptor.monitor)
      feedCoordinator.update(descriptor)
      synchronizeMonitoring(from: target, preferences: descriptor.monitor)
    } else {
      return false
    }
    saveSettings()
    return true
  }

  private func syncRecordingFeeds() {
    recordingModel.updateFeeds(feedCoordinator.descriptors.map {
      RecordingFeedDescriptor(id: $0.id, name: $0.name, recordingConstantFrameRate: $0.recordingConstantFrameRate)
    })
  }

  /// Publishes the complete feed topology in one transaction. The camera
  /// extension receives it through CMIO and retains existing devices until
  /// their clients release them during reconciliation.
  private func publishVirtualCameraRegistry(_ snapshot: AppSettingsSnapshot, reason: String) {
    let previous = virtualCameraRegistryStore.load()
    let candidate = VirtualCameraRegistrySnapshot.forFeeds(snapshot.feeds,
      outputMode: snapshot.outputMode, previous: previous)
    do {
      try virtualCameraRegistryStore.save(candidate)
      if candidate != previous {
        registryLog.notice("Registry publish: generation \(candidate.generation, privacy: .public), \(candidate.devices.filter(\.enabled).count, privacy: .public) cameras (\(snapshot.outputMode == .program ? "Program" : "separate cameras", privacy: .public)), reason: \(reason, privacy: .public)")
      }
      registryPublisher.publish(candidate)
    } catch {
      registryLog.error("Registry publish failed: \(error.localizedDescription, privacy: .public)")
      showStatus("Virtual cameras could not be updated: \(error.localizedDescription)")
    }
  }

  // MARK: - One pipeline per camera

  /// What a camera's frames go through: its saved processing, its LUT burned
  /// in only once that LUT is in its pipeline, at the cadence it last detected.
  func effectiveConfiguration(for id: FeedID) -> PipelineConfiguration {
    guard let descriptor = descriptor(for: id) else { return PipelineConfiguration() }
    var configuration = descriptor.configuration
    if let pause = devices.first(where: { $0.id == descriptor.selectedDevice })?.mayPause {
      let value = pause.components
      configuration.sourcePauseAllowanceSeconds = Double(value.seconds) + Double(value.attoseconds) / 1e18
    } else {
      configuration.sourcePauseAllowanceSeconds = nil
    }
    configuration.applyLUT = descriptor.applyLUT && lutState(id).loaded
    configuration.sourceDuration = detectedSourceDurations[id] ?? lastSourceDurations[id] ?? configuration.sourceDuration
    return configuration
  }

  private func pipeline(for id: FeedID) -> AppliedPipeline? {
    guard let descriptor = descriptor(for: id) else { return nil }
    var configuration = effectiveConfiguration(for: id)
    // Detected cadence belongs to the controller, so telemetry alone must not
    // make an unchanged settings edit reconfigure the running pipeline.
    configuration.sourceDuration = nil
    return AppliedPipeline(configuration: configuration, pipelineEnabled: descriptor.pipelineEnabled)
  }

  /// Brings a running camera's controller to its effective configuration.
  /// A no-op when nothing it uses changed, so it is safe to call after any edit.
  private func applyPipeline(_ id: FeedID) {
    if let error = descriptor(for: id)?.processingDeclarationError { showStatus(error); return }
    guard feedCoordinator.isFeedRunning(id), let descriptor = descriptor(for: id),
      let next = pipeline(for: id), next != appliedPipelines[id] else { return }
    appliedPipelines[id] = next
    if var status = cameraUpdates[id] {
      status.pipelineEnabledApplied = nil
      status.output = ""
      cameraUpdates[id] = status
    }
    feedCoordinator.reconfigureCapture(feedID: id, configuration: effectiveConfiguration(for: id),
      pipelineEnabled: descriptor.pipelineEnabled)
    reconcileProgramTransportDemand()
  }

  /// Connects a camera's controller to the app: status, monitor frames, the
  /// burn-in LUT its monitor's Output stage shows, and Program frames. Done
  /// once per camera, at launch or when it is added, the same for every camera.
  private func wireCamera(_ feedID: FeedID) {
    let controller = feedCoordinator.capture(for: feedID)
    controller.setMonitorSink(monitorCoordinator.captureSink(for: MonitorTargetID(feedID.rawValue)))
    // The Output (LUT) picture and Output-stage tools show the very MonitorLUT
    // this camera burns in (nil while Apply LUT is off), read at each encode.
    monitorCoordinator.setBurnInLUTSource(for: MonitorTargetID(feedID.rawValue)) { [weak controller] in
      controller?.burnInLUT
    }
    // Frames go from the capture delivery thread straight into the Program
    // route (and from there to the Program camera); none pass through here.
    feedCoordinator.installProgramFrameDelivery(feedID: feedID)
    controller.onUpdate = { [weak self] update in
      MainActor.assumeIsolated { self?.cameraDidUpdate(feedID, update) }
    }
  }

  /// A camera's status. Controllers can outlive their camera while their stop
  /// work drains, so updates for a removed camera are ignored.
  private func cameraDidUpdate(_ feedID: FeedID, _ update: CaptureUpdate) {
    guard descriptor(for: feedID) != nil else { return }
    if let previous = _cameraUpdates[feedID], CaptureUpdateState(previous) == CaptureUpdateState(update) {
      // Only telemetry changed: stored without telling the observers of `cameraUpdates`.
      _cameraUpdates[feedID] = update
    } else {
      cameraUpdates[feedID] = update
    }
    telemetry.captureChanged(feedID)
    if update.stopped {
      captureLog.notice("Stopped \(feedID.rawValue, privacy: .public): \(update.message, privacy: .public)")
      cameraStateRevision &+= 1
      monitorCoordinator.sourceStateChanged(target: MonitorTargetID(feedID.rawValue), running: false, message: update.message)
      detectedSourceDurations[feedID] = nil
      appliedPipelines[feedID] = nil
      feedCoordinator.stopCapture(feedID: feedID)
      // A camera can fail on its own. Stop only its recording; the director
      // keeps cutting between the cameras still live.
      recordingModel.stop(feedID: feedID)
      retireProgramSource(feedID)
      reconcileAutoSwitcher()
      reconcileProgramTransportDemand()
      return
    }
    if let duration = update.sourceDuration, duration.isNumeric, duration.epoch == 0, duration.value > 0,
      detectedSourceDurations[feedID] != duration {
      lastSourceDurations[feedID] = duration
      detectedSourceDurations[feedID] = duration
      reconcileProgramTransportDemand()
    }
    if feedID == selectedFeedID { feedAutoSwitcherAudio(update) }
  }

  /// Opens one camera's capture. The one start path, for every camera, manual
  /// or automatic, in either output mode.
  private func launchCapture(_ id: FeedID) {
    guard let descriptor = descriptor(for: id) else { return }
    if let error = descriptor.processingDeclarationError { showStatus(error); return }
    feedCoordinator.setCameraOutputEnabled(feedID: id, enabled: outputMode != .program)
    detectedSourceDurations[id] = nil
    feedCoordinator.programOutput.setSourcePauseTolerance(id,
      mayPause: devices.first(where: { $0.id == descriptor.selectedDevice })?.mayPause)
    guard feedCoordinator.startCapture(feedID: id, deviceID: descriptor.selectedDevice,
      configuration: effectiveConfiguration(for: id), pipelineEnabled: descriptor.pipelineEnabled) else {
      feedCoordinator.setProgramSourceHealth(id, healthy: false)
      return
    }
    // A source retired after a failure must become eligible again only after
    // its next capture actually starts.
    feedCoordinator.setProgramSourceHealth(id, healthy: true)
    appliedPipelines[id] = pipeline(for: id)
    cameraUpdates[id] = CaptureUpdate(message: "Opening input device…")
    cameraStateRevision &+= 1
    if outputMode == .program { reconcileAutoSwitcher() }
    reconcileProgramTransportDemand()
  }

  /// Ends one camera's capture, its virtual camera output and its recording.
  private func endCapture(_ id: FeedID, message: String) {
    recordingModel.stop(feedID: id)
    feedCoordinator.stopCapture(feedID: id)
    appliedPipelines[id] = nil
    detectedSourceDurations[id] = nil
    if outputMode == .program { retireProgramSource(id) }
    monitorCoordinator.sourceStateChanged(target: MonitorTargetID(id.rawValue), running: false, message: message)
    cameraUpdates[id] = nil
    cameraStateRevision &+= 1
    reconcileAutoSwitcher()
    reconcileProgramTransportDemand()
  }

  /// Whether a manual Start can open the camera now.
  private func canStart(_ id: FeedID) -> Bool {
    guard let descriptor = descriptor(for: id), descriptor.enabled else { return false }
    return !feedCoordinator.isFeedRunning(id) && !lutLoadingFeeds.contains(id) &&
      devices.contains { $0.id == descriptor.selectedDevice } && inputInUse(by: id) == nil
  }

  /// What the interface calls an input: its label while listed (`UIInputLabels`),
  /// its last name seen and ID digits while unplugged, nil for none.
  func inputLabel(_ device: String) -> String? {
    guard !device.isEmpty else { return nil }
    return devices.label(for: device) ?? UIInputLabels.missingLabel(id: device, lastName: lastInputNames[device])
  }

  /// Only an explicit plugin declaration permits multiple camera owners.
  func inputShareable(_ deviceID: String) -> Bool {
    devices.first(where: { $0.id == deviceID })?.shareable == true
  }

  /// Another camera assigned an exclusive input. Shared sources can serve several cameras.
  func inputHolder(_ device: String, excluding id: FeedID) -> FeedDescriptor? {
    guard !device.isEmpty, !inputShareable(device) else { return nil }
    return feedDescriptors.first { $0.id != id && $0.selectedDevice == device }
  }

  /// A running camera holding this camera's exclusive input. Unknown sources
  /// remain exclusive until discovery explicitly declares them shareable.
  private func inputInUse(by id: FeedID) -> FeedDescriptor? {
    guard let device = descriptor(for: id)?.selectedDevice, !device.isEmpty,
      !inputShareable(device) else { return nil }
    return feedDescriptors.first { $0.id != id && $0.selectedDevice == device && feedCoordinator.isFeedRunning($0.id) }
  }

  /// Remembers a Start that didn't start the camera, so its strip can say why
  /// instead of doing nothing. Starting or stopping the camera clears it.
  private func noteStartAttempt(_ id: FeedID, started: Bool) {
    if started { refusedStarts.remove(id) } else if refusedStarts.insert(id).inserted { cameraStateRevision &+= 1 }
  }

  /// A camera's input changed: a Start refused for its old input is history.
  private func forgetStartRefusal(_ id: FeedID) {
    if refusedStarts.remove(id) != nil { cameraStateRevision &+= 1 }
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
    if lutLoadingFeeds.contains(id) { return "Its LUT is still loading. Start it again in a moment." }
    return inputUnavailableReason(descriptor.selectedDevice, for: id)
  }

  /// Why camera `id` on input `device` can't start, nil while that input is listed and free.
  /// With no input listed there is no available device to choose.
  private func inputUnavailableReason(_ device: String, for id: FeedID) -> String? {
    if device.isEmpty && !devices.isEmpty { return driverWarning ?? "Choose an input for this camera." }
    if !devices.contains(where: { $0.id == device }) { return driverWarning ?? "Connect an input device." }
    if let holder = inputInUse(by: id) { return "\(holder.name) is using this input. Choose another input." }
    return nil
  }

  /// Removes one failed source from Program eligibility without ending the
  /// session. The director hears the same health change on its next tick.
  private func retireProgramSource(_ feedID: FeedID) {
    feedCoordinator.setProgramSourceHealth(feedID, healthy: false)
    // The director clock is the selected input's. The stopped source's own
    // timestamps are cleared and must not be used. A zero sample still
    // records health without moving that clock backward.
    autoSwitcherBridge?.setCameraHealth(cameraID: feedID, healthy: false, at: directorClock())
  }

  // MARK: - Automatic start

  /// A camera app uses this camera's virtual camera (or, in Program mode, the
  /// Program camera).
  func cameraRequested(_ id: FeedID) -> Bool { feedPolicies[id]?.requested == true }

  private func demandRouteID(for id: FeedID) -> String {
    outputMode == .program ? VirtualCameraDescriptor.program().id : feedRouteID(id)
  }

  /// What a camera on automatic start is doing, and why.
  func automaticStatus(_ id: FeedID) -> String {
    guard let descriptor = descriptor(for: id) else { return "" }
    if feedCoordinator.isFeedRunning(id) {
      if !demandStartedFeeds.contains(id) { return "Camera is running. It stays up until Stop." }
      return cameraRequested(id)
        ? "Camera in use. Hide preview without interrupting camera output."
        : "Preview is live. Hide it to stop capture until a camera app needs it."
    }
    if manuallyStoppedFeeds.contains(id) { return "Camera stopped. It stays off until you start it." }
    if let error = routeErrors[demandRouteID(for: id)] { return error }
    if feedPolicies[id]?.captureRequested != true {
      return "Waiting for a camera app or visible preview. Capture and video processing are off."
    }
    if lutLoadingFeeds.contains(id) { return "Restoring your LUT…" }
    if let reason = inputUnavailableReason(descriptor.selectedDevice, for: id) { return reason }
    return "Camera stopped. Retry to resume preview or camera output."
  }

  func retryAutomaticFeed(feedID: FeedID? = nil) {
    let id = feedID ?? selectedFeedID
    manuallyStoppedFeeds.remove(id)
    var policy = feedPolicies[id] ?? AutomaticFeedPolicy()
    policy.retry()
    feedPolicies[id] = policy
    programTransportRequired = false
    programTransportConfiguration = nil
    // `start()` is idempotent while the monitor is healthy, and retries the
    // listener registration after an initial setup failure. `refresh()` alone
    // is a no-op in that failed state because the monitor is disabled there.
    demandMonitor.start()
    demandMonitor.refresh()
    reconcileAutomaticFeed()
  }

  /// Starts and stops cameras on automatic start from their demand: a camera
  /// app, a visible picture, a recording, or (Program mode) Program's. The
  /// same rules for every camera.
  private func reconcileAutomaticFeed() {
    guard !launching else { return }
    // In Program mode a camera the user started keeps Program's sources up.
    let programRequested = monitorDemand.contains(MonitorTargetID("program")) ||
      routeDemand[VirtualCameraDescriptor.program().id] == true ||
      (outputMode == .program && feedDescriptors.contains {
        feedCoordinator.isFeedRunning($0.id) && !demandStartedFeeds.contains($0.id)
      })
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
      let camera = routeDemand[feedRouteID(id)] == true
      policy.demand(camera || (outputMode == .program && programRequested) || recording)
      policy.previewDemand(descriptor.previewEnabled && monitorDemand.contains(MonitorTargetID(id.rawValue)))
      let isRunning = feedCoordinator.isFeedRunning(id)
      // A camera waits for its own LUT, so its first frame is graded.
      let ready = FeedLifecycleDemandPolicy.canStartSource(automaticEnabled: descriptor.automaticFeed,
        manuallyStopped: manuallyStoppedFeeds.contains(id),
        deviceAvailable: devices.contains { $0.id == descriptor.selectedDevice } && inputInUse(by: id) == nil,
        loading: lutLoadingFeeds.contains(id))
      let action = policy.action(ready: ready, running: isRunning)
      feedPolicies[id] = policy
      let why = [camera ? "camera app" : nil, recording ? "recording" : nil,
        outputMode == .program && programRequested ? "Program" : nil,
        policy.previewRequested ? "preview" : nil].compactMap { $0 }.joined(separator: ", ")
      switch action {
      case .start:
        captureLog.notice("Start \(id.rawValue, privacy: .public): automatic (\(why.isEmpty ? "demand" : why, privacy: .public))")
        demandStartedFeeds.insert(id)
        refusedStarts.remove(id)
        launchCapture(id)
      case .stop:
        guard demandStartedFeeds.contains(id), !recording else { continue }
        captureLog.notice("Stop \(id.rawValue, privacy: .public): automatic (no camera app, preview or recording needs it)")
        demandStartedFeeds.remove(id)
        endCapture(id, message: "Waiting for demand")
      case nil: break
      }
    }
    reconcileProgramTransportDemand()
  }

  /// Program transport follows its camera clients and the actual on-air source.
  private func reconcileProgramTransportDemand() {
    let producerID = feedCoordinator.programOutput.selectedFeedID
    let producer = feedDescriptors.first { $0.id == producerID && $0.enabled }
    let required = FeedLifecycleDemandPolicy.programTransportRequired(
      programMode: outputMode == .program,
      cameraRequested: routeDemand[VirtualCameraDescriptor.program().id] == true,
      onAirProducerRunning: producer.map { feedCoordinator.isFeedRunning($0.id) } ?? false)
    let contract = programContract(for: producer)
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
      self.showStatus("Program camera unavailable: \(error.localizedDescription)")
    }
  }

  /// The camera format a Program source delivers. The LUT changes pixel
  /// values, not the format, so it never renegotiates the Program camera.
  private func programContract(for descriptor: FeedDescriptor?) -> PipelineConfiguration {
    guard let descriptor else {
      return FeedLifecycleDemandPolicy.programContract(configuration: PipelineConfiguration(),
        pipelineEnabled: true, detectedSourceDuration: nil)
    }
    var contract = FeedLifecycleDemandPolicy.programContract(configuration: effectiveConfiguration(for: descriptor.id),
      pipelineEnabled: descriptor.pipelineEnabled, detectedSourceDuration: detectedSourceDurations[descriptor.id])
    contract.applyLUT = false
    return contract
  }

  /// Program output counters for diagnostics: route, GPU conversion, camera.
  var programOutputDiagnostics: (route: ProgramRouteStatistics, camera: ProgramOutputBridge.Statistics,
                                 gpu: ProgramNormalizer.Statistics?, contract: ProgramOutputFormat?) {
    (feedCoordinator.programRouteStatistics, feedCoordinator.programOutputStatistics,
     feedCoordinator.programNormalizerStatistics, feedCoordinator.programOutput.contract)
  }

  // MARK: - Per-camera control

  func descriptor(for id: FeedID) -> FeedDescriptor? { feedDescriptors.first { $0.id == id } }

  /// Automatic mode asked this camera to run and it isn't running: its start failed.
  /// The interface offers Retry (one attempt per camera session, no background loop).
  /// A camera the user stopped hasn't failed; it stays off until Start.
  func automaticStartFailed(_ id: FeedID) -> Bool {
    if startRefusal(id) != nil { return true }
    guard let descriptor = descriptor(for: id), descriptor.automaticFeed, !feedCoordinator.isFeedRunning(id),
      !manuallyStoppedFeeds.contains(id) else { return false }
    return feedPolicies[id]?.captureRequested == true
  }

  func isCameraRunning(_ id: FeedID) -> Bool { feedCoordinator.isFeedRunning(id) }

  /// Cached device facts and live counters for the camera's input; never
  /// calls into the driver.
  func deviceDiagnostics(_ id: FeedID) -> DeviceDiagnostics? {
    guard let deviceID = descriptor(for: id)?.selectedDevice, !deviceID.isEmpty else { return nil }
    return hardware.diagnostics(deviceID)
  }

  /// The latest status for any camera. A view reading it follows its state only; one that
  /// shows its running values (timecode, levels, counters) reads `liveCameraUpdate`.
  func cameraUpdate(_ id: FeedID) -> CaptureUpdate? { cameraUpdates[id] }

  /// The latest status, followed with every update (4 Hz while capturing).
  func liveCameraUpdate(_ id: FeedID) -> CaptureUpdate? {
    _ = telemetry.camera(id).capture
    return cameraUpdates[id]
  }

  /// Program mode: the "Ultracam · Program" virtual camera has at least one client.
  var programInUse: Bool { routeDemand[VirtualCameraDescriptor.program().id] == true }

  private func feedRouteID(_ id: FeedID) -> String {
    if let cached = feedRouteIDs[id] { return cached }
    let routeID = VirtualCameraDescriptor.feed(feedID: id.rawValue).id
    feedRouteIDs[id] = routeID
    return routeID
  }

  /// Separate mode: this camera's virtual camera has at least one client.
  func cameraInUse(_ id: FeedID) -> Bool {
    routeDemand[feedRouteID(id)] == true
  }

  /// Starts one camera, whichever is selected. It then stays up until Stop.
  func startCamera(_ id: FeedID) {
    guard let descriptor = descriptor(for: id), descriptor.enabled else { return }
    if let error = descriptor.processingDeclarationError { showStatus(error); return }
    manuallyStoppedFeeds.remove(id)
    guard !feedCoordinator.isFeedRunning(id) else { return }
    guard canStart(id) else {
      captureLog.notice("Start \(id.rawValue, privacy: .public): user, refused")
      noteStartAttempt(id, started: false)
      return
    }
    captureLog.notice("Start \(id.rawValue, privacy: .public): user")
    noteStartAttempt(id, started: true)
    // A camera the user started is theirs: demand never stops it.
    demandStartedFeeds.remove(id)
    launchCapture(id)
    reconcileAutomaticFeed()
  }

  /// Stops one camera: capture, its output and its recording. Other cameras
  /// keep running. Stop is a choice: automatic start leaves it off until Start.
  func stopCamera(_ id: FeedID) {
    guard descriptor(for: id) != nil else { return }
    manuallyStoppedFeeds.insert(id)
    refusedStarts.remove(id)
    demandStartedFeeds.remove(id)
    if feedCoordinator.isFeedRunning(id) {
      captureLog.notice("Stop \(id.rawValue, privacy: .public): user")
      endCapture(id, message: "Camera stopped")
    } else {
      recordingModel.stop(feedID: id)
      cameraStateRevision &+= 1
    }
    expireResolvedStartRefusals()
  }

  func startAllCameras() {
    for descriptor in feedDescriptors where descriptor.enabled && !descriptor.selectedDevice.isEmpty {
      startCamera(descriptor.id)
    }
  }

  func stopAllCameras() {
    for descriptor in feedDescriptors where feedCoordinator.isFeedRunning(descriptor.id) {
      stopCamera(descriptor.id)
    }
  }

  /// Edits one camera's saved settings and applies them to its pipeline. The
  /// one path for every camera's edits; the selection plays no part.
  func updateCamera(_ id: FeedID, _ mutate: (inout FeedDescriptor) -> Void) {
    guard var descriptor = descriptor(for: id) else { return }
    let before = descriptor
    mutate(&descriptor)
    // One input serves one camera: an input another camera has is refused, and a
    // running camera keeps its input. None is remembered so discovery leaves it.
    if descriptor.selectedDevice != before.selectedDevice {
      if inputHolder(descriptor.selectedDevice, excluding: id) != nil || cameraActive(id) {
        descriptor.selectedDevice = before.selectedDevice
      } else {
        if descriptor.selectedDevice.isEmpty { inputsClearedByChoice.insert(id) } else { inputsClearedByChoice.remove(id) }
        // Another camera on this input: its signal calibration doesn't apply.
        descriptor.monitor.forgetCameraCalibration()
      }
    }
    guard descriptor != before else { return }
    if descriptor.applyLUT != before.applyLUT {
      lutLog.notice("Apply LUT \(descriptor.applyLUT ? "on" : "off", privacy: .public): \(id.rawValue, privacy: .public), running: \(self.isCameraRunning(id), privacy: .public), saved LUT: \(descriptor.lutBookmark != nil, privacy: .public)")
    }
    feedCoordinator.update(descriptor)
    if descriptor.recordingConstantFrameRate != before.recordingConstantFrameRate { syncRecordingFeeds() }
    if descriptor.processingChoicesDiffer(from: before) { synchronizeProcessing(from: descriptor) }
    saveSettings(reason: "camera settings changed")
    if descriptor.selectedDevice != before.selectedDevice { forgetStartRefusal(id) }
    if descriptor.previewEnabled != before.previewEnabled {
      monitorCoordinator.setPreviewEnabled(descriptor.previewEnabled, for: MonitorTargetID(id.rawValue))
    }
    // The saved LUT changed to another file than the one in this camera's
    // pipeline, or a load in flight is superseded: read it. A bookmark for the
    // same file reads nothing.
    if descriptor.lutInputSpaceID != before.lutInputSpaceID || descriptor.lutOutputSpaceID != before.lutOutputSpaceID {
      cancelLUTLoad(id)
      cameraLUTs[id] = nil
      if descriptor.lutBookmark != nil { restoreLUT(id) }
    } else if descriptor.lutBookmark != before.lutBookmark,
      lutLoadingFeeds.contains(id) || !sameLUTFile(descriptor.lutBookmark, lutState(id).bookmark) {
      cancelLUTLoad(id)
      cameraLUTs[id] = nil
      if descriptor.lutBookmark != nil { restoreLUT(id) }
    } else if descriptor.applyLUT, !before.applyLUT, !lutState(id).loaded, descriptor.lutBookmark != nil,
      !lutLoadingFeeds.contains(id) {
      // Turned on with its saved LUT not in memory (it could not be read at
      // launch): read it again. It is applied when it loads.
      restoreLUT(id)
    }
    applyPipeline(id)
    if descriptor.automaticFeed != before.automaticFeed {
      if !descriptor.automaticFeed { demandStartedFeeds.remove(id) }
      installAutomaticFeedMonitor()
    } else if descriptor.previewEnabled != before.previewEnabled {
      reconcileAutomaticFeed()
    }
  }

  /// Clears every saved preference. Only allowed while no camera runs or records;
  /// the app should quit afterwards so nothing writes the old state back.
  @discardableResult
  func resetAllSettings() -> Bool {
    guard canEditFeedTopology else { return false }
    settingsResetPending = true
    cameraControls.reset()
    vendorSettings.reset()
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
    let contracts = feedDescriptors.filter { $0.enabled && feedCoordinator.isFeedRunning($0.id) }.map(programContract)
    guard let first = contracts.first else { return false }
    return contracts.contains { $0 != first }
  }
}
