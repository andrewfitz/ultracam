import Foundation
import SwiftUI

// The new interface renders a presentation derived from one plain snapshot of
// the app's state. The snapshot is copied from AppModel and RecordingModel;
// the derivation below is pure, so every label, tally and enablement rule can
// be tested without capture hardware, SwiftUI or AppKit.

// MARK: - Snapshot


enum UILayout: String, CaseIterable, Sendable, Equatable {
  case single, sideBySide, programView, fourUp
  var title: String {
    switch self {
    case .single: return "Single"
    case .sideBySide: return "Side by Side"
    case .programView: return "Program View"
    case .fourUp: return "Four Up"
    }
  }
  var symbol: String {
    switch self {
    case .single: return "rectangle"
    case .sideBySide: return "rectangle.split.2x1"
    // Not `tv`: that's Program itself, and this names a layout (large pane plus thumbnails).
    case .programView: return "sidebar.squares.trailing"
    case .fourUp: return "square.grid.2x2"
    }
  }
}

enum UIRecordingStatus: String, Sendable, Equatable { case idle, recording, paused, finishing }

enum UISignal: Sendable, Equatable {
  /// The camera is not capturing.
  case none
  /// Capture is running but no frame has arrived yet.
  case connecting
  case live(format: String)
  case noSignal
  case unsupported(String)
  case deviceMissing
}

enum UIMonitorTool: Int, CaseIterable, Sendable, Equatable {
  case guides, zebra, falseColor, focus, scopes
  var title: String {
    switch self {
    case .guides: return "Guides"
    case .zebra: return "Zebra"
    case .falseColor: return "False Color"
    case .focus: return "Focus Peaking"
    case .scopes: return "Scopes"
    }
  }
  /// Exposure, then framing, then measurement: the order of the menu and the tool bar.
  static let menuOrder: [UIMonitorTool] = [.guides, .zebra, .falseColor, .focus, .scopes]
  /// ⌥⌘ and this key turns the tool on or off on the selected camera.
  var key: KeyEquivalent {
    switch self {
    case .guides: return "g"
    case .zebra: return "z"
    case .falseColor: return "l"
    case .focus: return "f"
    case .scopes: return "k"
    }
  }
  var symbol: String {
    switch self {
    case .guides: return UISymbol.guides
    case .zebra: return UISymbol.zebra
    case .falseColor: return UISymbol.falseColor
    case .focus: return UISymbol.focusPeaking
    case .scopes: return UISymbol.scopes
    }
  }
}

struct UIAudioLevels: Sendable, Equatable {
  var present = false
  var peakLeft = 0.0, peakRight = 0.0, rmsLeft = 0.0, rmsRight = 0.0
  /// Fixtures: every channel's peak, as a live meter shows it. Nil is the stereo pair above.
  var channelPeaks: [Double]? = nil
}

struct UICameraRecording: Sendable, Equatable {
  var status: UIRecordingStatus = .idle
  var elapsed: TimeInterval = 0
  var fileBytes: Int64 = 0
  var megabitsPerSecond: Double = 0
  var droppedFrames = 0
  /// The gaps in this take's video that those frames fell in.
  var sourceGaps = 0
  var systemCompatibilityFrames: UInt64 = 0
  var compatibilityConversionActive = false
  /// Engineering words, so they live in the Recording popover and never on the picture.
  var compatibilityNote: String? {
    guard status == .recording, compatibilityConversionActive, systemCompatibilityFrames > 0 else { return nil }
    return "Compatibility conversion: \(systemCompatibilityFrames) frames."
  }
  /// The format a rolling take records in, whatever the global choice has become since.
  var takeCodec: RecordingCodec?
  /// What was chosen, when the source couldn't use it and `takeCodec` is the fallback.
  var takeFallbackFrom: RecordingCodec?
  var failed = false
  var error: String?
  /// A note on the take that isn't an error, such as audio re-synced to the picture.
  var note: String?
  /// The take's audio, measured from its start: so far while it records, then
  /// the finished take's until the next one starts.
  var audio: AudioTakeSummary?
  /// The most recent finished take, kept until the next take starts.
  var savedFileName: String?
  var savedURL: URL?
  var savedDuration: TimeInterval?
  var folderPath: String?
  /// The volume `folderPath` is on: its drive's `UIDrive.id`. Nil when no drive read names it.
  var volumeID: String?
  var folderIsCustom = false
  /// Seconds of recording left on this camera's destination volume, if known.
  var secondsLeft: TimeInterval?
}

struct UICameraSnapshot: Sendable, Equatable, Identifiable {
  var ingestCPUCopyFrames: UInt64 = 0
  var ingestCPUCopyActive = false
  var id: String
  var name: String
  /// The assigned input's ID, listed or not; nil when the camera has none (None).
  var inputID: String?
  /// The assigned input's label (`UIInputLabels.label`), also while it's unplugged; nil with none.
  var inputName: String?
  /// The input's connector when it isn't HDMI, the usual one (ruling 23): "SDI".
  var inputConnector: String?
  var deviceAvailable = true
  var running = false
  var signal: UISignal = .none
  var outputFormat: String?
  /// True while an effect or processing change is renegotiating the output.
  var applying = false
  /// This camera's virtual camera has at least one client.
  var inUse = false
  /// Its route can't be read, so `inUse` means nothing: the clients are unknown, not none.
  var clientUnknown = false
  /// Its virtual camera's sink is open, so frames sent now reach a client.
  var sinkConnected = false
  /// A client has been waiting and no frames are reaching it.
  var clientWaiting = false
  /// The extension's queue has stayed full: the client stopped taking frames.
  var queueStalled = false
  /// Why this camera's virtual camera couldn't connect, while it can't.
  var sinkFailure: String?
  /// Its own run, take and LUT load are over, and it isn't the last camera.
  var canRemove = true
  /// How long the signal has been gone from a camera that had a picture, past the loss
  /// hold. Nil for a camera that never had one, which just has no signal.
  var signalLostFor: TimeInterval?
  /// `systemUptime` of the same, so a view can tick it while no updates arrive.
  var signalLostSince: TimeInterval?
  /// Its paired camera body. Nil means none, so the left pane draws one line less.
  var body: UICameraBody?
  /// Seconds of steady signal still needed before Program may cut here again.
  var cutBlockedFor: TimeInterval?
  /// It stopped by itself, or its take did, and nobody has acknowledged that yet.
  var unexpectedStop: UIUnexpectedStop?
  /// "In use", "Not in use", or that nobody can tell.
  var clientLine: String { inUse ? "In use" : clientUnknown ? "Use unknown" : "Not in use" }
  var processing = true
  var effects: [Bool] = [false, true, true, false]
  var resizeTarget: ResizeTarget = .hd1080
  var scalingMode: ProgramScalingMode = .fit
  var colorTarget: ColorTarget = .yuv4208
  var frameRateTarget: FrameRateTarget = .fps2997
  var lutName: String?
  var lutLoading = false
  var lutError: String?
  var gamut = "Unspecified / custom LUT"
  var sourceProfileID = "unspecified"
  var lutInputSpaceID = "rec709-video"
  var lutOutputSpaceID = "rec709-video"
  var programColorSpaceID = "rec709-video"
  var recordingConstantFrameRate = false
  var sourceFrameRate: FrameRate? = nil
  /// What the camera is sending, nil before a format is known. It decides what a take can
  /// record, and sizes the estimates.
  var sourceFormat: SourceFormat? = nil
  /// Dropouts since Start, kept on the signal badge once there are any.
  var signalDropouts = 0
  /// The source's depth and chroma ("10-bit 4:2:2"), nil before a format is known.
  var sourcePixel: String? = nil
  var showsRecordingConstantFrameRateCompatibility: Bool { sourceFrameRate?.isVariable == true }
  var previewEnabled = true
  var automaticStart = false
  var automaticStatus: String?
  /// Automatic mode tried to start this camera and failed; Retry is available.
  var automaticStartFailed = false
  var timecode: String?
  var audio = UIAudioLevels()
  /// How many channels the expanded strip's meter shows (Settings › Audio).
  var channelsShown: UIChannelsShown = .asDetected
  /// What the source really declares; 0 before it has.
  var audioChannels = 0
  var audioSampleRate = 0
  var activeTools: Set<UIMonitorTool> = []
  /// Clip indicators show: not one of the interface's tools, but enabled like one.
  var clipIndicators = false
  var recording = UICameraRecording()
  var message = ""
}

