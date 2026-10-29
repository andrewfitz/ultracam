import CoreMedia
import Foundation
import XCTest

private final class FrameReleaseCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

@objcMembers final class ProcessedFrameChecks: XCTestCase {
  private func metadata(_ value: Int64) -> ProcessedFrameMetadata {
    ProcessedFrameMetadata(presentationTime: CMTime(value: value, timescale: 60_000),
      duration: VideoContract.fastDuration, width: 1920, height: 1080,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
  }

  private func frame(_ value: Int64, released counter: FrameReleaseCounter? = nil)
    -> ProcessedFrame<Int> {
    ProcessedFrame(payload: Int(value), metadata: metadata(value),
      onReleased: counter?.increment)
  }

  func testOneProcessedFrameHasIndependentRouteLeases() throws {
    let counter = FrameReleaseCounter()
    var source: ProcessedFrame<Int>? = frame(7, released: counter)
    let fanOut = FrameFanOut<Int>(label: "processed-frame-test-independent")
    let preview = try fanOut.addRoute(id: "preview", capacity: 2, policy: .reject)
    let camera = try fanOut.addRoute(id: "camera", capacity: 2, policy: .reject)

    XCTAssertEqual(fanOut.publish(try XCTUnwrap(source))["preview"], .enqueued)
    XCTAssertEqual(preview.pendingCount, 1)
    XCTAssertEqual(camera.pendingCount, 1)
    let previewLease = try XCTUnwrap(preview.dequeue())
    let cameraLease = try XCTUnwrap(camera.dequeue())
    XCTAssertEqual(previewLease.payload, 7)
    XCTAssertEqual(cameraLease.metadata?.presentationTime, metadata(7).presentationTime)

    previewLease.release()
    XCTAssertTrue(previewLease.isReleased)
    source = nil
    XCTAssertEqual(counter.count, 0, "The camera route still owns the processed frame")
    XCTAssertEqual(cameraLease.payload, 7)
    cameraLease.release()
    XCTAssertEqual(counter.count, 1)
    cameraLease.release()
    XCTAssertEqual(counter.count, 1, "Release is idempotent")
    fanOut.close()
  }

  func testRejectPreservesPendingFrame() throws {
    let rejectFanOut = FrameFanOut<Int>(label: "processed-frame-test-reject")
    let rejectRoute = try rejectFanOut.addRoute(id: "camera", capacity: 1, policy: .reject)
    var accepted: ProcessedFrame<Int>? = frame(20)
    var rejected: ProcessedFrame<Int>? = frame(21)
    XCTAssertEqual(rejectFanOut.publish(try XCTUnwrap(accepted))["camera"], .enqueued)
    XCTAssertEqual(rejectFanOut.publish(try XCTUnwrap(rejected))["camera"], .rejected)
    XCTAssertEqual(rejectFanOut.publishSummary(try XCTUnwrap(rejected)),
      FrameFanOutSummary(enqueued: 0, rejected: 1, routerClosed: false))
    XCTAssertEqual(rejectRoute.pendingCount, 1, "A full route never evicts a pending frame")
    accepted = nil
    rejected = nil
    XCTAssertEqual(try XCTUnwrap(rejectRoute.dequeue()?.payload), 20)
    rejectFanOut.close()
  }

  func testCancellationOnlyDrainsItsRoute() throws {
    let counter = FrameReleaseCounter()
    let fanOut = FrameFanOut<Int>(label: "processed-frame-test-cancel")
    let cancelled = try fanOut.addRoute(id: "preview", capacity: 2, policy: .reject)
    let remaining = try fanOut.addRoute(id: "camera", capacity: 2, policy: .reject)
    var source: ProcessedFrame<Int>? = frame(30, released: counter)
    _ = fanOut.publish(try XCTUnwrap(source))
    let remainingLease = try XCTUnwrap(remaining.dequeue())
    cancelled.cancel()
    cancelled.cancel()
    XCTAssertTrue(cancelled.isCancelled)
    XCTAssertEqual(cancelled.pendingCount, 0)
    XCTAssertEqual(remainingLease.payload, 30)
    source = nil
    XCTAssertEqual(counter.count, 0)
    remainingLease.release()
    XCTAssertEqual(counter.count, 1)
    fanOut.close()
  }

  func testCloseDrainsPendingButKeepsDequeuedLeaseValid() throws {
    let counter = FrameReleaseCounter()
    let fanOut = FrameFanOut<Int>(label: "processed-frame-test-close")
    let route = try fanOut.addRoute(id: "camera", capacity: 2, policy: .reject)
    var source: ProcessedFrame<Int>? = frame(40, released: counter)
    _ = fanOut.publish(try XCTUnwrap(source))
    let dequeued = try XCTUnwrap(route.dequeue())
    source = nil
    fanOut.close()
    XCTAssertTrue(fanOut.isClosed)
    XCTAssertTrue(route.isCancelled)
    XCTAssertEqual(dequeued.payload, 40, "Teardown cannot invalidate an in-use lease")
    XCTAssertEqual(counter.count, 0)
    dequeued.release()
    XCTAssertEqual(counter.count, 1)
    fanOut.close()
  }

  func testInvalidAndDuplicateRoutesAreRejected() throws {
    let fanOut = FrameFanOut<Int>(label: "processed-frame-test-routes")
    XCTAssertThrowsError(try fanOut.addRoute(id: "", capacity: 1, policy: .reject)) { error in
      XCTAssertEqual(error as? FrameFanOutError, .invalidRouteID)
    }
    XCTAssertThrowsError(try fanOut.addRoute(id: "camera", capacity: 0, policy: .reject)) { error in
      XCTAssertEqual(error as? FrameFanOutError, .invalidCapacity)
    }
    _ = try fanOut.addRoute(id: "camera", capacity: 1, policy: .reject)
    XCTAssertThrowsError(try fanOut.addRoute(id: "camera", capacity: 1, policy: .reject)) { error in
      XCTAssertEqual(error as? FrameFanOutError, .duplicateRoute("camera"))
    }
    fanOut.close()
    XCTAssertThrowsError(try fanOut.addRoute(id: "after-close", capacity: 1, policy: .reject)) { error in
      XCTAssertEqual(error as? FrameFanOutError, .routerClosed)
    }
  }

  func testCancelledRouteHandleCannotControlReusedID() throws {
    let fanOut = FrameFanOut<Int>(label: "processed-frame-test-route-generation")
    let oldRoute = try fanOut.addRoute(id: "preview", capacity: 1, policy: .reject)
    oldRoute.cancel()
    let replacement = try fanOut.addRoute(id: "preview", capacity: 1, policy: .reject)

    XCTAssertTrue(oldRoute.isCancelled)
    XCTAssertEqual(oldRoute.pendingCount, 0)
    XCTAssertNil(oldRoute.dequeue())

    let source = frame(50)
    XCTAssertEqual(fanOut.publish(source)["preview"], .enqueued)
    XCTAssertEqual(replacement.pendingCount, 1)
    oldRoute.cancel()
    XCTAssertEqual(replacement.pendingCount, 1, "A stale handle must not cancel a replacement route")
    XCTAssertEqual(try XCTUnwrap(replacement.dequeue()?.payload), 50)
    fanOut.close()
  }

  func testReleaseCallbacksCanMutateRouterDuringDrain() throws {
    let fanOut = FrameFanOut<Int>(label: "processed-frame-test-reentrant-drain")
    let first = try fanOut.addRoute(id: "first", capacity: 1, policy: .reject)
    let second = try fanOut.addRoute(id: "second", capacity: 1, policy: .reject)
    var source: ProcessedFrame<Int>? = ProcessedFrame(
      payload: 60,
      metadata: metadata(60),
      onReleased: { second.cancel() })
    _ = fanOut.publish(try XCTUnwrap(source))
    // Leave the second route empty so the callback from releasing the first
    // route mutates the route dictionary while drain is iterating it.
    _ = second.dequeue()
    source = nil
    fanOut.drain()
    XCTAssertFalse(first.isCancelled)
    XCTAssertTrue(second.isCancelled)
    XCTAssertEqual(first.pendingCount, 0)
    fanOut.close()
  }

}
