import CoreMedia
import CoreVideo
import IOSurface
import XCTest

@MainActor @objcMembers final class ProgramOutputRouteChecks: XCTestCase {
  private func feed(_ id: String) -> FeedID { FeedID(rawValue: id) }
  private func mediaTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 60_000)
  }

  private func frame(_ id: FeedID, at seconds: Double) throws -> ProcessedFrame<CVPixelBuffer> {
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
      kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image)
    guard status == kCVReturnSuccess, let image else {
      throw VideoError.message("Cannot create Program test frame.")
    }
    return ProcessedFrame(payload: image, metadata: ProcessedFrameMetadata(
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 60_000),
      duration: VideoContract.fastDuration, width: 2, height: 2,
      pixelFormat: UInt32(kCVPixelFormatType_32BGRA)))
  }

  func testProgramRoutePublishesSelectedFeedOnlyAndCutsAtBoundary() throws {
    let a = feed("alpha")
    let b = feed("beta")
    let route = ProgramOutputRoute(feedIDs: [a, b])
    let consumer = try route.addConsumerRoute(capacity: 4)

    guard case .accepted = route.ingest(feedID: a, frame: try frame(a, at: 0)).decision else {
      return XCTFail("Initial selected feed should establish the program timeline")
    }
    let skipped = route.ingest(feedID: b, frame: try frame(b, at: 0.033))
    XCTAssertEqual(skipped.fanOut.enqueued, 0, "A non-selected source publishes nothing")
    XCTAssertEqual(route.statistics.skippedNonSelected, 1, "Every skip is counted by reason")
    guard case .queued = route.requestCut(to: b) else {
      return XCTFail("Manual Program cut should queue")
    }
    guard case .cutApplied = route.ingest(feedID: b, frame: try frame(b, at: 0)).decision else {
      return XCTFail("Target feed should apply at its next valid frame")
    }
    XCTAssertEqual(consumer.pendingCount, 2,
      "Frames already on air before the cut are still delivered, in order")
    let onAir = try XCTUnwrap(consumer.dequeue())
    XCTAssertEqual(onAir.metadata?.presentationTime, .zero)
    onAir.release()
    let first = try XCTUnwrap(consumer.dequeue())
    let firstTime = try XCTUnwrap(first.metadata?.presentationTime)
    first.release()
    XCTAssertEqual(consumer.pendingCount, 0)
    XCTAssertEqual(CMTimeCompare(firstTime, VideoContract.fastDuration), 0,
      "The first frame after a cut starts at the next Program timeline boundary")
  }

  func testProgramCutHonorsEarliestMediaTimeFromAutoDirector() throws {
    let a = feed("alpha")
    let b = feed("beta")
    let route = ProgramOutputRoute(feedIDs: [a, b])
    guard case .accepted = route.ingest(feedID: a, frame: try frame(a, at: 0)).decision else {
      return XCTFail("Initial Program frame should be accepted")
    }
    guard case .queued = route.requestCut(to: b, noEarlierThan: mediaTime(1)) else {
      return XCTFail("Timestamped cut should queue")
    }
    guard case .skipped(.staleQueuedFrame) = route.ingest(feedID: b,
      frame: try frame(b, at: 0.5)).decision else {
      return XCTFail("A target frame before cutTime must not apply the cut")
    }
    guard case .cutApplied = route.ingest(feedID: b, frame: try frame(b, at: 1)).decision else {
      return XCTFail("The first target frame at cutTime should apply the cut")
    }
  }

  func testFeedCoordinatorMutatesTheLiveProgramScheduler() throws {
    let a = FeedDescriptor(id: feed("alpha"), name: "Wide")
    let b = FeedDescriptor(id: feed("beta"), name: "Tight")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(
      feeds: [a, b], outputMode: .program))
    guard case .accepted = coordinator.ingestProgramFrame(feedID: a.id,
      frame: try frame(a.id, at: 0))?.decision else {
      return XCTFail("The initial Program source should be accepted")
    }

    coordinator.setSwitcher(SwitcherSettings(selectedFeedID: b.id, automatic: false,
      intervalSeconds: 30, strategy: .fixedInterval))
    XCTAssertEqual(coordinator.programOutput.pendingFeedID, b.id,
      "Settings and manual requests must target the scheduler used by ingest")
    guard case .cutApplied = coordinator.ingestProgramFrame(feedID: b.id,
      frame: try frame(b.id, at: 0))?.decision else {
      return XCTFail("The requested Program cut should apply at the next target frame")
    }
  }

  func testProgramRouteReconfigurationKeepsOnlyEnabledFeeds() throws {
    let a = feed("alpha")
    let b = feed("beta")
    let route = ProgramOutputRoute(feedIDs: [a, b])
    XCTAssertEqual(route.selectedFeedID, a)
    route.updateFeeds([b])
    XCTAssertEqual(route.selectedFeedID, b)
    XCTAssertFalse(route.hasPendingCut)
  }

  func testProgramRouteResetDrainsOldTimelineFrames() throws {
    let source = feed("alpha")
    let route = ProgramOutputRoute(feedIDs: [source])
    let consumer = try route.addConsumerRoute(capacity: 4)
    guard case .accepted = route.ingest(feedID: source, frame: try frame(source, at: 0)).decision else {
      return XCTFail("Initial Program frame should be accepted")
    }
    XCTAssertEqual(consumer.pendingCount, 1)
    route.reset()
    XCTAssertEqual(consumer.pendingCount, 0)
  }

  func testFeedCoordinatorPublishesSeparateOrProgramRegistryAndProgramDemand() throws {
    let a = FeedDescriptor(id: feed("alpha"), name: "Wide")
    let b = FeedDescriptor(id: feed("beta"), name: "Tight")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(feeds: [a, b]))
    XCTAssertEqual(coordinator.virtualCameraDescriptors.map(\.kind), [.feed, .feed])
    coordinator.setOutputMode(.program)
    XCTAssertEqual(coordinator.virtualCameraDescriptors.map(\.kind), [.program])

    let start = coordinator.setProgramConsumer(true, at: 0)
    XCTAssertEqual(start, [.start(feedID: "alpha")])
    XCTAssertEqual(coordinator.activeDemandFeedIDs, Set(["alpha"]))
    let stop = coordinator.setProgramConsumer(false, at: 1)
    XCTAssertEqual(stop, [.stop(feedID: "alpha")])
    XCTAssertTrue(coordinator.activeDemandFeedIDs.isEmpty)
  }

  func testSelectionWithNothingOnAirChangesAtOnce() {
    let a = FeedDescriptor(id: feed("alpha"), name: "Wide")
    let b = FeedDescriptor(id: feed("beta"), name: "Tight")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(
      feeds: [a, b], outputMode: .separateCameras,
      switcher: SwitcherSettings(selectedFeedID: a.id)))

    XCTAssertEqual(coordinator.programOutput.selectedFeedID, a.id)
    // Nothing is on air in separate-camera mode, so there is no cut to wait
    // for: the selection, the saved value and the route agree at once.
    coordinator.setSwitcher(SwitcherSettings(selectedFeedID: b.id))
    coordinator.setOutputMode(.program)
    XCTAssertEqual(coordinator.programOutput.selectedFeedID, b.id)
    XCTAssertNil(coordinator.programOutput.pendingFeedID)
    XCTAssertEqual(coordinator.snapshot.switcher.selectedFeedID, b.id)
  }

  func testProgramBridgePreservesImageAndTimingAndOwnsDemandLifecycle() throws {
    let source = feed("alpha")
    let route = ProgramOutputRoute(feedIDs: [source])
    let consumer = try route.addConsumerRoute(capacity: 4)
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
      kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    guard let image else { return XCTFail("Program image allocation failed") }
    let timestamp = CMTime.zero
    let frame = ProcessedFrame(payload: image, metadata: ProcessedFrameMetadata(
      presentationTime: timestamp, duration: VideoContract.fastDuration, width: 2,
      height: 2, pixelFormat: UInt32(kCVPixelFormatType_32BGRA)))
    var connects = 0
    var disconnects = 0
    var sent: [CMSampleBuffer] = []
    let hostNow = CMTime(value: 5_000, timescale: 1_000)
    let bridge = ProgramOutputBridge(route: consumer,
      connect: { _, _ in connects += 1 },
      disconnect: { disconnects += 1 },
      send: { sample in sent.append(sample); return true }, hostClock: { hostNow })
    try bridge.setDemand(true, configuration: PipelineConfiguration(),
      passthroughFormat: kCVPixelFormatType_32BGRA)
    _ = route.ingest(feedID: source, frame: frame)
    bridge.pump()
    XCTAssertEqual(connects, 1)
    XCTAssertEqual(sent.count, 1)
    XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sent[0]), hostNow), 0,
      "Program time (zero for the first frame) goes out anchored on the host clock")
    XCTAssertEqual(CMSampleBufferGetDuration(sent[0]), VideoContract.fastDuration)
    XCTAssertEqual(CMSampleBufferGetImageBuffer(sent[0]), image)
    XCTAssertEqual(bridge.currentStatistics.delivered, 1)
    XCTAssertEqual(consumer.pendingCount, 0)

    bridge.disconnect()
    XCTAssertEqual(disconnects, 1)
    XCTAssertFalse(bridge.isDemanded)
    XCTAssertFalse(bridge.isConnected)
  }

  /// Host time keeps the Program clock's spacing through delivery jitter of up to
  /// two frames, and after a short gap on air (Program time continues where it left
  /// off, real time moved on) the next frames go out at real time, not the gap late.
  func testProgramBridgeReanchorsAfterAShortGapButNotOnJitter() throws {
    let source = feed("alpha")
    let route = ProgramOutputRoute(feedIDs: [source])
    let consumer = try route.addConsumerRoute(capacity: 4)
    final class Clock { var now = CMTime(value: 1_000 * 60_000, timescale: 60_000) }
    let clock = Clock()
    var sent: [CMTime] = []
    let bridge = ProgramOutputBridge(route: consumer, connect: { _, _ in }, disconnect: {},
      send: { sample in sent.append(CMSampleBufferGetPresentationTimeStamp(sample)); return true },
      hostClock: { clock.now })
    try bridge.setDemand(true, configuration: PipelineConfiguration(),
      passthroughFormat: kCVPixelFormatType_32BGRA)
    let image = try frame(source, at: 0).payload
    let start = clock.now
    // `frames` Program frame durations (1001/60000 s) after `start`, plus `extra`.
    func host(_ frames: Double, extra: CMTime = .zero) -> CMTime {
      CMTimeAdd(CMTimeAdd(start, CMTime(value: CMTimeValue((frames * 1001).rounded()), timescale: 60_000)), extra)
    }
    func deliver(_ index: Int, at time: CMTime) {
      clock.now = time
      _ = route.ingest(feedID: source, frame: processed(image, at: Int64(index)))
      bridge.pump()
    }
    // Each frame up to 1.9 frames late or 0.9 early.
    let jitter = [0, 1.5, -0.9, 0.7, 1.9, -0.5, 0.2, 1.2]
    for (index, offset) in jitter.enumerated() { deliver(index, at: host(Double(index) + offset)) }
    XCTAssertEqual(sent, (0..<8).map { host(Double($0)) }, "Jitter within two frames keeps the anchor")

    let gap = CMTime(value: 12_000, timescale: 60_000)  // 0.2 s
    for index in 8..<11 { deliver(index, at: host(Double(index), extra: gap)) }
    XCTAssertEqual(Array(sent.suffix(3)), (8..<11).map { host(Double($0), extra: gap) },
      "After a gap the frames go out at real time, spaced as Program")
    XCTAssertEqual(bridge.currentStatistics.delivered, 11)
  }

  func testProgramBridgeReconnectsAfterTransientSinkFailure() throws {
    let source = feed("alpha")
    let route = ProgramOutputRoute(feedIDs: [source])
    let consumer = try route.addConsumerRoute(capacity: 4)
    var connects = 0
    var sends = 0
    let bridge = ProgramOutputBridge(route: consumer,
      connect: { _, _ in connects += 1 }, disconnect: {}, send: { _ in
        sends += 1
        if sends == 1 { throw SinkFailure.disconnected }
        return true
      })

    try bridge.setDemand(true, configuration: PipelineConfiguration(),
      passthroughFormat: kCVPixelFormatType_32BGRA)
    _ = route.ingest(feedID: source, frame: try frame(source, at: 0))
    bridge.pump()
    XCTAssertEqual(bridge.currentStatistics.sendErrors, 1)
    XCTAssertTrue(bridge.isDemanded, "A transient enqueue error must preserve active demand")
    // The reconnect runs on the bridge's control queue, off the frame path.
    bridge.waitUntilIdle()

    _ = route.ingest(feedID: source, frame: try frame(source, at: 1.0 / 30.0))
    bridge.pump()
    XCTAssertEqual(connects, 2, "A failed send reconnects the sink on the control queue")
    XCTAssertEqual(bridge.currentStatistics.delivered, 1)
    XCTAssertTrue(bridge.isConnected)
  }

  // MARK: - Delivery order, drops, threading

  private nonisolated func ioSurfaceFrame(_ width: Int, _ height: Int, _ format: OSType,
                              fill: (CVPixelBuffer) -> Void = { _ in }) throws -> CVPixelBuffer {
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
      &image)
    guard status == kCVReturnSuccess, let image else { throw VideoError.message("allocation failed") }
    CVPixelBufferLockBaseAddress(image, [])
    fill(image)
    CVPixelBufferUnlockBaseAddress(image, [])
    return image
  }

  private nonisolated func processed(_ image: CVPixelBuffer, at index: Int64,
                         duration: CMTime = VideoContract.fastDuration) -> ProcessedFrame<CVPixelBuffer> {
    ProcessedFrame(payload: image, metadata: ProcessedFrameMetadata(
      presentationTime: CMTime(value: index * duration.value, timescale: duration.timescale),
      duration: duration, width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
      pixelFormat: UInt32(CVPixelBufferGetPixelFormatType(image))))
  }

  /// Fills a 10-bit 4:2:2 bi-planar frame: Y = 64 + (x * 7 + y * 3) % 877,
  /// Cb = 512 + x % 100, Cr = 400 + y % 50 (10-bit code values, MSB-aligned).
  private nonisolated func fillX422(_ image: CVPixelBuffer) {
    let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(image, 0) / 2
    let y = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt16.self)
    let cs = CVPixelBufferGetBytesPerRowOfPlane(image, 1) / 2
    let c = CVPixelBufferGetBaseAddressOfPlane(image, 1)!.assumingMemoryBound(to: UInt16.self)
    for row in 0..<height {
      for x in 0..<width { y[row * ys + x] = UInt16(64 + (x * 7 + row * 3) % 877) << 6 }
      for x in 0..<(width / 2) {
        c[row * cs + 2 * x] = UInt16(512 + x % 100) << 6
        c[row * cs + 2 * x + 1] = UInt16(400 + row % 50) << 6
      }
    }
  }

  func testEverySelectedFrameReachesProgramInOrderFromCaptureThreads() throws {
    let a = feed("alpha")
    let b = feed("beta")
    let route = ProgramOutputRoute(feedIDs: [a, b])
    let consumer = try route.addConsumerRoute(capacity: 1_000)
    let image = try frame(a, at: 0).payload
    let frames = 300
    let group = DispatchGroup()
    // Two capture delivery threads, as in the app: A on air, B starting.
    route.setSourceHealth(b, healthy: true)
    let cutRequested = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInteractive).async(group: group) {
      for index in 0..<frames {
        route.ingest(feedID: a, frame: self.processed(image, at: Int64(index)))
        if index == frames / 3 {
          _ = route.requestCut(to: b)
          cutRequested.signal()
        }
      }
    }
    DispatchQueue.global(qos: .userInteractive).async(group: group) {
      cutRequested.wait()  // B finishes opening while A is on air
      for index in 0..<frames { route.ingest(feedID: b, frame: self.processed(image, at: Int64(index))) }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
    let stats = route.statistics
    XCTAssertEqual(stats.mainThreadIngests, 0, "No Program frame touched the main thread")
    XCTAssertEqual(stats.published, stats.accepted, "Every accepted frame was published")
    XCTAssertEqual(stats.overflowRejected, 0)
    XCTAssertEqual(consumer.pendingCount, Int(stats.accepted))
    var last: CMTime?
    var count = 0
    while let lease = consumer.dequeue() {
      let time = try XCTUnwrap(lease.metadata?.presentationTime)
      if let last { XCTAssertGreaterThan(CMTimeCompare(time, last), 0, "Program time is strictly increasing") }
      last = time
      count += 1
      lease.release()
    }
    XCTAssertEqual(count, Int(stats.accepted))
    XCTAssertEqual(route.selectedFeedID, b)
  }

  func testFullCameraRouteIsACountedVisibleErrorNotASilentDrop() throws {
    let source = feed("alpha")
    let route = ProgramOutputRoute(feedIDs: [source])
    let consumer = try route.addConsumerRoute(capacity: 4)
    let events = EventLog()
    route.onEvent = { events.append($0) }
    let image = try frame(source, at: 0).payload
    for index in 0..<6 { route.ingest(feedID: source, frame: processed(image, at: Int64(index))) }
    let stats = route.statistics
    XCTAssertEqual(stats.accepted, 6)
    XCTAssertEqual(stats.published, 4)
    XCTAssertEqual(stats.overflowRejected, 2)
    XCTAssertEqual(consumer.pendingCount, 4)
    XCTAssertEqual(events.errors.count, 1, "The first overflow is reported; counts carry the rest")
    // Oldest frames are kept: the consumer sees an in-order prefix.
    XCTAssertEqual(consumer.dequeue()?.metadata?.presentationTime, .zero)
  }

  func testNoCameraClientMeansNothingIsQueuedOrCountedAsAnError() throws {
    let source = feed("alpha")
    let route = ProgramOutputRoute(feedIDs: [source])
    let consumer = try route.addConsumerRoute(capacity: 2)
    route.setOutput(contract: nil, active: false)
    let image = try frame(source, at: 0).payload
    for index in 0..<5 { route.ingest(feedID: source, frame: processed(image, at: Int64(index))) }
    XCTAssertEqual(consumer.pendingCount, 0)
    XCTAssertEqual(route.statistics.withoutConsumer, 5)
    XCTAssertEqual(route.statistics.overflowRejected, 0)
  }

  func testCaptureDeliveryReachesTheProgramCameraOffTheMainThread() throws {
    let a = FeedDescriptor(id: feed("alpha"), name: "Wide")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(feeds: [a], outputMode: .program))
    let route = try coordinator.addProgramOutputRoute(id: "camera-test", capacity: 64, policy: .reject)
    let sent = EventLog()
    let hostNow = CMTime(value: 100 * 60_000, timescale: 60_000)
    let bridge = ProgramOutputBridge(route: route, connect: { _, _ in }, disconnect: {},
      send: { sample in
        sent.appendSend(Thread.isMainThread, CMSampleBufferGetPresentationTimeStamp(sample))
        return true
      }, hostClock: { hostNow })
    coordinator.attachProgramBridge(bridge)
    var contract = PipelineConfiguration()
    contract.downscale = true
    contract.convertTo420 = true
    try bridge.setDemand(true, configuration: contract, passthroughFormat: kCVPixelFormatType_422YpCbCr10)
    XCTAssertEqual(coordinator.programOutput.contract,
      ProgramOutputFormat(configuration: contract, passthroughFormat: kCVPixelFormatType_422YpCbCr10))
    XCTAssertTrue(coordinator.start(a.id))
    let image = try ioSurfaceFrame(1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let done = expectation(description: "capture thread")
    DispatchQueue.global(qos: .userInteractive).async {
      for index in 0..<30 {
        coordinator.programOutput.ingest(fromCapture: a.id, frame: self.processed(image, at: Int64(index)))
      }
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    bridge.waitUntilIdle()
    XCTAssertEqual(bridge.currentStatistics.delivered, 30)
    XCTAssertEqual(bridge.currentStatistics.mainThreadSends, 0)
    XCTAssertEqual(sent.mainThreadSends, 0)
    XCTAssertEqual(coordinator.programOutput.statistics.mainThreadIngests, 0)
    XCTAssertEqual(sent.times, (0..<30).map { CMTimeAdd(hostNow, CMTime(value: Int64($0) * 1_001, timescale: 60_000)) },
      "One host-clock anchor per connection keeps the Program spacing exact")

    // A cut to a camera with other settings must not renegotiate: the contract
    // is held once frames have gone out on this connection.
    var other = contract
    other.downscale = false
    try bridge.setDemand(true, configuration: other, passthroughFormat: kCVPixelFormatType_422YpCbCr10)
    XCTAssertEqual(bridge.currentStatistics.contractChangesHeld, 1)
    XCTAssertEqual(bridge.contract?.width, 1920)
    // The on-air camera's own change (e.g. cadence detected after the first
    // frame) does renegotiate, and the route converts to the new contract.
    try bridge.setDemand(true, configuration: other, passthroughFormat: kCVPixelFormatType_422YpCbCr10,
      renegotiate: true)
    XCTAssertEqual(bridge.contract?.width, 3840)
    XCTAssertEqual(coordinator.programOutput.contract?.width, 3840)

    // A stopped source's late callbacks are ignored.
    coordinator.stop(a.id)
    XCTAssertNil(coordinator.programOutput.ingest(fromCapture: a.id, frame: processed(image, at: 31)))
  }

  func testCutToStartingCameraWaitsAndFailedStartRollsBackVisibly() throws {
    let a = FeedDescriptor(id: feed("alpha"), name: "Wide")
    let b = FeedDescriptor(id: feed("beta"), name: "Tight")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(feeds: [a, b], outputMode: .program))
    var now: TimeInterval = 0
    coordinator.programOutput.setPendingCutClock({ now }, timeout: 2, startingTimeout: 30)
    let image = try frame(a.id, at: 0).payload
    XCTAssertTrue(coordinator.start(a.id))
    coordinator.setProgramSourceHealth(a.id, healthy: true)
    _ = coordinator.ingestProgramFrame(feedID: a.id, frame: processed(image, at: 0))
    XCTAssertTrue(coordinator.programOutput.isOnAir)
    XCTAssertTrue(coordinator.start(b.id))
    coordinator.setProgramSourceHealth(b.id, healthy: true)  // "Opening UltraStudio…"
    guard case .queued = coordinator.requestProgramCut(to: b.id) else {
      return XCTFail("A cut to a starting camera queues")
    }
    for index in 1...20 {
      now = Double(index)  // 20 s of opening, inside the 30 s starting bound
      _ = coordinator.ingestProgramFrame(feedID: a.id, frame: processed(image, at: Int64(index)))
      _ = coordinator.evaluateSwitcher(at: CMTime(seconds: now, preferredTimescale: 600))
    }
    XCTAssertEqual(coordinator.programOutput.pendingFeedID, b.id, "Still waiting for the first frame")
    XCTAssertEqual(coordinator.switcher.selectedFeedID, a.id, "Saved selection is what is on air")
    XCTAssertEqual(coordinator.snapshot.switcher.selectedFeedID, a.id)

    let abandoned = expectation(description: "abandoned cut reaches the main actor")
    coordinator.onProgramCutAbandoned = { feedID, reason in
      XCTAssertEqual(feedID, b.id)
      XCTAssertEqual(reason, .targetUnavailable)
      abandoned.fulfill()
    }
    coordinator.setProgramSourceHealth(b.id, healthy: false)  // failed to start
    wait(for: [abandoned], timeout: 5)
    XCTAssertNil(coordinator.programOutput.pendingFeedID)
    XCTAssertEqual(coordinator.programOutput.selectedFeedID, a.id)

    // Restarted, it lands on its first frame.
    coordinator.setProgramSourceHealth(b.id, healthy: true)
    guard case .queued = coordinator.requestProgramCut(to: b.id) else { return XCTFail("queues again") }
    let applied = expectation(description: "cut applied reaches the main actor")
    coordinator.onProgramCutApplied = { feedID, _, _ in
      XCTAssertEqual(feedID, b.id)
      applied.fulfill()
    }
    guard case .cutApplied = coordinator.ingestProgramFrame(feedID: b.id, frame: processed(image, at: 0))?.decision else {
      return XCTFail("The first frame lands the cut")
    }
    wait(for: [applied], timeout: 5)
    XCTAssertEqual(coordinator.switcher.selectedFeedID, b.id)
  }

  /// Measures capture delivery → Program camera send, off the main thread,
  /// for a matching (zero-copy) source and a 4K 10-bit source converted on
  /// the GPU, paced at 59.94 fps.
  func testProgramLatencyFromCaptureToCameraSend() throws {
    let a = FeedDescriptor(id: feed("alpha"), name: "Wide")
    let b = FeedDescriptor(id: feed("beta"), name: "Tight")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(feeds: [a, b], outputMode: .program))
    let route = try coordinator.addProgramOutputRoute(id: "latency", capacity: 64, policy: .reject)
    let clock = LatencyClock()
    let bridge = ProgramOutputBridge(route: route, connect: { _, _ in }, disconnect: {},
      send: { sample in clock.sent(CMSampleBufferGetPresentationTimeStamp(sample)); return true })
    coordinator.attachProgramBridge(bridge)
    var contract = PipelineConfiguration()
    contract.downscale = true
    contract.convertTo420 = true
    try bridge.setDemand(true, configuration: contract, passthroughFormat: kCVPixelFormatType_422YpCbCr10)
    XCTAssertTrue(coordinator.start(a.id))
    XCTAssertTrue(coordinator.start(b.id))
    let matching = try ioSurfaceFrame(1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let uhd = try ioSurfaceFrame(3840, 2160, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, fill: fillX422)
    let output = coordinator.programOutput
    let done = expectation(description: "paced capture thread")
    // A strict timer paces the frames: a process started from a background shell
    // or agent has its timers coalesced, and a Thread.sleep(1/59.94) loop then
    // took about 32 s instead of 4 s.
    let pacer = DispatchSource.makeTimerSource(flags: .strict,
      queue: DispatchQueue(label: "paced capture", qos: .userInteractive))
    var index = 0
    pacer.schedule(deadline: .now(), repeating: 1.0 / 59.94, leeway: .nanoseconds(0))
    pacer.setEventHandler {
      if index == 120 {
        _ = output.requestCut(to: b.id)
      }
      let source = index < 120 ? a.id : b.id
      let image = index < 120 ? matching : uhd
      clock.ingest(Int64(index))
      output.ingest(fromCapture: source, frame: self.processed(image, at: Int64(index)))
      index += 1
      if index == 240 {
        pacer.cancel()
        done.fulfill()
      }
    }
    pacer.resume()
    wait(for: [done], timeout: 30)
    bridge.waitUntilIdle()
    let deadline = Date().addingTimeInterval(5)
    while bridge.currentStatistics.delivered < 240, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
      bridge.waitUntilIdle()
    }
    XCTAssertEqual(bridge.currentStatistics.delivered, 240)
    XCTAssertEqual(bridge.currentStatistics.mainThreadSends, 0)
    XCTAssertEqual(output.statistics.mainThreadIngests, 0)
    XCTAssertEqual(output.statistics.overflowRejected, 0)
    let passthrough = clock.latencies(0..<120)
    let converted = clock.latencies(121..<240)
    func describe(_ values: [Double]) -> String {
      guard !values.isEmpty else { return "none" }
      let sorted = values.sorted()
      return String(format: "p50 %.3f ms, p95 %.3f ms, max %.3f ms",
        sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 95 / 100)], sorted.last!)
    }
    print("Program latency capture→camera send, zero-copy 1080 420v: \(describe(passthrough))")
    print("Program latency capture→camera send, 4K x422 → 1080 420v on GPU: \(describe(converted))")
    if let gpu = coordinator.programNormalizerStatistics {
      print(String(format: "Program normalize GPU: %.3f ms mean, %.3f ms max over %d frames",
        gpu.meanGPUMilliseconds, gpu.maxGPUMilliseconds, Int(gpu.frames)))
    }
  }

  // MARK: - Format normalization

  func testDifferentFormatSourceIsConvertedToTheContractOnTheGPUInOrder() throws {
    let a = feed("alpha")
    let b = feed("beta")
    let route = ProgramOutputRoute(feedIDs: [a, b])
    let consumer = try route.addConsumerRoute(capacity: 64)
    let normalizer = try ProgramNormalizer()
    route.setNormalizerProvider { normalizer }
    let contract = ProgramOutputFormat(width: 1920, height: 1080,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: VideoContract.fastDuration)
    route.setOutput(contract: contract, active: true)
    let matching = try ioSurfaceFrame(1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let uhd = try ioSurfaceFrame(3840, 2160, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, fill: fillX422)
    // A (matching, passthrough) → cut → B (4K 10-bit 4:2:2 at 29.97, GPU,
    // each frame sent twice on the 59.94 contract) → cut → A again.
    // Passthrough frames after a GPU frame must wait for it.
    let started = ProcessInfo.processInfo.systemUptime
    route.ingest(feedID: a, frame: processed(matching, at: 0))
    route.ingest(feedID: a, frame: processed(matching, at: 1))
    _ = route.requestCut(to: b)
    for index in 0..<10 {
      route.ingest(feedID: b, frame: processed(uhd, at: Int64(index), duration: VideoContract.slowDuration))
    }
    _ = route.requestCut(to: a)
    route.ingest(feedID: a, frame: processed(matching, at: 2))
    let deadline = Date().addingTimeInterval(10)
    while route.statistics.published < 23, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    let wall = (ProcessInfo.processInfo.systemUptime - started) * 1_000
    let stats = route.statistics
    XCTAssertEqual(stats.published, 23)
    XCTAssertEqual(stats.normalized, 10, "Each 29.97 frame is converted once and sent twice")
    XCTAssertEqual(stats.cadenceRepeats, 10)
    XCTAssertEqual(stats.normalizationFailures, 0)
    var leases: [FrameLease<CVPixelBuffer>] = []
    while let lease = consumer.dequeue() { leases.append(lease) }
    XCTAssertEqual(leases.count, 23)
    XCTAssertEqual(leases.map { $0.metadata?.presentationTime ?? .invalid },
      (0..<23).map { CMTime(value: Int64($0) * 1_001, timescale: 60_000) },
      "One frame per 59.94 slot across both cuts: no gaps, no overlaps")
    for pair in stride(from: 2, to: 22, by: 2) {
      XCTAssertTrue(leases[pair].payload === leases[pair + 1].payload, "A repeat re-sends the same IOSurface")
    }
    var last: CMTime?
    for lease in leases {
      let metadata = try XCTUnwrap(lease.metadata)
      let image = try XCTUnwrap(lease.payload)
      XCTAssertTrue(contract.matches(metadata), "Every Program frame has the contract's format")
      XCTAssertEqual(CVPixelBufferGetWidth(image), 1920)
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
      XCTAssertEqual(metadata.duration, VideoContract.fastDuration, "Samples carry the contract's duration")
      XCTAssertNotNil(CVPixelBufferGetIOSurface(image))
      if let last { XCTAssertGreaterThan(CMTimeCompare(metadata.presentationTime, last), 0) }
      last = metadata.presentationTime
    }
    XCTAssertTrue(leases[0].payload === matching, "Matching frames pass through with no copy")
    XCTAssertTrue(leases[22].payload === matching)

    // Level check: 2×2 box of 10-bit luma, then rounded to 8 bits; chroma
    // averaged 2 wide × 4 tall (4:2:2 4K → 4:2:0 1080).
    let converted = try XCTUnwrap(leases[2].payload)
    CVPixelBufferLockBaseAddress(converted, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(converted, .readOnly) }
    let y = CVPixelBufferGetBaseAddressOfPlane(converted, 0)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(converted, 0)
    let c = CVPixelBufferGetBaseAddressOfPlane(converted, 1)!.assumingMemoryBound(to: UInt8.self)
    let cs = CVPixelBufferGetBytesPerRowOfPlane(converted, 1)
    func luma(_ x: Int, _ row: Int) -> Double { Double(64 + (x * 7 + row * 3) % 877) }
    var lumaErrors = 0
    var chromaErrors = 0
    for row in stride(from: 0, to: 1080, by: 7) {
      for x in stride(from: 0, to: 1920, by: 5) {
        let mean = (luma(2 * x, 2 * row) + luma(2 * x + 1, 2 * row) + luma(2 * x, 2 * row + 1) +
          luma(2 * x + 1, 2 * row + 1)) / 4
        if Int(y[row * ys + x]) != Int((mean / 4 + 0.5).rounded(.down)) { lumaErrors += 1 }
      }
    }
    for row in stride(from: 0, to: 540, by: 3) {
      for x in stride(from: 0, to: 960, by: 7) {
        var cb = 0.0, cr = 0.0
        for dx in 0..<2 { for dy in 0..<4 { cb += Double(512 + (2 * x + dx) % 100); cr += Double(400 + (4 * row + dy) % 50) } }
        if Int(c[row * cs + 2 * x]) != Int((cb / 8 / 4 + 0.5).rounded(.down)) ||
          Int(c[row * cs + 2 * x + 1]) != Int((cr / 8 / 4 + 0.5).rounded(.down)) { chromaErrors += 1 }
      }
    }
    XCTAssertEqual(lumaErrors, 0)
    XCTAssertEqual(chromaErrors, 0)
    leases.forEach { $0.release() }
    let gpu = normalizer.currentStatistics
    print(String(format: "Program normalize 4K x422 → 1080 420v: GPU %.3f ms mean, %.3f ms max; 23 sends capture→route %.2f ms mean, %.2f ms max; wall %.1f ms",
      gpu.meanGPUMilliseconds, gpu.maxGPUMilliseconds, stats.meanStageMilliseconds, stats.maxStageMilliseconds, wall))
  }

  func testV210AndUpscaleConversionsAreLevelExact() throws {
    let normalizer = try ProgramNormalizer()
    func convert(_ source: CVPixelBuffer, _ format: ProgramOutputFormat) throws -> CVPixelBuffer {
      let done = DispatchSemaphore(value: 0)
      let box = EventLog()
      try normalizer.normalize(source, to: format) { result in
        if case let .success(output) = result { box.setBuffer(output) }
        done.signal()
      }
      XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
      return try XCTUnwrap(box.buffer)
    }
    let uhd = try ioSurfaceFrame(3840, 2160, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, fill: fillX422)
    // x422 → v210 → x422 is bit-exact (same samples, different packing).
    let packed = try convert(uhd, ProgramOutputFormat(width: 3840, height: 2160,
      pixelFormat: kCVPixelFormatType_422YpCbCr10, duration: VideoContract.fastDuration))
    let unpacked = try convert(packed, ProgramOutputFormat(width: 3840, height: 2160,
      pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, duration: VideoContract.fastDuration))
    CVPixelBufferLockBaseAddress(uhd, .readOnly)
    CVPixelBufferLockBaseAddress(unpacked, .readOnly)
    var mismatches = 0
    for plane in 0..<2 {
      let lhs = CVPixelBufferGetBaseAddressOfPlane(uhd, plane)!.assumingMemoryBound(to: UInt16.self)
      let rhs = CVPixelBufferGetBaseAddressOfPlane(unpacked, plane)!.assumingMemoryBound(to: UInt16.self)
      let ls = CVPixelBufferGetBytesPerRowOfPlane(uhd, plane) / 2
      let rs = CVPixelBufferGetBytesPerRowOfPlane(unpacked, plane) / 2
      for row in stride(from: 0, to: 2160, by: 3) {
        for x in 0..<3840 where lhs[row * ls + x] != rhs[row * rs + x] { mismatches += 1 }
      }
    }
    CVPixelBufferUnlockBaseAddress(unpacked, .readOnly)
    CVPixelBufferUnlockBaseAddress(uhd, .readOnly)
    XCTAssertEqual(mismatches, 0)

    // A flat 1080 4:2:0 8-bit picture upscaled to 4K 10-bit keeps its levels
    // exactly (8-bit code × 4).
    let flat = try ioSurfaceFrame(1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { image in
      memset(CVPixelBufferGetBaseAddressOfPlane(image, 0), 180,
        CVPixelBufferGetBytesPerRowOfPlane(image, 0) * 1080)
      let c = CVPixelBufferGetBaseAddressOfPlane(image, 1)!.assumingMemoryBound(to: UInt8.self)
      for index in 0..<(CVPixelBufferGetBytesPerRowOfPlane(image, 1) * 540) { c[index] = index % 2 == 0 ? 100 : 160 }
    }
    let up = try convert(flat, ProgramOutputFormat(width: 3840, height: 2160,
      pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, duration: VideoContract.fastDuration))
    CVPixelBufferLockBaseAddress(up, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(up, .readOnly) }
    let y = CVPixelBufferGetBaseAddressOfPlane(up, 0)!.assumingMemoryBound(to: UInt16.self)
    let c = CVPixelBufferGetBaseAddressOfPlane(up, 1)!.assumingMemoryBound(to: UInt16.self)
    XCTAssertEqual(y[0] >> 6, 720)
    XCTAssertEqual(y[(CVPixelBufferGetBytesPerRowOfPlane(up, 0) / 2) * 2159 + 3839] >> 6, 720)
    XCTAssertEqual(c[0] >> 6, 400)
    XCTAssertEqual(c[1] >> 6, 640)
  }

  // MARK: - Cadence

  private func cadenceRoute(contractDuration: CMTime, capacity: Int = 64) throws
    -> (ProgramOutputRoute, FrameRoute<CVPixelBuffer>, CVPixelBuffer) {
    let route = ProgramOutputRoute(feedIDs: [feed("alpha"), feed("beta")])
    let consumer = try route.addConsumerRoute(capacity: capacity)
    route.setOutput(contract: ProgramOutputFormat(width: 1920, height: 1080,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: contractDuration), active: true)
    return (route, consumer, try ioSurfaceFrame(1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
  }

  private func drain(_ consumer: FrameRoute<CVPixelBuffer>) -> [(CMTime, CMTime, CVPixelBuffer?)] {
    var sent: [(CMTime, CMTime, CVPixelBuffer?)] = []
    while let lease = consumer.dequeue() {
      sent.append((lease.metadata?.presentationTime ?? .invalid, lease.metadata?.duration ?? .invalid, lease.payload))
      lease.release()
    }
    return sent
  }

  func testFasterSourceSendsEveryOtherFrameOnASlowerContract() throws {
    let (route, consumer, image) = try cadenceRoute(contractDuration: VideoContract.slowDuration)
    for index in 0..<20 { route.ingest(feedID: feed("alpha"), frame: processed(image, at: Int64(index))) }
    let sent = drain(consumer)
    XCTAssertEqual(sent.count, 10, "59.94 into a 29.97 camera sends 29.97 frames, not 59.94 with 33 ms labels")
    XCTAssertEqual(sent.map(\.0), (0..<10).map { CMTime(value: Int64($0) * 2_002, timescale: 60_000) })
    XCTAssertTrue(sent.allSatisfy { $0.1 == VideoContract.slowDuration }, "Every sample carries the contract duration")
    XCTAssertEqual(route.statistics.cadenceSkipped, 10)
    XCTAssertEqual(route.statistics.accepted, 20)
    XCTAssertEqual(route.statistics.published, 10)
  }

  func testSlowerSourceRepeatsTheSameSurfaceOnAFasterContract() throws {
    let (route, consumer, image) = try cadenceRoute(contractDuration: VideoContract.fastDuration)
    for index in 0..<10 {
      route.ingest(feedID: feed("alpha"), frame: processed(image, at: Int64(index), duration: VideoContract.slowDuration))
    }
    let sent = drain(consumer)
    XCTAssertEqual(sent.count, 20, "29.97 into a 59.94 camera fills every slot instead of leaving gaps")
    XCTAssertEqual(sent.map(\.0), (0..<20).map { CMTime(value: Int64($0) * 1_001, timescale: 60_000) })
    XCTAssertTrue(sent.allSatisfy { $0.1 == VideoContract.fastDuration })
    XCTAssertTrue(sent.allSatisfy { $0.2 === image }, "A repeat is the same IOSurface with the next time: no copy")
    XCTAssertEqual(route.statistics.cadenceRepeats, 10)
    XCTAssertEqual(route.statistics.published, 20)
  }

  func testCutsBetweenCadencesStayOnTheContractGrid() throws {
    let a = feed("alpha"), b = feed("beta")
    // 29.97 camera: A at 59.94 (odd frame count), cut to B at 29.97, cut back.
    var (route, consumer, image) = try cadenceRoute(contractDuration: VideoContract.slowDuration)
    route.setSourceHealth(b, healthy: true)
    for index in 0..<5 { route.ingest(feedID: a, frame: processed(image, at: Int64(index))) }
    _ = route.requestCut(to: b)
    for index in 0..<3 {
      route.ingest(feedID: b, frame: processed(image, at: Int64(index), duration: VideoContract.slowDuration))
    }
    _ = route.requestCut(to: a)
    for index in 100..<104 { route.ingest(feedID: a, frame: processed(image, at: Int64(index))) }
    var sent = drain(consumer)
    XCTAssertEqual(sent.map(\.0), (0..<8).map { CMTime(value: Int64($0) * 2_002, timescale: 60_000) },
      "Each cut lands on the next 29.97 slot: strictly increasing, exactly one frame apart")
    XCTAssertTrue(sent.allSatisfy { $0.1 == VideoContract.slowDuration })

    // 59.94 camera: A at 29.97, cut to B at 59.94.
    (route, consumer, image) = try cadenceRoute(contractDuration: VideoContract.fastDuration)
    route.setSourceHealth(b, healthy: true)
    for index in 0..<3 {
      route.ingest(feedID: a, frame: processed(image, at: Int64(index), duration: VideoContract.slowDuration))
    }
    _ = route.requestCut(to: b)
    for index in 0..<4 { route.ingest(feedID: b, frame: processed(image, at: Int64(index))) }
    sent = drain(consumer)
    XCTAssertEqual(sent.map(\.0), (0..<10).map { CMTime(value: Int64($0) * 1_001, timescale: 60_000) })
    XCTAssertTrue(sent.allSatisfy { $0.1 == VideoContract.fastDuration })
  }

  func testNormalizerThatIsNotBuiltOrFailsIsACountedErrorThatNeverBlocks() throws {
    let source = feed("alpha")
    let route = ProgramOutputRoute(feedIDs: [source])
    let consumer = try route.addConsumerRoute(capacity: 16)
    let events = EventLog()
    route.onEvent = { events.append($0) }
    route.setOutput(contract: ProgramOutputFormat(width: 1920, height: 1080,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: VideoContract.fastDuration), active: true)
    let matching = try ioSurfaceFrame(1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let other = try ioSurfaceFrame(64, 64, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    // Not built yet: the route never compiles it on the frame path.
    route.setNormalizerProvider { nil }
    route.ingest(feedID: source, frame: processed(other, at: 0))
    XCTAssertEqual(route.statistics.normalizerNotReady, 1)
    XCTAssertEqual(events.errors.count, 1, "Shown, not silent")
    // A converter that reports a GPU stall: counted, and later frames flow.
    let stalled = StalledNormalizer()
    route.setNormalizerProvider { stalled }
    let started = ProcessInfo.processInfo.systemUptime
    route.ingest(feedID: source, frame: processed(other, at: 1))
    route.ingest(feedID: source, frame: processed(matching, at: 2))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.1, "A stalled GPU never blocks ingest")
    XCTAssertEqual(route.statistics.normalizationFailures, 2)
    XCTAssertEqual(consumer.pendingCount, 1, "The next matching frame still reaches the camera")
  }

  func testOnAirTimestampSkipsAreCountedAndReported() throws {
    let source = feed("alpha")
    let route = ProgramOutputRoute(feedIDs: [source])
    let events = EventLog()
    route.onEvent = { events.append($0) }
    let image = try frame(source, at: 0).payload
    // Duplicate timestamps: an earlier one would be a stream clock restart.
    route.ingest(feedID: source, frame: processed(image, at: 5))
    for _ in 0..<2 { route.ingest(feedID: source, frame: processed(image, at: 5)) }
    XCTAssertEqual(route.statistics.skippedInvalidTimestamp, 2)
    XCTAssertTrue(events.errors.isEmpty, "One or two can race a source being retired")
    route.ingest(feedID: source, frame: processed(image, at: 5))
    XCTAssertEqual(route.statistics.skippedInvalidTimestamp, 3)
    XCTAssertEqual(events.errors.count, 1, "The on-air camera's frames being skipped is a visible error")
    // Still skipping when the latch re-arms (a new client): reported again,
    // not only at exactly the third skip.
    route.acknowledgeOutputError()
    route.ingest(feedID: source, frame: processed(image, at: 5))
    XCTAssertEqual(events.errors.count, 2, "A stream that is still broken is reported again")
  }

  func testOnAirStreamClockRestartKeepsProgramOnTheGrid() throws {
    let a = feed("alpha"), b = feed("beta")
    let (route, consumer, image) = try cadenceRoute(contractDuration: VideoContract.fastDuration)
    let events = EventLog()
    route.onEvent = { events.append($0) }
    route.setSourceHealth(a, healthy: true)
    route.setSourceHealth(b, healthy: true)
    for index in 3_000..<3_005 { route.ingest(feedID: a, frame: processed(image, at: Int64(index))) }
    // Auto mode: an HDMI mode change on the on-air camera restarts its
    // streams, and stream time goes back near zero while it stays live.
    for index in 0..<5 {
      guard case .accepted = route.ingest(feedID: a, frame: processed(image, at: Int64(index))).decision else {
        return XCTFail("Program must not go to standby black after the on-air clock restarts")
      }
    }
    _ = route.requestCut(to: b)
    route.ingest(feedID: b, frame: processed(image, at: 0))
    let sent = drain(consumer)
    XCTAssertEqual(sent.map(\.0), (0..<11).map { CMTime(value: Int64($0) * 1_001, timescale: 60_000) },
      "Program time stays strictly increasing, one slot apart, across the restart and the next cut")
    XCTAssertEqual(route.statistics.skippedInvalidTimestamp, 0)
    XCTAssertTrue(events.errors.isEmpty)
  }

  func testErrorLatchRearmsAfterAHealthyStretch() throws {
    let source = feed("alpha")
    let route = ProgramOutputRoute(feedIDs: [source])
    let consumer = try route.addConsumerRoute(capacity: 8)
    let events = EventLog()
    route.onEvent = { events.append($0) }
    route.setOutput(contract: ProgramOutputFormat(width: 1920, height: 1080,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: VideoContract.fastDuration), active: true)
    let matching = try ioSurfaceFrame(1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let other = try ioSurfaceFrame(64, 64, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    route.setNormalizerProvider { nil }
    var index: Int64 = 0
    func ingest(_ image: CVPixelBuffer) {
      route.ingest(feedID: source, frame: processed(image, at: index))
      index += 1
      _ = drain(consumer)
    }
    ingest(other)  // converter not built yet, early in the session
    ingest(other)
    XCTAssertEqual(events.errors.count, 1, "Repeats of one fault are latched")
    for _ in 1..<ProgramOutputRoute.healthyPublishesToRearm { ingest(matching) }
    ingest(other)
    XCTAssertEqual(events.errors.count, 1, "A stretch shorter than the re-arm bound keeps the latch")
    for _ in 0..<ProgramOutputRoute.healthyPublishesToRearm { ingest(matching) }
    // Later, a different fault: the GPU stalls.
    route.setNormalizerProvider { StalledNormalizer() }
    ingest(other)
    XCTAssertEqual(events.errors.count, 2, "The first failure after a healthy stretch is shown again")
    XCTAssertEqual(route.statistics.normalizationFailures, 4)
  }

  func testFeedRebuildKeepsTheCutOnAirAndReportsADroppedCut() throws {
    let a = feed("alpha"), b = feed("beta"), c = feed("gamma")
    let route = ProgramOutputRoute(feedIDs: [a, b])
    let events = EventLog()
    route.onEvent = { events.append($0) }
    let image = try frame(a, at: 0).payload
    route.setSourceHealth(a, healthy: true)
    route.setSourceHealth(b, healthy: true)
    route.ingest(feedID: a, frame: processed(image, at: 0))
    route.ingest(feedID: b, frame: processed(image, at: 0))
    route.updateFeeds([a, b, c])  // a camera is added while A is on air
    XCTAssertTrue(route.isOnAir, "The on-air camera is still on air after a rebuild")
    guard case .queued = route.requestSelection(b, cutsAllowed: true) else {
      return XCTFail("A request right after a rebuild is a cut, not an instant selection")
    }
    route.updateFeeds([a, b])  // another rebuild while the cut is pending
    XCTAssertEqual(route.pendingFeedID, b, "A pending cut survives a rebuild")
    guard case .cutApplied = route.ingest(feedID: b, frame: processed(image, at: 1)).decision else {
      return XCTFail("The carried cut lands on the target's next frame")
    }
    XCTAssertEqual(route.selectedFeedID, b)

    _ = route.requestCut(to: a)
    route.updateFeeds([b])  // the pending target is removed
    XCTAssertFalse(route.hasPendingCut)
    let deadline = Date().addingTimeInterval(1)
    while events.abandoned.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    XCTAssertEqual(events.abandoned.map(\.0), [a], "A dropped cut is reported so its requester is released")
    XCTAssertEqual(events.abandoned.first?.1, .targetUnavailable)
  }

  func testNormalizerReplacesThePoolBuffersStaleColorAndGeometryTags() throws {
    let normalizer = try ProgramNormalizer()
    let contract = ProgramOutputFormat(width: 1920, height: 1080,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: VideoContract.fastDuration)
    func convert(_ source: CVPixelBuffer) throws -> (IOSurfaceID, [String: Any]) {
      let done = DispatchSemaphore(value: 0)
      let box = EventLog()
      try normalizer.normalize(source, to: contract) { result in
        if case let .success(output) = result { box.setBuffer(output) }
        done.signal()
      }
      XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
      let output = try XCTUnwrap(box.buffer)
      let attachments = (CVBufferCopyAttachments(output, .shouldPropagate) as? [String: Any]) ?? [:]
      return (IOSurfaceGetID(CVPixelBufferGetIOSurface(output)!.takeUnretainedValue()), attachments)
    }
    let hdr = try ioSurfaceFrame(3840, 2160, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    let tags: [(CFString, CFTypeRef)] = [
      (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020),
      (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
      (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020),
      (kCVImageBufferMasteringDisplayColorVolumeKey, Data(count: 24) as CFData),
      (kCVImageBufferContentLightLevelInfoKey, Data(count: 4) as CFData),
      (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
      (kCVImageBufferCleanApertureKey, [kCVImageBufferCleanApertureWidthKey: 3840,
        kCVImageBufferCleanApertureHeightKey: 2160, kCVImageBufferCleanApertureHorizontalOffsetKey: 0,
        kCVImageBufferCleanApertureVerticalOffsetKey: 0] as CFDictionary),
    ]
    for (key, value) in tags { CVBufferSetAttachment(hdr, key, value, .shouldPropagate) }
    let untagged = try ioSurfaceFrame(3840, 2160, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    // Enough HDR frames that every pool buffer has carried HDR tags.
    var hdrSurfaces = Set<IOSurfaceID>()
    for _ in 0..<8 {
      let (surface, attachments) = try convert(hdr)
      hdrSurfaces.insert(surface)
      XCTAssertEqual(attachments[kCVImageBufferTransferFunctionKey as String] as? String,
        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String, "The source's own color tags are carried")
      XCTAssertNil(attachments[kCVImageBufferCleanApertureKey as String],
        "A 3840×2160 clean aperture does not describe a 1920×1080 image")
      XCTAssertEqual(attachments[kCVImageBufferChromaLocationTopFieldKey as String] as? String,
        kCVImageBufferChromaLocation_Center as String, "Resampled chroma is centered")
    }
    var reused = false
    for _ in 0..<8 {
      let (surface, attachments) = try convert(untagged)
      reused = reused || hdrSurfaces.contains(surface)
      for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                  kCVImageBufferYCbCrMatrixKey, kCVImageBufferMasteringDisplayColorVolumeKey,
                  kCVImageBufferContentLightLevelInfoKey, kCVImageBufferCleanApertureKey] {
        XCTAssertNil(attachments[key as String], "Cut to an untagged camera: no stale \(key) on Program")
      }
    }
    XCTAssertTrue(reused, "The check must run on recycled pool buffers")
  }

  func testIdleNormalizerReleasesItsSurfacesAndPool() throws {
    let normalizer = try ProgramNormalizer(idleReleaseDelay: 0.05)
    let contract = ProgramOutputFormat(width: 1920, height: 1080,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: VideoContract.fastDuration)
    let done = DispatchSemaphore(value: 0)
    for _ in 0..<3 {
      let source = try ioSurfaceFrame(640, 360, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
      try normalizer.normalize(source, to: contract) { _ in done.signal() }
    }
    for _ in 0..<3 { XCTAssertEqual(done.wait(timeout: .now() + 5), .success) }
    XCTAssertGreaterThan(normalizer.currentStatistics.cachedSurfaces, 0)
    let deadline = Date().addingTimeInterval(2)
    while normalizer.currentStatistics.cachedSurfaces > 0, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertEqual(normalizer.currentStatistics.cachedSurfaces, 0,
      "An idle normalizer pins no capture or Program surfaces")
    // It still converts afterwards (the pool is rebuilt on demand), and an
    // explicit release on output change frees the completed surfaces.
    let source = try ioSurfaceFrame(640, 360, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    try normalizer.normalize(source, to: contract) { _ in done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    let slow = try ProgramNormalizer()
    try slow.normalize(source, to: contract) { _ in done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    let drained = Date().addingTimeInterval(1)
    while Date() < drained {
      slow.releaseIdleResources()
      if slow.currentStatistics.cachedSurfaces == 0 { break }
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertEqual(slow.currentStatistics.cachedSurfaces, 0)
  }

  func testCutToCameraWithNoSignalExpiresAndAutomaticSwitchingContinues() throws {
    let a = FeedDescriptor(id: feed("alpha"), name: "Wide")
    let b = FeedDescriptor(id: feed("beta"), name: "Tight")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(feeds: [a, b], outputMode: .program))
    coordinator.setSwitcher(SwitcherSettings(selectedFeedID: a.id, automatic: true,
      intervalSeconds: 3, strategy: .fixedInterval))
    var now: TimeInterval = 0
    coordinator.programOutput.setPendingCutClock({ now }, timeout: 2, startingTimeout: 8)
    let image = try frame(a.id, at: 0).payload
    XCTAssertTrue(coordinator.start(a.id))
    XCTAssertTrue(coordinator.start(b.id))  // opened, but its HDMI has no signal
    _ = coordinator.ingestProgramFrame(feedID: a.id, frame: processed(image, at: 0))
    let abandoned = expectation(description: "abandoned cut reaches the main actor")
    abandoned.assertForOverFulfill = false  // each re-request expires too
    coordinator.onProgramCutAbandoned = { feedID, reason in
      XCTAssertEqual(feedID, b.id)
      XCTAssertEqual(reason, .expired)
      abandoned.fulfill()
    }
    var queued = 0
    for index in 1...40 {
      now = Double(index) * 0.5
      _ = coordinator.ingestProgramFrame(feedID: a.id, frame: processed(image, at: Int64(index)))
      if case .cutQueued = coordinator.evaluateSwitcher(at: CMTime(seconds: now, preferredTimescale: 600)) {
        queued += 1
      }
      if index == 12 {
        XCTAssertEqual(coordinator.programOutput.pendingFeedID, b.id, "Inside the starting bound it waits")
      }
    }
    wait(for: [abandoned], timeout: 5)
    XCTAssertEqual(coordinator.programOutput.selectedFeedID, a.id)
    XCTAssertGreaterThanOrEqual(queued, 2, "Fixed-interval switching asks again after the dead cut expires")
  }

  static let allTests = [
    ("selected feed and boundary cut", testProgramRoutePublishesSelectedFeedOnlyAndCutsAtBoundary),
    ("timestamped auto cut boundary", testProgramCutHonorsEarliestMediaTimeFromAutoDirector),
    ("coordinator uses live Program scheduler", testFeedCoordinatorMutatesTheLiveProgramScheduler),
    ("enabled feed reconfiguration", testProgramRouteReconfigurationKeepsOnlyEnabledFeeds),
    ("Program reset drains old timeline", testProgramRouteResetDrainsOldTimelineFrames),
    ("registry modes and Program demand", testFeedCoordinatorPublishesSeparateOrProgramRegistryAndProgramDemand),
    ("selection with nothing on air", testSelectionWithNothingOnAirChangesAtOnce),
    ("Program bridge lifecycle and timing", testProgramBridgePreservesImageAndTimingAndOwnsDemandLifecycle),
    ("Program bridge reconnects after sink failure", testProgramBridgeReconnectsAfterTransientSinkFailure),
    ("in-order delivery from capture threads", testEverySelectedFrameReachesProgramInOrderFromCaptureThreads),
    ("full camera route is a counted error", testFullCameraRouteIsACountedVisibleErrorNotASilentDrop),
    ("no client queues nothing", testNoCameraClientMeansNothingIsQueuedOrCountedAsAnError),
    ("capture delivery off the main thread", testCaptureDeliveryReachesTheProgramCameraOffTheMainThread),
    ("starting camera cut and rollback", testCutToStartingCameraWaitsAndFailedStartRollsBackVisibly),
    ("GPU normalization to the contract", testDifferentFormatSourceIsConvertedToTheContractOnTheGPUInOrder),
    ("v210 and upscale levels", testV210AndUpscaleConversionsAreLevelExact),
    ("Program latency", testProgramLatencyFromCaptureToCameraSend),
    ("faster source halved to the contract", testFasterSourceSendsEveryOtherFrameOnASlowerContract),
    ("slower source repeated to the contract", testSlowerSourceRepeatsTheSameSurfaceOnAFasterContract),
    ("cuts between cadences stay on the grid", testCutsBetweenCadencesStayOnTheContractGrid),
    ("normalizer not built or stalled never blocks", testNormalizerThatIsNotBuiltOrFailsIsACountedErrorThatNeverBlocks),
    ("on-air timestamp skips reported", testOnAirTimestampSkipsAreCountedAndReported),
    ("on-air clock restart stays on the grid", testOnAirStreamClockRestartKeepsProgramOnTheGrid),
    ("error latch re-arms after a healthy stretch", testErrorLatchRearmsAfterAHealthyStretch),
    ("feed rebuild keeps cut state", testFeedRebuildKeepsTheCutOnAirAndReportsADroppedCut),
    ("normalizer replaces stale tags", testNormalizerReplacesThePoolBuffersStaleColorAndGeometryTags),
    ("idle normalizer releases surfaces", testIdleNormalizerReleasesItsSurfacesAndPool),
    ("no-signal cut expires, auto continues", testCutToCameraWithNoSignalExpiresAndAutomaticSwitchingContinues),
  ]
}

private enum SinkFailure: Error { case disconnected }

/// A converter whose GPU is too far behind: it reports the stall at once.
private final class StalledNormalizer: ProgramFrameNormalizing, @unchecked Sendable {
  func canNormalize(_ metadata: ProcessedFrameMetadata, to contract: ProgramOutputFormat) -> Bool { true }
  func normalize(_ source: CVPixelBuffer, to contract: ProgramOutputFormat,
                 completion: @escaping @Sendable (Result<CVPixelBuffer, Error>) -> Void) throws {
    throw VideoError.message("stalled")
  }
}

/// Ingest and send times keyed by frame index (Program PTS / 1001).
private final class LatencyClock: @unchecked Sendable {
  private let lock = NSLock()
  private var ingested: [Int64: TimeInterval] = [:]
  private var sentAt: [Int64: TimeInterval] = [:]
  private var sendOrder: [Int64] = []

  func ingest(_ index: Int64) {
    lock.lock(); ingested[index] = ProcessInfo.processInfo.systemUptime; lock.unlock()
  }

  func sent(_ time: CMTime) {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    let index = Int64(sendOrder.count)
    sendOrder.append(time.value)
    sentAt[index] = now
    lock.unlock()
  }

  /// Sends happen in ingest order (one per accepted frame), so the n-th send
  /// belongs to the n-th ingested frame.
  func latencies(_ range: Range<Int64>) -> [Double] {
    lock.lock(); defer { lock.unlock() }
    return range.compactMap { index in
      guard let start = ingested[index], let end = sentAt[index] else { return nil }
      return (end - start) * 1_000
    }
  }
}

/// Thread-safe recorder for callbacks that arrive off the main thread.
private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [ProgramRouteEvent] = []
  private var sends: [(Bool, CMTime)] = []
  private var stored: CVPixelBuffer?

  func append(_ event: ProgramRouteEvent) { lock.lock(); events.append(event); lock.unlock() }
  func appendSend(_ main: Bool, _ time: CMTime) { lock.lock(); sends.append((main, time)); lock.unlock() }
  func setBuffer(_ buffer: CVPixelBuffer) { lock.lock(); stored = buffer; lock.unlock() }

  var errors: [String] {
    lock.lock(); defer { lock.unlock() }
    return events.compactMap { if case let .outputError(message) = $0 { return message }; return nil }
  }
  var abandoned: [(FeedID, ProgramCutAbandonReason)] {
    lock.lock(); defer { lock.unlock() }
    return events.compactMap { if case let .cutAbandoned(feedID, reason) = $0 { return (feedID, reason) }; return nil }
  }
  var mainThreadSends: Int { lock.lock(); defer { lock.unlock() }; return sends.filter(\.0).count }
  var times: [CMTime] { lock.lock(); defer { lock.unlock() }; return sends.map(\.1) }
  var buffer: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return stored }
}