/// The camera body behind a capture device, as the left pane shows it.
struct UICameraBody: Sendable, Equatable {
  /// What the body reports about itself that can end the picture.
  struct Warning: Sendable, Equatable { var text: String; var short: String }
  var name: String
  var connected = true
  /// Nil until its control plugin reports one with a known unit.
  var battery: UIBattery? = nil
  /// The body's ID, for a link to its Settings › Hardware row.
  var id = ""
  /// It dropped on its own; Reconnect uses the saved sign-in.
  var lost = false
  /// Overheating, a low battery in a known unit, a card error: the worst one.
  var warning: Warning? = nil
  /// The body's latest notice that still matters (reconnecting, card full).
  var notice: String? = nil
}

struct UIUnexpectedStop: Sendable, Equatable {
  /// Why the camera stopped, while it's still stopped. A restart clears this half.
  var reason: String?
  /// It was on air when it stopped.
  var wasOnAir = false
  /// A take ended early with it. Stays until acknowledged.
  var take = false
  var savedDuration: TimeInterval?
  /// The camera stopped and has been started again: what's left is the take's half.
  var restarted = false
  /// When the camera stopped, in milliseconds, for the stop and the take it left: another
  /// stop is another incident. Nil for a take that ended on its own.
  var incident: Int64? = nil
}

/// Program moved off a camera that lost its signal. It stays until it's acknowledged.
struct UIProgramMove: Sendable, Equatable {
  enum Cause: Sendable, Equatable { case signalLost, stopped, notReady }
  var from: String
  var to: String
  /// Hold was on: loss overrode it once, and it stays on for the new shot.
  var heldShot = false
  var cause = Cause.signalLost

  var title: String {
    switch cause {
    case .signalLost: return "\(from) signal lost"
    case .stopped: return "\(from) stopped"
    case .notReady: return "\(from) has no picture yet"
    }
  }
}

/// An error that used to reach only Diagnostics. Stays until acknowledged or resolved.
struct UIAppProblem: Sendable, Equatable, Identifiable {
  var id: String
  var text: String
}

struct UIShotTiming: Sendable, Equatable {
  /// When the camera now on Program went on air; views tick from here.
  var startedAt: Date?
  var currentShot: TimeInterval?
  var minimum: TimeInterval = 10
  var softMaximum: TimeInterval = 20
  var maximum: TimeInterval = 30
}

struct UICutRecord: Sendable, Equatable, Identifiable {
  var id = UUID()
  var at: Date
  var cameraID: String
  var cameraName: String
  var automatic: Bool
}

struct UIDrive: Sendable, Equatable, Identifiable {
  /// The volume, which its name can't be: two volumes can share one ("8TB" and a mount named "8TB 1").
  var id: String { volumeID ?? name }
  /// The volume's display name.
  var name: String
  var availableBytes: Int64
  var totalBytes: Int64
  /// Nil when unknown, and on a full drive (`isFull`).
  var secondsLeft: TimeInterval?
  /// Less time left than this is low (Settings › Alerts, Low Space).
  var lowSeconds: TimeInterval = UIPresentationBuilder.defaultLowDriveSeconds
  /// Its volume UUID, else its mount point. Nil for a drive known only by name (fixtures).
  var volumeID: String? = nil
  /// The recording folders on it.
  var folders: [String] = []
}

struct UITake: Sendable, Equatable, Identifiable {
  var id: URL { url }
  var url: URL
  var name: String
  var date: Date
  var duration: TimeInterval?
  /// Frames this take lost, from its sidecar; nil for an older take without the count.
  var lostFrames: UInt64? = nil
}

struct UIInterruptedTake: Sendable, Equatable, Identifiable {
  var id: String
  var title: String
}

struct UIInstallState: Sendable, Equatable {
  var canRequestChanges = true
  var pending = false
  var status = ""
  var unavailableReason: String?
  /// True when an Ultracam camera device is present in the system.
  var installed = true
  /// What macOS says about the extension (versions, enabled, approval); nil until it answers.
  var system: ExtensionSystemState?
  var needsApproval: Bool { status.localizedCaseInsensitiveContains("approve") }
}

struct UISessionSnapshot: Sendable, Equatable {
  var syncCameras = false
  var cameras: [UICameraSnapshot] = []
  /// Switching exists with two cameras: Program is published and cuts are offered.
  var programAvailable: Bool { FeedLifecycleDemandPolicy.programPublished(enabledCameras: cameras.count) }
  var selectedID: String = ""
  var programInUse = false
  /// Program's route can't be read: its clients are unknown, not none.
  var programClientUnknown = false
  /// Program's sink is open, so frames sent now reach its clients.
  var programSinkConnected = false
  var programClientLine: String { programInUse ? "In use" : programClientUnknown ? "Use unknown" : "Not in use" }
  var onAirID: String?
  var pendingCutID: String?
  var autoSwitching = false
  var autoHold = false
  var strategy: SwitcherStrategy = .manual
  /// Natural talking head: the camera preferred for the wide/anchor shot, if fixed.
  var anchorID: String?
  /// Natural talking head: the camera preferred for emphasis, if fixed.
  var emphasisID: String?
  /// A picture is expanded from a grid layout; Restore Layout returns to it.
  var expandedFrom: UILayout?
  var strategyTitle = "Manual"
  var shot = UIShotTiming()
  var programFormatMismatch = false
  /// A Program cut that did not land, or Program frames the output dropped.
  var programIssue: String?
  var programMoved: UIProgramMove?
  /// A cut landed while a client watched a camera's own device, and Program has none.
  var cutsMissClient = false
  /// The extension's Program queue has stayed full.
  var programQueueStalled = false
  /// A take has outlived the last client seen during it.
  var unusedTake = false
  var appProblems: [UIAppProblem] = []
  /// Notifications have never been asked for, so Attention may offer them.
  var offerAlerts = false
  var recentCuts: [UICutRecord] = []
  /// The format chosen for every camera, applied to the next take.
  var codec: RecordingCodec = .proRes42210Bit
  var timecodeTitle = "Mac Clock"
  var defaultFolderPath: String?
  var drives: [UIDrive] = []
  var recentTakes: [UITake] = []
  var interruptedTakes: [UIInterruptedTake] = []
  var recoveringID: String?
  var recoveryMessage: String?
  /// The recovered movie, for the sheet's Show in Finder.
  var recoveredURL: URL?
  var interruptedTakesOpen = false
  var install = UIInstallState()
  var canAddCamera = true
  var layout: UILayout = .sideBySide
  var collapsed: Set<String> = []
  var sidebarVisible = true
  var inspectorOpen = false
  /// The camera whose rename prompt is open, if any.
  var renamingCameraID: String?
  /// Under 1100 pt the toolbar's cut buttons keep their digits only, with names in help.
  var narrowWindow = false
  /// The left pane's one collapsible section. Nothing collapses by itself.
  var virtualCamerasCollapsed = false
  /// Settings › General: stopping several takes and quitting ask first. On by default.
  var askBeforeEnding = true
}

// MARK: - Presentation

enum UITally: Sendable, Equatable {
  case none
  /// Red ring and "ON AIR": frames from this camera are reaching Program's clients.
  case onAir
  /// Red ring and "ISO": frames from this camera are reaching a client of its own device.
  case iso
  /// On Program, a client is watching, and there's no picture. Orange: red stays
  /// reserved for frames arriving.
  case noPicture
  /// On Program, with nothing receiving it.
  case program
  /// A cut to this camera is pending (it lands on the next Program frame).
  case next
  var badge: String? {
    switch self {
    case .none: return nil
    case .onAir: return "ON AIR"
    case .iso: return "ISO"
    case .noPicture: return "NO PICTURE"
    case .program: return "PROGRAM"
    case .next: return "NEXT"
    }
  }
  /// Sentence case for text outside the picture (strip, sidebar, menus, status).
  var label: String? {
    switch self {
    case .none: return nil
    case .onAir: return "On air"
    case .iso: return "ISO"
    case .noPicture: return "No picture"
    case .program: return "Program"
    case .next: return "Next"
    }
  }
  /// Red means frames are reaching someone, by either route. Two reds keep their
  /// words apart, so they never hide which picture Program is on.
  var isRed: Bool { self == .onAir || self == .iso }
}

