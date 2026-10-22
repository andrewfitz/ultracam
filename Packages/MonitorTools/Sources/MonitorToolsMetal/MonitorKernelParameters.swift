import Foundation

/// Mirrors Params in MonitorTools.metal.txt: ten aligned 16-byte rows.
/// Source mapping, scope sampling and peaking thresholds have distinct fields.
struct KernelParameters {
  var width: UInt32 = 0, height: UInt32 = 0, planes: UInt32 = 0, format: UInt32 = 0
  var outWidth: UInt32 = 0, outHeight: UInt32 = 0, flags: UInt32 = 0, scopeMode: UInt32 = 0
  var threshold: Float = 95, widthIRE: Float = 5, opacity: Float = 0.65, focusThreshold: Float = 0.1
  var noise: Float = 0.02, focusOpacity: Float = 0.85, gain: Float = 1, sourceLogRescaled: Float = 0
  var scopeWidth: UInt32 = 768, scopeHeight: UInt32 = 256, scopeSamplingStride: UInt32 = 1, scopeSamplingPhase: UInt32 = 0
  var referenceOffsetStops: Float = 0, originX: Float = 0, originY: Float = 0, reserved2: Float = 0
  var coefficients = SIMD4<Float>(0.2126, 0.7152, 0.0722, 0)
  var mapping = SIMD4<Float>(1, 1, 0, 0)
  var peak = SIMD4<Float>(1, 0, 0, 1)
  /// Picture region (x, y, width, height) drawn across the whole target.
  var aperture = SIMD4<Float>(0, 0, 0, 0)
}

enum MonitorKernelFlag {
  static let scopeGraticule: UInt32 = 1 << 0
  static let zebra: UInt32 = 1 << 0
  static let zebraBand: UInt32 = 1 << 1
  static let focus: UInt32 = 1 << 2
  static let logC3: UInt32 = 1 << 3
  static let logC4: UInt32 = 1 << 4
  static let sonyARRIReference: UInt32 = 1 << 7
  static let sonySGamut3: UInt32 = 1 << 8
  static let elZone: UInt32 = 1 << 10
  static let sonySLog3: UInt32 = 1 << 9
}
