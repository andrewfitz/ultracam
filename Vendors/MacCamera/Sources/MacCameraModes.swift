import AVFoundation
import CoreVideo
import CryptoKit
import Foundation

struct MacCameraMode {
  let format: AVCaptureDevice.Format
  private let capabilities: Capabilities

  var id: String { capabilities.settingFormat.id }
  var width: Int { capabilities.width }
  var height: Int { capabilities.height }
  var pixel: OSType { capabilities.pixel }
  var ranges: [VendorCaptureRateRange] { capabilities.settingFormat.ranges }
  var rates: [VendorCaptureRate] { capabilities.settingFormat.rates }
  var label: String { capabilities.settingFormat.label }
  var settingFormat: VendorCaptureFormat { capabilities.settingFormat }

  init(_ format: AVCaptureDevice.Format) {
    self.format = format
    let ranges = format.videoSupportedFrameRateRanges.map {
      VendorCaptureRateRange(shortest: $0.minFrameDuration, longest: $0.maxFrameDuration)
    }
    capabilities = Capabilities(description: format.formatDescription, ranges: ranges,
      colorSpaces: format.supportedColorSpaces.map(\.rawValue))
  }

  struct Capabilities {
    let width: Int
    let height: Int
    let pixel: OSType
    let settingFormat: VendorCaptureFormat

    init(description: CMFormatDescription, ranges: [VendorCaptureRateRange], colorSpaces: [Int]) {
      let size = CMVideoFormatDescriptionGetDimensions(description)
      width = Int(size.width)
      height = Int(size.height)
      pixel = CMFormatDescriptionGetMediaSubType(description)
      let validRanges = ranges.filter {
        MacCameraMode.validDuration($0.shortest) && MacCameraMode.validDuration($0.longest) && $0.shortest <= $0.longest
      }
      let durations = validRanges.map {
        "\(MacCameraMode.timeID($0.shortest))-\(MacCameraMode.timeID($0.longest))"
      }.sorted()
      let tags = [
        kCMFormatDescriptionExtension_ColorPrimaries,
        kCMFormatDescriptionExtension_TransferFunction,
        kCMFormatDescriptionExtension_YCbCrMatrix,
        kCMFormatDescriptionExtension_FullRangeVideo,
        kCMFormatDescriptionExtension_PixelAspectRatio,
        kCMFormatDescriptionExtension_FieldCount,
        kCMFormatDescriptionExtension_FieldDetail,
        kCMFormatDescriptionExtension_ChromaLocationTopField,
        kCMFormatDescriptionExtension_ChromaLocationBottomField
      ].map { MacCameraMode.extensionValue(description, key: $0) ?? "" }
      let signature = ["mac-camera-format-2", String(width), String(height), String(pixel), String(durations.count)] +
        durations + [String(colorSpaces.count)] + colorSpaces.sorted().map { String($0) } + tags
      let id = SHA256.hash(data: Data(signature.map { "\($0.utf8.count):\($0)" }.joined().utf8))
        .map { String(format: "%02x", $0) }.joined()
      let standard = [
        CMTime(value: 1, timescale: 15), CMTime(value: 1001, timescale: 24000),
        CMTime(value: 1, timescale: 24), CMTime(value: 1, timescale: 25),
        CMTime(value: 1001, timescale: 30000), CMTime(value: 1, timescale: 30),
        CMTime(value: 1, timescale: 48), CMTime(value: 1, timescale: 50),
        CMTime(value: 1001, timescale: 60000), CMTime(value: 1, timescale: 60),
        CMTime(value: 1, timescale: 90), CMTime(value: 1, timescale: 120)
      ]
      let candidates = validRanges.flatMap { [$0.shortest, $0.longest] } + standard.filter { duration in
        validRanges.contains { $0.contains(duration) }
      }
      var seen = Set<String>()
      var durationsByRate = candidates.sorted(by: >).filter { seen.insert(MacCameraMode.timeID($0)).inserted }
      if let preferred = durationsByRate.indices.min(by: {
        abs(1 / durationsByRate[$0].seconds - 30) < abs(1 / durationsByRate[$1].seconds - 30)
      }) {
        let duration = durationsByRate.remove(at: preferred)
        durationsByRate.insert(duration, at: 0)
      }
      let rates = durationsByRate.map { VendorCaptureRate(duration: $0, label: MacCameraMode.rateLabel($0)) }
      let label = (["\(width) × \(height)", MacCameraMode.macCameraSubtypeName(pixel)] +
        Self.colorLabels(description, colorSpaces: colorSpaces)).joined(separator: " · ")
      settingFormat = VendorCaptureFormat(id: id, label: label, rates: rates, ranges: validRanges)
    }

