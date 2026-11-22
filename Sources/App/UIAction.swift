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
  case toggleInspector
  case setInspectorOpen(Bool)
  case showInspector(cameraID: String)
  /// Opens the status bar's problem list in the main window (the menu bar's Attention row).
  case showProblems
  /// The status bar opened the list it was asked for.
  case problemsShown
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
  case setAllowUpscale(cameraID: String, Bool)
  case setColorTarget(cameraID: String, ColorTarget)
  case setFrameRateTarget(cameraID: String, FrameRateTarget)
  case setSyncCameras(Bool, sourceID: String)
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
  case requestCaptureAccess(pluginID: String)
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
  case startProgramStream
  case stopProgramStream
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
  /// The sheet that lists every interrupted take, from Record's popover and the Record menu.
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
  /// Settings › Hardware with one row expanded: a capture device ID, a camera body ID, or nil.
  case openHardware(itemID: String?)
  /// Connects a camera's paired body again with its saved sign-in (problem list, picture, inspector, sheet).
  case reconnectCameraBody(cameraID: String)
  case openDiagnostics
  case openDiagnosticsSection(UIDiagnosticsSection)
  case openMainWindow
  /// System Settings at Camera Extensions, where macOS waits for an approval.
  case openExtensionApproval
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
  func needsConfirmation(in currentPresentation: @autoclosure () -> UISessionPresentation) -> String? {
    switch self {
    case .stopCamera(let id):
      let presentation = currentPresentation()
      guard let camera = presentation.cameras.first(where: { $0.id == id }), camera.stopNeedsConfirmation else { return nil }
      return camera.stopConfirmationMessage
    case .removeCamera(let id):
      let settings = "Its settings are deleted. Recordings on disk are kept."
      guard currentPresentation().streamAudioFeedID == id else { return settings }
      return settings + " This removes the stream’s audio source. To restore audio, restart the stream with another source."
    case .setSyncCameras(true, let sourceID):
      let presentation = currentPresentation()
      guard let source = presentation.cameras.first(where: { $0.id == sourceID }),
        presentation.cameras.count > 1 else { return nil }
      let others = presentation.cameras.filter { $0.id != source.id }.map(\.name).joined(separator: ", ")
      return "\(others) \(presentation.cameras.count > 2 ? "take" : "takes") \(source.name)'s effects, LUT, monitor tools, source declarations and preview setting, and meeting apps may see \(presentation.cameras.count > 2 ? "their" : "its") format change. Inputs and folders stay separate."
    case .stopAllRecordings:
      let presentation = currentPresentation()
      let takes = presentation.cameras.filter { $0.recordButtonActive || $0.pauseTitle == "Resume" }.count
      guard presentation.askBeforeEnding, takes > 1 else { return nil }
      return "\(takes) recordings end. Cameras keep running and on-air video continues."
    case .resetAllSettings:
      return "Camera, effect, folder, monitor and layout settings return to their defaults. Saved streaming settings and credentials are cleared. Recordings on disk are kept. Ultracam quits when it’s done."
    case .stopAllCameras:
      return Self.endingMessage(in: currentPresentation(), quitting: false)
    default:
      return nil
    }
  }

  /// What ending everything would cost, or nil when it costs nothing.
  static func endingMessage(in presentation: UISessionPresentation, quitting: Bool = true) -> String? {
    let recording = presentation.cameras.filter { $0.recordButtonActive || $0.pauseTitle == "Resume" }
    let onAir = presentation.cameras.contains { $0.tally.isRed }
    guard !recording.isEmpty || onAir || presentation.streamActive else { return nil }
    var parts: [String] = []
    if !recording.isEmpty { parts.append("\(recording.count == 1 ? "1 recording ends" : "\(recording.count) recordings end")") }
    if onAir { parts.append(recording.isEmpty ? "On-air video stops" : "on-air video stops") }
    let message = parts.isEmpty ? "" : parts.joined(separator: " and ") + "."
    guard presentation.streamActive else { return message }
    let stream = quitting ? "Quitting ends the Program stream."
      : presentation.streamAudioFeedID != nil ? "A connected Program stream continues with black video and silent audio."
      : "A connected Program stream continues with black video."
    return [message, stream].filter { !$0.isEmpty }.joined(separator: " ")
  }

  /// The confirmation dialog's title: the question the message answers.
  func confirmationTitle(in presentation: UISessionPresentation) -> String {
    let name: (String) -> String = { id in presentation.cameras.first { $0.id == id }?.name ?? "Camera" }
    switch self {
    case .stopCamera(let id): return "Stop \(name(id))?"
    case .stopAllCameras: return presentation.cameras.count == 1 ? "Stop \(presentation.cameras[0].name)?" : "Stop All Capture?"
    case .removeCamera(let id): return "Remove \(name(id))?"
    case .resetAllSettings: return "Reset All Settings?"
    case .setSyncCameras(_, let id): return "Sync Cameras from \(name(id))?"
    case .stopAllRecordings: return "\(presentation.recordControl.title)?"
    case .quit: return "Quit Ultracam?"
    default: return "Are you sure?"
    }
  }

  /// The verb of the confirmation dialog, named for what it does.
  func confirmationButtonTitle(in presentation: UISessionPresentation) -> String {
    switch self {
    case .stopCamera: return "Stop Capture"
    case .stopAllCameras: return presentation.cameras.count == 1 ? "Stop Capture" : "Stop All Capture"
    case .removeCamera: return "Remove Camera"
    case .resetAllSettings: return "Reset and Quit"
    case .setSyncCameras: return "Sync Cameras"
    case .stopAllRecordings: return presentation.recordControl.title
    case .quit: return "Quit Ultracam"
    default: return "Continue"
    }
  }
}
