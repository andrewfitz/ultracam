#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import XCTest

@objcMembers final class DeckLinkReusableConformanceChecks: XCTestCase {
  func testActualAdapterSharedStopBarrier() throws {
    let session = DeckLinkCaptureSession()
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    let buffer = CapturedPixelBuffer(immutable: try XCTUnwrap(image))
    try PluginConformanceHarness.serializedStopBarrier(session: session,
      start: { session.startFixture(handlers: $0) },
      emit: { session.deliverFixtureFrame(buffer.value, at: CMTime(value: 1, timescale: 1)) })
  }
  func testActualAdapterUsesSharedTranscriptOracle() throws {
    let session = DeckLinkCaptureSession()
    let recorder = NativeConformanceRecorder()
    session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    session.deliverFixtureFrame(try XCTUnwrap(image), at: CMTime(value: 1, timescale: 1))
    session.stop()
    let values = recorder.values
    var oracle = PluginConformanceHarness.Transcript()
    for value in values { try oracle.accept(value) }
    XCTAssertTrue(values.contains { if case .frame = $0.payload { true } else { false } })
    XCTAssertThrowsError(try oracle.accept(try XCTUnwrap(values.last)))
    session.deliverFixtureFrame(try XCTUnwrap(image), at: CMTime(value: 2, timescale: 1))
    XCTAssertEqual(recorder.values.count, values.count)
  }
}
private final class NativeConformanceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CaptureDelivery] = []
  var values: [CaptureDelivery] { lock.withLock { storage } }
  func append(_ value: CaptureDelivery) { lock.withLock { storage.append(value) } }
}
#endif
