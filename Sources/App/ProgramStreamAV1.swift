#if ULTRACAM_STREAM_PUBLISHING || canImport(ProgramAV1)
import CoreMedia
import Foundation
import ProgramAV1

/// The publisher's serial input task owns libaom. A slot covers the raw input and its
/// compressed AV1 output until the transport has consumed the reference picture.
private final class ProgramStreamSoftwareAV1: ProgramStreamVideoEncoding, @unchecked Sendable {
  let output: AsyncStream<CMSampleBuffer>
  private let continuation: AsyncStream<CMSampleBuffer>.Continuation
  private let encoder: ProgramAV1Encoder
  private let dropped: @Sendable () -> Void
  private let failed: @Sendable () -> Void
  private let lock = NSLock()
  private var pending = 0

  init(format: ProgramStreamFormat, dropped: @escaping @Sendable () -> Void, failed: @escaping @Sendable () -> Void) throws {
    encoder = try ProgramAV1Encoder(width: format.size.width, height: format.size.height, frameDuration: format.rate.duration,
      bitrate: format.videoMbps * 1_000_000)
    self.dropped = dropped
    self.failed = failed
    let channel = AsyncStream.makeStream(of: CMSampleBuffer.self, bufferingPolicy: .bufferingOldest(8))
    output = channel.stream
    continuation = channel.continuation
  }

  func append(_ sample: CMSampleBuffer) {
    guard lock.withLock({
      guard pending < 8 else { return false }
      pending += 1
      return true
    }) else { dropped(); return }
    do {
      let packet = try encoder.encode(sample)
      if case .enqueued = continuation.yield(packet) { return }
    } catch {}
    releaseOutputSlot()
    failed()
  }

  func releaseOutputSlot() { lock.withLock { pending -= 1 } }
  func finish() { continuation.finish() }
}

func makeProgramStreamAV1Encoder(format: ProgramStreamFormat, dropped: @escaping @Sendable () -> Void,
                                 failed: @escaping @Sendable () -> Void) throws -> any ProgramStreamVideoEncoding {
  try ProgramStreamSoftwareAV1(format: format, dropped: dropped, failed: failed)
}
#elseif canImport(RTMPHaishinKit)
func makeProgramStreamAV1Encoder(format: ProgramStreamFormat, dropped: @escaping @Sendable () -> Void,
                                 failed: @escaping @Sendable () -> Void) throws -> any ProgramStreamVideoEncoding {
  throw ProgramStreamPublisherError.encoderUnavailable
}
#endif
