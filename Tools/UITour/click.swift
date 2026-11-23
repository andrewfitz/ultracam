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
guard CGPreflightPostEventAccess() else {
  fputs("Cannot send mouse events. Check Accessibility permission.\n", stderr)
  exit(1)
}
// Create the entire gesture before posting anything. A failed release must not
// leave the pointer button held down.
let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp]
let events = types.compactMap { type in
  CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
}
guard events.count == types.count else {
  fputs("Cannot create mouse events.\n", stderr)
  exit(1)
}
for event in events {
  event.post(tap: .cghidEventTap)
  usleep(event.type == .mouseMoved ? 120_000 : 60_000)
}
