import CoreMedia
import CoreVideo
import VideoToolbox

/// The recording profiles exposed by the source recorder. A profile is admitted
/// only when the declared source carries the depth/chroma layout that its
/// encoder contract can consume without an implicit conversion.
enum RecordingProfileMatrixProfile: String, CaseIterable, Codable, Sendable {
  case proResLT
  case proRes422
  case proRes422HQ
  case proRes4444
  case hevcMain
  case hevcMain10
  case hevcMain10_422

  var codec: CMVideoCodecType {
    switch self {
    case .proResLT: return kCMVideoCodecType_AppleProRes422LT
    case .proRes422: return kCMVideoCodecType_AppleProRes422
    case .proRes422HQ: return kCMVideoCodecType_AppleProRes422HQ
    case .proRes4444: return kCMVideoCodecType_AppleProRes4444
    case .hevcMain, .hevcMain10, .hevcMain10_422:
      return kCMVideoCodecType_HEVC
    }
  }

  var requiredBitDepth: Int { self == .hevcMain ? 8 : 10 }

  var encoderPixelFormat: OSType {
    switch self {
    case .hevcMain: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    case .hevcMain10: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    case .proRes4444: return kCVPixelFormatType_64RGBALE
    default: return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    }
  }

  var profileLevel: String? {
    switch self {
    case .hevcMain: return kVTProfileLevel_HEVC_Main_AutoLevel as String
    case .hevcMain10: return kVTProfileLevel_HEVC_Main10_AutoLevel as String
    case .hevcMain10_422: return kVTProfileLevel_HEVC_Main42210_AutoLevel as String
    default: return nil
    }
  }

  var requires422: Bool {
    switch self {
    case .proResLT, .proRes422, .proRes422HQ, .hevcMain10_422: return true
    default: return false
    }
  }

  var displayName: String {
    switch self {
    case .proResLT: return "ProRes 422 LT"
    case .proRes422: return "ProRes 422"
    case .proRes422HQ: return "ProRes 422 HQ"
    case .proRes4444: return "ProRes 4444"
    case .hevcMain: return "HEVC Main"
    case .hevcMain10: return "HEVC Main 10"
    case .hevcMain10_422: return "HEVC Main 10 4:2:2"
    }
  }
}

enum RecordingProfileMatrixError: Error, Equatable, CustomStringConvertible, Sendable {
  case unsupportedSourcePixel(PixelFormatID)
  case insufficientBitDepth(profile: RecordingProfileMatrixProfile, sourceDepth: Int)
  case chromaMismatch(profile: RecordingProfileMatrixProfile)
  case noRecordingRoute(PixelFormatID)
  case unsupportedRepack(profile: RecordingProfileMatrixProfile, source: PixelFormatID)

  var description: String {
    switch self {
    case .unsupportedSourcePixel(let pixel): return "Source pixel format \(pixel.rawValue) is not in the pixel format table."
    case let .insufficientBitDepth(profile, depth): return "\(profile.displayName) requires \(profile.requiredBitDepth)-bit input; source is \(depth)-bit."
    case .chromaMismatch(let profile): return "\(profile.displayName) requires 4:2:2 source chroma."
    case let .unsupportedRepack(profile, pixel): return "No GPU recording repack from \(pixel.rawValue) to \(profile.displayName) is implemented."
    case .noRecordingRoute(let pixel): return "Source pixel format \(pixel.rawValue) has no recording route."
    }
  }
}

/// Pure source/encoder admission. It deliberately does not probe or mutate an
/// AVAssetWriter; VideoToolbox availability is checked by the writer later.
enum RecordingRepackRoute: Equatable, Sendable {
  case native
  case v210To422
  case packedRGB(RGBFormat)
  case packed422(Packed422Format)
  case full420ToVideo420
  case p216To422
  case i420ToVideo420
  case pa16To422

  /// P216 recording intentionally reduces 16-bit components to the 10-bit
  /// encoder contract. Full-range 8-bit 420 also quantizes its legal-range map.
  var quantizesSource: Bool {
    switch self {
    case .p216To422, .pa16To422, .full420ToVideo420: return true
    default: return false
    }
  }
}

enum RecordingProfileMatrix {
  static func rgbFormat(for pixel: PixelFormatID) -> RGBFormat? {
    switch pixel.rawValue {
    case kCVPixelFormatType_32BGRA: return .bgra8
    case kCVPixelFormatType_32RGBA: return .rgba8
    case 0x72323130: return .r210
    case 0x5231324c: return .r12l
    default: return nil
    }
  }

  /// Identifies implemented encoder repacks independently of whether the
  /// complete source pipeline has admitted this pixel format. Production
  /// callers must first use validate(_:source:) to require registered routes.
  static func repackRoute(_ profile: RecordingProfileMatrixProfile, sourcePixel: PixelFormatID, sourceRange: Colorimetry.Range? = nil) throws -> RecordingRepackRoute {
    // Declared range is authoritative even when the fourCC matches the
    // encoder input. Full-range 420v must be physically requantized into a
    // distinct video-range 420v buffer before submission.
    if profile == .hevcMain, sourcePixel == .video420, sourceRange == .full {
      return .full420ToVideo420
    }
    if sourcePixel.rawValue == profile.encoderPixelFormat { return .native }
    if sourcePixel == .v210, profile.requires422 { return .v210To422 }
    if profile.requires422 {
      switch sourcePixel {
      case .twoVuy: return .packed422(.twoVuy)
      case .yuvs: return .packed422(.yuvs)
      case .uyva: return .packed422(.uyva)
      case .p216: return .p216To422
      case .pa16: return .pa16To422
      default: break
      }
    }
    if profile == .hevcMain, sourcePixel == .full420 { return .full420ToVideo420 }
    if profile == .hevcMain, sourcePixel == .i420 { return .i420ToVideo420 }
    if profile == .proRes4444, let rgb = rgbFormat(for: sourcePixel) { return .packedRGB(rgb) }
    throw RecordingProfileMatrixError.unsupportedRepack(profile: profile, source: sourcePixel)
  }

  static func validate(_ profile: RecordingProfileMatrixProfile, source: SourceFormat) throws {
    guard let entry = PixelFormatTable.entry(for: source.pixel) else {
      throw RecordingProfileMatrixError.unsupportedSourcePixel(source.pixel)
    }
    guard entry.routes.contains("recording"), entry.gpuRoutes.contains("recording") else {
      throw RecordingProfileMatrixError.noRecordingRoute(source.pixel)
    }
    // Route availability is independent of the source's theoretical precision.
    // No recording route may promise a conversion that has not been implemented.
    _ = try repackRoute(profile, sourcePixel: source.pixel, sourceRange: source.colour.range)
  }

  static func supports(_ profile: RecordingProfileMatrixProfile, source: SourceFormat) -> Bool {
    (try? validate(profile, source: source)) != nil
  }
}
