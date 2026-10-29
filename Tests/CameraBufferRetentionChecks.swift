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
}
