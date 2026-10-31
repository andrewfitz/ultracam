import Foundation

/// Every user command the new interface can issue. Views never call the models
/// directly; they send one of these, so menus, toolbar, strips, the inspector
/// and the menu bar item share one implementation that can be tested.
enum UIAction: Sendable, Equatable {
  // Selection, layout and chrome
  case select(cameraID: String)
  case selectNumber(Int)
  case setLayout(UILayout)
  case toggleCollapsed(cameraID: String)
  case setAllCollapsed(Bool)
  case toggleSidebar
  case toggleInspector
  case setInspectorOpen(Bool)
  case setSidebarVisible(Bool)
  case showInspector(cameraID: String)
  /// The pictures got too narrow with both side columns open: close the one opened earlier.
  case makeRoomForPictures
  /// Shows one camera alone (Single layout) from a grid; Restore Layout returns.
  case expandPicture(cameraID: String)
  case restoreLayout
  /// Swaps the first two pictures in the grid.
  case swapPictures

  // Cameras (capture and output)
  case startCamera(cameraID: String)
  case stopCamera(cameraID: String)
  case startAllCameras
  case stopAllCameras
  case setProcessing(cameraID: String, Bool)
  case setEffect(cameraID: String, index: Int, Bool)
  case setResizeTarget(cameraID: String, ResizeTarget)
  case setScalingMode(cameraID: String, ProgramScalingMode)
  case setColorTarget(cameraID: String, ColorTarget)
  case setFrameRateTarget(cameraID: String, FrameRateTarget)
  case setSyncCameras(Bool)
  /// The format of the next take, for every camera.
  case setCodec(RecordingCodec)
  case chooseLUT(cameraID: String)
  case setGamut(cameraID: String, String)
  case setSourceProfile(cameraID: String, String)
  case setLUTInputSpace(cameraID: String, String)
  case setLUTOutputSpace(cameraID: String, String)
  /// What Ultracam · Program sends: one color space for every camera (Settings › Virtual Cameras).
  case setProgramColorSpace(String)
  case setRecordingConstantFrameRate(cameraID: String, Bool)
  case setInput(cameraID: String, deviceID: String)
  case refreshInputs
  case setPreviewEnabled(cameraID: String, Bool)
  case setAutomaticStart(cameraID: String, Bool)
  case retryAutomaticStart(cameraID: String)
  /// Reopens a stalled or starved camera's output. Its capture and take keep running.
  case restartCamera(cameraID: String)
  /// Details on an unexpected stop or an early take: shows why, and acknowledges it.
  case acknowledgeStop(cameraID: String)
  case acknowledgeProgramMove
  case acknowledgeProblem(id: String)
  case addCamera
  case removeCamera(cameraID: String)
  case forgetLUT(cameraID: String)
  case renameCamera(cameraID: String, name: String)
  /// Opens the one rename prompt (`uiRenameAlert`) for a camera; every entry point sends this.
  case beginRename(cameraID: String)
  /// Closes the rename prompt without renaming.
  case endRename

  // Program
  case cut(cameraID: String)
  case cutNumber(Int)
  case setAutoSwitching(Bool)
  case setAutoHold(Bool)
  case setStrategy(SwitcherStrategy)
  case setAnchor(cameraID: String?)
  case setEmphasis(cameraID: String?)

  // Recording
  case toggleRecording(cameraID: String)
  case pauseOrResume(cameraID: String)
  case recordAll
  case stopAllRecordings
  case pauseAll
  /// Resumes every paused take (Pause All turns into Resume All when every take is paused).
  case resumeAll
  case toggleRecordingSelected
  case chooseRecordingFolder(cameraID: String?)
  case useDefaultFolder(cameraID: String)
  case clearDefaultFolder
  case revealInFinder(URL)
  case revealRecordings
  case recover(id: String)
  /// The sheet that lists every interrupted take, from Attention's row.
  case showInterruptedTakes
  case hideInterruptedTakes

  // Monitor
  case toggleTool(cameraID: String, UIMonitorTool)
  case toggleClipIndicators(cameraID: String)
  /// Turns off every tool on the camera, and leaves their settings.
  case hideAllTools(cameraID: String)
  case freeze(cameraID: String)
  case toggleClean(cameraID: String)
  case detachMonitor(cameraID: String)
  case resetMonitorTools(cameraID: String)
  case copyMonitorSettings(from: String, to: String)

