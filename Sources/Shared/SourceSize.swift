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
    let aspectNumerator = Int128(width) * Int128(pixelAspect.numerator)
    let aspectDenominator = Int128(height) * Int128(pixelAspect.denominator)
    // The products can overflow Int64 even when their reduced ratio fits.
    var divisor = aspectNumerator
    var remainder = aspectDenominator
    while remainder != 0 { (divisor, remainder) = (remainder, divisor % remainder) }
    guard let numerator = Int64(exactly: aspectNumerator / divisor),
      let denominator = Int64(exactly: aspectDenominator / divisor) else {
      throw SourceFormatError.invalid("Source display aspect overflows Int64")
    }
    self.width = width; self.height = height; self.pixelAspect = pixelAspect
    displayAspect = try Rational(numerator, denominator)
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
       policy: SourceScalingPolicy = .fit, allowUpscale: Bool = false) throws {
    guard destinationWidth > 0, destinationHeight > 0 else { throw SourceFormatError.invalid("Invalid destination size") }
    self.source = source; self.destinationWidth = destinationWidth; self.destinationHeight = destinationHeight; self.policy = policy
    let sw = Double(source.width) * Double(source.pixelAspect.numerator) / Double(source.pixelAspect.denominator)
    let sh = Double(source.height)
    let sx = Double(destinationWidth) / sw
    let sy = Double(destinationHeight) / sh
    let scale = policy == .fit ? min(sx, sy, allowUpscale ? .infinity : 1) : max(sx, sy)
    scaledWidth = sw * scale; scaledHeight = sh * scale
    offsetX = (Double(destinationWidth) - scaledWidth) / 2
    offsetY = (Double(destinationHeight) - scaledHeight) / 2
  }
}

enum SourceAdmissionError: Error, Equatable, Sendable { case unsupportedSize(String), invalidAspect }
struct SourceSizeProjection: Sendable {
  let source: SourceSize
  let displayAspect: Rational
  let destination: (width: Int, height: Int)?
  let fit: SourceScalePlan?
}

struct SourceSizeAdmission: Sendable {
  static func snapshot(_ format: SourceFormat, destination: (width: Int, height: Int)? = nil,
                        allowUpscale: Bool = false) throws -> SourceSizeProjection {
    let size = try SourceSize(format)
    guard size.pixelAspect.denominator > 0 else { throw SourceAdmissionError.invalidAspect }
    let fit = try destination.map { canvas in
      guard canvas.width > 0, canvas.height > 0 else {
        throw SourceAdmissionError.unsupportedSize("Destination must be positive")
      }
      return try SourceScalePlan(source: size, destinationWidth: canvas.width,
        destinationHeight: canvas.height, allowUpscale: allowUpscale)
    }
    return SourceSizeProjection(source: size, displayAspect: size.displayAspect, destination: destination, fit: fit)
  }

  static func validate(_ format: SourceFormat, destination: (width: Int, height: Int)? = nil,
                       allowUpscale: Bool = false) throws -> SourceSize {
    try snapshot(format, destination: destination, allowUpscale: allowUpscale).source
  }
}
