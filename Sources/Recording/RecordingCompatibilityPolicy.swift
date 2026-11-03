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
