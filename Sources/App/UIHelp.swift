import SwiftUI

/// Ultracam Help (⌘?): a short guide and every keyboard shortcut.
struct UIHelpView: View {
  private let steps = [
    "Install the Ultracam camera from the sidebar or Settings › Camera, and approve it in System Settings.",
    "Choose each camera's input device in its inspector (⌥⌘I), then Start Camera.",
    "In your meeting app, choose “Ultracam · Camera 1” (or “Ultracam · Program” in Program mode).",
    "To back up the meeting, choose a recording folder and press Record. Recordings are the camera original, without the LUT or effects.",
  ]

  private let shortcuts: [(String, String)] = [
    ("⌘↩", "Start or stop the cameras"),
    ("⇧⌘B", "Processing for the selected camera (off = complete bypass)"),
    ("⇧⌘P", "Video preview"),
    ("⌘R", "Record or stop the selected camera"),
    ("⇧⌘R", "Pause or resume the selected camera's recording"),
    ("⌥⌘R", "Record all or stop all recordings"),
    ("⌃1–⌃4", "Cut Program to a camera"),
    ("⌃⌥A", "Automatic switching"),
    ("⌘1–⌘4", "Select a camera"),
    ("⌥⌘1–⌥⌘4", "Layout: Single, Side by Side, Program View, Four Up"),
    ("⌃⌘S", "Show or hide the sidebar"),
    ("⌥⌘S", "Collapse or expand all strips"),
    ("⌥⌘K", "Scopes for the selected camera"),
    ("⌥⌘I", "Inspector"),
    ("⌃⌥F", "Freeze the selected picture"),
    ("⌃⌥C", "Clean view for the selected picture"),
    ("⌘O", "Load a LUT for the selected camera"),
    ("⌘0", "Show Main Window"),
    ("⌘,", "Settings"),
  ]

  var body: some View {
    Form {
      Section("Getting Started") {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
          // A hanging number: wrapped lines start under the text, not under the number.
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(index + 1).").monospacedDigit().frame(width: 18, alignment: .trailing)
            Text(step).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      Section("Good to Know") {
        Text("Clicking a picture selects that camera; it never cuts. Cut with the toolbar, a strip's Cut button or ⌃1–⌃4.")
        Text("Stopping a camera that is recording or on air asks first.")
        Text("Record › Pause All pauses every take. When every take is paused, it becomes Resume All.")
        Text("Changing Resize, Color format, Frame-rate cap or Processing renegotiates the camera format, so the meeting's video updates briefly. The LUT doesn't.")
      }
      Section {
        ForEach(shortcuts, id: \.0) { key, command in
          // The system font draws ⌘ ⇧ ⌥ ⌃ at full size, as menus do; SF Mono shrinks them.
          LabeledContent(command) { Text(key).font(.body).foregroundStyle(.secondary) }
        }
      } header: {
        Text("Keyboard Shortcuts")
      } footer: {
        Text("⌃1–⌃4 are also Mission Control's Switch to Desktop shortcuts. If a cut does nothing, turn those off in System Settings › Keyboard › Keyboard Shortcuts › Mission Control, or cut with the toolbar.")
          .font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 640)
  }
}
