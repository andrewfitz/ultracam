import CoreGraphics
import Foundation

// Dismiss a menu inside the tour process even if another app becomes frontmost.
guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]), pid > 0 else {
  fputs("Usage: escape <pid>\n", stderr)
  exit(64)
}
guard CGPreflightPostEventAccess(),
  let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
  let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else {
  fputs("Cannot send Escape. Check Accessibility permission.\n", stderr)
  exit(1)
}
down.postToPid(pid)
up.postToPid(pid)
