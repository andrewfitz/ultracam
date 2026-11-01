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

/// A camera that stopped by itself, or a take that ended early. Held until someone
/// has seen it: not persisted, because after a relaunch Interrupted Takes carries the loss.
struct UnexpectedStop: Equatable, Sendable {
  /// Why. Shown while `cameraStopped`, and for the take after.
  let reason: String
  let at: Date
  /// False once it restarts, or when only the take ended. The take result stays.
  var cameraStopped: Bool
  var wasOnAir = false
  /// The camera stopped and was started again: the take's half is the same incident.
  var restarted = false
  /// Filled in when the take finishes: nil until then, and with no take.
  var take: UnexpectedTakeResult?
}

enum UnexpectedTakeResult: Equatable, Sendable {
  case saved(URL, duration: TimeInterval, lostFrames: UInt64)
  /// Recovery owns it: it's in Interrupted Takes.
  case interrupted
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
  /// What Ultracam · Program sends. One value for Program, kept on every camera because
  /// Program takes it from the camera on air; the first camera's is the setting.
  var programColorSpaceID: String { feedDescriptors.first?.programColorSpaceID ?? "rec709-video" }
  func setProgramColorSpace(_ space: String) {
    for descriptor in feedDescriptors where descriptor.programColorSpaceID != space {
      updateCamera(descriptor.id, shareProcessing: false) { $0.programColorSpaceID = space }
    }
  }
  /// The LUT a camera burns into its output now (nil when none): what its
  /// virtual camera, Program and monitor Output stage get. Recording never
  /// does: it takes the camera original. Never creates a capture controller.
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

  /// Switching exists with two cameras: Program is published and cuts are offered.
  var programAvailable: Bool {
    FeedLifecycleDemandPolicy.programPublished(enabledCameras: feedDescriptors.filter(\.enabled).count)
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
      var settings = feedCoordinator.switcher
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
    return "Runs with two cameras, while Program has a picture or a take rolls"
  }

  /// Nothing runs, stops, records or loads anywhere: settings can be wiped.
  var canResetSettings: Bool {
    FeedLifecycleDemandPolicy.canResetSettings(loading: !lutLoadingFeeds.isEmpty,
      sourceActive: feedDescriptors.contains { cameraActive($0.id) },
      recordingActive: recordingModel.feeds.contains { $0.isActive })
  }

  var canAddCamera: Bool {
    FeedLifecycleDemandPolicy.canAddCamera(enabledCameras: feedDescriptors.filter(\.enabled).count)
  }