enum UITileState: Sendable, Equatable {
  case live, connecting, noSignal, signalLost, unsupported(String), deviceMissing, stopped, previewHidden, updating
  /// True when the picture area shows video (tool chips and overlays only make sense then).
  var showsPicture: Bool { self == .live || self == .updating }
}

enum UIStripState: String, Sendable, Equatable {
  case ready, recording, paused, finishing, saved, noFolder, failed, recordingNoSignal, stopped, waiting, updating
}

enum UITone: String, Sendable, Equatable { case neutral, positive, warning, critical, onAir }

struct UIChip: Sendable, Equatable, Identifiable {
  var id: Int
  var title: String
  var isOn: Bool
  var enabled: Bool
  var help: String
}

struct UICameraPresentation: Sendable, Equatable, Identifiable {
  var id: String
  var number: Int
  var name: String
  var inputName: String
  var selected: Bool
  var collapsed: Bool
  var tally: UITally
  var tileState: UITileState
  var stripState: UIStripState
  var statusBadge: String
  var statusTone: UITone
  var recordTitle: String
  var recordDetail: String
  var recordTone: UITone
  var recordButtonActive: Bool
  var recordButtonEnabled: Bool
  var recordButtonHelp: String
  var pauseTitle: String?
  var sizeLine: String?
  var dropsLine: String?
  var dropsWarning: Bool
  var folderLine: String
  var timeLeftLine: String?
  /// The help and VoiceOver wording of the output row.
  var outputLine: String
  /// What the camera sends: one value at every width, "1080p 29.97". Chroma stays in the
  /// Effects menu and on the signal badge.
  var outputValue: String
  var outputInUse: Bool
  var showsCut: Bool
  var cutEnabled: Bool
  /// Why Cut is off, for the tooltip. Nil when it's on.
  var cutHelp: String?
  var chips: [UIChip]
  var processing: Bool
  var applying: Bool
  var canStart: Bool
  var canStop: Bool
  var stopNeedsConfirmation: Bool
  var stopConfirmationMessage: String
  var timecode: String
  var audio: UIAudioLevels
  var activeTools: [UIMonitorTool]
  var accessibilityLabel: String
  var lutError: String?
  var automaticStartFailed: Bool
  /// The failed take ran out of disk space: the strip offers another folder.
  var diskFull = false
  /// How many channels the expanded strip's meter shows. Collapsed strips show 1–2.
  var channelsShown: UIChannelsShown = .asDetected
  /// A note on the current or last take that needs a look, such as audio
  /// re-synced after a signal drop, or an audio over. Shown with a warning symbol.
  var recordingNote: String? = nil
  /// The take's audio in full ("Audio −23.4 LUFS · max −2.1 dBTP · no overs"),
  /// for a tooltip and VoiceOver: so far while recording, the last take's once saved.
  var takeAudioHelp: String? = nil
  /// This camera's worst problem, in place of its folder row. The strip never changes height.
  var stripProblem: UIStripProblem? = nil
  /// The format of this camera's take, or of its next one: "HEVC 4:2:2".
  var formatTitle: String = ""
  /// "ProRes 4444 → ProRes 422 HQ", when the source can't use the choice.
  var formatFallback: String? = nil
  /// The fallback's reason, for help.
  var formatHelp: String = ""
  /// The strip's state word when collapsed, in place of a row it hasn't got.
  var collapsedWord: String? = nil
  /// That word is a problem: a triangle, and words in primary.
  var collapsedWarns = false
  var signalDropouts = 0
  /// The sidebar's glyph for this camera.
  var state: UIState = .inactive
  /// "Signal lost 0:06", from a camera that had a picture.
  var lostTitle: String? = nil
  /// What that means now: the take's countdown, and that nothing can take over.
  var lostDetail: String? = nil
  /// With Auto off, the camera a large Cut on the placeholder goes to.
  var lostCut: UICutButton? = nil
  var canRemove = false
  var removeHelp = ""

  /// The LUT's one-click toggle, a fixed slot on every strip. Off while Effects are off,
  /// and with nothing loaded.
  var lutChip: UIChip? { chips.first }
  var lutIsOn: Bool { (lutChip?.isOn ?? false) && processing }
  var lutEnabled: Bool { (lutChip?.enabled ?? false) && processing }
}

/// One row of an Input picker: a listed device, and the other camera that already uses it.
struct UIInputOption: Sendable, Equatable, Identifiable {
  var id: String
  var label: String
  /// Another camera assigned this input; the row is disabled for this camera.
  var usedBy: String?
}

/// Device labels that stay apart when two units share a model name. The driver's own
/// "(1)"/"(2)" follow enumeration order, so they can name a different unit next launch.
enum UIInputLabels {
  /// The last four hex digits of the persistent ID: "0AB8" for input:00000000a1850ab8.
  static func suffix(_ id: String) -> String {
    let digits = id.split(separator: ":").last.map(String.init) ?? id
    return String(digits.filter { $0.isLetter || $0.isNumber }.suffix(4)).uppercased()
  }

  /// The name, with the ID's last four digits when another input in `inputs` has the same name.
  /// "Recorder (0AB8)": a plain string, so no " · " join (J 22).
  static func label(id: String, name: String, among inputs: [(id: String, name: String)]) -> String {
    inputs.contains { $0.id != id && $0.name == name } ? "\(name) (\(suffix(id)))" : name
  }

  /// An assigned input that isn't listed. The last name seen this session when there is one.
  static func missingLabel(id: String, lastName: String?) -> String {
    "\(lastName ?? "Input device") (\(suffix(id)))"
  }

  /// The picker rows for one camera: every listed input, labelled, with the camera that holds it.
  static func options(_ inputs: [(id: String, name: String)], cameras: [UICameraSnapshot],
    for cameraID: String) -> [UIInputOption] {
    inputs.map { input in
      UIInputOption(id: input.id, label: label(id: input.id, name: input.name, among: inputs),
        usedBy: cameras.first { $0.id != cameraID && $0.inputID == input.id }?.name)
    }
  }
}

enum UIRecordControl: Sendable, Equatable {
  /// `ready` cameras can roll now out of `total`.
  case record(all: Bool, enabled: Bool, ready: Int, total: Int)
  case stop
  case stopAll(count: Int)
  var title: String {
    switch self {
    case .record(let all, _, let ready, let total):
      if !all { return "Record" }
      return ready > 0 && ready < total ? "Record \(ready) of \(total)" : "Record All"
    case .stop: return "Stop Recording"
    // One take of several keeps stopAll's action: toggling the selected camera could start a second.
    case .stopAll(let count): return count == 1 ? "Stop Recording" : "Stop \(count) Recordings"
    }
  }
}

/// The Start button, only while a camera is stopped. Stop Cameras leaves the toolbar: it
/// stays at ⌘↩, in the Camera menu and in the menu bar.
struct UIStartControl: Sendable, Equatable {
  var title: String
  var enabled: Bool
  var action: UIAction
  var help: String
}

struct UICutButton: Sendable, Equatable, Identifiable {
  var id: String
  var number: Int
  var name: String
  /// Its camera is on Program. Whether that's on air is `tally`'s to say.
  var onAir: Bool
  var pending: Bool
  var enabled: Bool
  /// Why it's off, when it's off.
  var help: String? = nil
  /// Program's tally while its camera is on Program (`.onAir`, `.noPicture` or `.program`), else none.
  var tally: UITally = .none
}

/// One typed piece of a status segment. Pieces are separated by spacing, never " · ":
/// the text stays whole in `UIStatusSegment.text`, for help and VoiceOver.
enum UIStatusPiece: Sendable, Equatable {
  case strong(String)
  case dim(String)
  case value([UIValuePart])
  case virtualCamera(inUse: Bool)
  case recordingDot
  case pausedGlyph
  case warningGlyph
  /// The shot clock: its own view, so it ticks without the bar.
  case shot(bar: Bool, countsAuto: Bool)
}

struct UIStatusSegment: Sendable, Equatable, Identifiable {
  enum Kind: String, Sendable { case output, program, recording, audio, warning }
  var id: Kind { kind }
  var kind: Kind
  var text: String
  var tone: UITone
  /// The problem segment's level and one action, a button in the bar.
  var level: UIProblemLevel? = nil
  var action: UIProblemAction? = nil
  /// What the bar draws at each density. Help keeps `text` at every one.
  var pieces: [UIStatusPiece] = []
  var compactPieces: [UIStatusPiece] = []
  var essentialPieces: [UIStatusPiece] = []
}

