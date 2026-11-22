import CoreGraphics
import Foundation

// Scrolls by LINES at screen point x y (top-left origin), like a mouse wheel; negative scrolls down.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 4, let x = Double(arguments[0]), x.isFinite,
  let y = Double(arguments[1]), y.isFinite, let lines = Int32(arguments[2]), (-100...100).contains(lines),
  let pid = pid_t(arguments[3]), pid > 0 else {
  fputs("Usage: scroll x y lines pid (finite coordinates, -100...100 lines)\n", stderr)
  exit(64)
}
let point = CGPoint(x: x, y: y)
guard CGPreflightPostEventAccess(),
  let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
  fputs("Cannot send tour scroll events. Check Accessibility permission.\n", stderr)
  exit(1)
}
move.postToPid(pid)
usleep(120_000)
for _ in 0..<abs(lines) {
  guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
    wheel1: lines < 0 ? -1 : 1, wheel2: 0, wheel3: 0) else {
    fputs("Cannot create a tour scroll event.\n", stderr)
    exit(1)
  }
  event.location = point
  event.postToPid(pid)
  usleep(30_000)
}
