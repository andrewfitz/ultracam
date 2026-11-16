import CoreMedia
import CoreMediaIO
import CoreVideo
import XCTest

@objcMembers final class CameraBufferRetentionChecks: XCTestCase {
  private func sample() throws -> CMSampleBuffer {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    return try VideoContract.sample(XCTUnwrap(image), at: .zero, duration: CMTime(value: 1, timescale: 30))
  }

  func testDequeuedConsumerStillConsumesBudgetUntilReleased() throws {
    var raw: CMSimpleQueue?
    XCTAssertEqual(CMSimpleQueueCreate(allocator: nil, capacity: 8, queueOut: &raw), noErr)
    let queue = CameraBufferQueue(try XCTUnwrap(raw), retentionPolicy:
      try MediaRetentionPolicy(maximumBytes: 1_000_000, maximumDuration: 0.04))
    let input = try sample()
    XCTAssertTrue(try queue.send(input))
    let token = try XCTUnwrap(CMSimpleQueueDequeue(queue.queue))
    XCTAssertFalse(try queue.send(input), "Dequeuing transfers ownership; it does not release retained media")
    XCTAssertEqual(queue.retentionSnapshot.currentSlots, 1)
    Unmanaged<CMSampleBuffer>.fromOpaque(token).release()
    XCTAssertEqual(queue.retentionSnapshot.currentSlots, 0)
    XCTAssertTrue(try queue.send(input), "Keeping the original sample must not retain the transport lease")
    queue.drain()
    XCTAssertEqual(queue.retentionSnapshot.currentSlots, 0)
  }

  func testHardBytesRejectBeforeEnqueueAndClosePreservesConsumer() throws {
    var raw: CMSimpleQueue?
    XCTAssertEqual(CMSimpleQueueCreate(allocator: nil, capacity: 8, queueOut: &raw), noErr)
    let queue = CameraBufferQueue(try XCTUnwrap(raw), retentionPolicy:
      try MediaRetentionPolicy(maximumBytes: 1, maximumDuration: 1, minimumSlots: 2))
    XCTAssertFalse(try queue.send(sample()))
    XCTAssertEqual(CMSimpleQueueGetCount(queue.queue), 0)
    XCTAssertEqual(queue.retentionSnapshot.currentBytes, 0)
    XCTAssertEqual(queue.retentionSnapshot.rejected, 1)
    queue.close()
    XCTAssertThrowsError(try queue.send(sample()))
  }

  func testTransportLeaseStaysOutOfSerializedSampleMetadata() throws {
    var raw: CMSimpleQueue?
    XCTAssertEqual(CMSimpleQueueCreate(allocator: nil, capacity: 8, queueOut: &raw), noErr)
    let queue = CameraBufferQueue(try XCTUnwrap(raw))
    let input = try sample()
    XCTAssertTrue(try queue.send(input, pauseAllowanceAttachment: NSNumber(value: 0.5)))
    let token = try XCTUnwrap(CMSimpleQueueDequeue(queue.queue))
    let owner = Unmanaged<CMSampleBuffer>.fromOpaque(token)
    autoreleasepool {
      let transport = owner.takeUnretainedValue()
      XCTAssertEqual((CMGetAttachment(transport, key: VideoContract.sourcePauseAllowanceAttachmentKey,
        attachmentModeOut: nil) as? NSNumber)?.doubleValue, 0.5)
      XCTAssertNil(CMGetAttachment(input, key: VideoContract.sourcePauseAllowanceAttachmentKey,
        attachmentModeOut: nil))
      for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
        let attachments = CMCopyDictionaryOfAttachments(allocator: nil, target: transport, attachmentMode: mode)
        if let attachments {
          XCTAssertTrue(PropertyListSerialization.propertyList(attachments, isValidFor: .binary),
            "CMIO serializes sample attachments even when marked ShouldNotPropagate")
          XCTAssertNil((attachments as NSDictionary)["org.ultracam.camera.transport-retention"])
        }
      }
    }
    XCTAssertEqual(queue.retentionSnapshot.currentSlots, 1,
      "The local lease must remain alive while CMIO owns the dequeued sample")
    owner.release()
    XCTAssertEqual(queue.retentionSnapshot.currentSlots, 0)
  }
}