  /// A camera can go while the others run and record. Its own run, take and LUT load have to
  /// finish first; a meeting client on it keeps its device, on black, until that client leaves.
  func canRemoveCamera(_ id: FeedID) -> Bool {
    FeedLifecycleDemandPolicy.canRemoveCamera(cameraCount: feedDescriptors.count,
      loading: lutLoadingFeeds.contains(id), sourceActive: cameraActive(id),
      recordingActive: recordingModel.feeds.contains { $0.id == id && $0.isActive })
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
  /// Who is really using each route, this moment: tally and problems read this. Work reads
  /// `routeHeld`, which outlasts a client by `LiveWatchLimits.clientRelease`.
  private var routeDemand: [String: Bool] = [:]
  /// Routes whose client left, and when that takes effect (`systemUptime`).
  @ObservationIgnored private var routeReleaseAt: [String: TimeInterval] = [:]
  /// What each running camera's controller was last told about its sink.
  @ObservationIgnored private var sinkDemand: [FeedID: FeedLifecycleDemandPolicy.SinkDemand] = [:]
  /// Routes the demand monitor can't read: whether they have a client is unknown, not "no".
  private var unknownRoutes: Set<String> = []
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
  /// The name of every input seen, so an unplugged one keeps its name. Saved across
  /// launches by the hardware inventory.
  @ObservationIgnored private var lastInputNames: [String: String] = [:] {
    // After Reset nothing is saved, or a device arriving before the quit would write them back.
    didSet { if !settingsResetPending { hardwareInventory.recordNames(lastInputNames) } }
  }
  /// Errors that used to reach only Diagnostics. Each stays until acknowledged or resolved.
  private(set) var appProblems: [UIAppProblem] = []
  private(set) var unexpectedStops: [FeedID: UnexpectedStop] = [:]
  /// Program moved off a camera that lost its signal.
  private(set) var programMoved: UIProgramMove?
  /// The extension's Program queue has been full past `LiveWatchLimits.queueStall`.
  private(set) var programQueueStalled = false
  /// A cut landed with a client on a camera's own device and none on Program.
  private(set) var cutsMissClient = false
  /// A take has outlived the last client seen during it.
  private(set) var unusedTake = false
  /// Which cameras have really lost their signal, and which may take a cut again.
  @ObservationIgnored private var signalHealth = SignalHealthTracker()
  /// The cameras in the order their strips show. The interface owns that order.
  @ObservationIgnored var stripOrder: ([FeedID]) -> [FeedID] = { $0 }
  /// Program's sink is open. Polled by the live watch: the bridge isn't observable.
  private(set) var programSinkConnected = false
  /// Cameras whose client has been waiting for frames past `LiveWatchLimits.clientWaiting`.
  private(set) var waitingClients: Set<FeedID> = []
  @ObservationIgnored private var clientWaitingSince: [FeedID: TimeInterval] = [:]
  /// Cameras whose extension queue has been full past `LiveWatchLimits.queueStall`.
  private(set) var stalledCameras: Set<FeedID> = []
  @ObservationIgnored private var unusedTakeWatch = UnusedTakeWatch()
  /// Early takes someone has seen, until the next take starts on that camera.
  private(set) var acknowledgedTakes: Set<FeedID> = []
  @ObservationIgnored private var liveWatchTimer: Timer?
  /// When a failed sink connect may next try again, while its client waits.
  @ObservationIgnored private var connectRetryAt: [FeedID: TimeInterval] = [:]
  @ObservationIgnored private var programConnectRetryAt: TimeInterval = 0
  private var programTransportRequired = false
  /// `programPicture` as of the last reconcile: its rise moves Program off an empty camera.
  @ObservationIgnored private var programPictureWanted = false
  @ObservationIgnored private var monitorProgramAvailable = false
  private var programTransportConfiguration: PipelineConfiguration?
  /// The contract last written to the closed Program camera.
  @ObservationIgnored private var programPreNegotiated: PipelineConfiguration?
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
  /// Nicknames, last known names and cached device status (Settings › Hardware, the left pane).
  let hardwareInventory: HardwareInventory
  var controlViewFactories: [String: ControlViewFactory] { hardware.controlViewFactories() }
  /// A listed capture device as its plugin describes it; nil once unlisted.
  func captureDevice(_ deviceID: String) -> CaptureDeviceInfo? { hardware.captureDevice(deviceID) }
  /// Each capture vendor's driver, by vendor ID.
  var captureDrivers: [String: DriverStatus] { hardware.captureDrivers() }
  func captureVendor(for deviceID: String) -> VendorDescriptor? { hardware.captureDescriptor(deviceID) }
  /// Capture vendors in registry order; Settings › Hardware groups devices by them.
  var captureVendors: [VendorDescriptor] { hardware.captureVendors() }
  /// Camera Control vendors in registry order.
  var controlVendors: [VendorDescriptor] { hardware.controlPlugins().map(\.descriptor) }
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
  /// The cameras the running director cuts between, fixed when it was built.
  private var directorCameras: (anchor: FeedID, emphasis: FeedID)?
  /// The camera whose clock the running director last heard (`directorClockFeedID`).
  @ObservationIgnored private var directorClockOwner: FeedID?
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
  /// Shown as the status warning until cleared.
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
    self.hardwareInventory = HardwareInventory(defaults: store.preferenceDefaults, hardware: hardware)
    lastInputNames = hardwareInventory.lastKnownNames
    self.registryPublisher = registryPublisher ?? VirtualCameraRegistryPublisher()
    hideFromDock = store.hideFromDock
    self.virtualCameraRegistryStore = registryStore ?? VirtualCameraRegistryStore()
    let snapshot = store.loadSnapshot()
    persistedSnapshot = snapshot
    // Saved without an input beside cameras that have one: that camera was set to None.
    // Only a fresh setup, where no camera has an input yet, is filled in on its own.
    inputsClearedByChoice = Set(snapshot.feeds.filter(\.inputClearedByChoice).map(\.id))
    if snapshot.feeds.contains(where: { !$0.selectedDevice.isEmpty }) {
      inputsClearedByChoice.formUnion(snapshot.feeds.filter { $0.selectedDevice.isEmpty }.map(\.id))
    }
    monitorCoordinator = MonitorCoordinator(feeds: snapshot.feeds, program: snapshot.programMonitor,
      workspace: snapshot.monitorWorkspacePreferences)
    let capturePool = FeedCapturePool(factory: { feedID in
      CaptureController(services: hardware.captureServices(feedID))
    })
    feedCoordinator = FeedCoordinator(snapshot: snapshot, capturePool: capturePool)
    let coordinator = feedCoordinator
    if let programBridge = hardware.programBridge { coordinator.makeProgramBridge = programBridge }
    recordingModel = RecordingModel(
      feeds: feedCoordinator.descriptors.map { RecordingFeedDescriptor(id: $0.id, name: $0.name, recordingConstantFrameRate: $0.recordingConstantFrameRate) },
      driver: NativeRecordingSessionDriver(captureForFeed: { id in coordinator.capture(for: id) },
        rawAudioCallbackAvailable: true),
      folderStore: recordingFolderStore ?? RecordingFolderStore())
    self.lutLoader = lutLoader
    allowCPUConversion = store.allowCPUConversion
    recordingModel.codec = store.recordingCodec
    recordingModel.timecodeMode = store.recordingTimecodeMode
    recordingModel.naming = store.recordingNaming
    recordingModel.onRecordingChoicesChanged = { [weak self] in
      guard let self else { return }
      self.settingsStore.recordingCodec = self.recordingModel.codec
      self.settingsStore.recordingTimecodeMode = self.recordingModel.timecodeMode
      self.settingsStore.recordingNaming = self.recordingModel.naming
    }
    recordingModel.compatibilityPolicy = sampledRecordingCompatibilityPolicy
    recordingModel.sourceFormat = { [weak self] id in self?.cameraUpdate(id)?.sourceFormat }
    hardware.setCompatibilityPolicy(sampledRecordingCompatibilityPolicy)
    monitorCoordinator.onConfigurationChange = { [weak self] target, configuration in
      guard let self else { return }
      // The coordinator reports a target's whole preferences: they replace the saved ones.
      let previous = self.monitorPreferences(of: target)
      if target.rawValue == "program" {
        self.feedCoordinator.programMonitor = configuration
      } else if let descriptor = self.feedDescriptors.first(where: { $0.id.rawValue == target.rawValue }) {
        if descriptor.monitor.signal.logProfileID != configuration.signal.logProfileID {
          // A camera declaration updates its processing, but stays camera-specific
          // while synchronized monitor tools are copied below.
          self.updateCamera(descriptor.id, shareProcessing: false) { camera in
            camera.monitor = configuration
            camera.setSourceProfile(configuration.signal.logProfileID ?? "unspecified")
          }
        } else {
          var updated = descriptor
          updated.monitor = configuration
          self.feedCoordinator.update(updated)
        }
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
    monitorCoordinator.updateTargets(feeds: feedCoordinator.descriptors, programAvailable: programAvailable)
    recordingModel.onOutputFolderChanged = { [weak self] folder in
      self?.autoSwitcherTimeline?.setOutputFolder(folder)
    }
    recordingModel.onRecordingStarted = { [weak self] feedID, url in
      guard let self else { return }
      self.acknowledgedTakes.remove(feedID)
      if self.unexpectedStops[feedID]?.cameraStopped == false { self.unexpectedStops[feedID] = nil }
      self.beginTakeAudio(feedID)
      // A take can be what starts the director, and it binds to that director's timeline.
      self.reconcileAutomaticFeed()
      guard let timeline = self.autoSwitcherTimeline else { return }
      self.recordingTimelines[feedID] = timeline
      timeline.recordingStarted(feedID: feedID, url: url, mediaStart: self.directorUpdate?.mediaTime)
    }
    recordingModel.onRecordingFinished = { [weak self] feedID, url in
      guard let self else { return }
      self.noteTakeFinished(feedID, saved: url)
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
      self?.noteCutReach()
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
        sourceTime: sourceTime, programTime: programTime, directorAppliedAt: nil)
      // The director clock is one camera's audio time. The frame that
      // landed the cut has a different source's video PTS, so acknowledging
      // with that PTS moves the director onto the wrong timeline. Nil keeps
      // the shot start on the decision's own cut time.
      self.autoSwitcherBridge?.acknowledge(decisionID: decisionID, appliedAt: nil)
    }
    launching = false
    // Program color is one setting, kept on every camera, and older builds could save it apart:
    // what Program declared would change with the camera on air. The first camera's wins.
    let programColor = programColorSpaceID
    if feedDescriptors.contains(where: { $0.programColorSpaceID != programColor }) {
      for var descriptor in feedDescriptors where descriptor.programColorSpaceID != programColor {
        descriptor.programColorSpaceID = programColor
        feedCoordinator.update(descriptor)
      }
      persistedSnapshot = feedCoordinator.snapshot
      store.saveSnapshot(persistedSnapshot)
    }
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
      // Retries a monitor that couldn't register, now that CMIO's cameras changed.
      if self?.wantsDemandMonitor == true { self?.demandMonitor.refresh() }
      // Program's camera may be new, after its write found none to go to.
      self?.programPreNegotiated = nil
      self?.reconcileProgramTransportDemand()
    }
    demandMonitor.onRouteChange = { [weak self] change in
      self?.routeDemandChanged(change.route.id, requested: change.requested, error: change.error)
    }
    if wantsDemandMonitor { demandMonitor.start() }
  }

