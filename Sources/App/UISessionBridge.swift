import AppKit
import SwiftUI

enum UISideColumn: Sendable { case sidebar, inspector }

/// Interface-only preferences that are not part of the capture settings.
@MainActor @Observable
final class UIInterfaceState {
  private let defaults: UserDefaults
  var layout: UILayout { didSet { defaults.set(layout.rawValue, forKey: "ui.layout") } }
  var collapsed: Set<String> { didSet { defaults.set(Array(collapsed), forKey: "ui.collapsed") } }
  var sidebarVisible: Bool {
    didSet {
      defaults.set(sidebarVisible, forKey: "ui.sidebar")
      if sidebarVisible { lastOpenedColumn = .sidebar }
    }
  }
  /// Display order of the pictures (camera IDs); cameras not listed follow in their saved order.
  var order: [String] { didSet { defaults.set(order, forKey: "ui.order") } }
  /// Set while a picture is expanded from a grid layout.
  var expandedFrom: UILayout?
  var inspectorOpen = false { didSet { if inspectorOpen { lastOpenedColumn = .inspector } } }
  /// Which side column the user opened most recently; it stays when space runs out.
  var lastOpenedColumn: UISideColumn = .sidebar
  /// Tests set this so confirmations are recorded instead of shown as modal alerts.
  var alertsDisabled = false
  /// A pending confirmation: the message and the action to run when confirmed.
  var confirmation: (message: String, action: UIAction)?
  /// The camera whose rename prompt is open (`uiRenameAlert`), if any.
  var renamingCameraID: String?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    layout = UILayout(rawValue: defaults.string(forKey: "ui.layout") ?? "") ?? .sideBySide
    collapsed = Set(defaults.stringArray(forKey: "ui.collapsed") ?? [])
    sidebarVisible = defaults.object(forKey: "ui.sidebar") as? Bool ?? true
    order = defaults.stringArray(forKey: "ui.order") ?? []
    defaultCollapsed = defaults.string(forKey: "ui.collapsed.default") == "collapsed"
  }

  /// Settings › General › Channel strips: new cameras start collapsed.
  let defaultCollapsed: Bool

  /// Sorts cameras into the display order.
  func ordered<T>(_ items: [T], id: (T) -> String) -> [T] {
    items.enumerated().sorted { lhs, rhs in
      let left = order.firstIndex(of: id(lhs.element)) ?? (order.count + lhs.offset)
      let right = order.firstIndex(of: id(rhs.element)) ?? (order.count + rhs.offset)
      return left < right
    }.map(\.element)
  }
}

enum UIFormatLabels {
  /// "3840 × 2160 · v210 · 4:2:2 10-bit · 59.94 fps" → "2160p 59.94".
  static func shortFormat(_ label: String) -> String? {
    let parts = label.components(separatedBy: " · ")
    guard let size = parts.first, size.contains("×") else { return nil }
    let height = size.components(separatedBy: "×").last?.trimmingCharacters(in: .whitespaces) ?? ""
    let rate = parts.first { $0.hasSuffix("fps") }?.replacingOccurrences(of: " fps", with: "") ?? ""
    guard !height.isEmpty else { return nil }
    return rate.isEmpty ? "\(height)p" : "\(height)p \(rate)"
  }

  static func signal(running: Bool, deviceAvailable: Bool, update: CaptureUpdate?) -> UISignal {
    guard running else { return .none }
    guard let update else { return .connecting }
    let input = update.input
    if let format = shortFormat(input) { return .live(format: format) }
    let lowered = (input + " " + update.message).lowercased()
    if lowered.contains("unsupported") { return .unsupported(input) }
    // The backend says so explicitly once it has looked for a signal.
    if lowered.contains("no video signal") || lowered.contains("no hdmi") { return deviceAvailable ? .noSignal : .deviceMissing }
    if input == "No signal" && update.frames > 0 { return .noSignal }
    return deviceAvailable ? .connecting : .deviceMissing
  }
}

