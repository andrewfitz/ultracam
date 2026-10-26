/// Counts view body evaluations for the offscreen performance check
/// (`Tools/UIVerify/LivePerformanceVerify.swift`). Only UI_VERIFY builds count;
/// in the app `count` is an empty inline function.
enum UIRenderProbe {
  #if UI_VERIFY
  @MainActor private(set) static var counts: [String: Int] = [:]
  @MainActor static func count(_ name: String) { counts[name, default: 0] += 1 }
  @MainActor static func reset() { counts = [:] }
  #else
  @inline(__always) static func count(_ name: String) {}
  #endif
}
