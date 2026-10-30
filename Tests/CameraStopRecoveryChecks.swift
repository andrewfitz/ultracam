import CoreMedia
import CoreVideo
import XCTest

@objcMembers final class CameraStopRecoveryChecks: XCTestCase {
  func testFailedStopPreservesLiveQueueAndCapacityUntilConfirmedRetry() throws {
    var pending: (() -> Void)?
    let recovery = CameraStreamStopRecovery(capacity: 1, schedule: { pending = $0 })
    var raw: CMSimpleQueue?
    XCTAssertEqual(CMSimpleQueueCreate(allocator: nil, capacity: 2, queueOut: &raw), noErr)
    let queue = CameraBufferQueue(try XCTUnwrap(raw))
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    weak let storage = image
    var sample: CMSampleBuffer? = try VideoContract.sample(XCTUnwrap(image), at: .zero,
      duration: VideoContract.fastDuration)
    XCTAssertTrue(try queue.send(XCTUnwrap(sample)))
    sample = nil; image = nil
    var stopped = false, attempts = 0
    let token = try recovery.reserve(deviceID: 1, streamID: 2, queue: queue, stop: { attempts += 1; return stopped ? noErr : -1 })
    recovery.stop(token)
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(recovery.retainedStreams, 1)
    XCTAssertEqual(CMSimpleQueueGetCount(queue.queue), 1, "Failed stop must not dequeue a live consumer's queue")
    XCTAssertNotNil(storage)
    XCTAssertEqual(queue.retentionSnapshot.currentSlots, 1)
    XCTAssertThrowsError(try recovery.reserve(deviceID: 3, streamID: 4, queue: queue, stop: { noErr }))
    XCTAssertNotNil(pending)
    stopped = true
    let retry = pending; pending = nil; retry?()
    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(recovery.retainedStreams, 0)
    XCTAssertEqual(CMSimpleQueueGetCount(queue.queue), 0)
    XCTAssertNil(storage)
    XCTAssertEqual(queue.retentionSnapshot.currentSlots, 0)
    XCTAssertNil(pending)
    recovery.stop(token)
    XCTAssertEqual(attempts, 2, "Successful quiescence is drained once")
  }

  func testPendingStopRejectsSameNativeIdentityDespiteSpareCapacity() throws {
    var pending: (() -> Void)?
    let recovery = CameraStreamStopRecovery(capacity: 4, schedule: { pending = $0 })
    var raw: CMSimpleQueue?
    XCTAssertEqual(CMSimpleQueueCreate(allocator: nil, capacity: 2, queueOut: &raw), noErr)
    let queue = CameraBufferQueue(try XCTUnwrap(raw))
    var stopped = false
    let old = try recovery.reserve(deviceID: 10, streamID: 20, queue: queue, stop: { stopped ? noErr : -1 })
    recovery.stop(old)
    XCTAssertEqual(recovery.retainedStreams, 1)
    XCTAssertThrowsError(try recovery.reserve(deviceID: 10, streamID: 20, queue: queue, stop: { noErr }),
      "An old retry must never be able to stop a reconnected native stream")
    let other = try recovery.reserve(deviceID: 10, streamID: 21, queue: queue, stop: { noErr })
    recovery.stop(other)
    stopped = true
    let retry = pending; pending = nil; retry?()
    XCTAssertEqual(recovery.retainedStreams, 0)
    let replacement = try recovery.reserve(deviceID: 10, streamID: 20, queue: queue, stop: { noErr })
    recovery.stop(replacement)
    XCTAssertEqual(recovery.retainedStreams, 0)
  }
}
