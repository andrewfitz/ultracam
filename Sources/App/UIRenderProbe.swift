import Synchronization

/// Counts view body evaluations, and records values render-pass closures see, for the
/// offscreen performance check (`Tools/UIVerify/LivePerformanceVerify.swift`). Only UI_VERIFY
/// builds count; in the app `count` and `sample` are empty inline functions.
enum UIRenderProbe {
  #if UI_VERIFY
  @MainActor private(set) static var counts: [String: Int] = [:]
  @MainActor static func count(_ name: String) { counts[name, default: 0] += 1 }
  @MainActor static func reset() { counts = [:]; samples.withLock { $0 = [:] } }
  /// Values a render-pass closure sees (`visualEffect` runs off the main actor's view updates).
  nonisolated static let samples = Mutex<[String: [Double]]>([:])
  nonisolated static func sample(_ name: String, _ value: Double) { samples.withLock { $0[name, default: []].append(value) } }
  #else
  @inline(__always) static func count(_ name: String) {}
  @inline(__always) static func sample(_ name: String, _ value: Double) {}
  #endif
}
