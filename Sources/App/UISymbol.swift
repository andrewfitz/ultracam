/// One symbol per noun, everywhere (07 section 1). Views name the noun; this names the
/// SF Symbol, with state variants as functions. All of these exist on macOS 15 or earlier,
/// so on the 26.0 deployment target. MonitorKit can't import this, so its detached tool bar
/// keeps its own list with the same Zebra, Clip and Clean View names.
enum UISymbol {
  // Cameras
  static let camera = "video"
  static let cameraOnAir = "video.fill"
  static let noCameras = "video.badge.plus"
  /// No signal, and a dropout count. It means nothing else.
  static let noSignal = "video.slash"
  static func virtualCamera(inUse: Bool) -> String { inUse ? "video.badge.checkmark" : "video.badge.ellipsis" }
  static let waitingCamera = "video.badge.ellipsis"
  static let installExtension = "video.badge.plus"
  static let updateExtension = "arrow.down.circle"
  static let restartNeeded = "arrow.clockwise.circle"

  // Switching. Program is `tv`, and a virtual camera is the glyphs above: two nouns.
  static let program = "tv"
  static let iso = "video.fill"
  static let cut = "arrow.left.arrow.right"
  static let auto = "wand.and.sparkles"
  static let startWithApps = "bolt.badge.automatic"
  static func hold(on: Bool) -> String { on ? "pin.fill" : "pin" }
  static let shotTime = "timer"

  // Layout and window
  static let inspector = "sidebar.trailing"
  static let expandStrip = "chevron.right"
  static let collapseStrip = "chevron.down"
  static let collapseAll = "rectangle.compress.vertical"
  static let expandAll = "rectangle.expand.vertical"
  static let restoreLayout = "arrow.down.right.and.arrow.up.left"
  static let more = "ellipsis.circle"
  static let add = "plus"

  // Recording
  static let record = "record.circle"
  static let stop = "stop.fill"
  static let paused = "pause.fill"
  static let start = "play.fill"
  static let saved = "checkmark.circle.fill"
  static let take = "film"
  static let format = "film.stack"
  static let timecode = "clock"
  static let folder = "folder"
  static func drive(low: Bool) -> String { low ? "externaldrive.badge.exclamationmark" : "externaldrive" }

  // Effects
  static func lut(on: Bool) -> String { on ? "cube.fill" : "cube" }
  static let effects = "square.stack.3d.up"
  static let effectsOff = "square.stack.3d.up.slash"
  static let updating = "arrow.triangle.2.circlepath"

  // Picture
  static let pictureSettings = "camera.filters"
  static let previewHidden = "eye.slash"
  static let showPreview = "eye"
  static let freeze = "snowflake"
  static func cleanView(on: Bool) -> String { on ? "rectangle.inset.filled" : "rectangle.dashed" }
  static let detach = "arrow.up.forward.square"
  static func monitorTools(anyOn: Bool) -> String {
    anyOn ? "slider.horizontal.below.square.filled.and.square" : "slider.horizontal.3"
  }
  static let zebra = "circle.lefthalf.striped.horizontal"
  static let falseColor = "paintpalette"
  static let clipIndicators = "arrow.up.and.line.horizontal.and.arrow.down"
  static let focusPeaking = "scope"
  static let guides = "squareshape.split.3x3"
  static let scopes = "waveform.path.ecg"

  // Hardware
  static let input = "cable.connector"
  static let inputDisconnected = "cable.connector.slash"
  static let cameraBody = "camera"
  static let cameraControl = "camera.aperture"
  static func wifi(connected: Bool) -> String { connected ? "wifi" : "wifi.slash" }
  static let batteryMinutes = "minus.plus.batteryblock"
  /// The level symbol for a percentage, by bucket.
  static func battery(percent: Int) -> String {
    switch percent {
    case 88...: return "battery.100percent"
    case 63...: return "battery.75percent"
    case 38...: return "battery.50percent"
    case 13...: return "battery.25percent"
    default: return "battery.0percent"
    }
  }

  // State
  static let warning = "exclamationmark.triangle.fill"
  static let information = "info.circle"
  static let retry = "arrow.clockwise"
  static let audio = "waveform"
  static let microphoneReminder = "mic.slash"
  static let diagnostics = "stethoscope"
  static let settings = "gearshape"
  static let openWindow = "macwindow"
  static let alerts = "bell"
  static let advancedSettings = "gearshape.2"
}
