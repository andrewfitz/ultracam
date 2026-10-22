#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// The display's EDR headroom: peak over SDR white, 1 when the display shows no
/// EDR. It changes at any time (brightness, ambient light, other HDR content), so
/// a view reads it every frame and on screen changes; it reaches the picture as a
/// uniform (`MonitorOutputColor.headroom`) and rebuilds nothing.
public enum MonitorDisplayHeadroom {
  #if canImport(AppKit)
    /// `maximumExtendedDynamicRangeColorComponentValue`: what the screen shows now.
    /// It reads above 1 only once a window on it asks for EDR content.
    @MainActor public static func current(for screen: NSScreen?) -> Double {
      sanitized(Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1))
    }

    /// `maximumPotentialExtendedDynamicRangeColorComponentValue`: the most it can show.
    @MainActor public static func potential(for screen: NSScreen?) -> Double {
      sanitized(Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1))
    }
  #elseif canImport(UIKit)
    /// `UIScreen.currentEDRHeadroom`.
    @MainActor public static func current(for screen: UIScreen?) -> Double {
      sanitized(Double(screen?.currentEDRHeadroom ?? 1))
    }

    /// `UIScreen.potentialEDRHeadroom`.
    @MainActor public static func potential(for screen: UIScreen?) -> Double {
      sanitized(Double(screen?.potentialEDRHeadroom ?? 1))
    }
  #endif

  /// At least 1, finite; `MonitorOutputColor.normalized()` caps it at 64.
  public static func sanitized(_ value: Double) -> Double { value.isFinite ? max(1, value) : 1 }
}
