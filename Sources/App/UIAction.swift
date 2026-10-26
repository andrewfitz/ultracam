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
  case chooseLUT(cameraID: String)
  case setGamut(cameraID: String, String)
  case setInput(cameraID: String, deviceID: String)
  case refreshInputs
  case setPreviewEnabled(cameraID: String, Bool)
  case setAutomaticStart(cameraID: String, Bool)
  case retryAutomaticStart(cameraID: String)
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
  case setOutputMode(UIOutputMode)
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

  // Monitor
  case toggleTool(cameraID: String, UIMonitorTool)
  case freeze(cameraID: String)
  case toggleClean(cameraID: String)
  case detachMonitor(cameraID: String)
  case resetMonitorTools(cameraID: String)
  case copyMonitorSettings(from: String, to: String)

  // App
  case installCameraExtension
  case removeCameraExtension
  case openSettings
  case openDiagnostics
  case openMainWindow
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
    case .resetAllSettings:
      return "Cameras, effects, folders, monitor tools and layout return to their defaults. Recordings are not touched. Ultracam quits when it's done."
    case .stopAllCameras:
      let recording = presentation.cameras.filter { $0.recordButtonActive || $0.pauseTitle == "Resume" }
      let onAir = presentation.cameras.contains { $0.tally == .onAir }
      guard !recording.isEmpty || onAir else { return nil }
      var parts: [String] = []
      if !recording.isEmpty { parts.append("\(recording.count == 1 ? "1 recording ends" : "\(recording.count) recordings end")") }
      if onAir { parts.append(recording.isEmpty ? "On-air video stops" : "on-air video stops") }
      return parts.joined(separator: " and ") + "."
    default:
      return nil
    }
  }

  /// The confirmation dialog's title: the question the message answers.
  func confirmationTitle(in presentation: UISessionPresentation) -> String {
    let name: (String) -> String = { id in presentation.cameras.first { $0.id == id }?.name ?? "Camera" }
    switch self {
    case .stopCamera(let id): return "Stop \(name(id))?"
    case .stopAllCameras: return "Stop All Cameras?"
    case .removeCamera(let id): return "Remove \(name(id))?"
    case .resetAllSettings: return "Reset All Settings?"
    default: return "Are you sure?"
    }
  }

  /// The destructive button of the confirmation dialog, named for what it does.
  var confirmationButtonTitle: String {
    switch self {
    case .stopCamera: return "Stop Camera"
    case .stopAllCameras: return "Stop All Cameras"
    case .removeCamera: return "Remove Camera"
    case .resetAllSettings: return "Reset and Quit"
    default: return "Continue"
    }
  }
}
