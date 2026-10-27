import AppKit
import SwiftUI

/// Small standalone host: no running app model, devices or network access.
@MainActor final class HostedView {
  let window: NSWindow
  let host: NSView

  init<V: View>(_ view: V, size: CGSize, dark: Bool) {
    window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    hosting.sizingOptions = []
    host = hosting
    window.contentView = hosting
    window.setContentSize(size)
    window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.hasShadow = false
    window.animationBehavior = .none
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    host.layoutSubtreeIfNeeded()
  }

  func render() -> NSBitmapImageRep? {
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    let view = window.contentView?.superview ?? host
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
  }

  func close() { window.orderOut(nil); window.contentView = nil; window.close() }
}

struct SonyAXNode { var text: String; var object: NSObject }

@MainActor enum Accessibility {
  static func nodes(in root: NSObject) -> [SonyAXNode] {
    var queue = [root]
    var seen: Set<ObjectIdentifier> = []
    var result: [SonyAXNode] = []
    while let object = queue.popLast(), seen.count < 2000 {
      guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
      func read(_ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
      }
      let text = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
        .compactMap { read($0) as? String }.joined(separator: " | ")
      result.append(SonyAXNode(text: text, object: object))
      for key in ["accessibilityChildren", "accessibilityRows", "accessibilityChildrenInNavigationOrder"] {
        queue += (read(key) as? [Any] ?? []).compactMap { $0 as? NSObject }
      }
    }
    return result
  }

  static func press(_ node: SonyAXNode) -> Bool {
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard node.object.responds(to: selector) else { return false }
    _ = node.object.perform(selector)
    return true
  }
}
