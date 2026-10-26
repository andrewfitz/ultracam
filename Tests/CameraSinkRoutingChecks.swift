import CoreMedia
import CoreMediaIO
import CoreVideo
import XCTest

@objcMembers final class CameraSinkRoutingChecks: XCTestCase {
  private func sample(at time: CMTime = CMTime(value: 60_000, timescale: 60_000)) throws -> CMSampleBuffer {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    return try VideoContract.sample(XCTUnwrap(image), at: time, duration: VideoContract.fastDuration)
  }

  private func queue(capacity: Int32 = 2) throws -> CameraBufferQueue {
    var raw: CMSimpleQueue?
    XCTAssertEqual(CMSimpleQueueCreate(allocator: kCFAllocatorDefault, capacity: capacity, queueOut: &raw), noErr)
    return CameraBufferQueue(try XCTUnwrap(raw))
  }

  func testFeedRoutesMatchExtensionDescriptorAndRemainDistinct() {
    let alpha = FeedID(rawValue: "feed-alpha")
    let beta = FeedID(rawValue: "feed-beta")
    let alphaRoute = CameraSinkRoute(feedID: alpha)
    let betaRoute = CameraSinkRoute(feedID: beta)
    let alphaDescriptor = VirtualCameraDescriptor.feed(feedID: alpha.rawValue)

    XCTAssertEqual(alphaRoute.deviceUID, alphaDescriptor.deviceUID)
    XCTAssertEqual(alphaRoute.sourceStreamName, alphaDescriptor.displayName)
    XCTAssertEqual(alphaRoute.sinkStreamName, "\(alphaDescriptor.displayName) Input")
    XCTAssertEqual(alphaRoute.feedID, alpha.rawValue)
    XCTAssertNotEqual(alphaRoute.deviceUID, betaRoute.deviceUID)
    XCTAssertNotEqual(alphaRoute.sinkStreamName, betaRoute.sinkStreamName)
    XCTAssertNotEqual(alphaRoute.sourceStreamName, betaRoute.sourceStreamName)
  }

  @MainActor func testDemandFindsSourceStreamAfterCameraRename() {
    // The extension published these names before "Feed 1" became "Camera 1".
    let published: [(id: UInt32, name: String)] = [(7, "Ultracam · Feed 1 Input"), (8, "Ultracam · Feed 1")]
    XCTAssertEqual(CameraDemandMonitor.sourceStream(published, named: "Ultracam · Camera 1"), 8)
    XCTAssertEqual(CameraDemandMonitor.sourceStream(published, named: "Ultracam · Feed 1"), 8)
    XCTAssertNil(CameraDemandMonitor.sourceStream([(7, "Ultracam · Feed 1 Input")], named: "Ultracam · Camera 1"))
  }

  @MainActor func testSourceNamedInputIsNotChosenAsTheSink() {
    let streams: [(id: UInt32, name: String, direction: UInt32?)] = [
      (1, "Input Cam", nil),
      (2, "Input Cam Input", nil),
    ]
    let paired = CameraStreamNames.pair(streams, sinkName: "Renamed Input", sourceName: "Renamed")
    XCTAssertEqual(paired?.sink, 2)
    XCTAssertEqual(paired?.source, 1)
    XCTAssertEqual(CameraDemandMonitor.sourceStream([(1, "Input Cam"), (2, "Input Cam Input")], named: "Renamed"), 1)
    // DAL direction 0 is an output stream (the sink), 1 an input stream (the source).
    let directed = CameraStreamNames.pair([
      (3, "Not the source", 1),
      (4, "Whatever", 0),
    ], sinkName: "missing", sourceName: "missing")
    XCTAssertEqual(directed?.sink, 4)
    XCTAssertEqual(directed?.source, 3)
  }

