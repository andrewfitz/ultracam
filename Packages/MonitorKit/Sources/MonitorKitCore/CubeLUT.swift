import Foundation

/// A parsed .cube LUT: an Adobe Cube 1.0 3D or 1D table, or a DaVinci Resolve
/// shaper LUT (a 1D table, then a 3D table, with `LUT_1D_INPUT_RANGE` /
/// `LUT_3D_INPUT_RANGE`). The 1D table applies per channel before the 3D one.
public struct CubeLUT: Sendable, Equatable {
  // Cube 1.0 limits every numeric token to the range supported by a 32-bit
  // float implementation. Keep a stricter bound than `Float.isFinite` so a
  // value near Float.greatestFiniteMagnitude cannot overflow interpolation
  // or color conversion later in the GPU pipeline.
  private static let maximumNumber = Float(1e37)

  public let title: String
  /// Lattice points per axis of the 3D table; 0 for a 1D-only LUT.
  public let dimension: Int
  /// Input domain of the 3D table.
  public let domainMin: SIMD3<Float>
  public let domainMax: SIMD3<Float>
  // .cube ordering: red varies fastest, then green, then blue.
  public let rgba: [Float]
  /// The 1D table (shaper), RGB triplets in order; empty when there is none.
  public let shaper: [Float]
  /// Input domain of the 1D table, per channel.
  public let shaperDomainMin: SIMD3<Float>
  public let shaperDomainMax: SIMD3<Float>

  /// Entries of the 1D table.
  public var shaperSize: Int { shaper.count / 3 }
  public var hasCube: Bool { dimension > 0 }
  public static let maximumShaperSize = 65536

