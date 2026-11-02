import CoreVideo
import Foundation

/// A camera's burn-in LUT as a take found it at its start: the same immutable
/// `MonitorLUT` Program and the virtual camera burn in, its colour contract,
/// and the colour settings those burned-in frames use.
struct RecordingLUTSnapshot: @unchecked Sendable {
  let lut: MonitorLUT
  let colorSpace: LUTColorSpaceContract
  /// The camera's source profile (Settings › camera › Source), as Program uses it.
  let sourceColorimetryOverride: Colorimetry?
  /// The LUT output space the camera declares, nil for the LUT's own.
  let lutOutputColorimetry: Colorimetry?
}

/// Burns a take's LUT into its frames for the recorder (`RecordingLUTBurnIn`).
///
/// Its own `LUTProcessor` (own Metal 4 queue, slots and surface cache), owned
/// by the take's recorder queue, so it never competes with the camera's
/// processor for slots or waits behind Program and preview frames. It runs the
/// same kernels Program does (decode, MonitorKit's tetrahedral `mk_applyLUT`,
/// encode) at the source's size and rate, straight into the encoder's pool.
final class RecordingLUTRenderer: RecordingLUTBurnIn, @unchecked Sendable {
  let lutName: String
  let lutFileName: String?
  let lutInputColour: Colorimetry
  let lutOutputColour: Colorimetry
  let outputColour: Colorimetry
  private let snapshot: RecordingLUTSnapshot
  private let processor: LUTProcessor

  /// The encoder layouts the LUT kernels write.
  private static let targets: [OSType: ColorTarget] = Dictionary(uniqueKeysWithValues:
    [ColorTarget.yuv42210, .yuv42010, .yuv4208].map { ($0.pixelFormat, $0) })
  /// The source layouts `LUTProcessor` reads (its `validate`).
  private static let sources: Set<OSType> = Set(VideoContract.tenBit422).union([
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
    0x50323136, 0x32767579, 0x79757673, kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA,
    0x72323130, 0x5231324c, 0x49343230, 0x50413136])

  init(snapshot: RecordingLUTSnapshot, fileName: String? = nil) throws {
    let processor = try LUTProcessor(qos: .userInitiated)
    try processor.load(snapshot.lut, colorSpace: snapshot.colorSpace)
    self.processor = processor
    self.snapshot = snapshot
    lutName = snapshot.lut.cube.title
    lutFileName = fileName
    lutInputColour = snapshot.colorSpace.input
    lutOutputColour = snapshot.colorSpace.output
    outputColour = Self.recordedColour(snapshot)
  }

  /// How Program and the virtual camera tag burned-in frames
  /// (`CameraSink.resolvedOutputColour`, `LUTProcessor.submit`): the LUT
  /// output's primaries and transfer, video range, centred chroma.
  static func recordedColour(_ snapshot: RecordingLUTSnapshot) -> Colorimetry {
    let target = snapshot.lutOutputColorimetry ?? snapshot.colorSpace.output
    return Colorimetry(primaries: target.primaries, transfer: target.transfer,
      matrix: target.matrix == .identity ? .rec709 : target.matrix, range: .video,
      horizontalChromaSiting: .center, verticalChromaSiting: .center)
  }

  func refusal(sourcePixelFormat: OSType, encoderPixelFormat: OSType) -> String? {
    guard Self.targets[encoderPixelFormat] != nil else {
      return "the encoder takes \(VideoContract.fourCC(encoderPixelFormat)), which the LUT pass doesn’t write."
    }
    guard Self.sources.contains(sourcePixelFormat) else {
      return "the LUT pass can’t read this camera’s \(VideoContract.fourCC(sourcePixelFormat)) picture."
    }
    return nil
  }

  /// The take's configuration for one frame: LUT on, the source's own size,
  /// geometry and rate, the encoder's layout. Pixel aspect stays out of it so
  /// nothing is scaled; the writer tags the file with the source's aspect.
  func configuration(for source: CVPixelBuffer, encoderPixelFormat: OSType) throws -> PipelineConfiguration {
    guard let target = Self.targets[encoderPixelFormat] else {
      throw VideoError.message("The LUT pass doesn’t write \(VideoContract.fourCC(encoderPixelFormat)).")
    }
    var configuration = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: target.is420,
      reduceFrameRate: false)
    configuration.colorTarget = target
    configuration.sourceWidth = CVPixelBufferGetWidth(source)
    configuration.sourceHeight = CVPixelBufferGetHeight(source)
    configuration.sourceColorimetryOverride = snapshot.sourceColorimetryOverride
    configuration.lutOutputColorimetry = snapshot.lutOutputColorimetry
    return configuration
  }

  func render(_ source: CVPixelBuffer, sourceColour: Colorimetry?, into destination: CVPixelBuffer) throws -> Double {
    let configuration = try configuration(for: source, encoderPixelFormat: CVPixelBufferGetPixelFormatType(destination))
    return try processor.render(source, configuration: configuration, declaredSourceColorimetry: sourceColour,
      into: destination)
  }
}
