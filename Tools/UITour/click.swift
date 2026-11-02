import CoreGraphics
import Foundation

// Clicks the left mouse button at screen point x y (top-left origin), like a person would.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, let x = Double(arguments[0]), x.isFinite,
  let y = Double(arguments[1]), y.isFinite else {
  fputs("Usage: click x y (finite coordinates)\n", stderr)
  exit(64)
}
let point = CGPoint(x: x, y: y)
for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
  CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
  usleep(type == .mouseMoved ? 120_000 : 60_000)
}
