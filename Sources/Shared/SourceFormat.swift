import CoreMedia
import CryptoKit
import Foundation

enum SourceFormatError: Error { case invalid(String) }
struct Rational: Hashable, Codable, Sendable {
  let numerator: Int64
  let denominator: Int64
  static let one = try! Rational(1, 1)
  init(_ numerator: Int64, _ denominator: Int64) throws {
    guard denominator != 0, numerator != .min, denominator != .min else { throw SourceFormatError.invalid("Invalid rational") }
    var a = abs(numerator), b = abs(denominator)
    while b != 0 { (a, b) = (b, a % b) }
    let divisor = max(a, 1)
    self.numerator = numerator / divisor * (denominator < 0 ? -1 : 1)
    self.denominator = abs(denominator) / divisor
  }
  init(numerator: Int64, denominator: Int64) throws { try self.init(numerator, denominator) }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(c.decode(Int64.self, forKey: .numerator), c.decode(Int64.self, forKey: .denominator))
  }
}

// Explicit normalized numeric CMTime encoding; no system-type conformances.
private struct ContractTime: Hashable, Codable, Sendable {
  let value: Rational
  let epoch: Int64
  init(_ time: CMTime) throws {
    guard time.isNumeric, time.timescale > 0 else { throw SourceFormatError.invalid("Time must be numeric") }
    value = try Rational(time.value, Int64(time.timescale)); epoch = time.epoch
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    value = try c.decode(Rational.self, forKey: .value)
    epoch = try c.decode(Int64.self, forKey: .epoch)
    guard value.denominator <= Int32.max else { throw SourceFormatError.invalid("Time scale overflow") }
  }
  var time: CMTime { CMTime(value: value.numerator, timescale: Int32(value.denominator), flags: .valid, epoch: epoch) }
}
enum FrameRate: Hashable, Codable, Sendable {
  case constant(CMTime)
  case variable(nominal: CMTime, shortest: CMTime, longest: CMTime)
  var nominal: CMTime { switch self { case .constant(let t), .variable(let t, _, _): t } }
  var isVariable: Bool { if case .variable = self { true } else { false } }
  func validate() throws {
    let times: [CMTime]
    switch self { case .constant(let t): times = [t]; case .variable(let n, let s, let l): times = [s, n, l] }
    for t in times {
      _ = try ContractTime(t)
      guard t.epoch == 0, CMTimeCompare(t, .zero) > 0 else { throw SourceFormatError.invalid("Invalid frame duration") }
    }
    if times.count == 3, !(CMTimeCompare(times[0], times[1]) <= 0 && CMTimeCompare(times[1], times[2]) <= 0) { throw SourceFormatError.invalid("Unordered frame durations") }
  }
  private enum Keys: String, CodingKey { case kind, nominal, shortest, longest }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    let n = try c.decode(ContractTime.self, forKey: .nominal).time
    switch try c.decode(String.self, forKey: .kind) {
    case "constant": self = .constant(n)
    case "variable": self = .variable(nominal: n, shortest: try c.decode(ContractTime.self, forKey: .shortest).time, longest: try c.decode(ContractTime.self, forKey: .longest).time)
    default: throw SourceFormatError.invalid("Unknown rate kind")
    }
    try validate()
  }
  func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(isVariable ? "variable" : "constant", forKey: .kind)
    try c.encode(ContractTime(nominal), forKey: .nominal)
    if case .variable(_, let s, let l) = self { try c.encode(ContractTime(s), forKey: .shortest); try c.encode(ContractTime(l), forKey: .longest) }
  }
  private var times: [ContractTime?] {
    switch self { case .constant(let t): [try? ContractTime(t)]; case .variable(let n, let s, let l): [try? ContractTime(n), try? ContractTime(s), try? ContractTime(l)] }
  }
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.times == rhs.times }
  func hash(into hasher: inout Hasher) { hasher.combine(times) }
}
enum Scan: String, Codable, Sendable { case progressive, interlaced, psf }
enum VideoClockDomain: String, Codable, Sendable { case hostTime, deviceClock }
enum AudioClockDomain: String, Codable, Sendable { case pairedWithFrames, hostTime, deviceClock }
struct Colorimetry: Hashable, Codable, Sendable {
  enum Primaries: String, Codable, Sendable {
    case unspecified, rec709, rec2020, p3D65
    case canonCinemaGamut, vGamut, blackmagicWideGamutGen5, redWideGamutRGB
    case sGamut3, sGamut3Cine, arriWideGamut3, arriWideGamut4
  }
  enum Transfer: String, Codable, Sendable {
    case unspecified, rec709, sRGB, linear, pq, hlg, sLog3
    case canonLog, canonLog2, canonLog3, vLog, blackmagicFilmGen5, redLog3G10
    case arriLogC3, arriLogC4
  }
  enum Matrix: String, Codable, Sendable { case unspecified, identity, rec601, rec709, rec2020 }
  enum Range: String, Codable, Sendable { case video, full }
  enum ChromaSiting: String, Codable, Sendable { case unspecified, left, center, topLeft, top, bottomLeft, bottom }
  let primaries: Primaries
  let transfer: Transfer
  let matrix: Matrix
  let range: Range
  let horizontalChromaSiting: ChromaSiting
  let verticalChromaSiting: ChromaSiting
  static let rec709Video = Self(primaries: .rec709, transfer: .rec709, matrix: .rec709, range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
}
struct PixelFormatID: RawRepresentable, Hashable, Codable, Sendable {
  let rawValue: UInt32
  init(rawValue: UInt32) { self.rawValue = rawValue }
  static let v210 = Self(rawValue: 0x76323130)
  static let twoVuy = Self(rawValue: 0x32767579)
  static let yuvs = Self(rawValue: 0x79757673)
  static let video420 = Self(rawValue: 0x34323076)
  static let full420 = Self(rawValue: 0x34323066)
  static let bgra8 = Self(rawValue: 0x42475241)
  static let rgba8 = Self(rawValue: 0x52474241)
  static let r210 = Self(rawValue: 0x72323130)
  static let r12L = Self(rawValue: 0x5231324c)
  static let uyva = Self(rawValue: 0x55595641)
  static let p216 = Self(rawValue: 0x50323136)
  static let i420 = Self(rawValue: 0x49343230)
  static let pa16 = Self(rawValue: 0x50413136)
}
enum PixelFormatTable {
  enum ByteOrder: String, Sendable { case littleEndian, bigEndian }
  struct Plane: Hashable, Sendable {
    let metalFormat: String
    let pixelsPerGroup: Int
    let bytesPerGroup: Int
    // Packed entries describe chroma sampling inside groups, not a narrower
    // allocation. Their sole physical plane retains the full image extent.
    // Planar entries describe each physical plane's subsampling instead.
    let horizontalSubsampling: Int
    let verticalSubsampling: Int
    var packedBitsPerPixel: Int? = nil
  }
  struct Entry: Hashable, Sendable {
    let id: PixelFormatID
    let revision: UInt32
    let bitDepth: Int
    let containerShift: Int
    let packed: Bool
    let rowAlignment: Int
    let defaultRange: Colorimetry.Range
    let inputKernel: String
    let routes: Set<String>
    let gpuRoutes: Set<String>
    let byteOrder: ByteOrder
    let planes: [Plane]
    var captureQualified: Bool = false
  }
  // Metadata registration is distinct from capture admission. Only entries
  // with all six proven GPU routes authorize capture; see B5_PIXEL_ROUTE_PROOFS.md.
  private static func partial(_ id: PixelFormatID, bits: Int, packed: Bool, alignment: Int = 1,
    range: Colorimetry.Range = .video, kernel: String, routes: Set<String>, captureQualified: Bool = false,
    order: ByteOrder = .littleEndian, planes: [Plane]) -> Entry {
    Entry(id: id, revision: 1, bitDepth: bits, containerShift: 0, packed: packed,
      rowAlignment: alignment, defaultRange: range, inputKernel: kernel,
      routes: routes, gpuRoutes: routes, byteOrder: order, planes: planes, captureQualified: captureQualified)
  }
  private static let packed8 = [Plane(metalFormat: "rgba8Uint", pixelsPerGroup: 2, bytesPerGroup: 4, horizontalSubsampling: 2, verticalSubsampling: 1)]
  private static let rgb32 = [Plane(metalFormat: "rgba8Uint", pixelsPerGroup: 1, bytesPerGroup: 4, horizontalSubsampling: 1, verticalSubsampling: 1)]
  private static func planar(_ bytes: Int, vertical: Int) -> [Plane] {
    [Plane(metalFormat: bytes == 1 ? "r8Unorm" : "r16Unorm", pixelsPerGroup: 1, bytesPerGroup: bytes, horizontalSubsampling: 1, verticalSubsampling: 1),
     Plane(metalFormat: bytes == 1 ? "rg8Unorm" : "rg16Unorm", pixelsPerGroup: 1, bytesPerGroup: bytes * 2, horizontalSubsampling: 2, verticalSubsampling: vertical)]
  }
  static let entries: [Entry] = [
    Entry(id: .v210, revision: 1, bitDepth: 10, containerShift: 0, packed: true, rowAlignment: 128, defaultRange: .video, inputKernel: "fullPacked422", routes: ["input", "lut", "program", "recording", "monitor", "extension"], gpuRoutes: ["input", "lut", "program", "recording", "monitor", "extension"], byteOrder: .littleEndian, planes: [Plane(metalFormat: "rgba32Uint", pixelsPerGroup: 6, bytesPerGroup: 16, horizontalSubsampling: 2, verticalSubsampling: 1)], captureQualified: true),
    partial(.twoVuy, bits: 8, packed: true, kernel: "decodePacked422", routes: ["input", "lut", "program", "recording", "monitor", "extension"], captureQualified: true, planes: packed8),
    partial(.yuvs, bits: 8, packed: true, kernel: "decodePacked422", routes: ["input", "lut", "program", "recording", "monitor", "extension"], captureQualified: true, planes: packed8),
    partial(.video420, bits: 8, packed: false, kernel: "decodePlanar", routes: ["input", "lut", "program", "recording", "monitor", "extension"], captureQualified: true, planes: planar(1, vertical: 2)),
    partial(.full420, bits: 8, packed: false, range: .full, kernel: "decodePlanar", routes: ["input", "lut", "program", "recording", "monitor", "extension"], captureQualified: true, planes: planar(1, vertical: 2)),
    partial(.bgra8, bits: 8, packed: true, range: .full, kernel: "decodeRGB", routes: ["input", "lut", "program", "recording", "monitor", "extension"], captureQualified: true, planes: rgb32),
    partial(.rgba8, bits: 8, packed: true, range: .full, kernel: "decodeRGB", routes: ["input"], planes: rgb32),
    partial(.r210, bits: 10, packed: true, kernel: "decodeRGB", routes: ["input", "lut", "program", "recording", "monitor", "extension"], captureQualified: true, order: .bigEndian, planes: rgb32),
    partial(.r12L, bits: 12, packed: true, range: .full, kernel: "decodeRGB", routes: ["input", "lut", "program", "recording", "monitor", "extension"], captureQualified: true, planes: [Plane(metalFormat: "r8Uint", pixelsPerGroup: 2, bytesPerGroup: 9, horizontalSubsampling: 1, verticalSubsampling: 1, packedBitsPerPixel: 36)]),
    partial(.uyva, bits: 8, packed: false, kernel: "decodePacked422", routes: ["input", "lut", "program", "recording", "monitor", "extension"], captureQualified: true, planes: [Plane(metalFormat: "rgba8Uint", pixelsPerGroup: 2, bytesPerGroup: 4, horizontalSubsampling: 1, verticalSubsampling: 1), Plane(metalFormat: "r8Unorm", pixelsPerGroup: 1, bytesPerGroup: 1, horizontalSubsampling: 1, verticalSubsampling: 1)]),
    partial(.p216, bits: 16, packed: false, alignment: 2, kernel: "decodePlanar", routes: ["input", "lut", "program", "recording", "monitor", "extension"], captureQualified: true, planes: planar(2, vertical: 1)),
    partial(.i420, bits: 8, packed: false, kernel: "decodeNDIPlanar", routes: ["input", "lut", "program", "recording", "monitor", "extension"], captureQualified: true, planes: [Plane(metalFormat: "r8Unorm", pixelsPerGroup: 1, bytesPerGroup: 1, horizontalSubsampling: 1, verticalSubsampling: 1), Plane(metalFormat: "r8Unorm", pixelsPerGroup: 1, bytesPerGroup: 1, horizontalSubsampling: 2, verticalSubsampling: 2), Plane(metalFormat: "r8Unorm", pixelsPerGroup: 1, bytesPerGroup: 1, horizontalSubsampling: 2, verticalSubsampling: 2)]),
    partial(.pa16, bits: 16, packed: false, alignment: 2, kernel: "decodeNDIPlanar", routes: ["input", "lut", "program", "recording", "monitor", "extension"], captureQualified: true, planes: planar(2, vertical: 1) + [Plane(metalFormat: "r16Unorm", pixelsPerGroup: 1, bytesPerGroup: 2, horizontalSubsampling: 1, verticalSubsampling: 1)])
  ]
  static func entry(for id: PixelFormatID) -> Entry? { entries.first { $0.id == id } }
}

// v1 canonical encoding: sorted UTF-8 JSON keys, fixed enum string IDs,
// normalized rationals/times, versioned table revision; never Swift Hasher.
private func contractSignature<T: Encodable>(_ value: T, revision: UInt32 = 0) -> String {
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  let bytes = try! encoder.encode(value)
  return SHA256.hash(data: Data("ultracam-format-v1:pixel-revision=\(revision):".utf8) + bytes).map { String(format: "%02x", $0) }.joined()
}
struct SourceFormat: Hashable, Codable, Sendable {
  private enum CodingKeys: String, CodingKey { case width, height, pixelAspect, scan, pixel, colour, rate, clock }
  private var storedSignature = ""
  let width: Int, height: Int
  let pixelAspect: Rational
  let scan: Scan
  let pixel: PixelFormatID
  let colour: Colorimetry
  let rate: FrameRate
  let clock: VideoClockDomain
  init(width: Int, height: Int, pixelAspect: Rational = .one, scan: Scan = .progressive, pixel: PixelFormatID, colour: Colorimetry = .rec709Video, rate: FrameRate, clock: VideoClockDomain = .deviceClock) throws {
    self.width = width; self.height = height; self.pixelAspect = pixelAspect; self.scan = scan; self.pixel = pixel; self.colour = colour; self.rate = rate; self.clock = clock
    try validate()
    storedSignature = contractSignature(self, revision: PixelFormatTable.entry(for: pixel)!.revision)
  }
  func validate() throws {
    guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max), pixelAspect.numerator > 0, PixelFormatTable.entry(for: pixel) != nil else { throw SourceFormatError.invalid("Invalid dimensions, aspect or unsupported pixels") }
    try rate.validate()
  }
  var signature: String { storedSignature }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height), pixelAspect: c.decode(Rational.self, forKey: .pixelAspect), scan: c.decode(Scan.self, forKey: .scan), pixel: c.decode(PixelFormatID.self, forKey: .pixel), colour: c.decode(Colorimetry.self, forKey: .colour), rate: c.decode(FrameRate.self, forKey: .rate), clock: c.decode(VideoClockDomain.self, forKey: .clock))
  }
}
enum AudioSampleType: String, Codable, Sendable {
  case int16, int24in32, int32, float32
  var bytesPerSample: Int { self == .int16 ? 2 : 4 }
}
struct AudioChannelMap: Hashable, Codable, Sendable {
  let layoutTag: UInt32
  let labels: [UInt32]
  init(layoutTag: UInt32 = 0, labels: [UInt32] = []) { self.layoutTag = layoutTag; self.labels = labels }
}
struct SourceAudioFormat: Hashable, Codable, Sendable {
  private enum CodingKeys: String, CodingKey { case sampleRate, channels, sample, interleaved, layout, clock }
  private var storedSignature = ""
  let sampleRate: Double
  let channels: Int
  let sample: AudioSampleType
  let interleaved: Bool
  let layout: AudioChannelMap
  let clock: AudioClockDomain
  init(sampleRate: Double, channels: Int, sample: AudioSampleType, interleaved: Bool, layout: AudioChannelMap, clock: AudioClockDomain) throws {
    guard sampleRate.isFinite, sampleRate > 0, channels > 0, channels <= 65535, layout.labels.isEmpty || layout.labels.count == channels else { throw SourceFormatError.invalid("Invalid audio format or channel map") }
    self.sampleRate = sampleRate; self.channels = channels; self.sample = sample; self.interleaved = interleaved; self.layout = layout; self.clock = clock
    storedSignature = contractSignature(self)
  }
  var signature: String { storedSignature }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(sampleRate: c.decode(Double.self, forKey: .sampleRate), channels: c.decode(Int.self, forKey: .channels), sample: c.decode(AudioSampleType.self, forKey: .sample), interleaved: c.decode(Bool.self, forKey: .interleaved), layout: c.decode(AudioChannelMap.self, forKey: .layout), clock: c.decode(AudioClockDomain.self, forKey: .clock))
  }
}
enum SourceAudioDeclaration: Hashable, Codable, Sendable {
  case unknown, absent, present(SourceAudioFormat)
  var isResolved: Bool { if case .unknown = self { false } else { true } }
}
struct Timecode: Hashable, Codable, Sendable {
  let hours: Int, minutes: Int, seconds: Int, frames: Int
  let dropFrame: Bool
  let fieldMark: Bool?
  func validate(rate: FrameRate) throws {
    try rate.validate()
    let fps = 1 / CMTimeGetSeconds(rate.nominal)
    guard fps.isFinite, fps > 0, Double(frames) < ceil(fps) else { throw SourceFormatError.invalid("Timecode frame exceeds declared rate") }
    if dropFrame {
      let thirty = CMTimeCompare(rate.nominal, CMTime(value: 1001, timescale: 30000)) == 0
      let sixty = CMTimeCompare(rate.nominal, CMTime(value: 1001, timescale: 60000)) == 0
      guard !rate.isVariable, thirty || sixty else { throw SourceFormatError.invalid("Unsupported drop-frame rate") }
      if minutes % 10 != 0, seconds == 0, frames < (sixty ? 4 : 2) { throw SourceFormatError.invalid("Skipped drop-frame label") }
    }
  }
  init(hours: Int, minutes: Int, seconds: Int, frames: Int, dropFrame: Bool, fieldMark: Bool? = nil) throws {
    guard (0..<24).contains(hours), (0..<60).contains(minutes), (0..<60).contains(seconds), frames >= 0 else { throw SourceFormatError.invalid("Invalid timecode components") }
    self.hours = hours; self.minutes = minutes; self.seconds = seconds; self.frames = frames; self.dropFrame = dropFrame; self.fieldMark = fieldMark
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(hours: c.decode(Int.self, forKey: .hours), minutes: c.decode(Int.self, forKey: .minutes), seconds: c.decode(Int.self, forKey: .seconds), frames: c.decode(Int.self, forKey: .frames), dropFrame: c.decode(Bool.self, forKey: .dropFrame), fieldMark: c.decodeIfPresent(Bool.self, forKey: .fieldMark))
  }
}
struct CaptureEpochID: Hashable, Codable, Sendable {
  let sessionID: UUID
  let epoch: UInt64
  init(sessionID: UUID, epoch: UInt64) { self.sessionID = sessionID; self.epoch = epoch }
}
struct ClockInstanceID: Hashable, Codable, Sendable {
  let value: UUID
  init(value: UUID = UUID()) { self.value = value }
}
struct CaptureClockBindings: Hashable, Codable, Sendable {
  let video: ClockInstanceID
  let audio: ClockInstanceID?
  init(video: ClockInstanceID, audio: ClockInstanceID? = nil) { self.video = video; self.audio = audio }
}
struct ClockMapping: Hashable, Codable, Sendable {
  private let source: ContractTime
  private let host: ContractTime
  let rate: Rational
  var sourceAnchor: CMTime { source.time }
  var hostAnchor: CMTime { host.time }
  init(sourceAnchor: CMTime, hostAnchor: CMTime, rate: Rational) throws {
    source = try ContractTime(sourceAnchor); host = try ContractTime(hostAnchor)
    guard rate.numerator > 0 else { throw SourceFormatError.invalid("Clock rate must be positive") }
    self.rate = rate
  }
  func hostTime(for sourceTime: CMTime) throws -> CMTime {
    _ = try ContractTime(sourceTime)
    guard sourceTime.epoch == sourceAnchor.epoch else { throw SourceFormatError.invalid("Clock epoch mismatch") }
    let result = CMTimeAdd(hostAnchor, CMTimeMultiplyByFloat64(CMTimeSubtract(sourceTime, sourceAnchor), multiplier: Double(rate.numerator) / Double(rate.denominator)))
    _ = try ContractTime(result)
    return result
  }
  private enum CodingKeys: String, CodingKey { case sourceAnchor, hostAnchor, rate }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(sourceAnchor: c.decode(ContractTime.self, forKey: .sourceAnchor).time, hostAnchor: c.decode(ContractTime.self, forKey: .hostAnchor).time, rate: c.decode(Rational.self, forKey: .rate))
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(source, forKey: .sourceAnchor); try c.encode(host, forKey: .hostAnchor); try c.encode(rate, forKey: .rate)
  }
}