    private static func colorLabels(_ description: CMFormatDescription, colorSpaces: [Int]) -> [String] {
      let knownTags: [String: String] = [
        kCVImageBufferColorPrimaries_ITU_R_709_2 as String: "Rec. 709",
        kCVImageBufferColorPrimaries_ITU_R_2020 as String: "Rec. 2020",
        kCVImageBufferColorPrimaries_P3_D65 as String: "Display P3",
        kCVImageBufferTransferFunction_ITU_R_2100_HLG as String: "HLG",
        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String: "PQ",
        kCVImageBufferTransferFunction_sRGB as String: "sRGB",
        kCVImageBufferTransferFunction_Linear as String: "Linear"
      ]
      let tags = [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction]
        .compactMap { MacCameraMode.extensionValue(description, key: $0) }
        .map { knownTags[$0] ?? $0 }
      let spaces: [String] = colorSpaces.sorted().compactMap { value in
        switch AVCaptureColorSpace(rawValue: value) {
        case .sRGB: "sRGB"
        case .P3_D65: "Display P3"
        default: nil
        }
      }
      let spacesLabel = spaces.isEmpty ? [] : [spaces.joined(separator: " / ")]
      var seen = Set<String>()
      return (tags + spacesLabel).filter { seen.insert($0).inserted }
    }
  }

  /// Call while holding the device configuration lock.
  func apply(to device: AVCaptureDevice, minimum: CMTime?, maximum: CMTime?) throws {
    guard device.isConnected, device.formats.contains(format) else {
      throw PluginError.unavailable("The capture format was removed before configuration.")
    }
    guard [minimum, maximum].compactMap({ $0 }).allSatisfy(supports) else {
      throw PluginError.unsupported("The requested frame duration is outside the camera's supported ranges.")
    }
    if device.activeFormat != format { device.activeFormat = format }
    if let minimum, let maximum {
      guard !device.isVideoFrameDurationLocked, !device.isFollowingExternalSyncDevice else {
        throw PluginError.busy("The camera cadence is locked by another capture client or external sync.")
      }
      if device.isAutoVideoFrameRateEnabled {
        guard format.isAutoVideoFrameRateSupported else {
          throw PluginError.unsupported("This camera does not permit changing its automatic Frame Rate.")
        }
        device.isAutoVideoFrameRateEnabled = false
      }
      let caps: [AVFrameRateRange?] = [
        device.isCenterStageActive ? format.videoFrameRateRangeForCenterStage : nil,
        device.isPortraitEffectActive ? format.videoFrameRateRangeForPortraitEffect : nil,
        device.isStudioLightActive ? format.videoFrameRateRangeForStudioLight : nil,
        device.isBackgroundReplacementActive ? format.videoFrameRateRangeForBackgroundReplacement : nil,
        device.reactionEffectsInProgress.isEmpty ? nil : format.videoFrameRateRangeForReactionEffectsInProgress
      ]
      guard caps.compactMap({ $0 }).allSatisfy({ $0.minFrameDuration <= minimum && maximum <= $0.maxFrameDuration }) else {
        throw PluginError.unsupported("A macOS video effect limits the selected Frame Rate. Change the effect in Control Center or select another rate.")
      }
      if minimum > device.activeVideoMaxFrameDuration {
        device.activeVideoMaxFrameDuration = maximum
        device.activeVideoMinFrameDuration = minimum
      } else {
        device.activeVideoMinFrameDuration = minimum
        device.activeVideoMaxFrameDuration = maximum
      }
    }
  }

  func supports(_ duration: CMTime) -> Bool {
    settingFormat.supports(duration)
  }

  func sourceFormat(rate: FrameRate, clock: VideoClockDomain) throws -> SourceFormat {
    let description = format.formatDescription
    return try Self.sourceFormat(description: description, image: nil, rate: rate, clock: clock,
      scan: Self.scan(description: description, image: nil))
  }