/// One row of a virtual camera list.
struct UIVirtualCamera: Sendable, Equatable, Identifiable {
  var id: String
  /// The device name a meeting app lists: "Ultracam · Program".
  var name: String
  var cameraID: String?
  var inUse: Bool
  var clientLine: String
  var format: String?
}

/// A row of the Format menus: its rate per camera and time left for the current sources.
struct UIFormatChoice: Sendable, Equatable, Identifiable {
  var id: RecordingCodec { codec }
  var codec: RecordingCodec
  var title: String
  var selected: Bool
  /// "~64 Mb/s", per camera.
  var rate: String?
  /// "1 h 52 m left": the shortest across drives in use.
  var left: String?
  /// Why no current source can use it: "Needs a 4:2:0 source". Nil when one can.
  var reason: String?
}

struct UISessionPresentation: Sendable, Equatable {
  var title: String
  var cameras: [UICameraPresentation]
  var selected: UICameraPresentation?
  /// Two or more cameras: Program exists, and cut controls show in every layout.
  var programAvailable: Bool
  var layouts: [UILayout]
  var layout: UILayout
  var recordControl: UIRecordControl
  var camerasRunning: Bool
  var camerasControlTitle: String
  /// Nil once every camera runs, or none can start.
  var startControl: UIStartControl?
  var cutButtons: [UICutButton]
  var autoSwitching: Bool
  /// A strategy that switches on its own (anything but Manual), with cameras to switch.
  var canAutoSwitch: Bool
  /// Hold needs Auto on, whichever strategy is cutting.
  var canHoldShot: Bool
  /// Hold is on and doing something.
  var autoHoldOn = false
  /// Start/Stop can do something: a camera runs (Stop) or one can start.
  var canStartAny: Bool
  /// Show Recordings in Finder has a folder to open.
  var canRevealRecordings: Bool
  var statusSegments: [UIStatusSegment]
  /// Every problem, worst first: the one list all surfaces render.
  var problems: [UIProblem]
  /// The Program picture's own tally (`UIPresentationBuilder.programTally`).
  var programTally: UITally = .none
  /// Attention offers to turn alerts on: before a session, never while live.
  var offersAlerts = false
  /// Attention's rows after the problems, where nothing is wrong yet: an extension to install
  /// or update. They keep their noun as their symbol, and stay out of the status bar.
  var setupRows: [UIProblem] = []
  /// Every published camera, Program first.
  var virtualCameras: [UIVirtualCamera] = []
  var virtualCamerasInUse: Int { virtualCameras.filter(\.inUse).count }
  /// Stopping several takes and quitting ask first (Settings › General).
  var askBeforeEnding = true
  var outputSummary: String
  var outputInUse: Bool
  var recordingSummary: String
  var menuBarIcon: UIMenuBarIcon
  var pauseAllTitle: String = "Pause All"
  /// Takes are rolling or paused, so Pause All has something to act on.
  var canPauseAll = false
}

extension UISessionPresentation {
  /// A camera is on air or rolling: no time to ask anyone anything.
  var isLive: Bool { cameras.contains { $0.tally.isRed || $0.pauseTitle != nil } }
  /// The camera the menu bar preview shows: the one a meeting sees, then one a meeting has open,
  /// then the first running. Never the window's selection (D7): the menu has none.
  var previewCamera: UICameraPresentation? {
    cameras.first { $0.tally == .onAir } ?? cameras.first { $0.tally == .iso } ?? cameras.first(where: \.outputInUse)
      ?? cameras.first(where: \.canStop) ?? cameras.first
  }
}

enum UIMenuBarIcon: String, Sendable, Equatable {
  case stopped, waiting, live, bypass, recording, attention
  /// The camera: outlined while stopped or waiting, filled while it sends pictures.
  var symbol: String {
    switch self {
    case .stopped: return "video"
    case .waiting: return UISymbol.waitingCamera
    case .live, .bypass, .recording, .attention: return "video.fill"
    }
  }
  /// The state drawn as a badge on the camera, in the corner Apple's own badged camera symbols use.
  var badgeSymbol: String? {
    switch self {
    // Effects off has no badge: at real size it blurred into the two that matter, and the
    // panel says it.
    case .stopped, .waiting, .live, .bypass: return nil
    case .recording: return "circle.fill"
    case .attention: return UISymbol.warning
    }
  }
  var accessibilityLabel: String {
    switch self {
    case .stopped: return "Ultracam, cameras stopped"
    case .waiting: return "Ultracam, waiting for a meeting app"
    case .live: return "Ultracam, live with effects"
    case .bypass: return "Ultracam, live with effects off"
    case .recording: return "Ultracam, recording"
    case .attention: return "Ultracam needs attention"
    }
  }
}

// MARK: - Formatting

enum UIFormat {
  static func elapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
  }

  /// Short form for pills and status: "12:31", or "1:02:47" past an hour.
  static func shortElapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  /// "1 h 52 m", or "22 min" under an hour: the one form, on every surface.
  static func duration(_ seconds: TimeInterval) -> String {
    durationParts(seconds).map { "\($0.number) \($0.unit)" }.joined(separator: " ")
  }

  /// The same as parts, so the digits can be strong and the units dim.
  static func durationParts(_ seconds: TimeInterval) -> [UIValuePart] {
    let minutes = max(0, Int((seconds / 60).rounded(.down)))
    if minutes >= 60 {
      return [UIValuePart(number: "\(minutes / 60)", unit: "h"),
        UIValuePart(number: String(format: "%02d", minutes % 60), unit: "m")]
    }
    return [UIValuePart(number: "\(minutes)", unit: "min")]
  }

  /// "capture" for "/Volumes/8TB/capture".
  static func folderName(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    return name.isEmpty || name == "/" ? path : name
  }

  /// Where a folder is: "On 8TB" for an external volume, "~/Movies" or the parent path otherwise.
  static func folderLocation(_ path: String) -> String {
    let parts = (path as NSString).pathComponents
    if parts.count >= 3, parts[1] == "Volumes" {
      return parts.count == 3 ? "Volume" : "On \(parts[2])"
    }
    return ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
  }

  static func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }

  static func bitrate(_ megabits: Double) -> String {
    guard megabits.isFinite, megabits > 0 else { return "—" }
    guard megabits >= 1000 else { return String(format: "%.0f Mb/s", megabits) }
    // Two places under 10 Gb/s, where "1.77" and "1.8" are different drives' worth.
    var gigabits = String(format: megabits < 10_000 ? "%.2f" : "%.1f", megabits / 1000)
    if megabits < 10_000, gigabits.hasSuffix("0") { gigabits.removeLast() }
    return "\(gigabits) Gb/s"
  }
}

// MARK: - Derivation

enum UIPresentationBuilder {
  static let effectLongTitles = ["LUT", "Resize", "Color format", "Frame-rate cap"]

  static func tally(for camera: UICameraSnapshot, in session: UISessionSnapshot) -> UITally {
    let onAir = session.onAirID == camera.id
    let program = onAir ? programTally(camera, in: session) : .none
    if program == .onAir { return .onAir }
    // A client of the camera's own device: red, as frames reach it.
    if camera.inUse, camera.sinkConnected, sendsFrames(camera) { return .iso }
    if program == .noPicture { return .noPicture }
    if session.pendingCutID == camera.id, !onAir { return .next }
    return program
  }

  /// Program's own tally: the Program picture's, and the cut button's of the camera on it.
  /// `.onAir`, `.noPicture` or `.program`, never `.iso`: a client of the on-air camera's own
  /// device isn't watching Program.
  static func programTally(_ session: UISessionSnapshot) -> UITally {
    session.cameras.first { $0.id == session.onAirID }.map { programTally($0, in: session) } ?? .none
  }

  private static func programTally(_ camera: UICameraSnapshot, in session: UISessionSnapshot) -> UITally {
    // Red needs frames arriving, not just a client.
    if session.programInUse, session.programSinkConnected, sendsFrames(camera) { return .onAir }
    if session.programInUse, hasNoPicture(camera) { return .noPicture }
    return session.cameras.count > 1 ? .program : .none
  }

