import CoreGraphics
import Foundation

// Prints "id<TAB>layer<TAB>title" for each on-screen window of one process (by
// PID), so the tour captures that app's windows and menus and nothing else, even
// while another copy of Ultracam is running.
guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]), pid > 0 else {
  fputs("Usage: windows <pid>\n", stderr)
  exit(64)
}
guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
  fputs("Cannot list on-screen windows.\n", stderr)
  exit(1)
}
for window in windows where window[kCGWindowOwnerPID as String] as? Int == pid {
  let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
  // Skip the status item and other slivers; keep windows and open menus.
  guard (bounds["Width"] as? Double ?? 0) > 40, (bounds["Height"] as? Double ?? 0) > 40 else { continue }
  guard let id = window[kCGWindowNumber as String] as? Int, id > 0,
    let layer = window[kCGWindowLayer as String] as? Int else { continue }
  let title = (window[kCGWindowName as String] as? String ?? "")
    .components(separatedBy: .newlines.union(CharacterSet(charactersIn: "\t"))).joined(separator: " ")
  print("\(id)\t\(layer)\t\(title)")
}