/// Copies AppModel and RecordingModel state into a `UISessionSnapshot` and
/// performs `UIAction`s against the existing models.
@MainActor
struct UISessionBridge {
  let model: AppModel
  let interface: UIInterfaceState
  /// Supplied by the hosting views so actions that open windows work in the app.
  var openWindow: (String) -> Void = { _ in }
  var openSettings: () -> Void = {}

  func snapshot() -> UISessionSnapshot {
    // Register the observable camera state up front. Whether a camera runs is read
    // from the capture coordinator, which SwiftUI can't observe on its own.
    _ = model.cameraStateRevision
    _ = model.running
    _ = model.cameraUpdates
    let recording = model.recordingModel
    let folders = model.feedDescriptors.map { recording.outputFolder(for: $0.id) }
    let drives = Self.cachedDrives(for: folders) {
      UIRecordingLibrary.drives(for: folders,
        recordingRates: model.feedDescriptors.compactMap { descriptor -> (URL, Double)? in
          guard let folder = recording.outputFolder(for: descriptor.id),
            let state = recording.feeds.first(where: { $0.id == descriptor.id }),
            state.status == .recording || state.status == .paused else { return nil }
          return (folder, state.statistics?.videoMegabitsPerSecond ?? UIRecordingLibrary.nominalMegabits(codec: recording.codec, fast: true))
        })
    }
    var cameras: [UICameraSnapshot] = []
    for descriptor in model.feedDescriptors {
      let id = descriptor.id
      let running = model.isCameraRunning(id)
      let update = running ? model.cameraUpdate(id) : nil
      let deviceAvailable = model.devices.contains { $0.id == descriptor.selectedDevice }
      let selected = id == model.selectedFeedID
      let state = recording.feeds.first { $0.id == id }
      let stats = state?.statistics
      let folder = recording.outputFolder(for: id)
      var camera = UICameraSnapshot(id: id.rawValue, name: descriptor.name)
      camera.inputID = descriptor.selectedDevice.isEmpty ? nil : descriptor.selectedDevice
      camera.inputName = model.inputLabel(descriptor.selectedDevice)
      camera.deviceAvailable = deviceAvailable
      camera.running = running
      camera.signal = UIFormatLabels.signal(running: running, deviceAvailable: deviceAvailable, update: update)
      camera.outputFormat = update.flatMap { UIFormatLabels.shortFormat($0.output) }
      camera.applying = running && update != nil && update?.pipelineEnabledApplied == nil &&
        UIFormatLabels.shortFormat(update?.input ?? "") != nil
      camera.inUse = model.outputMode == .separateCameras && running && (model.cameraInUse(id) || update?.cameraOutputActive == true)
      camera.processing = selected ? model.pipelineEnabled : descriptor.pipelineEnabled
      let configuration = selected ? model.configuration : descriptor.configuration
      camera.effects = [selected ? (model.configuration.applyLUT || (!model.lutLoaded && descriptor.applyLUT)) : descriptor.applyLUT,
        configuration.downscale, configuration.convertTo420, configuration.reduceFrameRate]
      camera.lutName = selected ? (model.lutLoaded ? model.lutFileName ?? model.lutTitle : nil)
        : (descriptor.lutBookmark != nil ? "Saved LUT" : nil)
      camera.lutLoading = selected && model.loading
      camera.lutError = selected ? model.lutError : nil
      camera.gamut = selected ? model.gamut : descriptor.gamut
      camera.previewEnabled = descriptor.previewEnabled
      camera.previewError = update?.previewError
      camera.automaticStart = descriptor.automaticFeed
      // A refused Start says why, on any camera; otherwise the selected automatic camera's status.
      camera.automaticStatus = model.startRefusal(id) ?? (selected && descriptor.automaticFeed ? model.automaticFeedStatus : nil)
      camera.automaticStartFailed = model.automaticStartFailed(id)
      camera.timecode = update?.timecode
      if let update {
        camera.audio = UIAudioLevels(present: update.audioPresent, peakLeft: update.audioPeakLeft,
          peakRight: update.audioPeakRight, rmsLeft: update.audioRMSLeft, rmsRight: update.audioRMSRight)
      }
      let monitor = model.monitorCoordinator.preferences(for: MonitorTargetID(id.rawValue))
      camera.activeTools = UIMonitorBridge.activeTools(monitor)
      camera.message = update?.message ?? ""
      var rec = UICameraRecording()
      switch state?.status ?? .idle {
      case .idle: rec.status = .idle
      case .recording: rec.status = .recording
      case .paused: rec.status = .paused
      case .finishing: rec.status = .finishing
      }
      rec.elapsed = stats?.elapsed ?? 0
      rec.fileBytes = Int64(stats?.fileBytes ?? 0)
      rec.megabitsPerSecond = stats?.videoMegabitsPerSecond ?? 0
      rec.droppedFrames = Int(clamping: stats?.droppedVideoFrames ?? 0)
      rec.failed = stats?.failed == true
      rec.error = state?.error ?? stats?.lastError
      rec.savedURL = state?.savedURL
      rec.savedFileName = state?.savedURL?.lastPathComponent
      rec.savedDuration = state?.savedURL != nil ? stats?.elapsed : nil
      rec.folderPath = folder?.path
      rec.folderIsCustom = recording.customOutputFolder(for: id) != nil
      rec.secondsLeft = folder.flatMap { url in drives.first { $0.name == UIRecordingLibrary.volumeName(for: url) }?.secondsLeft }
      camera.recording = rec
      cameras.append(camera)
    }
    var session = UISessionSnapshot()
    session.outputMode = model.outputMode == .program ? .program : .separate
    session.cameras = interface.ordered(cameras, id: \.id)
    session.selectedID = model.selectedFeedID.rawValue
    session.programInUse = model.programInUse
    session.onAirID = model.outputMode == .program ? model.switcherSelectedFeedID?.rawValue : nil
    session.pendingCutID = model.switcherPendingFeedID?.rawValue
    let switcher = model.switcherSettings
    session.autoSwitching = switcher.automatic
    session.autoHold = switcher.naturalTalkingHead.manualHold
    session.strategy = switcher.strategy
    session.anchorID = switcher.naturalTalkingHead.anchorFeedID?.rawValue
    session.emphasisID = switcher.naturalTalkingHead.emphasisFeedID?.rawValue
    session.expandedFrom = interface.expandedFrom
    session.strategyTitle = UIStrategy.title(switcher.strategy)
    session.shot = UIShotTiming(startedAt: model.programShotStartedAt, currentShot: model.programShotStartedAt.map { Date().timeIntervalSince($0) },
      minimum: switcher.naturalTalkingHead.minimumShotDuration,
      softMaximum: switcher.naturalTalkingHead.softMaximumShotDuration,
      maximum: switcher.naturalTalkingHead.maximumShotDuration)
    session.programFormatMismatch = model.programFormatMismatch
    session.programIssue = model.programIssue
    session.recentCuts = model.recentCuts
    session.codecTitle = recording.codec.title
    session.timecodeTitle = UITimecode.title(recording.timecodeMode)
    session.defaultFolderPath = recording.outputFolder?.path
    session.drives = drives
    session.recentTakes = UIRecordingLibrary.cachedRecentTakes(in: model.feedDescriptors.compactMap { recording.outputFolder(for: $0.id) })
    session.interruptedTakes = recording.interruptedRecordings.map { UIInterruptedTake(id: $0.id.path, title: $0.title) }
    session.recoveringID = recording.recoveringID?.path
    session.recoveryMessage = recording.recoveryMessage
    session.install = UIInstallState(canRequestChanges: model.installer.canRequestChanges, pending: model.installer.pending,
      status: model.installer.status, unavailableReason: model.installer.unavailableReason,
      installed: UIExtensionDetector.isInstalled())
    session.canEditTopology = model.canEditFeedTopology
    session.layout = model.outputMode == .program || interface.layout != .programView ? interface.layout : .sideBySide
    session.collapsed = interface.collapsed
    session.sidebarVisible = interface.sidebarVisible
    session.inspectorOpen = interface.inspectorOpen
    session.renamingCameraID = interface.renamingCameraID
    return session
  }

