import AppKit

// The helper has no command-line interface or permanent privileged process.
// Standard Additions runs this fixed operation through macOS authentication.
let reloadCommand = #"""
  set -eu
  uid=$(/usr/bin/id -u _cmiodalassistants)
  camera="user/$uid/CMIOExtension.org.ultracam.app.camera"
  if /bin/launchctl kickstart -k "$camera" 2>/dev/null; then
    exit 0
  fi
  if /usr/bin/pgrep -qx -u "$uid" org.ultracam.app.camera; then
    /usr/bin/killall -TERM -u "$uid" org.ultracam.app.camera
    exit 0
  fi
  # During replacement, launchd can remove the old job before registering the
  # new one. Restart the registration assistant so it reloads the enabled job.
  registrar=system/com.apple.cmio.registerassistantservice
  /bin/launchctl kickstart -k "$registrar" 2>/dev/null || /bin/launchctl kill SIGTERM "$registrar"
  """#
let script = reloadCommand.replacingOccurrences(of: "\\", with: "\\\\")
  .replacingOccurrences(of: "\"", with: "\\\"")
let app = NSApplication.shared
var error: NSDictionary?
NSAppleScript(source: "do shell script \"\(script)\" with administrator privileges")?.executeAndReturnError(&error)
if let error, error[NSAppleScript.errorNumber] as? Int != -128 {
  let alert = NSAlert()
  alert.messageText = "Couldn’t reload the Ultracam camera service"
  alert.informativeText = error[NSAppleScript.errorMessage] as? String ?? "macOS rejected the reload."
  alert.addButton(withTitle: "OK")
  app.activate(ignoringOtherApps: true)
  alert.runModal()
}
