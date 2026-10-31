import SwiftUI

/// Ultracam Help (⌘?): a short guide and every keyboard shortcut. "Settings › X" is a link
/// that opens Settings at that tab.
struct UIHelpView: View {
  @Environment(\.openSettings) private var openSettings

  private let steps = [
    "Install the Ultracam camera from the sidebar or [Settings › Virtual Cameras](ultracam-settings:virtualCameras), and approve it in System Settings.",
    "Choose each camera's input device in its inspector (⌥⌘I), then Start Camera.",
    "In your meeting app, choose “Ultracam · Camera 1” (or “Ultracam · Program” with two or more cameras).",
    "To back up the meeting, choose a recording folder and a format in the sidebar's Recording section, then press Record. Recordings are the camera original, without the LUT or effects.",
  ]

  private let shortcuts: [(String, String)] = [
    ("⌘↩", "Start or stop the cameras"),
    ("⇧⌘B", "Effects for the selected camera (Effects Off sends the camera original)"),
    ("⇧⌘P", "Video preview"),
    ("⌘R", "Record or stop the selected camera"),
    ("⇧⌘R", "Pause or resume the selected camera's recording"),
    ("⌥⌘R", "Record all or stop all recordings"),
    ("⌥⌘P", "Pause All, or Resume All when every take is paused"),
    ("⌃1–⌃4", "Cut Program to a camera"),
    ("⌃⌥A", "Automatic switching"),
    ("⌃⌥H", "Hold the current shot: Auto stays on and makes no cuts"),
    ("⌘1–⌘4", "Select a camera"),
    ("⌥⌘1–⌥⌘4", "Layout: Single, Side by Side, Program View, Four Up"),
    ("⌃⌘S", "Show or hide the sidebar"),
    ("⌥⌘S", "Collapse or expand all strips"),
    ("⌥⌘G", "Guides for the selected camera"),
    ("⌥⌘Z", "Zebra for the selected camera"),
    ("⌥⌘L", "False color for the selected camera"),
    ("⌥⌘F", "Focus peaking for the selected camera"),
    ("⌥⌘K", "Scopes for the selected camera"),
    ("⌥⌘X", "Clip indicators for the selected camera"),
    ("⌥⌘I", "Inspector"),
    ("⌃⌥F", "Freeze the selected picture"),
    ("⌃⌥C", "Clean View for the selected picture"),
    ("⌃⌥D", "Diagnostics"),
    ("⌘O", "Load a LUT for the selected camera"),
    ("⌘0", "Show Main Window"),
    ("⌘,", "Settings"),
  ]

  /// Work while a meeting app is in front, once turned on in Settings › General.
  private let backgroundShortcuts: [(String, String)] = [
    ("⌃⌥⌘1–⌃⌥⌘7", "Cut Program to a camera"),
    ("⌃⌥⌘A", "Automatic switching"),
    ("⌃⌥⌘H", "Hold the current shot"),
    ("⌃⌥⌘R", "Record every camera that can. It never stops a take"),
  ]

  var body: some View {
    Form {
      Section("Getting Started") {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
          // A hanging number: wrapped lines start under the text, not under the number.
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(index + 1).").monospacedDigit().frame(width: 18, alignment: .trailing)
            Text(LocalizedStringKey(step)).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      Section("Good to Know") {
        Text("Clicking a picture selects that camera; it never cuts. Cut with the toolbar, a strip's Cut button or ⌃1–⌃4.")
        Text("Stopping a camera that is recording or on air asks first, and so do stopping several takes and quitting. Cancel is the default, so Return never ends a take.")
        Text("Record › Pause All pauses every take. When every take is paused, it becomes Resume All.")
        Text("LUT On and LUT Off change the picture only, so meeting apps keep their format. Everything in a strip's Effects menu changes the format they receive, so the meeting's video updates briefly.")
        Text("Every camera records one format, chosen in the sidebar or Record › Format. A camera whose source can't use it records the nearest format, and its strip says so in orange.")
        Text("Timecode and folders are in [Settings › Recording](ultracam-settings:recording). Capture devices, their names and connectors, and camera body pairing are in [Settings › Hardware](ultracam-settings:hardware). Channels Shown is in [Settings › Audio](ultracam-settings:audio).")
      }
      Section("Recording") {
        Text("Program is not recorded. A session leaves each camera's original and a list of the cuts.")
        Text("Takes are always written as fragmented QuickTime movies. The first fragment is written after 1 s, then every 10 s. Hidden .partial files and journals sit beside each take until it finishes.")
        Text("An interrupted take appears in Attention. Recovery copies complete fragments into a separate _Recovered.mov without re-encoding and keeps the original.")
      }
      Section("Monitor Tools") {
        Text("Each camera has its own guides, zebra, false color, focus peaking and scopes. Hover a picture for the full tool bar, or use View › Monitor Tools. Scopes' refresh is set per camera in its Scopes popover.")
        Text("New cameras start with monitor tools off. Zebra starts at 95 IRE, and the picture shows the camera's output with its LUT. Right-click a picture to copy its tools to another camera.")
        Text("Monitor tools never change camera output or recordings. Six-band false color works with any source; S-Log3 and LogC modes need the matching source declaration.")
      }
      Section {
        ForEach(shortcuts, id: \.0) { key, command in shortcutRow(key, command) }
      } header: {
        Text("Keyboard Shortcuts")
      } footer: {
        Text("⌃1–⌃4 are also Mission Control's Switch to Desktop shortcuts. If a cut does nothing, turn those off in System Settings › Keyboard › Keyboard Shortcuts › Mission Control, or cut with the toolbar.")
          .font(.uiMeta).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        ForEach(backgroundShortcuts, id: \.0) { key, command in shortcutRow(key, command) }
      } header: {
        Text("Background Shortcuts")
      } footer: {
        Text("Off until you turn them on in [Settings › General](ultracam-settings:general). They reach Ultracam while a meeting app is in front, and the meeting app doesn't get the key.")
          .font(.uiMeta).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 640)
    .environment(\.openURL, OpenURLAction { url in
      guard let tab = UISettingsTab.linked(url) else { return .systemAction }
      UIAppEnvironment.interface.settingsTab = tab
      openSettings()
      return .handled
    })
  }

  /// The key combination in primary, on a keycap chip. The system font draws ⌘ ⇧ ⌥ ⌃ at full
  /// size, as menus do; SF Mono shrinks them.
  private func shortcutRow(_ key: String, _ command: String) -> some View {
    LabeledContent(command) { UIKeycap(key) }
  }
}