  public enum ParseError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
      switch self { case .invalid(let reason): return "Invalid LUT: \(reason)" }
    }
  }

  public init(text: String, fallbackTitle: String = "Untitled LUT") throws {
    guard text.utf8.count <= 32 * 1024 * 1024 else {
      throw ParseError.invalid("file exceeds 32 MB")
    }
    // A number of LUT exporters write a UTF-8 byte-order mark even though
    // the .cube format is otherwise plain UTF-8.  `String` preserves that
    // marker as U+FEFF, which would otherwise make the first header key
    // unknown (for example, `\u{FEFF}LUT_3D_SIZE`).  It is metadata rather
    // than part of the title or first directive, so remove it before parsing.
    var source = text
    if source.first == "\u{FEFF}" { source.removeFirst() }
    // Callers commonly pass a filename-derived fallback, but a malformed or
    // extensionless URL can still produce an empty string. Keep the parsed
    // model displayable even when an explicit TITLE is empty.
    var title = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Untitled LUT" : fallbackTitle
    var size3: Int?, size1: Int?
    var domain: (SIMD3<Float>, SIMD3<Float>)?
    var range3: (Float, Float)?, range1: (Float, Float)?
    var domainMinSeen = false, domainMaxSeen = false
    var low = SIMD3<Float>(repeating: 0)
    var high = SIMD3<Float>(repeating: 1)
    var shaper: [Float] = []
    var values: [Float] = []
    var headers: Set<String> = []
    var dataStarted = false
    for (index, raw) in source.components(separatedBy: .newlines).enumerated() {
      guard raw.utf8.count <= 250 else {
        throw ParseError.invalid("line \(index + 1): line exceeds 250 bytes")
      }
      // The specification defines comments as lines beginning with `#`, but
      // inline comments are common in exported files. Strip an inline marker
      // only when it is outside a quoted TITLE so a title such as
      // `TITLE "Look #1"` remains intact.
      var quoted = false
      var commentStart: String.Index?
      for cursor in raw.indices {
        let character = raw[cursor]
        if character == "\"" { quoted.toggle() }
        else if character == "#" && !quoted {
          commentStart = cursor
          break
        }
      }
      let uncommented = commentStart.map { String(raw[..<$0]) } ?? raw
      let line = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty { continue }
      let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard let key = parts.first else { continue }
      func invalid(_ reason: String) -> ParseError {
        .invalid("line \(index + 1): \(reason)")
      }
      func numbers(_ count: Int) throws -> [Float] {
        guard parts.count == count + 1 else { throw invalid("\(key) requires \(count) numbers") }
        let n = parts.dropFirst().compactMap(Float.init)
        guard n.count == count, n.allSatisfy({ $0.isFinite && abs($0) <= Self.maximumNumber }) else {
          throw invalid("\(key) numbers must be finite and within ±1e37")
        }
        return n
      }
      if key == "TITLE" {
        guard !dataStarted, headers.insert(key).inserted else {
          throw invalid("duplicate or misplaced TITLE")
        }
        let payload = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard payload.count >= 2, payload.first == "\"", payload.last == "\"" else {
          throw invalid("TITLE must be enclosed in quotes")
        }
        let parsed = String(payload.dropFirst().dropLast())
        guard !parsed.contains("\"") else {
          throw invalid("TITLE contains an unescaped quote")
        }
        // Preserve the filename fallback for an explicitly empty TITLE so the
        // UI never renders a blank LUT name.
        if !parsed.isEmpty { title = parsed }
        continue
      }
      if ["LUT_3D_SIZE", "LUT_1D_SIZE", "DOMAIN_MIN", "DOMAIN_MAX", "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE"]
        .contains(key)
      {
        guard !dataStarted, headers.insert(key).inserted else {
          throw invalid("duplicate or misplaced \(key)")
        }
        switch key {
        case "LUT_3D_SIZE":
          guard parts.count == 2, let size = Int(parts[1]), (2...65).contains(size) else {
            throw invalid("3D size must be between 2 and 65")
          }
          size3 = size
        case "LUT_1D_SIZE":
          guard parts.count == 2, let size = Int(parts[1]), (2...Self.maximumShaperSize).contains(size) else {
            throw invalid("1D size must be between 2 and \(Self.maximumShaperSize)")
          }
          size1 = size
        case "DOMAIN_MIN":
          let n = try numbers(3)
          low = SIMD3(n[0], n[1], n[2])
          domainMinSeen = true
        case "DOMAIN_MAX":
          let n = try numbers(3)
          high = SIMD3(n[0], n[1], n[2])
          domainMaxSeen = true
        case "LUT_3D_INPUT_RANGE":
          let n = try numbers(2)
          range3 = (n[0], n[1])
        default:
          let n = try numbers(2)
          range1 = (n[0], n[1])
        }
        continue
      }
      guard size1 != nil || size3 != nil else { throw invalid("expected LUT_3D_SIZE or LUT_1D_SIZE before data") }
      dataStarted = true
      guard parts.count == 3 else { throw invalid("expected an RGB triplet") }
      let triplet = parts.compactMap(Float.init)
      guard triplet.count == 3, triplet.allSatisfy({ $0.isFinite && abs($0) <= Self.maximumNumber }) else {
        throw invalid("expected three finite RGB numbers within ±1e37")
      }
      // A shaper LUT lists its 1D table first, then the 3D table.
      if let n1 = size1, shaper.count < n1 * 3 {
        shaper.append(contentsOf: triplet)
      } else if let n3 = size3, values.count < n3 * n3 * n3 * 4 {
        values.append(contentsOf: triplet)
        values.append(1)
      } else {
        throw invalid("too many entries")
      }
    }
    let n3 = size3 ?? 0
    guard size1 != nil || size3 != nil, shaper.count == (size1 ?? 0) * 3, values.count == n3 * n3 * n3 * 4 else {
      throw ParseError.invalid("missing size or incomplete table")
    }
    if domainMinSeen || domainMaxSeen { domain = (low, high) }
    // DOMAIN_MIN/MAX belong to the table of an Adobe file; with both tables
    // (Resolve's layout) the ranges are given by the *_INPUT_RANGE keywords.
    var cubeDomain = (SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
    var shaperDomain = cubeDomain
    if let r = range3 { cubeDomain = (SIMD3(repeating: r.0), SIMD3(repeating: r.1)) }
    if let r = range1 { shaperDomain = (SIMD3(repeating: r.0), SIMD3(repeating: r.1)) }
    if let d = domain {
      if size3 != nil {
        guard range3 == nil else { throw ParseError.invalid("both DOMAIN and LUT_3D_INPUT_RANGE are given") }
        cubeDomain = d
      } else {
        guard range1 == nil else { throw ParseError.invalid("both DOMAIN and LUT_1D_INPUT_RANGE are given") }
        shaperDomain = d
      }
    }
    for (name, d) in [("3D", cubeDomain), ("1D", shaperDomain)] {
      guard d.1.x > d.0.x, d.1.y > d.0.y, d.1.z > d.0.z else {
        throw ParseError.invalid("\(name) domain maximum must exceed its minimum")
      }
      let span = d.1 - d.0
      let inverse = SIMD3<Float>(repeating: 1) / span
      guard [span.x, span.y, span.z, inverse.x, inverse.y, inverse.z].allSatisfy(\.isFinite) else {
        throw ParseError.invalid("domain span cannot be represented safely in floating-point processing")
      }
    }
    self.title = title
    self.dimension = size3 ?? 0
    self.domainMin = cubeDomain.0
    self.domainMax = cubeDomain.1
    self.rgba = values
    self.shaper = shaper
    self.shaperDomainMin = shaperDomain.0
    self.shaperDomainMax = shaperDomain.1
  }

  /// The 3D lattice as RGBA32 float, red fastest: the first n slices of the GPU
  /// texture (`MonitorLUT` stores the shaper in the slices after them).
  public var data: Data { rgba.withUnsafeBytes { Data($0) } }
}