  /// Running with a picture: frames leave it.
  private static func sendsFrames(_ camera: UICameraSnapshot) -> Bool {
    if case .live = camera.signal { return camera.running }
    return false
  }

  static func tileState(for camera: UICameraSnapshot) -> UITileState {
    if !camera.deviceAvailable && !camera.running { return .deviceMissing }
    guard camera.running else { return .stopped }
    switch camera.signal {
    case .none, .connecting: return .connecting
    case .noSignal: return camera.signalLostFor == nil ? .noSignal : .signalLost
    case .unsupported(let mode): return .unsupported(mode)
    case .deviceMissing: return .deviceMissing
    case .live:
      if !camera.previewEnabled { return .previewHidden }
      return camera.applying ? .updating : .live
    }
  }

  static func stripState(for camera: UICameraSnapshot) -> UIStripState {
    let recording = camera.recording
    switch recording.status {
    case .finishing: return .finishing
    // A failed take has stopped writing, whatever its status says until it closes.
    case .paused: return recording.failed ? .failed : .paused
    case .recording:
      if recording.failed { return .failed }
      if case .noSignal = camera.signal { return .recordingNoSignal }
      return camera.applying ? .updating : .recording
    case .idle:
      if recording.failed || recording.error != nil || camera.unexpectedStop?.take == true { return .failed }
      // Stays until the next take, through a stop or a lost signal.
      if recording.savedFileName != nil { return .saved }
      if !camera.running { return .stopped }
      switch camera.signal {
      case .noSignal, .unsupported, .connecting, .none, .deviceMissing: return .waiting
      case .live: break
      }
      if recording.folderPath == nil { return .noFolder }
      return .ready
    }
  }

  static func camera(_ camera: UICameraSnapshot, index: Int, in session: UISessionSnapshot) -> UICameraPresentation {
    let tally = tally(for: camera, in: session)
    let tile = tileState(for: camera)
    let strip = stripState(for: camera)
    let rec = camera.recording
    let isRecording = rec.status == .recording || rec.status == .paused
    let liveFormat: String? = { if case .live(let format) = camera.signal { return format }; return nil }()

    let (statusBadge, statusTone): (String, UITone) = {
      if !camera.running {
        // "No input" when none was ever chosen, as the picture says; "Input disconnected" when it's unplugged.
        if !camera.deviceAvailable { return (camera.inputName == nil ? "No input" : "Input disconnected", .warning) }
        // The picture offers Retry; the badge names the same problem instead of a neutral "Stopped".
        return camera.automaticStartFailed ? ("Couldn't start", .warning) : ("Stopped", .neutral)
      }
      switch camera.signal {
      case .live(let format): return (format, .positive)
      case .connecting, .none: return ("Starting…", .neutral)
      case .noSignal: return ("No signal", .warning)
      case .unsupported: return ("Unsupported format", .warning)
      case .deviceMissing: return ("Input disconnected", .warning)
      }
    }()

    let recordTitle: String
    var recordDetail = ""
    var recordTone: UITone = .neutral
    switch strip {
    // Every clock on screen uses the short form ("12:31", "1:02:47").
    case .recording, .updating: recordTitle = "Recording"; recordDetail = UIFormat.shortElapsed(rec.elapsed); recordTone = .critical
    case .recordingNoSignal:
      recordTitle = "Recording"; recordDetail = UIFormat.shortElapsed(rec.elapsed); recordTone = .warning
    case .paused: recordTitle = "Paused"; recordDetail = UIFormat.shortElapsed(rec.elapsed); recordTone = .warning
    case .finishing: recordTitle = "Saving…"; recordDetail = "Writing the last of the take"
    case .saved:
      // The duration beside the word, the file below it; a take's lost frames take the
      // file's place, because they're what the next look is for.
      recordTitle = ["Saved", rec.savedDuration.map(UIFormat.shortElapsed)].compactMap { $0 }.joined(separator: " ")
      recordTone = .positive
      recordDetail = rec.droppedFrames > 0 ? lostFramesLine(rec) : rec.savedFileName ?? ""
    case .noFolder: recordTitle = "No folder"; recordDetail = "Choose where \(camera.name) records"; recordTone = .warning
    case .failed:
      // Orange, not red: red means recording or on air (D8), and a failed take is neither.
      recordTone = .warning
      if diskFull(camera, in: session) {
        // Say what to do, not the writer's error text; Details still has that.
        recordTitle = "Disk full"
        recordDetail = "Free space on \(drive(for: camera, in: session)?.name ?? "the drive") or choose another folder"
      } else {
        recordTitle = "Take ended early"
        recordDetail = takeSavedLine(camera) ?? rec.error ?? "The take ended with an error."
      }
    case .stopped: recordTitle = "Not recording"; recordDetail = "Start the camera to record"
    case .waiting:
      // Name what is actually missing; the badge and picture already say which signal problem it is.
      recordTitle = "Can't record yet"
      recordDetail = rec.folderPath == nil ? "Needs a supported signal and a recording folder" : "Needs a supported signal"
    case .ready: recordTitle = "Ready to record"; recordDetail = "Camera original, no LUT or effects"
    }

    let canRecordNow = camera.running && liveFormat != nil && rec.folderPath != nil && rec.status == .idle
    let recordButtonActive = rec.status == .recording || rec.status == .paused
    let recordButtonEnabled = rec.status == .recording || rec.status == .paused || canRecordNow
    let recordHelp: String = {
      if rec.status == .recording || rec.status == .paused { return "Stop Recording (⌘R)" }
      if !camera.running { return "Start this camera before recording it." }
      if liveFormat == nil { return "Recording becomes available when a supported signal arrives." }
      if rec.folderPath == nil { return "Choose a recording folder first." }
      if rec.status == .finishing { return "Saving the previous take." }
      return "Record (⌘R)"
    }()

    let titles = ["LUT", camera.resizeTarget.title, camera.colorTarget.title, camera.frameRateTarget.title]
    let chips = titles.enumerated().map { index, title in
      UIChip(id: index, title: title, isOn: camera.effects.indices.contains(index) && camera.effects[index],
        enabled: index != 0 || camera.lutName != nil,
        help: index == 0
          ? (camera.lutName == nil ? "Load a .cube LUT to enable this effect." : "Apply the LUT. Doesn't change the camera output format.")
          : "\(effectLongTitles[index]). Changes the camera output format; the video updates briefly.")
    }

    let outputLine: String
    if tally == .onAir {
      outputLine = "On air"
    } else if session.onAirID == camera.id, tally != .iso {
      outputLine = "In Program, no viewer yet"
    } else if session.pendingCutID == camera.id {
      outputLine = "Next"
    } else {
      outputLine = "Ultracam · \(camera.name), \(camera.clientLine.lowercased())"
    }

    let elapsedShort = UIFormat.shortElapsed(rec.elapsed)
    var labelParts = [camera.name]
    if let label = tally.label { labelParts.append(label) }
    if isRecording { labelParts.append(rec.status == .paused ? "recording paused at \(elapsedShort)" : "recording \(elapsedShort)") }
    if tile != .live { labelParts.append(statusBadge) }
    // The take's audio warns only when it needs a look: an over, or a true peak at −1 dBTP or above.
    let takeAudio = isRecording || strip == .saved ? rec.audio : nil
    let audioNote = takeAudio.flatMap { $0.needsAttention ? $0.note : nil }
    // A saved take's losses are in its detail line; the writer's sentence is for Diagnostics.
    let takeNote = strip == .saved && rec.droppedFrames > 0 ? nil : rec.note
    let recordingNote = [takeNote, audioNote].compactMap { $0 }.joined(separator: ". ")
    if let audioNote { labelParts.append(audioNote) }
    let format = format(of: camera, in: session)

    return UICameraPresentation(
      id: camera.id, number: index + 1, name: camera.name,
      inputName: camera.inputName ?? "No input",
      selected: camera.id == session.selectedID,
      collapsed: session.collapsed.contains(camera.id) ||
        (session.cameras.count > 1 && (session.layout == .fourUp || session.layout == .programView)),
      tally: tally, tileState: tile, stripState: strip,
      statusBadge: statusBadge, statusTone: statusTone,
      recordTitle: recordTitle, recordDetail: recordDetail, recordTone: recordTone,
      recordButtonActive: recordButtonActive, recordButtonEnabled: recordButtonEnabled, recordButtonHelp: recordHelp,
      pauseTitle: rec.status == .recording ? "Pause" : rec.status == .paused ? "Resume" : nil,
      sizeLine: isRecording ? (rec.fileBytes > 0 ? UIFormat.bytes(rec.fileBytes) : "—") : nil,
      // A green "0 dropped" doesn't sit beside a take that's losing its picture.
      dropsLine: isRecording ? (strip == .recordingNoSignal ? "Losing frames"
        : rec.droppedFrames > 0 ? "\(rec.droppedFrames) dropped" : "0 dropped") : nil,
      dropsWarning: rec.droppedFrames > 0 || strip == .recordingNoSignal,
      folderLine: rec.folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No recording folder",
      // A drive with nothing free has no time left to show; say so instead of hiding the line.
      timeLeftLine: rec.secondsLeft.map { "\(UIFormat.duration($0)) left" }
        ?? (drive(for: camera, in: session).map(isFull) == true ? "No space left" : nil),
      outputLine: outputLine,
      outputValue: outputValue(camera),
      outputInUse: (session.onAirID == camera.id && session.programInUse) || camera.inUse,
      showsCut: session.programAvailable && session.onAirID != camera.id,
      cutEnabled: session.programAvailable && canTakeCut(camera) && session.onAirID != camera.id,
      cutHelp: cutHelp(camera, in: session),
      chips: chips, processing: camera.processing, applying: camera.applying,
      canStart: !camera.running && camera.deviceAvailable,
      canStop: camera.running,
      stopNeedsConfirmation: camera.running && (isRecording || tally.isRed),
      stopConfirmationMessage: stopMessage(camera: camera, recording: isRecording, onAir: tally.isRed),
      timecode: camera.timecode ?? "—", audio: camera.audio,
      activeTools: UIMonitorTool.allCases.filter { camera.activeTools.contains($0) },
      accessibilityLabel: labelParts.joined(separator: ", "),
      lutError: camera.lutError, automaticStartFailed: camera.automaticStartFailed,
      diskFull: diskFull(camera, in: session), channelsShown: camera.channelsShown,
      recordingNote: recordingNote.isEmpty ? nil : recordingNote,
      takeAudioHelp: takeAudio.map { (isRecording ? "This take so far: " : "Last take: ") + $0.note },
      stripProblem: stripProblem(camera, in: session),
      formatTitle: format.title, formatFallback: format.fallback, formatHelp: format.help,
      collapsedWord: collapsedWord(camera, strip: strip, badge: statusBadge, in: session),
      collapsedWarns: strip == .noFolder || strip == .failed || statusTone == .warning || format.fallback != nil,
      signalDropouts: camera.signalDropouts,
      state: state(camera, strip: strip, tone: statusTone),
      lostTitle: lostClock(camera).map { "Signal lost \($0)" },
      lostDetail: lostDetail(camera, in: session),
      lostCut: lostCut(camera, index: index, in: session),
      canRemove: camera.canRemove, removeHelp: removeHelp(camera, in: session))
  }