  func presentation() -> UISessionPresentation { UIPresentationBuilder.session(snapshot()) }

  /// Free space takes about 10 ms per volume to read, and every view that rebuilds the
  /// context (window, sidebar, inspector, their bindings) read it on each capture update,
  /// 4 Hz per running camera: main-thread time taken from scrolling. The figures are
  /// reused for two seconds.
  private static var driveCache: (folders: [String?], date: Date, drives: [UIDrive])?

  private static func cachedDrives(for folders: [URL?], read: () -> [UIDrive]) -> [UIDrive] {
    let key = folders.map { $0?.path }
    if let cache = driveCache, cache.folders == key, Date().timeIntervalSince(cache.date) < 2 { return cache.drives }
    let drives = read()
    driveCache = (key, Date(), drives)
    return drives
  }

  private func feedID(_ raw: String) -> FeedID { FeedID(rawValue: raw) }

  /// Selecting reloads the camera's LUT and processing, so a tap on the camera
  /// that's already selected (its picture, its tools, Show Inspector) must not select it again.
  private func select(_ id: FeedID) {
    if id != model.selectedFeedID { _ = model.selectFeed(id) }
  }

  private func cameraID(number: Int) -> FeedID? {
    let descriptors = model.feedDescriptors
    return descriptors.indices.contains(number - 1) ? descriptors[number - 1].id : nil
  }