  // App
  case installCameraExtension
  case removeCameraExtension
  case openSettings
  /// How many channels a camera's strip meter shows (Settings › Audio, and the meter's menu).
  case setChannelsShown(cameraID: String, UIChannelsShown)
  /// Settings at one tab: what a "Settings › Recording" link does.
  case openSettingsTab(UISettingsTab)
  case openDiagnostics
  case openMainWindow
  /// System Settings at Camera Extensions, where macOS waits for an approval.
  case openExtensionApproval
  case setVirtualCamerasCollapsed(Bool)
  /// The window crossed the width under which toolbar cuts keep only their digits.
  case setNarrowWindow(Bool)
  /// Asks for notification permission. Only offered before a session.
  case turnOnAlerts
  case dismissAlertsPrompt
  /// Clears every saved preference, then quits (only while nothing runs or records).
  case resetAllSettings
  case quit
}

extension UIAction {
  /// Actions that end a recording or interrupt an on-air camera need a confirmation first.
  /// The message is the dialog's detail; `confirmationTitle(in:)` already asks the question.
  func needsConfirmation(in presentation: UISessionPresentation) -> String? {
    switch self {
    case .stopCamera(let id):
      guard let camera = presentation.cameras.first(where: { $0.id == id }), camera.stopNeedsConfirmation else { return nil }
      return camera.stopConfirmationMessage
    case .removeCamera:
      return "Its settings are deleted. Recordings on disk are kept."
    case .setSyncCameras(true):
      guard let source = presentation.selected, presentation.cameras.count > 1 else { return nil }
      let others = presentation.cameras.filter { $0.id != source.id }.map(\.name).joined(separator: ", ")
      return "\(others) \(presentation.cameras.count > 2 ? "take" : "takes") \(source.name)'s effects, LUT, monitor tools, source declarations and preview setting, and meeting apps may see \(presentation.cameras.count > 2 ? "their" : "its") format change. Inputs and folders stay separate."
    case .stopAllRecordings:
      let takes = presentation.cameras.filter { $0.recordButtonActive || $0.pauseTitle == "Resume" }.count
      guard presentation.askBeforeEnding, takes > 1 else { return nil }
      return "\(takes) recordings end. Cameras keep running and on-air video continues."
    case .resetAllSettings:
      return "Cameras, effects, folders, monitor tools and layout return to their defaults. Recordings are not touched. Ultracam quits when it's done."
    case .stopAllCameras:
      return Self.endingMessage(in: presentation)
    default:
      return nil
    }
  }

  /// What ending everything would cost, or nil when it costs nothing.
  static func endingMessage(in presentation: UISessionPresentation) -> String? {
    let recording = presentation.cameras.filter { $0.recordButtonActive || $0.pauseTitle == "Resume" }
    let onAir = presentation.cameras.contains { $0.tally.isRed }
    guard !recording.isEmpty || onAir else { return nil }
    var parts: [String] = []
    if !recording.isEmpty { parts.append("\(recording.count == 1 ? "1 recording ends" : "\(recording.count) recordings end")") }
    if onAir { parts.append(recording.isEmpty ? "On-air video stops" : "on-air video stops") }
    return parts.joined(separator: " and ") + "."
  }

  /// The confirmation dialog's title: the question the message answers.
  func confirmationTitle(in presentation: UISessionPresentation) -> String {
    let name: (String) -> String = { id in presentation.cameras.first { $0.id == id }?.name ?? "Camera" }
    switch self {
    case .stopCamera(let id): return "Stop \(name(id))?"
    case .stopAllCameras: return "Stop All Cameras?"
    case .removeCamera(let id): return "Remove \(name(id))?"
    case .resetAllSettings: return "Reset All Settings?"
    case .setSyncCameras: return "Sync cameras from \(presentation.selected?.name ?? "this camera")?"
    case .stopAllRecordings: return "\(presentation.recordControl.title)?"
    case .quit: return "Quit Ultracam?"
    default: return "Are you sure?"
    }
  }

  /// The verb of the confirmation dialog, named for what it does.
  func confirmationButtonTitle(in presentation: UISessionPresentation) -> String {
    switch self {
    case .stopCamera: return "Stop Camera"
    case .stopAllCameras: return "Stop All Cameras"
    case .removeCamera: return "Remove Camera"
    case .resetAllSettings: return "Reset and Quit"
    case .setSyncCameras: return "Sync Cameras"
    case .stopAllRecordings: return presentation.recordControl.title
    case .quit: return "Quit Ultracam"
    default: return "Continue"
    }
  }
}