  static func scan(description: CMFormatDescription, image: CVPixelBuffer?) throws -> Scan {
    func hasTwoFields(_ value: CFTypeRef?) throws -> Bool {
      guard let value else { return false }
      guard CFGetTypeID(value) == CFNumberGetTypeID(), let count = value as? NSNumber,
        count.doubleValue == 1 || count.doubleValue == 2 else {
        throw PluginError.unsupported("The Mac Camera delivered an invalid field count.")
      }
      return count.doubleValue == 2
    }
    let bufferFields = try hasTwoFields(image.flatMap { CVBufferCopyAttachment($0, kCVImageBufferFieldCountKey, nil) })
    let formatFields = try hasTwoFields(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_FieldCount))
    let hasDetail = image.flatMap { CVBufferCopyAttachment($0, kCVImageBufferFieldDetailKey, nil) } != nil ||
      CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_FieldDetail) != nil
    return bufferFields || formatFields || hasDetail ? .interlaced : .progressive
  }

  static func validateDelivery(native: OSType, fallback: OSType?, delivered: OSType) throws {
    let nativeQualified = PixelFormatTable.entry(for: PixelFormatID(rawValue: native))?.captureQualified == true
    let expected = nativeQualified ? native : fallback ?? native
    guard expected == delivered else {
      throw PluginError.unsupported("The camera's \(macCameraSubtypeName(native)) mode delivered \(macCameraSubtypeName(delivered)) instead of \(macCameraSubtypeName(expected)). Select a matching Capture Format or Input Delivery conversion in Hardware.")
    }
  }

  static func validateDimensions(width: Int, height: Int, deliveredWidth: Int, deliveredHeight: Int) throws {
    let matchesActiveFormat = deliveredWidth == width && deliveredHeight == height
    // Some cameras orient the full native picture without changing activeFormat.
    let matchesRotatedFormat = deliveredWidth == height && deliveredHeight == width
    guard matchesActiveFormat || matchesRotatedFormat else {
      throw PluginError.unsupported("The active \(width) × \(height) Mac Camera mode delivered \(deliveredWidth) × \(deliveredHeight). Select a Capture Format that the camera delivers at full size in Hardware.")
    }
  }

  static func sourceFormat(description sourceDescription: CMFormatDescription, image: CVPixelBuffer?,
    rate: FrameRate, clock: VideoClockDomain, scan: Scan) throws -> SourceFormat {
    let dimensions = CMVideoFormatDescriptionGetDimensions(sourceDescription)
    let pixel = PixelFormatID(rawValue: image.map(CVPixelBufferGetPixelFormatType) ?? CMFormatDescriptionGetMediaSubType(sourceDescription))
    guard let entry = PixelFormatTable.entry(for: pixel), entry.captureQualified else {
      throw PluginError.unsupported("Mac Camera delivered \(Self.macCameraSubtypeName(pixel.rawValue)), which lacks a qualified capture route. Choose a supported Capture Format or delivery conversion in Hardware.")
    }
    try validateRange(description: sourceDescription, image: image, entry: entry)
    let aspect = (image.flatMap { CVBufferCopyAttachment($0, kCVImageBufferPixelAspectRatioKey, nil) }
      ?? CMFormatDescriptionGetExtension(sourceDescription, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio)) as? [String: NSNumber]
    let horizontal = aspect?[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String]?.int64Value ?? 1
    let vertical = aspect?[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String]?.int64Value ?? 1
    return try SourceFormat(width: image.map(CVPixelBufferGetWidth) ?? Int(dimensions.width),
      height: image.map(CVPixelBufferGetHeight) ?? Int(dimensions.height),
      pixelAspect: Rational(horizontal, vertical), scan: scan,
      pixel: pixel, colour: color(description: sourceDescription, image: image, entry: entry), rate: rate, clock: clock)
  }

  private static func color(description: CMFormatDescription, image: CVPixelBuffer?, entry: PixelFormatTable.Entry) -> Colorimetry {
    func tag(_ imageKey: CFString, _ formatKey: CFString) -> String? {
      if let image, let value = CVBufferCopyAttachment(image, imageKey, nil) as? String { return value }
      return extensionValue(description, key: formatKey)
    }
    let primaries: Colorimetry.Primaries = switch tag(kCVImageBufferColorPrimariesKey, kCMFormatDescriptionExtension_ColorPrimaries) {
    case let value where value == kCVImageBufferColorPrimaries_ITU_R_709_2 as String: .rec709
    case let value where value == kCVImageBufferColorPrimaries_ITU_R_2020 as String: .rec2020
    case let value where value == kCVImageBufferColorPrimaries_P3_D65 as String: .p3D65
    default: .unspecified
    }
    let transfer: Colorimetry.Transfer = switch tag(kCVImageBufferTransferFunctionKey, kCMFormatDescriptionExtension_TransferFunction) {
    case let value where value == kCVImageBufferTransferFunction_ITU_R_709_2 as String: .rec709
    case let value where value == kCVImageBufferTransferFunction_sRGB as String: .sRGB
    case let value where value == kCVImageBufferTransferFunction_Linear as String: .linear
    case let value where value == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String: .pq
    case let value where value == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String: .hlg
    default: .unspecified
    }
    let matrix: Colorimetry.Matrix = switch tag(kCVImageBufferYCbCrMatrixKey, kCMFormatDescriptionExtension_YCbCrMatrix) {
    case let value where value == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String: .rec709
    case let value where value == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String: .rec601
    case let value where value == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String: .rec2020
    default: entry.inputKernel == "decodeRGB" ? .identity : .unspecified
    }
    let siting: (horizontal: Colorimetry.ChromaSiting, vertical: Colorimetry.ChromaSiting) =
      switch tag(kCVImageBufferChromaLocationTopFieldKey, kCMFormatDescriptionExtension_ChromaLocationTopField) {
      case let value where value == kCVImageBufferChromaLocation_Left as String: (.left, .center)
      case let value where value == kCVImageBufferChromaLocation_Center as String: (.center, .center)
      case let value where value == kCVImageBufferChromaLocation_TopLeft as String: (.left, .top)
      case let value where value == kCVImageBufferChromaLocation_Top as String: (.center, .top)
      case let value where value == kCVImageBufferChromaLocation_BottomLeft as String: (.left, .bottom)
      case let value where value == kCVImageBufferChromaLocation_Bottom as String: (.center, .bottom)
      default: (.unspecified, .unspecified)
      }
    return Colorimetry(primaries: primaries, transfer: transfer, matrix: matrix, range: entry.defaultRange,
      horizontalChromaSiting: siting.horizontal, verticalChromaSiting: siting.vertical)
  }

  static func validateRange(description: CMFormatDescription, image: CVPixelBuffer?, entry: PixelFormatTable.Entry) throws {
    func matches(_ value: CFTypeRef?) -> Bool {
      guard let value else { return true }
      return CFGetTypeID(value) == CFBooleanGetTypeID() && (value as? Bool) == (entry.defaultRange == .full)
    }
    let rangeKey = kCMFormatDescriptionExtension_FullRangeVideo
    guard matches(image.flatMap { CVBufferCopyAttachment($0, rangeKey, nil) }),
      matches(CMFormatDescriptionGetExtension(description, extensionKey: rangeKey)) else {
      throw PluginError.unsupported("The Mac Camera range metadata conflicts with its \(macCameraSubtypeName(entry.id.rawValue)) subtype.")
    }
  }

  private static func extensionValue(_ description: CMFormatDescription, key: CFString) -> String? {
    if let value = CMFormatDescriptionGetExtension(description, extensionKey: key) as? String { return value }
    if let value = CMFormatDescriptionGetExtension(description, extensionKey: key) as? NSNumber { return value.stringValue }
    if let values = CMFormatDescriptionGetExtension(description, extensionKey: key) as? [String: NSNumber] {
      return values.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
    return nil
  }

  static func validDuration(_ time: CMTime) -> Bool {
    time.isNumeric && time.epoch == 0 && time > .zero
  }

  static func timeID(_ time: CMTime) -> String {
    guard let value = try? Rational(time.value, Int64(time.timescale)) else { return "invalid" }
    return "\(value.numerator)/\(value.denominator)"
  }

  static func rateLabel(_ duration: CMTime) -> String {
    String(format: "%.6g fps", 1 / duration.seconds)
  }

  static func macCameraSubtypeName(_ code: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
    guard bytes.allSatisfy({ (32...126).contains($0) }) else { return String(format: "0x%08x", code) }
    return String(decoding: bytes, as: UTF8.self)
  }
}
