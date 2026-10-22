import Metal
import MonitorKit

/// GPU resources an accumulator or renderer replaced, kept referenced for
/// `MonitorFeed.retiredFrames` more encodes. Command buffers created without
/// retained references may still be using them; the host only keeps frames
/// and LUTs alive. Fixed slots, so aging and retiring never allocate.
struct RetiredResources {
  static let capacity = 6
  private var resources = InlineArray<6, (any MTLResource)?>(repeating: nil)
  private var ages = InlineArray<6, Int>(repeating: 0)
  private(set) var count = 0

  /// Holds `resource` from now until `MonitorFeed.retiredFrames` calls to `age()` later.
  mutating func retire(_ resource: (any MTLResource)?) {
    guard let resource else { return }
    // A free slot, else the oldest (only reached if one encode retires more than its share).
    var slot = 0, i = 0
    while i < Self.capacity {
      if resources[i] == nil {
        slot = i
        break
      }
      if ages[i] > ages[slot] { slot = i }
      i += 1
    }
    if resources[slot] == nil { count += 1 }
    resources[slot] = resource
    ages[slot] = 0
  }

  /// Once per encode, before anything it replaces is retired.
  mutating func age() {
    guard count > 0 else { return }
    var i = 0
    while i < Self.capacity {
      if resources[i] != nil {
        ages[i] += 1
        if ages[i] >= MonitorFeed.retiredFrames {
          resources[i] = nil
          count -= 1
        }
      }
      i += 1
    }
  }

  func holds(_ resource: any MTLResource) -> Bool {
    var i = 0
    while i < Self.capacity {
      if let r = resources[i], r === resource { return true }
      i += 1
    }
    return false
  }
}
