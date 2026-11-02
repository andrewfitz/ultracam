import CoreGraphics
import Foundation

// Scrolls by LINES at screen point x y (top-left origin), like a mouse wheel; negative scrolls down.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, let x = Double(arguments[0]), x.isFinite,
  let y = Double(arguments[1]), y.isFinite, let lines = Int32(arguments[2]), lines != Int32.min else {
  fputs("Usage: scroll x y lines (finite coordinates, integer lines)\n", stderr)
  exit(64)
}
let point = CGPoint(x: x, y: y)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(120_000)
for _ in 0..<abs(lines) {
  CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines < 0 ? -1 : 1, wheel2: 0, wheel3: 0)?
    .post(tap: .cghidEventTap)
  usleep(30_000)
}