  /// The one output value. Stopped, it's what the camera will send, from its effects.
  static func outputValue(_ camera: UICameraSnapshot) -> String {
    if let format = camera.outputFormat { return format }
    guard camera.processing else { return "Source format" }
    let size = camera.effects.indices.contains(1) && camera.effects[1] && camera.resizeTarget != .source
      ? camera.resizeTarget.title : nil
    let rate = camera.effects.indices.contains(3) && camera.effects[3] ? camera.frameRateTarget.title : nil
    return size == nil && rate == nil ? "Source format" : [size, rate].compactMap { $0 }.joined(separator: " ")
  }

  /// A rolling take shows its own format. A camera that isn't rolling shows what its next take
  /// would record, flagged when that isn't the choice. Before any signal, nothing is flagged.
  static func format(of camera: UICameraSnapshot, in session: UISessionSnapshot)
    -> (actual: RecordingCodec, title: String, fallback: String?, help: String) {
    let rec = camera.recording
    let rolling = rec.status != .idle
    let actual = (rolling ? rec.takeCodec : nil) ?? session.codec.resolved(for: camera.sourceFormat)
    let chosen = rolling ? rec.takeFallbackFrom : (actual != session.codec ? session.codec : nil)
    guard let chosen else {
      let help = rolling ? "\(camera.name) is recording in \(actual.title). Change the format after this take."
        : "\(camera.name)'s next take records \(actual.title)."
      return (actual, actual.title, nil, help)
    }
    let source = camera.sourceFormat.map { FormatDisplayIdentity($0).short } ?? "this source"
    return (actual, actual.title, "\(chosen.title) → \(actual.title)", "\(chosen.title) isn't available for \(source). This take records \(actual.title).")
  }

  /// A collapsed strip's state word. Rolling has none, because the REC pill says it.
  static func collapsedWord(_ camera: UICameraSnapshot, strip: UIStripState, badge: String, in session: UISessionSnapshot) -> String? {
    if let chosen = fallbackChoice(camera, in: session) {
      return "\(chosen.title.components(separatedBy: " ").first ?? chosen.title) fallback"
    }
    switch strip {
    case .recording, .updating, .recordingNoSignal: return nil
    case .paused: return "Paused"
    case .saved: return "Saved"
    case .finishing: return "Saving…"
    case .stopped: return badge
    case .waiting: return badge
    case .noFolder: return "No folder"
    case .failed: return diskFull(camera, in: session) ? "Disk full" : "Ended early"
    case .ready: return "Ready"
    }
  }

  /// The choice this camera's source can't use, when it isn't rolling yet.
  private static func fallbackChoice(_ camera: UICameraSnapshot, in session: UISessionSnapshot) -> RecordingCodec? {
    guard camera.recording.status == .idle, session.codec.resolved(for: camera.sourceFormat) != session.codec else { return nil }
    return session.codec
  }

  /// The glyph beside a camera's name in the left pane.
  static func state(_ camera: UICameraSnapshot, strip: UIStripState, tone: UITone) -> UIState {
    if tone == .warning || strip == .failed { return .warning }
    guard camera.running else { return .inactive }
    if case .live = camera.signal { return .healthy }
    return .starting
  }

  /// Why this camera can't be removed yet, or what removing it does.
  static func removeHelp(_ camera: UICameraSnapshot, in session: UISessionSnapshot) -> String {
    if session.cameras.count < 2 { return "Ultracam needs at least one camera." }
    if camera.canRemove { return "Remove \(camera.name) and its settings." }
    if camera.running { return "Stop \(camera.name) to remove it." }
    if camera.recording.status != .idle { return "\(camera.name)'s take has to finish first." }
    return camera.lutLoading ? "\(camera.name)'s LUT is still loading." : "\(camera.name) is still stopping."
  }

  static func addCameraHelp(_ session: UISessionSnapshot) -> String {
    session.canAddCamera ? "Add Camera" : "Ultracam supports \(FeedLifecycleDemandPolicy.maximumCameras) cameras."
  }

  /// "60 frames lost in 5 gaps".
  static func lostFramesLine(_ recording: UICameraRecording) -> String {
    let frames = recording.droppedFrames == 1 ? "1 frame lost" : "\(recording.droppedFrames) frames lost"
    switch recording.sourceGaps {
    case 0: return frames
    case 1: return "\(frames) in 1 gap"
    default: return "\(frames) in \(recording.sourceGaps) gaps"
    }
  }

  static func stopMessage(camera: UICameraSnapshot, recording: Bool, onAir: Bool) -> String {
    switch (recording, onAir) {
    case (true, true): return "\(camera.name) is recording and on air. Stopping the camera ends the take and its video output."
    case (true, false): return "\(camera.name) is recording. Stopping the camera ends the take."
    case (false, true): return "\(camera.name) is on air. Stopping the camera ends its video output."
    case (false, false): return "Stop \(camera.name)?"
    }
  }