  private func routeDemandChanged(_ route: String, requested: Bool?, error: String?) {
    // Every client edge, with its time in the log: whether apps open streams just to
    // probe a camera, and how often, can be read from these.
    if (routeDemand[route] == true) != (requested == true) || (requested == nil) != unknownRoutes.contains(route) {
      captureLog.notice("Client \(requested == nil ? "unknown" : requested == true ? "in" : "out", privacy: .public): \(route, privacy: .public)")
    }
    // Rises act at once. A fall waits out the hold, in case it was a probe.
    if requested == true {
      routeReleaseAt[route] = nil
    } else if routeDemand[route] == true {
      routeReleaseAt[route] = ProcessInfo.processInfo.systemUptime + LiveWatchLimits.clientRelease
    }
    routeDemand[route] = requested == true
    if requested == nil { unknownRoutes.insert(route) } else { unknownRoutes.remove(route) }
    routeErrors[route] = error
    reconcileAutomaticFeed()
    updateLiveWatch()
  }

  /// Tally needs real clients in every layout, so in the app this is always on. It only
  /// registers CMIO listeners: the demand property is the extension's own signal on the
  /// source stream, and watching it opens nothing.
  private var wantsDemandMonitor: Bool {
    hardware.observesCameraDemand
  }

  func refresh() {
    do {
      applyDevices(try hardware.devices(), fromDiscovery: false)
    } catch {
      applyDevices([], fromDiscovery: false)
      reportProblem(error.localizedDescription, key: "inputs")
    }
    driverWarning = hardware.driverWarning()
  }