  /// The layout the installed extension publishes, read from the live CMIO DAL:
  /// each camera's source reports kCMIOStreamPropertyDirection 1 and its
  /// "… Input" sink reports 0. The expected names deliberately don't match, so
  /// only direction decides. Pairing these the other way round started the
  /// source stream as a viewer and filled its receive queue: every camera frame
  /// was refused as "queue full" and camera apps saw standby black.
  @MainActor func testPublishedDirectionsPairTheInputStreamAsTheSink() {
    let published: [(id: UInt32, name: String, direction: UInt32?)] = [
      (45, "Ultracam · Camera 1", 1),
      (46, "Ultracam · Camera 1 Input", 0),
    ]
    let paired = CameraStreamNames.pair(published, sinkName: "Renamed Input", sourceName: "Renamed")
    XCTAssertEqual(paired?.sink, 46)
    XCTAssertEqual(paired?.source, 45)
    let named = CameraStreamNames.pair(published,
      sinkName: "Ultracam · Camera 1 Input", sourceName: "Ultracam · Camera 1")
    XCTAssertEqual(named?.sink, 46)
    XCTAssertEqual(named?.source, 45)
    // The DAL values are the opposite of the extension's own enum; pin both.
    XCTAssertEqual(CMIOExtensionStream.Direction.sink.rawValue, 1)
    XCTAssertEqual(CameraStreamNames.sinkDirection, 0)
    XCTAssertEqual(CameraStreamNames.sourceDirection, 1)
  }

  /// The camera extension starts with one "default" device until the app
  /// publishes its registry; that device keeps the original identity.
  func testBootstrapDeviceRouteKeepsTheOriginalSingleCameraIdentity() {
    let bootstrap = CameraSinkRoute(descriptor: .feed(feedID: "default", displayName: VideoContract.cameraName))
    XCTAssertEqual(bootstrap.deviceUID, VideoContract.deviceUID)
    XCTAssertEqual(bootstrap.sinkStreamName, VideoContract.sinkName)
    XCTAssertEqual(bootstrap.sourceStreamName, VideoContract.cameraName)
  }

  func testPerFeedQueuesRemainIndependentWhenOneSinkStops() throws {
    let alphaQueue = try queue()
    let betaQueue = try queue()
    let alphaSink = CameraSink(bufferQueue: alphaQueue, feedID: FeedID(rawValue: "alpha"))
    let betaSink = CameraSink(bufferQueue: betaQueue, feedID: FeedID(rawValue: "beta"))

    var alphaFrame: CMSampleBuffer? = try sample()
    var betaFrame: CMSampleBuffer? = try sample(at: CMTime(value: 61_001, timescale: 60_000))
    weak let alphaWeak = alphaFrame
    weak let betaWeak = betaFrame
    XCTAssertTrue(try alphaSink.send(XCTUnwrap(alphaFrame)))
    XCTAssertTrue(try betaSink.send(XCTUnwrap(betaFrame)))
    alphaFrame = nil
    betaFrame = nil
    XCTAssertNotNil(alphaWeak)
    XCTAssertNotNil(betaWeak)
    XCTAssertEqual(CMSimpleQueueGetCount(alphaQueue.queue), 1)
    XCTAssertEqual(CMSimpleQueueGetCount(betaQueue.queue), 1)

    alphaSink.disconnect()
    XCTAssertEqual(CMSimpleQueueGetCount(alphaQueue.queue), 0)
    XCTAssertNil(alphaWeak, "Stopping one feed must drain only that feed's queue")
    XCTAssertEqual(CMSimpleQueueGetCount(betaQueue.queue), 1)
    XCTAssertNotNil(betaWeak, "The second feed retains its queued frame")

    betaSink.disconnect()
    XCTAssertNil(betaWeak)
  }

  func testFeedCapturePoolCreatesRouteAwareServicesForNewFeeds() {
    let first = FeedID(rawValue: "pool-alpha")
    let second = FeedID(rawValue: "pool-beta")
    let pool = FeedCapturePool()
    let firstController = pool.controller(for: first)
    let secondController = pool.controller(for: second)
    XCTAssertFalse(firstController === secondController)
    XCTAssertEqual(pool.feedIDs.count, 2)
    XCTAssertTrue(pool.feedIDs.contains(first))
    XCTAssertTrue(pool.feedIDs.contains(second))
  }
}