  static func session(_ session: UISessionSnapshot) -> UISessionPresentation {
    let cameras = session.cameras.enumerated().map { camera($1, index: $0, in: session) }
    let recording = session.cameras.filter { $0.recording.status == .recording || $0.recording.status == .paused }
    let longest = recording.map(\.recording.elapsed).max() ?? 0
    let elapsed = UIFormat.shortElapsed(longest)
    let ready = cameras.filter(\.recordButtonEnabled).count
    let recordControl: UIRecordControl
    if !recording.isEmpty { recordControl = session.cameras.count > 1 ? .stopAll(count: recording.count) : .stop }
    else { recordControl = .record(all: session.cameras.count > 1, enabled: ready > 0, ready: ready, total: cameras.count) }

    let running = session.cameras.contains(where: \.running)
    // Only the strategies other than Manual cut on their own; Auto never shows as on when it can't switch.
    let canAutoSwitch = session.programAvailable && session.strategy != .manual
    let autoSwitching = canAutoSwitch && session.autoSwitching
    let canHoldShot = autoSwitching
    // The published device names, as a meeting app lists them.
    let inUse = (session.programInUse ? ["Program"] : []) + session.cameras.filter(\.inUse).map(\.name)
    let outputInUse = !inUse.isEmpty
    let outputSummary: String
    if !inUse.isEmpty { outputSummary = inUse.map { "Ultracam · \($0)" }.joined(separator: " and ") + " in use" }
    else if session.cameras.count == 1 { outputSummary = "Ultracam · \(session.cameras[0].name), \(session.cameras[0].clientLine.lowercased())" }
    else {
      let unknown = session.programClientUnknown || session.cameras.contains(where: \.clientUnknown)
      outputSummary = unknown ? "Ultracam cameras: use unknown" : "Ultracam cameras not in use"
    }

    // The worst drive here, every drive in the sidebar.
    let worstDrive = worstDrive(session.drives)
    let drivesLine = session.drives.compactMap { drive in
      isFull(drive) ? "\(drive.name) full" : drive.secondsLeft.map { "\(drive.name) \(UIFormat.duration($0)) left" }
    }
      .joined(separator: ", ")
    let paused = recording.filter { $0.recording.status == .paused }.count
    let rollingCount = recording.count - paused
    let recordingSummary: String
    if recording.isEmpty { recordingSummary = drivesLine.isEmpty ? "Not recording" : "Not recording, \(drivesLine)" }
    else {
      let count = recording.count > 1 ? (paused > 0 ? "\(rollingCount), \(paused) paused " : "\(recording.count) ") : (paused > 0 ? "paused " : "")
      recordingSummary = "REC \(count)\(elapsed)" + (drivesLine.isEmpty ? "" : ", \(drivesLine)")
    }

    // The worst problem comes first in the bar, with its action, so it's one click with the sidebar closed.
    let problems = problems(session)
    var segments: [UIStatusSegment] = []
    if let worst = problems.first {
      let text = worst.title + (problems.count > 1 ? "  +\(problems.count - 1)" : "")
      let pieces: [UIStatusPiece] = [.warningGlyph, .strong(text)]
      let compact: [UIStatusPiece] = problems.count > 1 ? [.warningGlyph, .strong("\(problems.count) problems")] : pieces
      segments.append(UIStatusSegment(kind: .warning, text: text, tone: .warning, level: worst.level, action: worst.action,
        pieces: pieces, compactPieces: compact, essentialPieces: compact))
    }
    let virtualCameras = virtualCameras(session)
    // With Program, its segment leads with the virtual camera glyph; this one only says what
    // that can't, a camera's own device in use.
    if !session.programAvailable || session.cameras.contains(where: \.inUse) {
      segments.append(outputSegment(session, cameras: virtualCameras, summary: outputSummary, inUse: outputInUse))
    }
    let onAirName = session.cameras.first { $0.id == session.onAirID }?.name
    if session.programAvailable {
      segments.append(programSegment(session, onAirName: onAirName, autoSwitching: autoSwitching, holding: canHoldShot && session.autoHold,
        onAirWord: cameras.contains { $0.tally == .onAir } ? "on air" : "in Program"))
    }
    segments.append(recordingSegment(worstDrive: worstDrive, recording: recording.count, paused: paused, elapsed: elapsed,
      summary: recordingSummary))
    // Audio can only be judged from a picture with a signal; a running camera without HDMI has none.
    let live = session.cameras.filter(isLive)
    // No segment at all until a camera is live.
    let withAudio = live.filter(\.audio.present)
    if !live.isEmpty {
      let healthy = withAudio.count == live.count
      let count = "\(withAudio.count) of \(live.count)"
      let text = healthy ? "Audio \(count)" : live.count == 1 ? "No embedded audio" : "Audio: \(count)"
      let pieces: [UIStatusPiece] = healthy ? [.dim("Audio"), .strong(count)] : [.warningGlyph, .strong(text)]
      segments.append(UIStatusSegment(kind: .audio, text: text, tone: healthy ? .neutral : .warning,
        pieces: pieces, compactPieces: pieces, essentialPieces: pieces))
    }

    let programTally = programTally(session)
    let cutButtons = session.programAvailable ? cameras.map {
      UICutButton(id: $0.id, number: $0.number, name: $0.name, onAir: session.onAirID == $0.id,
        pending: session.pendingCutID == $0.id, enabled: $0.cutEnabled || session.onAirID == $0.id, help: $0.cutHelp,
        tally: session.onAirID == $0.id ? programTally : .none)
    } : []

    // One camera has one picture: every grid layout is the single layout.
    let available = UILayout.allCases.filter { session.programAvailable || $0 != .programView }
    let layouts = cameras.count > 1 ? available : available.filter { $0 == .single }
    let layout = layouts.contains(session.layout) ? session.layout : .single

    var presentation = UISessionPresentation(
      title: "Ultracam",
      cameras: cameras, selected: cameras.first(where: \.selected),
      programAvailable: session.programAvailable,
      layouts: layouts, layout: layout, recordControl: recordControl,
      camerasRunning: running,
      camerasControlTitle: camerasControlTitle(session, running: running),
      startControl: startControl(cameras),
      cutButtons: cutButtons, autoSwitching: autoSwitching,
      canAutoSwitch: canAutoSwitch, canHoldShot: canHoldShot,
      canStartAny: running || cameras.contains(where: \.canStart),
      canRevealRecordings: session.defaultFolderPath != nil || session.cameras.contains { $0.recording.folderPath != nil },
      statusSegments: segments, problems: problems, outputSummary: outputSummary, outputInUse: outputInUse,
      recordingSummary: recordingSummary, menuBarIcon: menuBarIcon(session, problems: problems))
    presentation.offersAlerts = session.offerAlerts && !presentation.isLive
    presentation.programTally = programTally
    presentation.autoHoldOn = canHoldShot && session.autoHold
    presentation.setupRows = setupRows(session)
    presentation.virtualCameras = virtualCameras
    presentation.askBeforeEnding = session.askBeforeEnding
    presentation.canPauseAll = !recording.isEmpty
    presentation.pauseAllTitle = !recording.isEmpty && paused == recording.count ? "Resume All" : "Pause All"
    return presentation
  }

  /// The menus' Start or Stop row. One camera says which; several say "All" when it stops them.
  static func camerasControlTitle(_ session: UISessionSnapshot, running: Bool) -> String {
    if session.cameras.count == 1 { return running ? "Stop \(session.cameras[0].name)" : "Start Camera" }
    return running ? "Stop All Cameras" : "Start Cameras"
  }

  /// "Start Cameras" with every camera stopped, "Start Camera 2" with one of several.
  static func startControl(_ cameras: [UICameraPresentation]) -> UIStartControl? {
    let stopped = cameras.filter { !$0.canStop }
    guard !stopped.isEmpty else { return nil }
    let startable = stopped.filter(\.canStart)
    let help = startable.isEmpty ? "No camera can start: connect its input device or choose another input in the inspector." : nil
    if cameras.count == 1 {
      return UIStartControl(title: "Start Camera", enabled: !startable.isEmpty, action: .startAllCameras, help: help ?? "Start the camera (⌘↩).")
    }
    if stopped.count == 1, let only = stopped.first {
      return UIStartControl(title: "Start \(only.name)", enabled: only.canStart, action: .startCamera(cameraID: only.id),
        help: help ?? "Start \(only.name).")
    }
    return UIStartControl(title: "Start Cameras", enabled: !startable.isEmpty, action: .startAllCameras, help: help ?? "Start every stopped camera (⌘↩).")
  }