  private func applyDevices(_ next: [InputDevice], fromDiscovery: Bool) {
    // Discovery reports every arrival, including devices already listed.
    if fromDiscovery, next == devices { return }
    for device in next { lastInputNames[device.id] = device.name }
    devices = next
    hardwareInventory.devicesListed(next.map(\.id))
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
      if wantsDemandMonitor { demandMonitor.refresh() }
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
  /// immediately edits the new feed's independent settings. Other cameras keep
  /// running and recording, and Program keeps its frames.
  @discardableResult
  func addFeed(name: String? = nil) -> FeedID? {
    guard canAddCamera else { return nil }
    let source = feedCoordinator.selectedDescriptor
    let programColor = programColorSpaceID
    let id = feedCoordinator.add(name: name)
    wireCamera(id)
    // Program color is one setting: a new camera sends what the others do.
    if let added = descriptor(for: id), added.programColorSpaceID != programColor {
      var updated = added
      updated.programColorSpaceID = programColor
      feedCoordinator.update(updated)
    }
    feedCoordinator.capture(for: id).setProgramPictureWanted(programPictureWanted)
    synchronizeProcessing(from: source)
    synchronizeMonitoring(from: MonitorTargetID(source.id.rawValue), preferences: source.monitor)
    syncRecordingFeeds()
    guard selectFeed(id) else { return nil }
    saveSettings()
    // A second camera publishes Program: prepare its format before a client finds it.
    reconcileProgramTransportDemand()
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

  /// A take that ended by itself stays on the list until someone has seen it, as does one
  /// a stopped camera took with it. A take stopped by hand needs nothing.
  private func noteTakeFinished(_ id: FeedID, saved url: URL?) {
    let state = recordingModel.feeds.first { $0.id == id }
    let statistics = state?.statistics
    let failed = statistics?.failed == true || state?.error != nil
    guard failed || unexpectedStops[id] != nil else { return }
    var result: UnexpectedTakeResult?
    if let url {
      result = .saved(url, duration: statistics?.elapsed ?? 0, lostFrames: statistics?.droppedVideoFrames ?? 0)
    } else if statistics?.encodedFrames ?? 0 > 0 {
      result = .interrupted
    }
    if unexpectedStops[id] != nil {
      unexpectedStops[id]?.take = result
    } else {
      unexpectedStops[id] = UnexpectedStop(reason: state?.error ?? statistics?.lastError ?? "The take ended early.",
        at: Date(), cameraStopped: false, take: result)
    }
  }

  /// A take finished (saved, failed or stopped while starting): keep its audio for the strip, and log it.
  private func endTakeAudio(_ id: FeedID) {
    guard let summary = takeTaps.removeValue(forKey: id)?.endTake() else { return }
    takeAudio[id] = summary
    let name = feedDescriptors.first { $0.id == id }?.name ?? id.rawValue
    audioLog.notice("Take on \(name, privacy: .public): \(summary.note, privacy: .public), \(String(format: "%.1f", summary.duration), privacy: .public) s measured")
  }

  /// Removes an idle feed while the others carry on. The coordinator owns the
  /// running/removal guard and moves the selection to the first remaining camera.
  @discardableResult
  func removeFeed(_ id: FeedID) -> Bool {
    guard canRemoveCamera(id) else { return false }
    guard feedCoordinator.remove(id) else { return false }
    let route = feedRouteID(id)
    routeDemand[route] = nil
    routeReleaseAt[route] = nil
    unknownRoutes.remove(route)
    routeErrors[route] = nil
    feedRouteIDs[id] = nil
    cancelLUTLoad(id)
    takeAudio[id] = nil
    Task { await cameraControls.removeFeed(id.rawValue) }
    cameraLUTs[id] = nil
    cameraUpdates[id] = nil
    feedPolicies[id] = nil
    sinkDemand[id] = nil
    stalledCameras.remove(id)
    signalHealth.remove(id)
    unexpectedStops[id] = nil
    acknowledgedTakes.remove(id)
    clearProblem("declaration.\(id.rawValue)")
    waitingClients.remove(id)
    clientWaitingSince[id] = nil
    connectRetryAt[id] = nil
    detectedSourceDurations[id] = nil
    lastSourceDurations[id] = nil
    appliedPipelines[id] = nil
    monitorCoordinator.setBurnInLUTSource(for: MonitorTargetID(id.rawValue), nil)
    syncRecordingFeeds()
    saveSettings(reason: "camera removed")
    // It may have been the director's anchor or emphasis, or Program's selection. Down to one
    // camera, Program's demand went with it (`saveSettings`): cameras stop rendering for it,
    // and one started for it stops. This reconciles the director and the transport too.
    reconcileAutomaticFeed()
    return true
  }

  /// Live: no device, sink or take depends on the name. A running extension keeps the
  /// name it published, so meeting apps see the new one after it next restarts.
  @discardableResult
  func renameFeed(_ id: FeedID, name: String) -> Bool {
    guard let existing = feedCoordinator.descriptors.first(where: { $0.id == id }) else { return false }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    var updated = existing
    updated.name = trimmed
    feedCoordinator.update(updated)
    syncRecordingFeeds()
    saveSettings()
    return true
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
    // A cut with nothing on air fires no event, so the transport hears of it here.
    defer { reconcileProgramTransportDemand() }
    // Also with nothing on air, where the switcher would just select it.
    guard !signalHealth.isUnhealthy(feedID) else { return .rejectedMissingSource }
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

  /// The camera whose audio and clock the director runs on: the anchor while it runs,
  /// otherwise the emphasis camera, otherwise the first one running. Each input has its own
  /// stream clock, so this can't follow the selection, which any click moves, or Program.
  private var directorClockFeedID: FeedID? {
    let settings = feedCoordinator.switcher.naturalTalkingHead
    let preferred = [directorCameras?.anchor ?? settings.anchorFeedID, directorCameras?.emphasis ?? settings.emphasisFeedID]
    return preferred.compactMap { $0 }.first(where: feedCoordinator.isFeedRunning)
      ?? feedDescriptors.first { $0.enabled && feedCoordinator.isFeedRunning($0.id) }?.id
  }

  /// The director's clock source. No camera's pipeline depends on it.
  private var directorUpdate: CaptureUpdate? { directorClockFeedID.flatMap { cameraUpdates[$0] } }

  /// Audio packet time from the clock camera. That is the clock the Rust
  /// director ticks, so manual cuts have to be expressed on it.
  private func directorClock() -> CMTime {
    directorUpdate?.audioPacketTime ?? directorUpdate?.mediaTime ?? .zero
  }
  private func reconcileAutoSwitcher() {
    guard directorWanted,
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
    // A running director keeps its two cameras, and its clock moves from one to the other.
    // With neither left it hears nothing, so it starts over on two that run.
    if let directorCameras, autoSwitcherBridge != nil {
      if enabledIDs.contains(directorCameras.anchor) || enabledIDs.contains(directorCameras.emphasis) { return }
      stopAutoSwitcher()
    }
    guard let bridge = AutoSwitcherBridge(settings: settings, anchor: anchor, emphasis: emphasis) else {
      reportProblem("Natural Talking Head could not start its Rust director.", key: "director")
      return
    }
    autoSwitcherTimeline = AutoSwitcherTimelineRecorder(settings: settings, anchor: anchor,
      emphasis: emphasis, outputFolder: recordingModel.outputFolder)
    guard let timeline = autoSwitcherTimeline else { return }
    timeline.onError = { [weak self] message in
      self?.reportProblem("Auto-switcher timeline: \(message)", key: "timeline")
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
        guard let self, self.autoSwitcherBridge === bridge else { return }
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
        self.reportProblem("Auto director: \(message)", key: "director")
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
    directorCameras = (anchor, emphasis)
    directorClockOwner = directorClockFeedID
    if let current = feedCoordinator.programOutput.selectedFeedID,
      (current == anchor || current == emphasis) {
      bridge.manualOverride(cameraID: current, at: directorUpdate?.mediaTime ?? .zero)
    }
  }

  private func stopAutoSwitcher() {
    let directorCutPending = pendingAutoDecisionID != nil
    pendingAutoDecisionID = nil
    pendingAutoTargetFeedID = nil
    // Stopping or reconfiguring the director must not leave its queued target
    // in the Program scheduler to switch after the UI has disabled automation.
    // A cut the operator asked for isn't the director's to cancel.
    if directorCutPending { feedCoordinator.cancelProgramCut() }
    autoSwitcherBridge?.stop()
    autoSwitcherBridge = nil
    directorCameras = nil
    directorClockOwner = nil
    autoSwitcherTimeline?.finish()
    autoSwitcherTimeline = nil
  }

  private func feedAutoSwitcherAudio(_ update: CaptureUpdate) {
    guard let time = update.mediaTime ?? update.audioPacketTime else { return }
    if autoSwitcherBridge == nil {
      if directorWanted { _ = feedCoordinator.evaluateSwitcher(at: time) }
      else { feedCoordinator.expirePendingCut() }
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
    if wantsDemandMonitor { demandMonitor.start() }
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
    let available = programAvailable
    // A monitor that lost Program takes frames again from a new generation, and a Program
    // camera published again has had nothing written to it.
    if available, !monitorProgramAvailable {
      programMonitorTap?.restart()
      programPreNegotiated = nil
    }
    // Down to one camera: the monitor no longer follows Program, so its client is
    // forgotten here. Any client left keeps the device, on standby black, until it goes.
    if !available {
      let route = VirtualCameraDescriptor.program().id
      routeDemand[route] = nil
      routeReleaseAt[route] = nil
      unknownRoutes.remove(route)
    }
    monitorProgramAvailable = available
    monitorCoordinator.updateTargets(feeds: feedDescriptors, programAvailable: available)
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
    let candidate = VirtualCameraRegistrySnapshot.forFeeds(snapshot.feeds, previous: previous)
    do {
      try candidate.validateDeviceCount()
      try virtualCameraRegistryStore.save(candidate)
      if candidate != previous {
        registryLog.notice("Registry publish: generation \(candidate.generation, privacy: .public), \(candidate.devices.filter(\.enabled).count, privacy: .public) devices, reason: \(reason, privacy: .public)")
      }
      registryPublisher.publish(candidate)
    } catch {
      registryLog.error("Registry publish failed: \(error.localizedDescription, privacy: .public)")
      reportProblem("Virtual cameras could not be updated: \(error.localizedDescription)", key: "registry")
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
    if let error = descriptor(for: id)?.processingDeclarationError { reportProblem(error, key: "declaration.\(id.rawValue)"); return }
    clearProblem("declaration.\(id.rawValue)")
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
      signalHealth.remove(feedID)
      let failed: Bool
      if case .failed(let reason)? = update.stopCause {
        unexpectedStops[feedID] = UnexpectedStop(reason: reason, at: Date(), cameraStopped: true,
          wasOnAir: programInUse && switcherSelectedFeedID == feedID)
        failed = true
      } else {
        failed = false
      }
      monitorCoordinator.sourceStateChanged(target: MonitorTargetID(feedID.rawValue), running: false, message: update.message)
      detectedSourceDurations[feedID] = nil
      appliedPipelines[feedID] = nil
      sinkDemand[feedID] = nil
      feedCoordinator.stopCapture(feedID: feedID)
      // A camera can fail on its own. Stop only its recording; the director
      // keeps cutting between the cameras still live.
      recordingModel.stop(feedID: feedID)
      retireProgramSource(feedID)
      moveProgramToProducingCamera(.stopped)
      // A failed camera can't wait out a hold: it has already gone.
      if failed { moveProgram(off: feedID) }
      reconcileAutoSwitcher()
      reconcileProgramTransportDemand()
      return
    }
    signalHealth.note(feedID, signal: update.signal, now: ProcessInfo.processInfo.systemUptime)
    if let duration = update.sourceDuration, duration.isNumeric, duration.epoch == 0, duration.value > 0,
      detectedSourceDurations[feedID] != duration {
      lastSourceDurations[feedID] = duration
      detectedSourceDurations[feedID] = duration
      reconcileProgramTransportDemand()
    }
    if feedID == directorClockFeedID {
      if autoSwitcherBridge != nil, directorClockOwner != feedID { rebaseDirectorClock(on: feedID, update) }
      feedAutoSwitcherAudio(update)
    }
  }

  /// The running director's clock moved to another camera, the anchor having stopped or come
  /// back: its timing starts over on that camera's clock (`AutoSwitcherBridge.rebaseClock`).
  /// A cut it asked for on the old clock goes with that timing.
  private func rebaseDirectorClock(on feedID: FeedID, _ update: CaptureUpdate) {
    guard let bridge = autoSwitcherBridge, let cameras = directorCameras,
      let time = update.audioPacketTime ?? update.mediaTime else { return }
    captureLog.notice("Director clock: \(self.directorClockOwner?.rawValue ?? "none", privacy: .public) → \(feedID.rawValue, privacy: .public)")
    directorClockOwner = feedID
    if let decisionID = pendingAutoDecisionID {
      pendingAutoDecisionID = nil
      pendingAutoTargetFeedID = nil
      autoSwitcherTimeline?.recordRejected(decisionID: decisionID)
      feedCoordinator.cancelProgramCut()
    }
    bridge.rebaseClock(at: time, onAir: switcherSelectedFeedID, health: [cameras.anchor, cameras.emphasis].map {
      ($0, feedCoordinator.isFeedRunning($0) && !signalHealth.isUnhealthy($0))
    })
  }

  /// Opens one camera's capture. The one start path, for every camera, manual
  /// or automatic, in either output mode.
  private func launchCapture(_ id: FeedID) {
    guard let descriptor = descriptor(for: id) else { return }
    if let error = descriptor.processingDeclarationError { reportProblem(error, key: "declaration.\(id.rawValue)"); return }
    reconcileSink(id, starting: true)
    detectedSourceDurations[id] = nil
    feedCoordinator.programOutput.setSourcePauseTolerance(id,
      mayPause: devices.first(where: { $0.id == descriptor.selectedDevice })?.mayPause)
    guard feedCoordinator.startCapture(feedID: id, deviceID: descriptor.selectedDevice,
      configuration: effectiveConfiguration(for: id), pipelineEnabled: descriptor.pipelineEnabled) else {
      feedCoordinator.setProgramSourceHealth(id, healthy: false)
      return
    }
    // A source retired after a failure must become eligible again only after
    // its next capture actually starts. Its signal starts over with it.
    feedCoordinator.setProgramSourceHealth(id, healthy: true)
    feedCoordinator.setProgramSourceCutEligible(id, eligible: true)
    // A restart clears the camera's half of an unexpected stop; the take's stays until seen.
    if var stop = unexpectedStops[id] {
      if stop.cameraStopped { stop.restarted = true }
      stop.cameraStopped = false
      unexpectedStops[id] = stop.take == nil ? nil : stop
    }
    appliedPipelines[id] = pipeline(for: id)
    cameraUpdates[id] = CaptureUpdate(message: "Opening input device…")
    cameraStateRevision &+= 1
    if programMoved?.from == descriptor.name { programMoved = nil }
    reconcileAutoSwitcher()
    reconcileProgramTransportDemand()
    updateLiveWatch()
  }

  /// Ends one camera's capture, its virtual camera output and its recording.
  private func endCapture(_ id: FeedID, message: String) {
    recordingModel.stop(feedID: id)
    feedCoordinator.stopCapture(feedID: id)
    signalHealth.remove(id)
    appliedPipelines[id] = nil
    detectedSourceDurations[id] = nil
    sinkDemand[id] = nil
    retireProgramSource(id)
    moveProgramToProducingCamera(.stopped)
    monitorCoordinator.sourceStateChanged(target: MonitorTargetID(id.rawValue), running: false, message: message)
    cameraUpdates[id] = nil
    cameraStateRevision &+= 1
    reconcileAutoSwitcher()
    reconcileProgramTransportDemand()
  }

  /// Opens a camera's sink for its client and closes it after. Capture, its take and its
  /// monitor run straight through either, and a start takes the current value with it.
  private func reconcileSink(_ id: FeedID, starting: Bool = false) {
    guard starting || feedCoordinator.isFeedRunning(id) else { return }
    let wanted = FeedLifecycleDemandPolicy.SinkDemand(client: routeHeld(feedRouteID(id)),
      routeUnknown: cameraClientUnknown(id))
    guard starting || sinkDemand[id] != wanted else { return }
    sinkDemand[id] = wanted
    feedCoordinator.requestCameraOutputEnabled(feedID: id, enabled: wanted.open, framesWanted: wanted.framesWanted)
  }

  /// A client, or one that left less than the hold ago.
  private func routeHeld(_ route: String) -> Bool { routeDemand[route] == true || routeReleaseAt[route] != nil }

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
    if let nickname = hardwareInventory.nickname(for: device) { return nickname }
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
    // The stopped source's own timestamps are cleared and must not be used.
    // A zero sample still records health without moving the clock backward.
    autoSwitcherBridge?.setCameraHealth(cameraID: feedID, healthy: false, at: directorClock())
  }

  // MARK: - Automatic start

  /// Something needs this camera: a client of its own or of Program, or a take.
  func cameraRequested(_ id: FeedID) -> Bool { feedPolicies[id]?.requested == true }

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
    if let error = routeErrors[feedRouteID(id)] { return error }
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
    if wantsDemandMonitor {
      demandMonitor.start()
      demandMonitor.refresh()
    }
    reconcileAutomaticFeed()
  }

  /// Program has a client, or its monitor is showing: someone wants its pixels. Cuts land
  /// without this; it decides what renders, starts automatic cameras and runs the director.
  /// With one camera there is no Program to want.
  private var programPicture: Bool {
    programAvailable &&
      (routeHeld(VirtualCameraDescriptor.program().id) || monitorDemand.contains(MonitorTargetID("program")))
  }

  private var takeActive: Bool { recordingModel.feeds.contains { $0.status == .recording || $0.status == .paused } }

  /// A strategy that cuts on its own, and something its cuts reach: Program's picture, or a
  /// take's timeline. With neither it would cut for nobody, and write files doing it.
  private var directorWanted: Bool {
    let settings = feedCoordinator.switcher
    return settings.automatic && settings.strategy != .manual && (programPicture || takeActive)
  }

  /// Starts and stops cameras on automatic start from their demand: a client of their own,
  /// Program's picture, automatic switching during a take, a recording, or a visible
  /// preview. The same rules for every camera.
  private func reconcileAutomaticFeed() {
    guard !launching else { return }
    let programRequested = programPicture
    let autoTake = feedCoordinator.switcher.automatic && feedCoordinator.switcher.strategy != .manual && takeActive
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
      let camera = routeHeld(feedRouteID(id))
      policy.demand(camera || programRequested || autoTake || recording)
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
        programRequested ? "Program" : nil, autoTake ? "automatic switching" : nil,
        policy.previewRequested ? "preview" : nil].compactMap { $0 }.joined(separator: ", ")
      reconcileSink(id)
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
    if programRequested, !programPictureWanted { moveProgramToProducingCamera(.notReady) }
    // Before the transport: the picture has to be rendering when the contract lands.
    if programRequested != programPictureWanted { feedCoordinator.setProgramPictureWanted(programRequested) }
    programPictureWanted = programRequested
    reconcileAutoSwitcher()
    reconcileProgramTransportDemand()
  }

  /// Program with nothing to show while another camera has a picture: move to it, at once,
  /// as nothing is on air to cut from. A starting camera yields too, as its first frame
  /// may be seconds off. Never cuts a live source, so a lost signal stays the operator's
  /// call (`moveProgram`). The next live camera with frames, as `programFailover` finds it.
  /// The contract owner doesn't change, so frames convert rather than renegotiate under a client.
  private func moveProgramToProducingCamera(_ cause: UIProgramMove.Cause) {
    let output = feedCoordinator.programOutput
    guard let onAir = switcherSelectedFeedID, !output.isOnAir, !output.hasPendingCut else { return }
    guard let next = programFailover(after: onAir, withFrames: true),
      case .selectedImmediately = requestProgramCut(to: next) else { return }
    captureLog.notice("Program moved: \(onAir.rawValue, privacy: .public) → \(next.rawValue, privacy: .public), \(String(describing: cause), privacy: .public)")
    programShotStartedAt = Date()
    // Nobody is told about a selection no one can see.
    if programPicture, let from = descriptor(for: onAir)?.name, let to = descriptor(for: next)?.name {
      let settings = switcherSettings
      programMoved = UIProgramMove(from: from, to: to,
        heldShot: settings.automatic && settings.naturalTalkingHead.manualHold, cause: cause)
    }
  }

  /// Program transport follows its camera clients and the actual on-air source.
  private func reconcileProgramTransportDemand() {
    let producerID = feedCoordinator.programOutput.selectedFeedID
    let producer = feedDescriptors.first { $0.id == producerID && $0.enabled }
    let required = FeedLifecycleDemandPolicy.programTransportRequired(
      cameraRequested: routeHeld(VirtualCameraDescriptor.program().id),
      anyCameraRunning: feedDescriptors.contains { $0.enabled && feedCoordinator.isFeedRunning($0.id) })
    let contract = programContract(for: producer)
    // After any connect or close below: the bridge's control queue runs them in order, and
    // it writes the closed camera only once its session has closed.
    defer {
      if programAvailable, !programInUse, let producerID, detectedSourceDurations[producerID] != nil,
        contract != programPreNegotiated {
        programPreNegotiated = contract
        feedCoordinator.requestProgramOutputPreNegotiation(configuration: contract,
          passthroughFormat: kCVPixelFormatType_422YpCbCr10)
      }
    }
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
      // A session leaves the camera on its own contract: write the closed one afresh.
      programPreNegotiated = nil
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
      guard let self, requestID == self.programTransportRequestID else { return }
      guard let error else {
        self.clearProblem("program-connect")
        return
      }
      // The live watch tries again in a second while the client waits.
      self.programTransportRequired = false
      self.programTransportConfiguration = nil
      self.programContractOwner = nil
      // Only demand connects Program, so a client is waiting on this.
      self.reportProblem("Program camera unavailable: \(error.localizedDescription)", key: "program-connect")
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

  /// The "Ultracam · Program" virtual camera has at least one client.
  var programInUse: Bool { routeDemand[VirtualCameraDescriptor.program().id] == true }
  /// Program's route can't be read, so its clients are unknown.
  var programClientUnknown: Bool { unknownRoutes.contains(VirtualCameraDescriptor.program().id) }

  private func feedRouteID(_ id: FeedID) -> String {
    if let cached = feedRouteIDs[id] { return cached }
    let routeID = VirtualCameraDescriptor.feed(feedID: id.rawValue).id
    feedRouteIDs[id] = routeID
    return routeID
  }

  /// This camera's virtual camera has at least one client.
  func cameraInUse(_ id: FeedID) -> Bool {
    routeDemand[feedRouteID(id)] == true
  }

  /// This camera's route can't be read, so its clients are unknown.
  func cameraClientUnknown(_ id: FeedID) -> Bool { unknownRoutes.contains(feedRouteID(id)) }

  // MARK: - Live watch

  /// Frames going where they should, on the camera's own route.
  private func cameraDelivering(_ id: FeedID) -> Bool {
    guard feedCoordinator.isFeedRunning(id), let update = cameraUpdates[id], update.cameraOutputActive else { return false }
    return update.signal == .live || signalHealth.isWithinLossHold(id)
  }

  /// The extension's counters alone don't show a hang: a client that stops taking frames
  /// leaves the tally red and Zoom frozen. A queue full this long means exactly that.
  private func watchQueues(now: TimeInterval) {
    for descriptor in feedDescriptors {
      let id = descriptor.id
      let stalled = cameraUpdates[id]?.cameraQueueFullSince.map { now - $0 >= LiveWatchLimits.queueStall } == true
      if stalled != stalledCameras.contains(id) {
        if stalled { stalledCameras.insert(id) } else { stalledCameras.remove(id) }
      }
    }
    let program = feedCoordinator.programQueueFullSince.map { now - $0 >= LiveWatchLimits.queueStall } == true
    if program != programQueueStalled { programQueueStalled = program }
  }

  /// Cuts land on Program, and a client on a camera's own device won't see them.
  private func noteCutReach() {
    cutsMissClient = !programInUse && feedDescriptors.contains { cameraInUse($0.id) }
  }

  /// A take that has outlived its meeting says so, and only says so: a take is never stopped for this.
  private func watchUnusedTake(now: TimeInterval) {
    let unused = unusedTakeWatch.update(rolling: recordingModel.feeds.contains { $0.status == .recording || $0.status == .paused },
      clientConnected: routeDemand.values.contains(true), clientsUnknown: !unknownRoutes.isEmpty, now: now)
    if unused != unusedTake { unusedTake = unused }
  }

  /// A dropout inside the hold: every surface keeps calling it live.
  func signalWithinLossHold(_ id: FeedID) -> Bool { signalHealth.isWithinLossHold(id) }

  /// Why Program can't cut here though the picture is back: seconds of steady signal to go.
  func cutBlockedFor(_ id: FeedID) -> TimeInterval? {
    signalHealth.secondsUntilEligible(id, now: ProcessInfo.processInfo.systemUptime)
  }

  private func signalChanged(_ change: SignalHealthTracker.Change) {
    cameraStateRevision &+= 1
    switch change {
    case .unhealthy(let id):
      captureLog.notice("Signal lost \(id.rawValue, privacy: .public): past the 1 s hold")
      // No cut goes to it, but it stays a source: on air, its frames show again the moment
      // the signal does. The 5 s of steady signal are for cuts, not for what's on air.
      feedCoordinator.setProgramSourceCutEligible(id, eligible: false)
      autoSwitcherBridge?.setCameraHealth(cameraID: id, healthy: false, at: directorClock())
      moveProgram(off: id)
    case .eligible(let id):
      captureLog.notice("Signal steady \(id.rawValue, privacy: .public): eligible for Program again")
      feedCoordinator.setProgramSourceCutEligible(id, eligible: true)
      autoSwitcherBridge?.setCameraHealth(cameraID: id, healthy: true, at: directorClock())
      if programMoved?.from == descriptor(for: id)?.name { programMoved = nil }
    }
  }

  /// One failover rule for every strategy. With Auto on, Program leaves a camera with no
  /// picture for the next live one in strip order, over Hold if need be: a shot with no
  /// picture isn't worth holding, and Hold stays on for the new one. With Auto off, or
  /// nothing live, it stays and the problem list offers what can be done.
  private func moveProgram(off id: FeedID) {
    guard switcherSelectedFeedID == id else { return }
    let settings = switcherSettings
    guard settings.automatic, settings.strategy != .manual else { return }
    guard let next = programFailover(after: id) else { return }
    switch requestProgramCut(to: next) {
    case .queued, .coalesced, .selectedImmediately:
      captureLog.notice("Program moved: \(id.rawValue, privacy: .public) → \(next.rawValue, privacy: .public), signal lost")
      if let from = descriptor(for: id)?.name, let to = descriptor(for: next)?.name {
        programMoved = UIProgramMove(from: from, to: to, heldShot: settings.naturalTalkingHead.manualHold)
      }
    case .ignoredSameSource, .rejectedMissingSource:
      break
    }
    reconcileProgramTransportDemand()
  }

  /// Where Program goes off a camera with no picture, for both moves: the next camera in strip
  /// order that runs with a live signal not lost past the hold. `withFrames` also needs it to
  /// have sent Program a frame, for a move that shows it at once.
  private func programFailover(after onAir: FeedID, withFrames: Bool = false) -> FeedID? {
    let output = feedCoordinator.programOutput
    return ProgramFailover.nextLive(after: onAir, order: stripOrder(feedDescriptors.filter(\.enabled).map(\.id))) { candidate in
      candidate != onAir && feedCoordinator.isFeedRunning(candidate) && cameraUpdates[candidate]?.signal == .live &&
        !signalHealth.isUnhealthy(candidate) && (!withFrames || output.isProducing(candidate))
    }
  }

  /// What can only be learned by watching the clock: nothing arrives to say a client has
  /// been waiting. Reads state the models already hold, on the main actor, four times a
  /// second while a camera runs, a take rolls or a client is connected.
  private var wantsLiveWatch: Bool {
    running || recordingModel.hasActiveRecordings || routeDemand.values.contains(true) || !routeReleaseAt.isEmpty
  }

  private func updateLiveWatch() {
    guard !launching, wantsLiveWatch, liveWatchTimer == nil else { return }
    // Common modes: an open menu or a modal alert must not stop it.
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
      let alive = MainActor.assumeIsolated { () -> Bool in
        guard let self else { return false }
        self.liveWatchTick(now: ProcessInfo.processInfo.systemUptime)
        return self.liveWatchTimer != nil
      }
      if !alive { timer.invalidate() }
    }
    RunLoop.main.add(timer, forMode: .common)
    liveWatchTimer = timer
  }

  func liveWatchTick(now: TimeInterval) {
    signalHealth.tick(now: now).forEach(signalChanged)
    let released = routeReleaseAt.filter { now >= $0.value }.keys
    if !released.isEmpty {
      released.forEach { routeReleaseAt[$0] = nil }
      reconcileAutomaticFeed()
    }
    if programSinkConnected != feedCoordinator.programOutputConnected {
      programSinkConnected = feedCoordinator.programOutputConnected
    }
    if programInUse, !programTransportRequired, now >= programConnectRetryAt {
      programConnectRetryAt = now + LiveWatchLimits.connectRetry
      reconcileProgramTransportDemand()
    }
    for descriptor in feedDescriptors {
      let id = descriptor.id
      retrySink(id, now: now)
      guard cameraInUse(id), !cameraDelivering(id) else {
        clientWaitingSince[id] = nil
        if waitingClients.contains(id) { waitingClients.remove(id) }
        continue
      }
      let since = clientWaitingSince[id] ?? now
      clientWaitingSince[id] = since
      if now - since >= LiveWatchLimits.clientWaiting, !waitingClients.contains(id) { waitingClients.insert(id) }
    }
    if cutsMissClient, programInUse || !feedDescriptors.contains(where: { cameraInUse($0.id) }) { cutsMissClient = false }
    watchQueues(now: now)
    watchUnusedTake(now: now)
    if !wantsLiveWatch {
      liveWatchTimer?.invalidate()
      liveWatchTimer = nil
    }
  }

  /// A sink that failed to connect tries again every second while a client waits on it.
  /// With no client it stays quiet: nothing needs it, and that may be for hours.
  private func retrySink(_ id: FeedID, now: TimeInterval) {
    guard cameraInUse(id), feedCoordinator.isFeedRunning(id), cameraUpdates[id]?.cameraOutputActive != true,
      now >= connectRetryAt[id] ?? 0 else { return }
    connectRetryAt[id] = now + LiveWatchLimits.connectRetry
    feedCoordinator.capture(for: id).requestCameraReconnect(reason: "a client is waiting")
  }

  /// Gets frames moving to a stalled or starved client. A running camera reopens its
  /// output and keeps capturing, so a take rolls straight through this: its own sink,
  /// and Program's if it's on air. A stopped camera just starts.
  func restartCamera(_ id: FeedID) {
    guard descriptor(for: id) != nil else { return }
    guard feedCoordinator.isFeedRunning(id) else { startCamera(id); return }
    captureLog.notice("Restart output \(id.rawValue, privacy: .public): user")
    if switcherSelectedFeedID == id, programInUse { feedCoordinator.restartProgramOutput() }
    if cameraInUse(id) { feedCoordinator.capture(for: id).restartCameraOutput() }
  }

  /// Someone has seen it. The take result goes; a stopped camera still says so until it starts.
  func acknowledgeUnexpectedStop(_ id: FeedID) {
    acknowledgedTakes.insert(id)
    guard var stop = unexpectedStops[id] else { return }
    if stop.cameraStopped {
      stop.take = nil
      unexpectedStops[id] = stop
    } else {
      unexpectedStops[id] = nil
    }
  }

  func acknowledgeProgramMove() { programMoved = nil }

  func acknowledgeProblem(_ id: String) { appProblems.removeAll { $0.id == id } }

  /// Puts an error in the problem list as well as the selected camera's status. Repeats of
  /// one key replace it, so a retry that keeps failing is one row, not a growing list.
  private func reportProblem(_ message: String, key: String) {
    showStatus(message)
    appProblems.removeAll { $0.id == key }
    appProblems.append(UIAppProblem(id: key, text: message))
  }

  /// The cause went away by itself.
  private func clearProblem(_ key: String) {
    if appProblems.contains(where: { $0.id == key }) { appProblems.removeAll { $0.id == key } }
  }

  /// Starts one camera, whichever is selected. It then stays up until Stop.
  func startCamera(_ id: FeedID) {
    guard let descriptor = descriptor(for: id), descriptor.enabled else { return }
    if let error = descriptor.processingDeclarationError { reportProblem(error, key: "declaration.\(id.rawValue)"); return }
    clearProblem("declaration.\(id.rawValue)")
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
    // Stop means now: a client that just left holds nothing up.
    routeReleaseAt[feedRouteID(id)] = nil
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
  func updateCamera(_ id: FeedID, shareProcessing: Bool = true, _ mutate: (inout FeedDescriptor) -> Void) {
    guard var descriptor = descriptor(for: id) else { return }
    let before = descriptor
    mutate(&descriptor)
    // One input serves one camera: an input another camera has is refused, and a
    // running camera keeps its input. None is remembered so discovery leaves it.
    if descriptor.selectedDevice != before.selectedDevice {
      if inputHolder(descriptor.selectedDevice, excluding: id) != nil || cameraActive(id) {
        descriptor.selectedDevice = before.selectedDevice
      } else {
        descriptor.inputClearedByChoice = descriptor.selectedDevice.isEmpty
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
    if shareProcessing && descriptor.processingChoicesDiffer(from: before) { synchronizeProcessing(from: descriptor) }
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
    guard canResetSettings else { return false }
    settingsResetPending = true
    cameraControls.reset()
    vendorSettings.reset()
    hardwareInventory.reset()
    lastInputNames = [:]
    settingsStore.resetAll()
    return true
  }

  /// Every strategy control comes through here: Manual turns automatic off, so
  /// choosing a strategy later doesn't turn it back on unasked.
  func setStrategy(_ strategy: SwitcherStrategy) {
    var settings = switcherSettings
    settings.strategy = strategy
    if strategy == .manual { settings.automatic = false }
    settings.naturalTalkingHead.enabled = settings.automatic && strategy == .naturalTalkingHead
    updateSwitcher(settings)
  }

  /// Holds the current Program shot: automatic switching stays on but makes no cuts.
  func setAutoHold(_ hold: Bool) {
    var settings = switcherSettings
    guard settings.naturalTalkingHead.manualHold != hold else { return }
    settings.naturalTalkingHead.manualHold = hold
    updateSwitcher(settings)
  }

  #if ULTRACAM_TEST_SUPPORT
  var directorClockFeedIDForTesting: FeedID? { directorClockFeedID }
  var directorRunningForTesting: Bool { autoSwitcherBridge != nil }
  func timelineBoundForTesting(_ id: FeedID) -> Bool { recordingTimelines[id] != nil }
  func isProgramSourceProducingForTesting(_ id: FeedID) -> Bool { feedCoordinator.programOutput.isProducing(id) }
  func isSignalUnhealthy(_ id: FeedID) -> Bool { signalHealth.isUnhealthy(id) }
  var demandMonitorIsRunning: Bool { demandMonitor.isRunning }
  /// What the demand monitor reports, without CMIO. Nil is an unreadable route.
  func setCameraDemandForTesting(_ id: FeedID, requested: Bool?) {
    routeDemandChanged(feedRouteID(id), requested: requested, error: requested == nil ? "unreadable" : nil)
  }
  func setProgramDemandForTesting(requested: Bool?) {
    routeDemandChanged(VirtualCameraDescriptor.program().id, requested: requested, error: requested == nil ? "unreadable" : nil)
  }
  func deliverCaptureUpdateForTesting(_ id: FeedID, _ update: CaptureUpdate) { cameraDidUpdate(id, update) }
  #endif

  /// True when running Program sources deliver different camera formats. Cuts
  /// between them no longer renegotiate the Program camera: frames that don't
  /// match its format are converted on the GPU.
  var programFormatMismatch: Bool {
    let contracts = feedDescriptors.filter { $0.enabled && feedCoordinator.isFeedRunning($0.id) }.map(programContract)
    guard let first = contracts.first else { return false }
    return contracts.contains { $0 != first }
  }
}
