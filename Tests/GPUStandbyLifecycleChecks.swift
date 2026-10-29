#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class GPUStandbyLifecycleChecks: XCTestCase {
  private final class Pending {
    var callbacks: [@Sendable (Result<GPUStandbyImage, Error>) -> Void] = []
    var requested: [CMVideoFormatDescription] = []
    func submit(_ format: CMVideoFormatDescription, completion: @escaping @Sendable (Result<GPUStandbyImage, Error>) -> Void) {
      requested.append(format); callbacks.append(completion)
    }
  }
  private func image(_ format: CMVideoFormatDescription) throws -> GPUStandbyImage {
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, Int(dimensions.width), Int(dimensions.height),
      CMFormatDescriptionGetMediaSubType(format), [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made), kCVReturnSuccess)
    return GPUStandbyImage(pixelBuffer: try XCTUnwrap(made))
  }

  func testOldCompletionCannotPublishAfterFormatABA() throws {
    let queue = DispatchQueue(label: "standby.lifecycle.format-aba")
    let pending = Pending()
    var ready = 0
    let lifecycle = GPUStandbyLifecycle(queue: queue, submit: pending.submit) { ready += 1 }
    let a = try VideoContract.formatDescription(width: 64, height: 32, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let b = try VideoContract.formatDescription(width: 128, height: 64, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    queue.sync {
      XCTAssertNil(lifecycle.image(for: a))
      lifecycle.invalidate()
      XCTAssertNil(lifecycle.image(for: b))
      lifecycle.invalidate()
      XCTAssertNil(lifecycle.image(for: a))
    }
    pending.callbacks[0](.success(try image(a)))
    queue.sync {
      XCTAssertEqual(ready, 0, "An old A fill cannot satisfy the new A generation")
      XCTAssertEqual(pending.callbacks.count, 2, "B is coalesced into the latest A request")
    }
    pending.callbacks[1](.success(try image(a)))
    queue.sync { XCTAssertEqual(ready, 1) }
  }

  func testStopRestartInvalidatesSameFormatSubmission() throws {
    let queue = DispatchQueue(label: "standby.lifecycle.stop-aba")
    let pending = Pending()
    var ready = 0
    let lifecycle = GPUStandbyLifecycle(queue: queue, submit: pending.submit) { ready += 1 }
    let format = try VideoContract.formatDescription(width: 64, height: 32, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    queue.sync { _ = lifecycle.image(for: format); lifecycle.invalidate(); _ = lifecycle.image(for: format) }
    pending.callbacks[0](.success(try image(format)))
    queue.sync { XCTAssertEqual(ready, 0, "A stopped run must never complete the replacement run") }
    pending.callbacks[1](.success(try image(format)))
    queue.sync { XCTAssertEqual(ready, 1) }
  }

  func testRapidFormatGenerationsKeepOnlyOneSubmittedFillAndCoalesceLatest() throws {
    let queue = DispatchQueue(label: "standby.lifecycle.bounded-generations")
    let pending = Pending()
    var ready = 0
    let lifecycle = GPUStandbyLifecycle(queue: queue, submit: pending.submit) { ready += 1 }
    let a = try VideoContract.formatDescription(width: 64, height: 32, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let b = try VideoContract.formatDescription(width: 128, height: 64, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    queue.sync {
      _ = lifecycle.image(for: a)
      for index in 0..<100 {
        lifecycle.invalidate()
        _ = lifecycle.image(for: index % 2 == 0 ? b : a)
      }
      XCTAssertEqual(pending.callbacks.count, 1, "Withheld GPU feedback must not permit new generations to allocate more images")
    }
    pending.callbacks[0](.success(try image(a)))
    queue.sync {
      XCTAssertEqual(ready, 0, "Even the same A layout must not reuse a stale generation")
      XCTAssertEqual(pending.callbacks.count, 2, "Only latest desired generation starts after the outstanding fill finishes")
      XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(pending.requested.last!).width, 64)
    }
    // Stop the replacement too; its completion must not start a third fill.
    queue.sync { lifecycle.invalidate() }
    pending.callbacks[1](.success(try image(a)))
    queue.sync { XCTAssertEqual(ready, 0); XCTAssertEqual(pending.callbacks.count, 2) }
  }

  func testSubmissionAndGPUFailureDoNotRetryOrFallback() throws {
    let queue = DispatchQueue(label: "standby.lifecycle.failure")
    let format = try VideoContract.formatDescription(width: 64, height: 32, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    var attempts = 0
    let failed = GPUStandbyLifecycle(queue: queue, submit: { _, _ in attempts += 1; throw VideoError.message("injected allocation failure") }, ready: { XCTFail("Failed submission published") })
    queue.sync {
      for _ in 0..<5 { XCTAssertNil(failed.image(for: format)) }
      XCTAssertEqual(attempts, 1); XCTAssertEqual(failed.failureCount, 1)
      XCTAssertTrue(failed.lastError?.contains("allocation") == true)
    }
    let pending = Pending()
    let async = GPUStandbyLifecycle(queue: queue, submit: pending.submit, ready: { XCTFail("Failed GPU work published") })
    queue.sync { for _ in 0..<5 { XCTAssertNil(async.image(for: format)) }; XCTAssertEqual(pending.callbacks.count, 1) }
    pending.callbacks[0](.failure(VideoError.message("injected GPU failure")))
    queue.sync { XCTAssertNil(async.image(for: format)); XCTAssertEqual(async.failureCount, 1); XCTAssertEqual(pending.callbacks.count, 1) }
  }
}
#endif
