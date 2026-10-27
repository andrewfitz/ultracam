import CoreMedia
import CoreVideo
import Foundation

enum VideoContract {
  static let cameraName = "Ultracam"
  static let sinkName = "Ultracam Input"
  static let deviceUID = "org.ultracam.camera.device"
  static let extensionID = "org.ultracam.app.camera"
  // Read-only source demand, independent of the host's producer/sink stream.
  static let demandProperty = "4cc_udmd_glob_0000"
  static let demandSelector: UInt32 = 0x75646d64 // 'udmd'
  static let slowDuration = CMTime(value: 1001, timescale: 30_000)
  static let fastDuration = CMTime(value: 1001, timescale: 60_000)
  // GPU frames encoded and committed but not yet complete. The capture queue
  // encodes frame N+1 while the GPU runs frame N; it never waits for a frame.
  static let maxFramesInFlight = 3
  // Frames the processor warms before native capture starts.
  static let warmBufferCount = 3
  // Output pool minimum: frames in flight plus normal downstream retention
  // (display layer current/next image, CMIO queue and the extension's latest
  // image, the Program hop and the monitor). Allocation past this happens only
  // when a consumer actually holds more.
  static let outputPoolMinimum = maxFramesInFlight + 6
  // Not a busy policy: a consumer that holds this many output frames has
  // stalled. Reaching it is shown as an output stall error with a count; normal
  // operation stays near `outputPoolMinimum`.
  static let outputBufferLimit = 64
  // The camera extension's sink queue depth. The extension drains every ready
  // frame on each poll, so depth only absorbs real stalls; a full queue is a
  // counted camera stall, not a silent drop.
  static let cameraSinkQueueSize = 8
  static let tenBit422: [OSType] = [
    kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
    kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
    kCVPixelFormatType_422YpCbCr10,
  ]

  static func fourCC(_ value: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 255) }
    guard bytes.allSatisfy({ (32...126).contains($0) }) else { return String(format: "0x%08X", value) }
    return String(bytes: bytes, encoding: .ascii) ?? String(value)
  }

  static func formatDescription(width: Int, height: Int, pixelFormat: OSType) throws -> CMVideoFormatDescription {
    guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max) else {
      throw VideoError.message("Invalid video dimensions.")
    }
    guard tenBit422.contains(pixelFormat) || ColorTarget.allCases.contains(where: { $0.pixelFormat == pixelFormat }) else {
      throw VideoError.message("Unsupported video pixel format.")
    }
    // Core Media accepts odd dimensions when creating a description, but the
    // advertised bi-planar Y'CbCr layouts cannot represent them: 4:2:2 needs
    // paired luma samples and 4:2:0 additionally needs paired rows. Packed
    // v210 is handled separately and permits a final partial six-pixel group.
    let is420 = ColorTarget.allCases.contains { $0.pixelFormat == pixelFormat && $0.is420 }
    let isPacked422 = pixelFormat == kCVPixelFormatType_422YpCbCr10
    guard isPacked422 || width.isMultiple(of: 2), !is420 || height.isMultiple(of: 2) else {
      throw VideoError.message("Invalid video dimensions for pixel format.")
    }
    let fullRange = pixelFormat == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
    var format: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, codecType: pixelFormat,
      width: Int32(width), height: Int32(height),
      extensions: [
        kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCMFormatDescriptionExtension_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        kCMFormatDescriptionExtension_FullRangeVideo: fullRange as CFBoolean,
      ] as CFDictionary, formatDescriptionOut: &format)
    guard status == noErr, let format else { throw VideoError.message("Could not create video format (\(status)).") }
    return format
  }

  static func sample(_ buffer: CVPixelBuffer, at time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
    try VideoSampleFactory().sample(buffer, at: time, duration: duration)
  }
}

// Queue-confined. Core Media validates geometry, packed stride and color
// extensions before reusing a description; dimensions alone are insufficient.
final class VideoSampleFactory {
  private var format: CMVideoFormatDescription?
#if CAPTURE_LIFECYCLE_TESTS
  var beforeSampleCreationForTesting: (() -> Void)?
#endif

  func reset() { format = nil }

