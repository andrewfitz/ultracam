import Foundation

/// Capture runs and signal dropouts, one line each, in a plain file the
/// unified log can't age out: ~/Library/Logs/Ultracam/signal.log. Test runs
/// flood the unified log, which overnight kept only eight hours of Ultracam.
/// The sandbox allows this one folder (App.entitlements). Lines are written
/// off the capture queue, and the file rotates once to signal.1.log.
final class SignalLogFile: @unchecked Sendable {
  /// The app only: test and ui-verify runs use the same capture code.
  static let shared: SignalLogFile? = Bundle.main.bundleIdentifier == "org.ultracam.app" ? SignalLogFile() : nil

  let url: URL
  private let limit: UInt64
  private let queue = DispatchQueue(label: "org.ultracam.signal-log", qos: .utility)
  private let stamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
    return formatter
  }()

  init(folder: URL = SignalLogFile.defaultFolder, limit: UInt64 = 8 << 20) {
    url = folder.appendingPathComponent("signal.log")
    self.limit = limit
  }

  /// The real home's Library/Logs: NSHomeDirectory() is the sandbox container.
  static var defaultFolder: URL {
    let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
    return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Logs/Ultracam", isDirectory: true)
  }

  func record(_ message: String) {
    let now = Date()
    queue.async { self.append("\(self.stamp.string(from: now)) \(message)\n") }
  }

  /// Waits for recorded lines to reach the file.
  func flush() { queue.sync {} }

  private func append(_ line: String) {
    let manager = FileManager.default
    try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.uint64Value >= limit {
      let older = url.deletingLastPathComponent().appendingPathComponent("signal.1.log")
      try? manager.removeItem(at: older)
      try? manager.moveItem(at: url, to: older)
    }
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    let bytes = Array(line.utf8)
    _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
  }
}
