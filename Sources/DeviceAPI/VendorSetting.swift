import CoreMedia
import Foundation

enum VendorSettingValue: Codable, Hashable, Sendable {
  case boolean(Bool), signed(Int64), unsigned(UInt64), decimal(Double), text(String), choice(String)
  func validate() throws {
    if case .decimal(let value) = self, !value.isFinite { throw PluginError.unsupported("Setting must be finite") }
  }
}

struct VendorSetting: Identifiable, Sendable {
  typealias ID = String
  struct Choice: Equatable, Sendable {
    let id: String
    let label: String
    var labelKey: String? = nil
    var localizationTable: String? = nil
    func localizedLabel(in bundle: Bundle = .main) -> String {
      VendorDisplayLocalization.resolve(key: labelKey, fallback: label, table: localizationTable, in: bundle)
    }
  }
  enum AllowedValues: Sendable {
    case unrestricted, choices([Choice]), signed(ClosedRange<Int64>), unsigned(ClosedRange<UInt64>), decimal(ClosedRange<Double>)
  }
  let id: ID
  let labelKey: String
  var value: VendorSettingValue
  let allowedValues: AllowedValues
  let mutable: Bool
  let availabilityReason: String?
  let interruptsCapture: Bool
  /// The displayed value is desired but its most recent SDK application failed.
  /// Keep the setting actionable so callers may retry or choose another value.
  var applicationError: PluginError? = nil
  var labelFallback: String? = nil
  var localizationTable: String? = nil
  var availabilityReasonKey: String? = nil
  var captureFormats: [VendorCaptureFormat]? = nil
  var interruption: Interruption? = nil

  enum Interruption: Sendable {
    case video, audio
  }

  func validate(_ value: VendorSettingValue) throws {
    try value.validate()
    guard mutable else { throw PluginError.unsupported(availabilityReason ?? "Setting is read-only") }
    if let formats = captureFormats {
      if value == VendorCaptureMode.automatic { return }
      guard let mode = VendorCaptureMode(selection: value), let format = formats.first(where: { $0.id == mode.formatID }) else {
        throw PluginError.unsupported("The requested capture format is unavailable")
      }
      guard format.supports(mode.duration) else {
        throw PluginError.unsupported("The requested frame rate is outside this format’s supported ranges")
      }
      return
    }
    let allowed: Bool
    switch (allowedValues, value) {
    case (.unrestricted, _):
      switch (self.value, value) {
      case (.boolean, .boolean), (.signed, .signed), (.unsigned, .unsigned), (.decimal, .decimal), (.text, .text), (.choice, .choice): allowed = true
      default: allowed = false
      }
    case (.choices(let choices), .choice(let id)): allowed = choices.contains { $0.id == id }
    case (.signed(let range), .signed(let number)): allowed = range.contains(number)
    case (.unsigned(let range), .unsigned(let number)): allowed = range.contains(number)
    case (.decimal(let range), .decimal(let number)): allowed = range.contains(number)
    default: allowed = false
    }
    guard allowed else { throw PluginError.unsupported("Setting value is outside the supported values") }
  }

  func localizedLabel(in bundle: Bundle = .main) -> String {
    VendorDisplayLocalization.resolve(key: labelFallback == nil ? nil : labelKey,
      fallback: labelFallback ?? labelKey, table: localizationTable, in: bundle)
  }
  func localizedAvailabilityReason(in bundle: Bundle = .main) -> String? {
    availabilityReason.map { VendorDisplayLocalization.resolve(key: availabilityReasonKey,
      fallback: $0, table: localizationTable, in: bundle) }
  }
}

/// A format and fixed duration are a single vendor preference and apply operation.
struct VendorCaptureMode: Sendable {
  static let automatic = VendorSettingValue.choice("automatic")
  let formatID: String
  let duration: CMTime

  static func value(formatID: String, duration: CMTime) -> VendorSettingValue {
    let reduced = try? Rational(duration.value, Int64(duration.timescale))
    return .choice("\(formatID):\(reduced?.numerator ?? duration.value)/\(reduced?.denominator ?? Int64(duration.timescale))")
  }

  init?(selection: VendorSettingValue) {
    guard case .choice(let raw) = selection, let separator = raw.lastIndex(of: ":"), separator != raw.startIndex,
      let ratio = Self.ratio(raw[raw.index(after: separator)...]),
      let duration = Self.duration(value: ratio.0, timescale: ratio.1) else { return nil }
    formatID = String(raw[..<separator])
    self.duration = duration
  }

  /// Convert an FPS decimal or fraction directly to its reciprocal, without a floating-point round trip.
  static func customDuration(_ input: String) -> CMTime? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)[...]
    if let (numerator, denominator) = ratio(text) {
      return duration(value: denominator, timescale: numerator)
    }
    let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count),
      parts.allSatisfy({ $0.utf8.allSatisfy(Self.isDigit) }),
      let numerator = Int64(parts.joined()) else { return nil }
    let digits = parts.count == 2 ? parts[1].count : 0
    guard digits <= 18, let denominator = Int64("1" + String(repeating: "0", count: digits)) else { return nil }
    return duration(value: denominator, timescale: numerator)
  }

  private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }

  private static func ratio(_ text: Substring) -> (Int64, Int64)? {
    let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard pieces.count == 2, pieces.allSatisfy({ $0.utf8.allSatisfy(Self.isDigit) }),
      let numerator = Int64(pieces[0]), let denominator = Int64(pieces[1]) else { return nil }
    return (numerator, denominator)
  }

  private static func duration(value: Int64, timescale: Int64) -> CMTime? {
    guard value > 0, timescale > 0, let ratio = try? Rational(value, timescale),
      let scale = Int32(exactly: ratio.denominator) else { return nil }
    return CMTime(value: ratio.numerator, timescale: scale)
  }
}

struct VendorCaptureFormat: Identifiable, Sendable {
  let id: String
  let label: String
  let rates: [VendorCaptureRate]
  let ranges: [VendorCaptureRateRange]

  var allowsCustomRate: Bool { ranges.contains { CMTimeCompare($0.shortest, $0.longest) < 0 } }

  func supports(_ duration: CMTime) -> Bool {
    duration.isNumeric && duration.epoch == 0 && CMTimeCompare(duration, .zero) > 0 &&
      (ranges.contains { $0.contains(duration) } || rates.contains { CMTimeCompare($0.duration, duration) == 0 })
  }
}

struct VendorCaptureRate: Sendable {
  let duration: CMTime
  let label: String
}

struct VendorCaptureRateRange: Sendable {
  let shortest: CMTime
  let longest: CMTime

  func contains(_ duration: CMTime) -> Bool {
    CMTimeCompare(shortest, duration) <= 0 && CMTimeCompare(duration, longest) <= 0
  }
}