  func sample(_ buffer: CVPixelBuffer, at time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
    let description: CMVideoFormatDescription
    if let format, CMVideoFormatDescriptionMatchesImageBuffer(format, imageBuffer: buffer) {
      description = format
    } else {
      description = try refreshFormat(buffer)
    }
#if CAPTURE_LIFECYCLE_TESTS
    let beforeCreation = beforeSampleCreationForTesting
    beforeSampleCreationForTesting = nil
    beforeCreation?()
#endif
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    var status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: description,
      sampleTiming: &timing, sampleBufferOut: &sample)
    // Native consumers can add image attachments between the cache validation
    // above and sample creation. Refresh only for this exact mismatch, once;
    // ordinary frames keep their cached description and every other error is
    // reported immediately. Never spin if metadata keeps changing.
    if status == kCMSampleBufferError_InvalidMediaFormat {
      let refreshed = try refreshFormat(buffer)
      status = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: refreshed,
        sampleTiming: &timing, sampleBufferOut: &sample)
    }
    guard status == noErr, let sample else { throw VideoError.message("Could not create sample (\(status)).") }
    return sample
  }

  private func refreshFormat(_ buffer: CVPixelBuffer) throws -> CMVideoFormatDescription {
    var format: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
    guard status == noErr, let format else { throw VideoError.message("Invalid pixel buffer (\(status)).") }
    self.format = format
    return format
  }
}

enum ResizeTarget: String, Codable, CaseIterable, Sendable {
  case hd720, hd1080, uhd4K
  var title: String { switch self { case .hd720: "720p"; case .hd1080: "1080p"; case .uhd4K: "4K UHD" } }
  var width: Int { switch self { case .hd720: 1280; case .hd1080: 1920; case .uhd4K: 3840 } }
  var height: Int { width * 9 / 16 }
}

enum ColorTarget: String, Codable, CaseIterable, Sendable {
  case yuv4208, yuv42010, yuv4228, yuv42210
  var title: String { switch self {
    case .yuv4208: "4:2:0 8-bit"; case .yuv42010: "4:2:0 10-bit"
    case .yuv4228: "4:2:2 8-bit"; case .yuv42210: "4:2:2 10-bit"
  } }
  var is420: Bool { self == .yuv4208 || self == .yuv42010 }
  var isEightBit: Bool { self == .yuv4208 || self == .yuv4228 }
  var pixelFormat: OSType { switch self {
    case .yuv4208: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    case .yuv42010: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    case .yuv4228: kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
    case .yuv42210: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
  } }
}

enum FrameRateTarget: String, Codable, CaseIterable, Sendable {
  case fps60, fps5994, fps50, fps30, fps2997, fps25, fps24, fps23976
  var title: String { switch self {
    case .fps60: "60"; case .fps5994: "59.94"; case .fps50: "50"
    case .fps30: "30"; case .fps2997: "29.97"; case .fps25: "25"
    case .fps24: "24"; case .fps23976: "23.976"
  } }
  var duration: CMTime { switch self {
    case .fps5994: VideoContract.fastDuration
    case .fps2997: VideoContract.slowDuration
    case .fps23976: CMTime(value: 1001, timescale: 24000)
    default: CMTime(value: 1, timescale: Int32(title)!)
  } }
}

struct PipelineConfiguration: Equatable, Sendable {
  var applyLUT = false
  var downscale = true
  var convertTo420 = true
  var reduceFrameRate = false
  var inputFast = true

  var resizeTarget: ResizeTarget = .hd1080
  var colorTarget: ColorTarget = .yuv4208
  var frameRateTarget: FrameRateTarget = .fps2997
  var width: Int { downscale ? resizeTarget.width : 3840 }
  var height: Int { downscale ? resizeTarget.height : 2160 }
  var outputColor: ColorTarget { convertTo420 ? colorTarget : .yuv42210 }
  var pixelFormat: OSType {
    outputColor.pixelFormat
  }
  var duration: CMTime {
    let source = inputFast ? VideoContract.fastDuration : VideoContract.slowDuration
    return reduceFrameRate ? CMTimeMaximum(source, frameRateTarget.duration) : source
  }
  var untouched: Bool { !applyLUT && (!downscale || resizeTarget == .uhd4K) && !convertTo420 }
  var outputLabel: String {
    "\(width) × \(height) · \(outputColor.title) · \(String(format: "%.3f", 1 / duration.seconds)) fps"
  }
}

enum VideoError: LocalizedError {
  case message(String)
  /// Every output buffer is held downstream (`outputBufferLimit`): a stalled
  /// consumer. Reported as a visible, counted stall.
  case outputBackPressure
  /// The frame was abandoned because capture stopped while it waited for a GPU slot.
  case cancelled
  var errorDescription: String? {
    switch self {
    case .message(let text): return text
    case .outputBackPressure:
      return "Output stalled: a consumer is holding all \(VideoContract.outputBufferLimit) output frames."
    case .cancelled: return "Capture stopped before the frame was processed."
    }
  }
}