  /// Every published camera, Program first once there are two.
  static func virtualCameras(_ session: UISessionSnapshot) -> [UIVirtualCamera] {
    let program = session.programAvailable ? [UIVirtualCamera(id: "program", name: "Ultracam · Program", cameraID: nil,
      inUse: session.programInUse, clientLine: session.programClientLine,
      format: session.cameras.first { $0.id == session.onAirID }?.outputFormat)] : []
    return program + session.cameras.map {
      UIVirtualCamera(id: $0.id, name: "Ultracam · \($0.name)", cameraID: $0.id, inUse: $0.inUse, clientLine: $0.clientLine, format: $0.outputFormat)
    }
  }

  /// The green glyph and what it's about: Program, a camera, or how many of them.
  private static func outputSegment(_ session: UISessionSnapshot, cameras: [UIVirtualCamera], summary: String, inUse: Bool) -> UIStatusSegment {
    let using = cameras.filter(\.inUse)
    var words: [UIStatusPiece]
    if using.count > 1 {
      words = [.strong("\(using.count) of \(cameras.count) in use")]
    } else if session.programAvailable, let camera = using.first {
      words = [.strong(camera.name.replacingOccurrences(of: "Ultracam · ", with: "")), .dim("In use")]
    } else {
      words = [.strong(session.cameras.first?.name ?? "No camera")]
      if inUse { words.append(.dim("In use")) }
    }
    let pieces = [UIStatusPiece.virtualCamera(inUse: inUse)] + words
    return UIStatusSegment(kind: .output, text: summary, tone: inUse ? .positive : .neutral,
      pieces: pieces, compactPieces: pieces, essentialPieces: pieces)
  }

  /// The on-air camera, dim, then the shot. "Auto" is the toolbar's to say: this prints only
  /// what adds state, Hold and Manual, and "Auto in 4 s" while that counts.
  private static func programSegment(_ session: UISessionSnapshot, onAirName: String?, autoSwitching: Bool, holding: Bool,
    onAirWord: String) -> UIStatusSegment {
    let onAir = onAirName ?? "No camera"
    let mode = autoSwitching ? (holding ? "Hold" : "Auto") : "Manual"
    // After a manual cut Auto waits out the minimum shot.
    let counts = autoSwitching && !holding && session.recentCuts.first?.automatic == false
    let word: [UIStatusPiece] = autoSwitching ? (holding ? [.strong("Hold")] : []) : [.dim("Manual")]
    let lead: [UIStatusPiece] = [.virtualCamera(inUse: session.programInUse), .strong("Program"), .dim(onAir)]
    return UIStatusSegment(kind: .program, text: "\(onAir) \(onAirWord), \(mode)", tone: .neutral,
      pieces: lead + [.shot(bar: true, countsAuto: counts)] + word,
      compactPieces: lead + [.shot(bar: false, countsAuto: counts)] + word,
      essentialPieces: lead)
  }

  private static func recordingSegment(worstDrive: UIDrive?, recording: Int, paused: Int, elapsed: String, summary: String) -> UIStatusSegment {
    var state: [UIStatusPiece]
    let rolling = recording - paused
    if recording == 0 {
      state = [.dim("Not recording")]
    } else {
      let clock = UIStatusPiece.value([UIValuePart(number: elapsed)])
      state = rolling > 0 ? [.recordingDot, .dim(rolling > 1 ? "REC \(rolling)" : "REC"), clock] : [clock]
      if paused > 0 { state += [.pausedGlyph, .strong("\(paused)")] }
    }
    // A full drive says so: it has no time to show.
    if let full = worstDrive, isFull(full) {
      let driveName: [UIStatusPiece] = [.dim(full.name), .strong("full")]
      return UIStatusSegment(kind: .recording, text: summary, tone: recording == 0 ? .neutral : .critical,
        pieces: state + driveName, compactPieces: state + driveName, essentialPieces: state)
    }
    let drive = worstDrive.flatMap { drive in drive.secondsLeft.map { (drive.name, UIFormat.durationParts($0)) } }
    let driveName: [UIStatusPiece] = drive.map { [.dim($0.0), .value($0.1)] } ?? []
    return UIStatusSegment(kind: .recording, text: summary, tone: recording == 0 ? .neutral : .critical,
      pieces: state + driveName + (drive == nil ? [] : [.dim("left")]), compactPieces: state + driveName, essentialPieces: state)
  }

  /// The drive that runs out first: a full one before any, then the least time left. A drive
  /// whose free space can't be read has no time left and isn't full, so it's never the worst.
  static func worstDrive(_ drives: [UIDrive]) -> UIDrive? {
    func left(_ drive: UIDrive) -> TimeInterval? { isFull(drive) ? 0 : drive.secondsLeft }
    return drives.filter { left($0) != nil }.min { (left($0) ?? 0) < (left($1) ?? 0) }
  }

  /// The drive a camera records to: the volume its folder is on, as the drive read found it.
  /// A folder's path doesn't say: ~/Movies is on the startup volume, and a "/Volumes/8TB 1"
  /// mount is a volume named "8TB".
  static func drive(for camera: UICameraSnapshot, in session: UISessionSnapshot) -> UIDrive? {
    guard let path = camera.recording.folderPath else { return nil }
    if let volume = camera.recording.volumeID { return session.drives.first { $0.id == volume } }
    // Fixtures name no volume, and their drives none: their folders' /Volumes/<name> is the drive.
    let parts = (path as NSString).pathComponents
    guard parts.count >= 3, parts[1] == "Volumes" else { return nil }
    return session.drives.first { $0.volumeID == nil && $0.name == parts[2] }
  }

  /// The cameras a drive's row names by number.
  static func cameras(on drive: UIDrive, in session: UISessionSnapshot) -> [UICameraPresentation] {
    session.cameras.enumerated().compactMap { index, snapshot in
      Self.drive(for: snapshot, in: session)?.id == drive.id ? camera(snapshot, index: index, in: session) : nil
    }
  }

  /// `Change…` when idle, `Folder for Next Take…` during a take, which keeps its own folder.
  static func folderAction(_ session: UISessionSnapshot) -> String {
    if session.defaultFolderPath == nil, !session.cameras.contains(where: { $0.recording.folderPath != nil }) { return "Choose Folder…" }
    return session.cameras.contains(where: isRolling) ? "Folder for Next Take…" : "Change…"
  }

  /// Nothing free on a drive whose size is known (an unreadable drive reports zero for both).
  static func isFull(_ drive: UIDrive) -> Bool { drive.totalBytes > 0 && drive.availableBytes <= 0 }

  /// How the recording layer and AVFoundation word an out-of-space failure: the
  /// output manager's reservation ("… bytes of free space; only … are available"),
  /// AVError.diskFull (-11807), NSFileWriteOutOfSpaceError (640) and ENOSPC (28).
  static let diskFullPhrases = ["no space left", "disk is full", "disk full", "drive is full", "volume is full",
    "out of space", "enough space", "enough available space", "enough free space", "bytes of free space",
    "error -11807", "nscocoaerrordomain error 640", "nsposixerrordomain error 28."]
  /// Free space below this after a failed take means the drive filled, whatever the error says.
  static let nearlyFullBytes: Int64 = 256 * 1_048_576

  /// A failed take that ended because its drive filled.
  static func diskFull(_ camera: UICameraSnapshot, in session: UISessionSnapshot) -> Bool {
    let rec = camera.recording
    guard rec.failed || rec.error != nil else { return false }
    if let error = rec.error?.lowercased(), diskFullPhrases.contains(where: error.contains) { return true }
    guard let drive = drive(for: camera, in: session), drive.totalBytes > 0 else { return false }
    return drive.availableBytes < nearlyFullBytes
  }

  static func menuBarIcon(_ session: UISessionSnapshot) -> UIMenuBarIcon {
    menuBarIcon(session, problems: problems(session))
  }

  private static func menuBarIcon(_ session: UISessionSnapshot, problems: [UIProblem]) -> UIMenuBarIcon {
    if !problems.isEmpty { return .attention }
    if session.cameras.contains(where: { $0.recording.status == .recording }) { return .recording }
    let running = session.cameras.filter(\.running)
    guard !running.isEmpty else {
      return session.cameras.contains(where: \.automaticStart) ? .waiting : .stopped
    }
    // The camera a meeting sees, not the window's selection (D7): Program's, then one in use.
    let shown = running.first { $0.id == session.onAirID && session.programInUse } ?? running.first(where: \.inUse)
      ?? running.first { $0.id == session.onAirID } ?? running[0]
    return shown.processing ? .live : .bypass
  }
}
