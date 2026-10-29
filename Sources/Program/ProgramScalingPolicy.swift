import Foundation

enum ProgramScalingError: Error, Equatable {
  case invalidDimensions
  case arithmeticOverflow
}

/// Integer geometry for one aspect-preserving Program conversion.
struct ProgramScalingPlan: Equatable, Sendable {
  let sourceWidth: Int
  let sourceHeight: Int
  let targetWidth: Int
  let targetHeight: Int
  let scaledWidth: Int
  let scaledHeight: Int
  /// Centered offset in the target canvas (positive means a border).
  let offsetX: Int
  let offsetY: Int
  /// Centered crop in the scaled source (zero for `.fit`).
  let cropLeft: Int
  let cropTop: Int
  let cropWidth: Int
  let cropHeight: Int

  var hasPillarboxOrLetterbox: Bool { scaledWidth < targetWidth || scaledHeight < targetHeight }
  var hasCrop: Bool { cropLeft != 0 || cropTop != 0 || cropWidth != scaledWidth || cropHeight != scaledHeight }
}

enum ProgramScalingPolicy {
  /// Produces geometry without floating point, making boundary behavior deterministic.
  static func plan(sourceWidth: Int, sourceHeight: Int, targetWidth: Int, targetHeight: Int,
                   mode: ProgramScalingMode = .fit, pixelAspect: Rational = .one) throws -> ProgramScalingPlan {
    guard sourceWidth > 0, sourceHeight > 0, targetWidth > 0, targetHeight > 0 else {
      throw ProgramScalingError.invalidDimensions
    }
    guard pixelAspect.numerator > 0, pixelAspect.denominator > 0 else {
      throw ProgramScalingError.invalidDimensions
    }
    let (sw, widthOverflow) = Int64(sourceWidth).multipliedReportingOverflow(by: pixelAspect.numerator)
    let (sh, heightOverflow) = Int64(sourceHeight).multipliedReportingOverflow(by: pixelAspect.denominator)
    guard !widthOverflow, !heightOverflow else { throw ProgramScalingError.arithmeticOverflow }
    let tw = Int64(targetWidth), th = Int64(targetHeight)
    let sourceIsWider = try compare(sw, sh, tw, th) >= 0
    // Fit's limiting dimension is the narrower axis; crop's is the wider axis.
    let limitWidth: Bool = mode == .fit ? sourceIsWider : !sourceIsWider
    let scaledWidth: Int64
    let scaledHeight: Int64
    if limitWidth {
      scaledWidth = tw
      scaledHeight = try scaledProduct(sh, tw, sw, roundingUp: mode == .crop)
    } else {
      scaledHeight = th
      scaledWidth = try scaledProduct(sw, th, sh, roundingUp: mode == .crop)
    }
    guard scaledWidth > 0, scaledHeight > 0,
          scaledWidth <= Int64(Int.max), scaledHeight <= Int64(Int.max) else {
      throw ProgramScalingError.arithmeticOverflow
    }
    let w = Int(scaledWidth), h = Int(scaledHeight)
    switch mode {
    case .fit:
      return ProgramScalingPlan(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
        targetWidth: targetWidth, targetHeight: targetHeight, scaledWidth: w, scaledHeight: h,
        offsetX: (targetWidth - w) / 2, offsetY: (targetHeight - h) / 2,
        cropLeft: 0, cropTop: 0, cropWidth: w, cropHeight: h)
    case .crop:
      return ProgramScalingPlan(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
        targetWidth: targetWidth, targetHeight: targetHeight, scaledWidth: w, scaledHeight: h,
        offsetX: 0, offsetY: 0, cropLeft: max(0, (w - targetWidth) / 2),
        cropTop: max(0, (h - targetHeight) / 2), cropWidth: targetWidth, cropHeight: targetHeight)
    }
  }

  private static func compare(_ a: Int64, _ b: Int64, _ c: Int64, _ d: Int64) throws -> Int {
    let (left, leftOverflow) = a.multipliedReportingOverflow(by: d)
    let (right, rightOverflow) = c.multipliedReportingOverflow(by: b)
    guard !leftOverflow, !rightOverflow else { throw ProgramScalingError.arithmeticOverflow }
    return left == right ? 0 : (left > right ? 1 : -1)
  }

  private static func scaledProduct(_ value: Int64, _ numerator: Int64, _ denominator: Int64,
                                    roundingUp: Bool) throws -> Int64 {
    let (product, overflow) = value.multipliedReportingOverflow(by: numerator)
    guard !overflow else { throw ProgramScalingError.arithmeticOverflow }
    if roundingUp {
      let (adjusted, addOverflow) = product.addingReportingOverflow(denominator - 1)
      guard !addOverflow else { throw ProgramScalingError.arithmeticOverflow }
      return adjusted / denominator
    }
    return product / denominator
  }
}
