import AppKit

extension NSWindow {
  /// Orders a test window in without the user ever seeing it: fully transparent,
  /// click-through, no shadow or open animation, never key, and out of the window
  /// cycle. It is still on a screen, so display links, drawables and occlusion
  /// behave as for a shown window.
  func orderInvisiblyForTesting() {
    alphaValue = 0
    ignoresMouseEvents = true
    hasShadow = false
    animationBehavior = .none
    collectionBehavior = [.transient, .ignoresCycle]
    orderFrontRegardless()
  }
}