  /// Runs an action, asking for confirmation first when it would end a recording or on-air output.
  func send(_ action: UIAction, confirmed: Bool = false) {
    let presentation = presentation()
    guard !confirmed, let message = action.needsConfirmation(in: presentation) else {
      perform(action)
      return
    }
    // Ask in the window in front: the main window shows its own dialog, any
    // other key window (Settings, Diagnostics) gets a sheet, and without a key
    // window (menus while the app is in the background, the menu bar item) a
    // standard alert.
    let key = NSApplication.shared.keyWindow
    if interface.alertsDisabled || key?.identifier?.rawValue.hasPrefix("main") == true {
      interface.confirmation = (message, action)
      return
    }
    let alert = NSAlert()
    alert.messageText = action.confirmationTitle(in: presentation)
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: UISessionBridge.confirmTitle(for: action)).hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    if let key, key.isVisible, key.attachedSheet == nil {
      let bridge = self
      alert.beginSheetModal(for: key) { response in
        if response == .alertFirstButtonReturn { bridge.perform(action) }
      }
      return
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    perform(action)
  }

  func perform(_ action: UIAction) {
    let recording = model.recordingModel
    switch action {
    case .select(let id): select(feedID(id))
    case .selectNumber(let number): if let id = cameraID(number: number) { select(id) }
    case .setLayout(let layout): interface.layout = layout; interface.expandedFrom = nil
    case .toggleCollapsed(let id):
      if interface.collapsed.contains(id) { interface.collapsed.remove(id) } else { interface.collapsed.insert(id) }
    case .setAllCollapsed(let collapsed):
      interface.collapsed = collapsed ? Set(model.feedDescriptors.map(\.id.rawValue)) : []
    case .toggleSidebar: interface.sidebarVisible.toggle()
    case .toggleInspector: interface.inspectorOpen.toggle()
    case .setInspectorOpen(let open): if interface.inspectorOpen != open { interface.inspectorOpen = open }
    case .setSidebarVisible(let visible): if interface.sidebarVisible != visible { interface.sidebarVisible = visible }
    case .showInspector(let id): select(feedID(id)); interface.inspectorOpen = true
    case .makeRoomForPictures:
      guard interface.sidebarVisible && interface.inspectorOpen else { break }
      if interface.lastOpenedColumn == .sidebar { interface.inspectorOpen = false } else { interface.sidebarVisible = false }
    case .expandPicture(let id):
      select(feedID(id))
      if interface.layout != .single { interface.expandedFrom = interface.layout }
      interface.layout = .single
    case .restoreLayout:
      interface.layout = interface.expandedFrom ?? .sideBySide
      interface.expandedFrom = nil
    case .swapPictures:
      var ids = interface.ordered(model.feedDescriptors.map(\.id.rawValue), id: { $0 })
      if ids.count >= 2 { ids.swapAt(0, 1) }
      interface.order = ids
    case .startCamera(let id): model.startCamera(feedID(id))
    case .stopCamera(let id): model.stopCamera(feedID(id))
    case .startAllCameras: model.startAllCameras()
    case .stopAllCameras: model.stopAllCameras()
    case .setProcessing(let id, let on): model.updateCamera(feedID(id)) { $0.pipelineEnabled = on }
    case .setEffect(let id, let index, let on):
      model.updateCamera(feedID(id)) { descriptor in
        switch index {
        case 0: descriptor.applyLUT = on
        case 1: descriptor.downscale = on
        case 2: descriptor.convertTo420 = on
        case 3: descriptor.reduceFrameRate = on
        default: break
        }
      }
    case .chooseLUT(let id):
      model.chooseLUT(feedID: feedID(id))
    case .setGamut(let id, let gamut): model.updateCamera(feedID(id)) { $0.gamut = gamut }
    case .setInput(let id, let device): model.updateCamera(feedID(id)) { $0.selectedDevice = device }
    case .refreshInputs: model.refresh()
    case .setPreviewEnabled(let id, let on): model.updateCamera(feedID(id)) { $0.previewEnabled = on }
    case .setAutomaticStart(let id, let on): model.updateCamera(feedID(id)) { $0.automaticFeed = on }
    case .retryAutomaticStart(let id):
      // A refused Start retries as Start; a failed automatic start retries the automatic start.
      if model.startRefusal(feedID(id)) != nil { model.startCamera(feedID(id)) } else { model.retryAutomaticFeed(feedID: feedID(id)) }
    case .retryPreview: model.resetPreview()
    case .addCamera:
      if let id = model.addFeed(), interface.defaultCollapsed { interface.collapsed.insert(id.rawValue) }
    case .removeCamera(let id): _ = model.removeFeed(feedID(id))
    case .renameCamera(let id, let name):
      _ = model.renameFeed(feedID(id), name: name)
      interface.renamingCameraID = nil
    case .beginRename(let id): interface.renamingCameraID = id
    case .endRename: interface.renamingCameraID = nil
    case .cut(let id): _ = model.requestProgramCut(to: feedID(id))
    case .cutNumber(let number): if let id = cameraID(number: number) { _ = model.requestProgramCut(to: id) }
    case .setAutoSwitching(let on):
      var settings = model.switcherSettings
      // Manual never switches on its own, so Auto stays off with it (the controls are disabled too).
      settings.automatic = on && settings.strategy != .manual
      settings.naturalTalkingHead.enabled = on && settings.strategy == .naturalTalkingHead
      model.updateSwitcher(settings)
    case .setAutoHold(let hold): model.setAutoHold(hold)
    case .setStrategy(let strategy):
      var settings = model.switcherSettings
      settings.strategy = strategy
      if strategy == .manual { settings.automatic = false }
      settings.naturalTalkingHead.enabled = settings.automatic && strategy == .naturalTalkingHead
      model.updateSwitcher(settings)
    case .setOutputMode(let mode): model.setOutputMode(mode == .program ? .program : .separateCameras)
    case .setAnchor(let id): model.naturalAnchorFeedID = id.map(feedID)
    case .setEmphasis(let id): model.naturalEmphasisFeedID = id.map(feedID)
    case .forgetLUT(let id): model.forgetLUT(feedID(id))
    case .resetAllSettings:
      guard model.resetAllSettings() else { return }
      for key in ["ui.layout", "ui.collapsed", "ui.sidebar", "ui.order", "ui.collapsed.default"] { UserDefaults.standard.removeObject(forKey: key) }
      NSApplication.shared.terminate(nil)
    case .toggleRecording(let id):
      let fid = feedID(id)
      switch recording.feeds.first(where: { $0.id == fid })?.status ?? .idle {
      case .idle: recording.record(feedID: fid)
      case .recording, .paused: recording.stop(feedID: fid)
      case .finishing: break
      }
    case .pauseOrResume(let id):
      let fid = feedID(id)
      switch recording.feeds.first(where: { $0.id == fid })?.status ?? .idle {
      case .recording: recording.pause(feedID: fid)
      case .paused: recording.resume(feedID: fid)
      default: break
      }
    case .recordAll: recording.recordAll()
    case .stopAllRecordings: recording.stopAll()
    case .pauseAll: recording.pauseAll()
    case .resumeAll:
      for feed in recording.feeds where feed.status == .paused { recording.resume(feedID: feed.id) }
    case .toggleRecordingSelected: perform(.toggleRecording(cameraID: model.selectedFeedID.rawValue))
    case .chooseRecordingFolder(let id): UIPanels.chooseFolder(model: model, cameraID: id.map(feedID))
    case .useDefaultFolder(let id): recording.setOutputFolder(nil, for: feedID(id))
    case .clearDefaultFolder: recording.outputFolder = nil
    case .revealInFinder(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
    case .revealRecordings:
      if let folder = recording.outputFolder ?? model.feedDescriptors.compactMap({ recording.outputFolder(for: $0.id) }).first {
        NSWorkspace.shared.open(folder)
      }
    case .recover(let id): if let take = recording.interruptedRecordings.first(where: { $0.id.path == id }) { recording.recover(take) }
    case .toggleTool(let id, let tool):
      let gamut = model.descriptor(for: feedID(id))?.gamut ?? model.gamut
      UIMonitorBridge.toggle(tool, for: id, coordinator: model.monitorCoordinator,
        defaultSourceProfile: UIMonitorBridge.sourceProfile(forGamut: gamut))
    case .freeze, .toggleClean, .detachMonitor: UIMonitorBridge.perform(action, coordinator: model.monitorCoordinator)
    case .resetMonitorTools(let id):
      model.monitorCoordinator.resetSettings(for: MonitorTargetID(id))
    case .copyMonitorSettings(let from, let to):
      model.monitorCoordinator.copySettings(from: MonitorTargetID(from), to: MonitorTargetID(to))
    case .installCameraExtension: model.installer.install()
    case .removeCameraExtension: model.installer.uninstall()
    case .openSettings: openSettings()
    case .openDiagnostics: openWindow("diagnostics")
    case .openMainWindow:
      openWindow("main")
      NSApplication.shared.activate(ignoringOtherApps: true)
    case .quit:
      model.saveSettings()
      NSApplication.shared.terminate(nil)
    }
  }
}

extension UISessionBridge {
  /// The destructive button of a confirmation, shared by every place that asks.
  static func confirmTitle(for action: UIAction) -> String { action.confirmationButtonTitle }
}

enum UIStrategy {
  static func title(_ strategy: SwitcherStrategy) -> String {
    switch strategy {
    case .manual: return "Manual"
    case .fixedInterval: return "Fixed interval"
    case .naturalTalkingHead: return "Natural talking head"
    case .dynamicAnalysis: return "Dynamic analysis (later)"
    }
  }
}

enum UITimecode {
  static func title(_ mode: RecordingTimecodeMode) -> String {
    switch mode {
    case .source: return "No Timecode Track"
    case .recordStart: return "Record Start"
    case .wallClock: return "Mac Clock"
    }
  }
}
