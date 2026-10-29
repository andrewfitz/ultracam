import CoreVideo
import Foundation

/// Sole authorization boundary for handing a non-native recording input to
/// VideoToolbox. VT's internal CPU/GPU implementation is opaque: this type
/// permits system conversion, and never claims a CPU conversion occurred.
struct CPUCompatibilityConverter {
  let policy: RecordingCompatibilityPolicy
  func authorizeAdmission(reason: String) throws {
    guard policy.allowCPUConversion else {
      throw SourceRecordingError.unsupportedSample(
        "Recording cannot use its GPU route: \(reason) Enable Allow CPU conversion (compatibility) for the next take to permit system conversion.")
    }
  }
  func authorize(_ source: CVPixelBuffer, reason: String) throws -> CVPixelBuffer {
    try authorizeAdmission(reason: reason)
    return source
  }
}

