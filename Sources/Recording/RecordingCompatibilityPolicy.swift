import Foundation

/// Sample once at take start. System compatibility permits VideoToolbox to
/// convert internally; it makes no claim about whether VT uses CPU or GPU.
struct RecordingCompatibilityPolicy: Codable, Equatable, Sendable {
  let allowCPUConversion: Bool
  init(allowCPUConversion: Bool = false) { self.allowCPUConversion = allowCPUConversion }
  private enum CodingKeys: String, CodingKey { case allowCPUConversion }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    allowCPUConversion = try c.decodeIfPresent(Bool.self, forKey: .allowCPUConversion) ?? false
  }
  enum Route: String, Codable, Sendable { case gpu, systemCompatibility, refused }
  func route(gpuAvailable: Bool, gpuFailed: Bool = false) -> Route {
    if gpuAvailable && !gpuFailed { return .gpu }
    return allowCPUConversion ? .systemCompatibility : .refused
  }
  func refusalMessage(format: String, stage: String = "Recording") -> String {
    "\(stage) has no usable GPU route for \(format). Enable Allow CPU conversion (compatibility) for the next take to permit system conversion."
  }
}

struct RecordingConversionCounters: Codable, Equatable, Sendable {
  var gpuUnavailable: UInt64 = 0
  var gpuFailures: UInt64 = 0
  var systemCompatibilityFrames: UInt64 = 0
  var refusedFrames: UInt64 = 0
  mutating func record(route: RecordingCompatibilityPolicy.Route, gpuAvailable: Bool, gpuFailed: Bool) {
    if !gpuAvailable { gpuUnavailable &+= 1 }
    if gpuFailed { gpuFailures &+= 1 }
    if route == .systemCompatibility { systemCompatibilityFrames &+= 1 }
    if route == .refused { refusedFrames &+= 1 }
  }
}
