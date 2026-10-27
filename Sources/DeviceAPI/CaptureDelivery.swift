import Foundation
import CoreMedia
import CoreVideo

/// The producer transfers immutable publication ownership: neither pixels nor
/// attachments may change until the last wrapper is released. `owner` retains
/// SDK storage independently of the capture session. Consumers write elsewhere.
struct CapturedPixelBuffer: @unchecked Sendable {
  let value: CVPixelBuffer
  private let owner: AnyObject?
  init(immutable value: CVPixelBuffer, retaining owner: AnyObject? = nil) {
    self.value = value
    self.owner = owner
  }
}
struct CaptureFrameInfo: Sendable {
  let epochID: CaptureEpochID
  let formatSignature: String
  let presentationTime: CMTime
  let duration: CMTime
  let signalValid: Bool
  let timecode: Timecode?
  func validate() throws {
    guard presentationTime.isNumeric, presentationTime.epoch == 0, presentationTime >= .zero,
      duration.isNumeric, duration.epoch == 0, duration > .zero else {
      throw PluginError.unsupported("Invalid source frame timestamp or duration")
    }
  }
}
enum CaptureEvent: Sendable {
  case formatChanged(SourceFormat), audioFormatChanged(SourceAudioDeclaration)
  case discontinuity, waitingForSignal, signalLost(reason: String), unsupportedInput(String), fatal(String), info(String)
}
struct CaptureDelivery: Sendable {
  enum Payload: Sendable {
    case event(CaptureEvent)
    case frame(CapturedPixelBuffer, CaptureFrameInfo)
    case media(CaptureMediaInfo)
    case rawAudio(CaptureAudioPacket)
  }
  let sequence: UInt64
  let epochID: CaptureEpochID
  let formatSignature: String
  let clockBindings: CaptureClockBindings
  let mappingRevision: UInt64
  let payload: Payload
}
