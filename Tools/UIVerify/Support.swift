import AppKit
import SwiftUI

/// Collects check results. With STRICT=0, failures of view-dependent checks
/// are reported as pending instead of failing the run (useful while views
/// are being written); STRICT defaults to 1.
@MainActor final class Verifier {
  let strict: Bool
  let pngDirectory: URL
  private(set) var passed = 0
  private(set) var failed = 0
  private(set) var pending = 0
  private(set) var failures: [String] = []
  private(set) var pendings: [String] = []
  private(set) var images = 0

  init(output: URL, strict: Bool) {
    self.strict = strict
    pngDirectory = output.appendingPathComponent("png", isDirectory: true)
    try? FileManager.default.createDirectory(at: pngDirectory, withIntermediateDirectories: true)
  }

  func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "", viewDependent: Bool = false) {
    if condition {
      passed += 1
      return
    }
    let line = detail().isEmpty ? name : "\(name) — \(detail())"
    if viewDependent && !strict {
      pending += 1
      pendings.append(line)
      print("PENDING \(line)")
    } else {
      failed += 1
      failures.append(line)
      print("FAIL \(line)")
    }
  }

  func savedImage() { images += 1 }
}

/// An offscreen window hosting a SwiftUI view.
@MainActor final class HostedView {
  let window: NSWindow
  let host: NSView

  init<V: View>(_ view: V, size: CGSize, dark: Bool, titled: Bool = false) {
    let style: NSWindow.StyleMask = titled ? [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView] : [.borderless]
    window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let root = titled ? AnyView(view) : AnyView(view.frame(width: size.width, height: size.height))
    let hosting = NSHostingView(rootView: root)
    // The window owns the size; the hosting view must not push constraints back
    // (that loops with views that track their own width).
    hosting.sizingOptions = []
    if titled { hosting.sceneBridgingOptions = [.toolbars, .title] }
    host = hosting
    window.contentView = hosting
    window.setContentSize(size)
    window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
    window.orderFrontRegardless()
    // Split views lay out their columns over several passes; give titled windows longer.
    settle(titled ? 0.8 : 0.25)
    if titled { settle(0.4) }
  }

  /// Runs the view until layout and drawing stop changing, in 16 ms slices.
  /// `seconds` is only the upper limit: most views settle in a few slices.
  func settle(_ seconds: Double = 0.15) {
    let deadline = Date().addingTimeInterval(seconds)
    var quietSlices = 0
    repeat {
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.016))
      // Layout only: a ticking timecode or a progress spinner always needs display.
      let busy = host.needsLayout || (window.contentView?.needsLayout ?? false)
      quietSlices = busy ? 0 : quietSlices + 1
    } while quietSlices < 3 && Date() < deadline
    if ProcessInfo.processInfo.environment["UI_VERIFY_TIMING"] != nil {
      print("SETTLE \(quietSlices >= 3 ? "quiet" : "limit") \(Int((seconds - deadline.timeIntervalSinceNow) * 1000)) ms")
    }
    host.layoutSubtreeIfNeeded()
  }

  /// Renders the window frame (title bar and toolbar included for titled windows).
  func render() -> NSBitmapImageRep? {
    settle()
    let view = window.contentView?.superview ?? host
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
  }

  func close() {
    window.orderOut(nil)
    window.close()
  }
}

/// One element of the accessibility tree.
struct AXNode {
  var label: String
  var title: String
  var value: String
  var role: String
  var enabled: Bool
  var object: NSObject

  var text: String { [label, title, value].filter { !$0.isEmpty }.joined(separator: " | ") }
  var name: String { label.isEmpty ? title : label }
}

@MainActor enum Accessibility {
  /// Reads an accessibility property by its Objective-C name. KVC avoids the
  /// protocol's mix of optional and required requirements across element types.
  private static func read(_ object: NSObject, _ key: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(key)) else { return nil }
    return object.value(forKey: key)
  }

  static func nodes(in root: NSObject, limit: Int = 6000) -> [AXNode] {
    var result: [AXNode] = []
    var queue: [(NSObject, Int)] = [(root, 0)]
    var seen = Set<ObjectIdentifier>()
    while !queue.isEmpty && result.count < limit {
      let (object, depth) = queue.removeFirst()
      guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
      let value = read(object, "accessibilityValue")
      result.append(AXNode(label: read(object, "accessibilityLabel") as? String ?? "",
        title: read(object, "accessibilityTitle") as? String ?? "",
        value: (value as? String) ?? (value as? NSNumber)?.stringValue ?? "",
        role: (read(object, "accessibilityRole") as? String) ?? "",
        enabled: (read(object, "isAccessibilityEnabled") as? NSNumber)?.boolValue ?? true,
        object: object))
      guard depth < 60 else { continue }
      // Outlines and tables (the sidebar List) expose their content as rows, not children.
      for key in ["accessibilityChildren", "accessibilityRows", "accessibilityChildrenInNavigationOrder"] {
        for child in read(object, key) as? [Any] ?? [] {
          if let child = child as? NSObject { queue.append((child, depth + 1)) }
        }
      }
    }
    return result
  }

  static func press(_ node: AXNode) -> Bool {
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard node.object.responds(to: selector) else { return false }
    _ = node.object.perform(selector)
    return true
  }
}

@MainActor final class ActionLog {
  private(set) var actions: [UIAction] = []
  func append(_ action: UIAction) { actions.append(action) }
  func clear() { actions.removeAll() }
}

@MainActor enum Images {
  /// PNG encoding of a full window takes ~100 ms; it runs off the main thread on a
  /// finished, unshared bitmap. `waitForWrites` blocks until every image is on disk.
  private static let writes = DispatchGroup()
  // One encoder thread: it overlaps rendering without competing with it for every core.
  private static let encoder = DispatchQueue(label: "ui-verify.png", qos: .utility)
  static func write(_ rep: NSBitmapImageRep, to url: URL) {
    nonisolated(unsafe) let image = rep
    encoder.async(group: writes) {
      if let data = image.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
  }
  static func waitForWrites() { writes.wait() }

  /// Fraction of sampled pixels equal to the most common color, optionally within a
  /// centered region (a fraction of width and height).
  static func dominantFraction(_ rep: NSBitmapImageRep, region: Double = 1) -> Double {
    var counts: [UInt32: Int] = [:]
    var total = 0
    let insetX = Int(Double(rep.pixelsWide) * (1 - region) / 2)
    let insetY = Int(Double(rep.pixelsHigh) * (1 - region) / 2)
    let stepX = max(1, rep.pixelsWide / 64)
    let stepY = max(1, rep.pixelsHigh / 64)
    for y in stride(from: insetY, to: rep.pixelsHigh - insetY, by: stepY) {
      for x in stride(from: insetX, to: rep.pixelsWide - insetX, by: stepX) {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let key = UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8 | UInt32(color.blueComponent * 255)
        counts[key, default: 0] += 1
        total += 1
      }
    }
    guard total > 0 else { return 1 }
    return Double(counts.values.max() ?? total) / Double(total)
  }
}
