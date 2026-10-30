import CoreMedia
import CoreVideo
import Foundation

// Only app-settings, installed CMIO and monitor/GPU boundaries are replaced.
// The route, mapper, switcher, fan-out, retention, sample factory and bridge
// are compiled unchanged from their production files by the CPU runner.
struct FeedID: RawRepresentable, Hashable, Sendable { let rawValue: String }
enum SwitcherStrategy: Equatable { case manual, fixedInterval, naturalTalkingHead, dynamicAnalysis }
struct NaturalTalkingHeadSettings: Equatable { var anchorFeedID: FeedID?; var emphasisFeedID: FeedID? }
struct SwitcherSettings: Equatable {
  var selectedFeedID: FeedID?
  var automatic = false
  var intervalSeconds = 10.0
  var naturalTalkingHead = NaturalTalkingHeadSettings()
  var strategy = SwitcherStrategy.manual
}
struct FeedDescriptor { let id: FeedID; var enabled = true }
struct CameraSinkRoute {
  struct Descriptor { static func program() -> Self { Self() } }
  init(descriptor: Descriptor) {}
}
final class CameraSink {
  init(route: CameraSinkRoute) {}
  func connect(configuration: PipelineConfiguration, passthroughFormat: OSType) throws { fatalError("Injected sink required") }
  func disconnect() {}
  func send(_ sample: CMSampleBuffer) throws -> Bool { fatalError("Injected sink required") }
}
protocol MonitorFrameSink: AnyObject, Sendable {
  func offer(_ image: CVPixelBuffer, pts: CMTime, captureGeneration: UInt64, sequence: UInt64)
}
enum LUTProcessor {
  static func stampDeclaredColorimetry(_ colour: Colorimetry, on image: CVPixelBuffer) {
    CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(image, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
  }
  static func sourceColorimetry(_ image: CVPixelBuffer) throws -> Colorimetry {
    // Fixtures are explicitly stamped Rec.709 video-range, center-sited YUV.
    .init(primaries: .rec709, transfer: .rec709, matrix: .rec709, range: .video,
      horizontalChromaSiting: .center, verticalChromaSiting: .center)
  }
}
