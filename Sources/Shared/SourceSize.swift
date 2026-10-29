import Foundation

/// A validated source size and display-aspect projection. Pixel aspect is kept
/// as a rational; callers must choose fit/crop rather than stretching.
struct SourceSize: Hashable, Codable, Sendable {
  let width: Int
  let height: Int
  let pixelAspect: Rational
  let displayAspect: Rational
  init(width: Int, height: Int, pixelAspect: Rational = .one) throws {
    guard width > 0, height > 0, pixelAspect.numerator > 0 else {
      throw SourceFormatError.invalid("Invalid source size or pixel aspect")
    }
    let (aspectNumerator, numeratorOverflow) = Int64(width).multipliedReportingOverflow(by: pixelAspect.numerator)
    let (aspectDenominator, denominatorOverflow) = Int64(height).multipliedReportingOverflow(by: pixelAspect.denominator)
    guard !numeratorOverflow, !denominatorOverflow, aspectNumerator > 0, aspectDenominator > 0 else {
      throw SourceFormatError.invalid("Source display aspect overflows Int64")
    }
    guard let displayAspect = try? Rational(aspectNumerator, aspectDenominator) else {
      throw SourceFormatError.invalid("Invalid source display aspect")
    }
    self.width = width; self.height = height; self.pixelAspect = pixelAspect; self.displayAspect = displayAspect
  }
  init(_ format: SourceFormat) throws {
    try self.init(width: format.width, height: format.height, pixelAspect: format.pixelAspect)
  }
  private enum CodingKeys: String, CodingKey { case width, height, pixelAspect }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height), pixelAspect: c.decode(Rational.self, forKey: .pixelAspect))
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(width, forKey: .width); try c.encode(height, forKey: .height); try c.encode(pixelAspect, forKey: .pixelAspect)
  }
}

enum SourceScalingPolicy: String, Codable, Sendable { case fit, fill }
struct SourceScalePlan: Hashable, Codable, Sendable {
  let source: SourceSize
  let destinationWidth: Int
  let destinationHeight: Int
  let policy: SourceScalingPolicy
  let scaledWidth: Double
  let scaledHeight: Double
  let offsetX: Double
  let offsetY: Double
  init(source: SourceSize, destinationWidth: Int, destinationHeight: Int,
       policy: SourceScalingPolicy = .fit) throws {
    guard destinationWidth > 0, destinationHeight > 0 else { throw SourceFormatError.invalid("Invalid destination size") }
    self.source = source; self.destinationWidth = destinationWidth; self.destinationHeight = destinationHeight; self.policy = policy
    let sw = Double(source.width) * Double(source.pixelAspect.numerator) / Double(source.pixelAspect.denominator)
    let sh = Double(source.height)
    let sx = Double(destinationWidth) / sw
    let sy = Double(destinationHeight) / sh
    let scale = policy == .fit ? min(sx, sy) : max(sx, sy)
    scaledWidth = sw * scale; scaledHeight = sh * scale
    offsetX = (Double(destinationWidth) - scaledWidth) / 2
    offsetY = (Double(destinationHeight) - scaledHeight) / 2
  }
}

enum SourceAdmissionError: Error, Equatable, Sendable { case unsupportedSize(String), upscaleRequired(String), invalidAspect }
struct SourceSizeProjection: Sendable {
  let source: SourceSize
  let displayAspect: Rational
  let destination: (width: Int, height: Int)?
}

struct SourceSizeAdmission: Sendable {
  static func snapshot(_ format: SourceFormat, destination: (width: Int, height: Int)? = nil,
                        allowUpscale: Bool = false) throws -> SourceSizeProjection {
    let size = try validate(format, destination: destination, allowUpscale: allowUpscale)
    return SourceSizeProjection(source: size, displayAspect: size.displayAspect, destination: destination)
  }

  static func validate(_ format: SourceFormat, destination: (width: Int, height: Int)? = nil,
                       allowUpscale: Bool = false) throws -> SourceSize {
    let size = try SourceSize(format)
    guard size.pixelAspect.denominator > 0 else { throw SourceAdmissionError.invalidAspect }
    if let destination {
      guard destination.width > 0, destination.height > 0 else { throw SourceAdmissionError.unsupportedSize("Destination must be positive") }
      let sw = Double(size.width) * Double(size.pixelAspect.numerator) / Double(size.pixelAspect.denominator)
      if !allowUpscale && (Double(destination.width) > sw || Double(destination.height) > Double(size.height)) {
        throw SourceAdmissionError.upscaleRequired("Source is smaller than destination")
      }
    }
    return size
  }
}
