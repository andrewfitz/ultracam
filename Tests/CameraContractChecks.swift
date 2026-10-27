import CoreMedia
import CoreMediaIO
import CoreVideo
import XCTest

@objcMembers final class CameraContractChecks: XCTestCase {
  /// The extension's bootstrap device, which a provider without a registry publishes.
  static let bootstrapRoute = CameraSinkRoute(descriptor: .feed(feedID: "default", displayName: VideoContract.cameraName))

  func testAuthorizedProducerCanNegotiateAfterConsumerStarts() throws {
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false)
    try camera.queue.sync {
      try camera.setProperties(index: 0, frameDuration: VideoContract.slowDuration)
      try camera.source.startStream()
      camera.sink.beginConsumption { _ in }
      let fast = try sample()
      XCTAssertFalse(camera.receive(fast, discontinuity: []), "Ordinary ingress cannot renegotiate")
      XCTAssertTrue(camera.receive(fast, discontinuity: [], producerCanNegotiate: true))
      XCTAssertEqual(camera.duration, VideoContract.fastDuration)
      let tenBit = try sample(width: 3840, height: 2160,
        pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
      XCTAssertTrue(camera.receive(tenBit, discontinuity: [], producerCanNegotiate: true))
      XCTAssertEqual(camera.activeIndex, 5)
      XCTAssertTrue(camera.receive(tenBit, discontinuity: []), "Contract remains strict after negotiation")
      let invalidRate = try sample(duration: CMTime(value: 1, timescale: 120))
      XCTAssertFalse(camera.receive(invalidRate, discontinuity: [], producerCanNegotiate: true))
      XCTAssertEqual(camera.activeIndex, 5, "Invalid producer request must not partially change the contract")
      XCTAssertEqual(camera.duration, VideoContract.fastDuration)
      camera.sink.stopConsumption()
      try camera.source.stopStream()
    }
  }

  func testDemandTracksSourceConsumersAndIgnoresProducer() throws {
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false)
    let property = CMIOExtensionProperty(rawValue: VideoContract.demandProperty)
    func demand() throws -> String? {
      let properties = try camera.source.streamProperties(forProperties: [property])
      XCTAssertTrue(properties.propertiesDictionary[property]?.attributes?.isReadOnly == true)
      return properties.propertiesDictionary[property]?.value as? String
    }
    try camera.queue.sync {
      XCTAssertTrue(camera.source.availableProperties.contains(property))
      XCTAssertFalse(camera.sink.availableProperties.contains(property))
      XCTAssertEqual(try demand(), "0")
      camera.sink.beginConsumption { _ in }
      XCTAssertEqual(try demand(), "0", "Producer must not keep itself awake")
      try camera.source.startStream()
      try camera.source.startStream()
      XCTAssertEqual(try demand(), "1")
      try camera.source.stopStream()
      XCTAssertEqual(try demand(), "1", "One remaining viewer keeps capture requested")
      try camera.source.stopStream()
      XCTAssertEqual(try demand(), "0")
      try camera.source.stopStream()
      XCTAssertEqual(try demand(), "0")
      camera.sink.stopConsumption()
    }
  }

  private func sample(width: Int = 1920, height: Int = 1080,
    pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    time: CMTime = CMTime(value: 60_000, timescale: 60_000),
    duration: CMTime = VideoContract.fastDuration) throws -> CMSampleBuffer {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, pixelFormat,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    return try VideoContract.sample(XCTUnwrap(image), at: time, duration: duration)
  }

  func testAllAdvertisedFormatsAndAtomicNegotiation() throws {
    // Construct the real process singleton once without calling startService.
    let camera = CameraProvider(automaticTimers: false)
    try camera.queue.sync {
      XCTAssertEqual(camera.provider.devices.count, 1)
      XCTAssertEqual(camera.device.streams.count, 2)
      XCTAssertEqual(camera.formats.count, 18)
      for format in camera.formats {
        XCTAssertEqual(format.validFrameDurations, FrameRateTarget.allCases.map(\.duration))
        XCTAssertEqual(format.minFrameDuration, FrameRateTarget.fps60.duration)
        XCTAssertEqual(format.maxFrameDuration, FrameRateTarget.fps23976.duration)
      }
      let properties = CMIOExtensionStreamProperties(dictionary: [:])
      properties.activeFormatIndex = 5
      properties.frameDuration = CMTime(value: 1, timescale: 120)
      XCTAssertThrowsError(try camera.source.setStreamProperties(properties))
      XCTAssertEqual(camera.activeIndex, 0, "Invalid frame rate must not partially change the format")
      XCTAssertEqual(camera.duration, VideoContract.fastDuration)
      properties.frameDuration = CMTime(value: 33_366_667, timescale: 1_000_000_000)
      try camera.sink.setStreamProperties(properties)
      XCTAssertEqual(camera.activeIndex, 5)
      XCTAssertEqual(camera.duration, VideoContract.slowDuration, "Normalize floating client rates to exact NTSC")
      for stream in [camera.source, camera.sink] {
        let current = try stream.streamProperties(forProperties: [.streamActiveFormatIndex, .streamFrameDuration])
        XCTAssertEqual(current.activeFormatIndex, 5)
        XCTAssertEqual(current.frameDuration, VideoContract.slowDuration)
      }
      for invalid in [CMTime.invalid, .indefinite, .positiveInfinity, .zero, CMTime(value: 1, timescale: 120)] {
        properties.frameDuration = invalid
        XCTAssertThrowsError(try camera.sink.setStreamProperties(properties))
        XCTAssertEqual(camera.duration, VideoContract.slowDuration)
      }
      camera.sink.beginConsumption { _ in }
      properties.activeFormatIndex = 0
      properties.frameDuration = VideoContract.fastDuration
      XCTAssertThrowsError(try camera.source.setStreamProperties(properties), "Consumer must not change producer precision while it is running")
      XCTAssertEqual(camera.activeIndex, 5)
      camera.sink.stopConsumption()
      try camera.sink.setStreamProperties(properties)
      XCTAssertEqual(camera.activeIndex, 0)
      XCTAssertEqual(camera.duration, VideoContract.fastDuration)
    }
  }

  func testLiveFramesForwardOnceWithoutRetimingOrRepetition() throws {
    var now = CMTime(value: 60_000, timescale: 60_000)
    var emitted: [CMSampleBuffer] = []
    var hostTimes: [UInt64] = []
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false, clock: { now }, output: { sample, _, host in
      emitted.append(sample)
      hostTimes.append(host)
    })
    try camera.queue.sync {
      try camera.source.startStream()
      for index in 0..<10 {
        now = CMTime(value: 60_000 + Int64(index) * 1001, timescale: 60_000)
        let frame = try sample(time: now)
        XCTAssertTrue(camera.receive(frame, discontinuity: []))
        XCTAssertTrue(emitted.last === frame, "Preserve the original live sample and its attachments")
        camera.emitStandby()
        XCTAssertEqual(emitted.count, index + 1, "Independent source timer must not duplicate live frames")
        XCTAssertEqual(hostTimes.last, UInt64(CMTimeConvertScale(now, timescale: 1_000_000_000, method: .default).value))
      }
      try camera.source.stopStream()
      camera.emitStandby()
      XCTAssertEqual(emitted.count, 10, "No frames after last viewer stops")
    }
  }

  func testRejectMismatchedIngressAndRecoverFromSignalLoss() throws {
    var now = CMTime(value: 60_000, timescale: 60_000)
    var emitted: [CMSampleBuffer] = []
    var flags: [CMIOExtensionStream.DiscontinuityFlags] = []
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false, clock: { now }, output: { sample, discontinuity, _ in
      emitted.append(sample)
      flags.append(discontinuity)
    })
    try camera.queue.sync {
      try camera.source.startStream()
      XCTAssertFalse(camera.receive(try sample(width: 3840, height: 2160), discontinuity: []))
      XCTAssertFalse(camera.receive(try sample(duration: VideoContract.slowDuration), discontinuity: []))
      XCTAssertFalse(camera.receive(try sample(time: .invalid), discontinuity: []))
      XCTAssertFalse(camera.receive(try sample(pixelFormat: kCVPixelFormatType_422YpCbCr10), discontinuity: []))
      XCTAssertTrue(emitted.isEmpty)
      let live = try sample(time: now)
      XCTAssertTrue(camera.receive(live, discontinuity: [.sampleDropped]))
      XCTAssertTrue(flags.last!.contains(.sampleDropped))
      now = CMTime(value: 89_999, timescale: 60_000)
      camera.emitStandby()
      XCTAssertEqual(emitted.count, 1)
      now = CMTime(value: 90_000, timescale: 60_000)
      camera.emitStandby()
      XCTAssertEqual(emitted.count, 2)
      XCTAssertNil(camera.latest, "Discard the previous image on signal loss")
      XCTAssertTrue(flags.last!.contains(.time))
      let standby = try XCTUnwrap(CMSampleBufferGetImageBuffer(emitted.last!))
      try assertBlack(standby)
      // A capture frame queued before the last standby output needs a single
      // monotonic repair at recovery, retaining the sample's image and metadata.
      now = CMTime(value: 90_001, timescale: 60_000)
      let recovery = try sample(time: CMTime(value: 89_000, timescale: 60_000))
      XCTAssertTrue(camera.receive(recovery, discontinuity: []))
      XCTAssertEqual(emitted.count, 3)
      XCTAssertTrue(CMSampleBufferGetImageBuffer(emitted.last!) === CMSampleBufferGetImageBuffer(recovery))
      XCTAssertGreaterThan(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(emitted.last!),
        CMSampleBufferGetPresentationTimeStamp(emitted[1])), 0)
      XCTAssertTrue(flags.last!.contains(.time))
      try camera.source.stopStream()
    }
  }

  func testProgramClockAfterStandbyRebasesOnce() throws {
    var now = CMTime(value: 60_000, timescale: 60_000)
    var emitted: [CMSampleBuffer] = []
    var flags: [CMIOExtensionStream.DiscontinuityFlags] = []
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false, clock: { now }, output: { sample, discontinuity, _ in
      emitted.append(sample)
      flags.append(discontinuity)
    })
    try camera.queue.sync {
      try camera.source.startStream()
      XCTAssertTrue(camera.receive(try sample(time: now), discontinuity: []))
      now = CMTime(value: 90_000, timescale: 60_000)
      camera.emitStandby()
      XCTAssertEqual(emitted.count, 2)
      now = CMTime(value: 90_001, timescale: 60_000)
      let step = VideoContract.fastDuration
      for index in 0..<3 {
        let producer = CMTimeMultiply(step, multiplier: Int32(index))
        XCTAssertTrue(camera.receive(try sample(time: producer), discontinuity: []))
      }
      XCTAssertEqual(emitted.count, 5)
      let repaired = emitted.suffix(3).map { CMSampleBufferGetPresentationTimeStamp($0) }
      XCTAssertGreaterThan(CMTimeCompare(repaired[0], CMSampleBufferGetPresentationTimeStamp(emitted[1])), 0)
      XCTAssertEqual(CMTimeSubtract(repaired[1], repaired[0]), step)
      XCTAssertEqual(CMTimeSubtract(repaired[2], repaired[1]), step)
      XCTAssertTrue(flags[2].contains(.time), "Only the standby boundary is a timestamp discontinuity")
      XCTAssertFalse(flags[3].contains(.time))
      XCTAssertFalse(flags[4].contains(.time))
      try camera.source.stopStream()
    }
  }

  func testMalformedChromaCannotReachTransportOrExtensionSource() throws {
    let width = 1920
    let height = 1080
    let storage = UnsafeMutableRawPointer.allocate(byteCount: width * height * 2, alignment: 64)
    var addresses: [UnsafeMutableRawPointer?] = [storage, storage.advanced(by: width * height)]
    var widths = [width, width / 2]
    var heights = [height, height] // NV12 must have half-height chroma.
    var strides = [width, width]
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreateWithPlanarBytes(nil, width, height,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, 0, 2,
      &addresses, &widths, &heights, &strides, { context, _, _, _, _ in context?.deallocate() },
      storage, nil, &image)
    guard status == kCVReturnSuccess, let image else {
      storage.deallocate()
      throw VideoError.message("Cannot construct malformed chroma fixture (\(status)).")
    }
    let frame = try VideoContract.sample(image, at: CMTime(value: 1, timescale: 1), duration: VideoContract.fastDuration)
    XCTAssertThrowsError(try CameraFrameStager().stage(frame))
    let sink = CameraSink(bufferQueue: try bufferQueue(), route: Self.bootstrapRoute)
    XCTAssertThrowsError(try sink.send(frame))
    var emitted = 0
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false, output: { _, _, _ in emitted += 1 })
    try camera.queue.sync {
      try camera.source.startStream()
      XCTAssertFalse(camera.receive(frame, discontinuity: []))
      XCTAssertNil(camera.latest)
      XCTAssertEqual(emitted, 0)
      try camera.source.stopStream()
    }
  }

  func testStandbyBlackAndFormatChangesAcrossAllModes() throws {
    var now = CMTime(value: 60_000, timescale: 60_000)
    var emitted: CMSampleBuffer?
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false, clock: { now }, output: { sample, _, _ in emitted = sample })
    try camera.queue.sync {
      try camera.source.startStream()
      for index in camera.formats.indices {
        try camera.setProperties(index: index, frameDuration: nil)
        now = CMTimeAdd(now, VideoContract.fastDuration)
        camera.emitStandby()
        let frame = try XCTUnwrap(emitted)
        let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(frame))
        let expected = camera.formats[index].formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(expected)
        XCTAssertEqual(CVPixelBufferGetWidth(image), Int(dimensions.width))
        XCTAssertEqual(CVPixelBufferGetHeight(image), Int(dimensions.height))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), CMFormatDescriptionGetMediaSubType(expected))
        try assertBlack(image)
      }
      try camera.source.stopStream()
    }
  }

  private func assertBlack(_ image: CVPixelBuffer) throws {
    XCTAssertEqual(CVPixelBufferLockBaseAddress(image, .readOnly), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let type = CVPixelBufferGetPixelFormatType(image)
    if ColorTarget.allCases.contains(where: { $0.pixelFormat == type && $0.isEightBit }) {
      for plane in 0..<2 {
        let pointer = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, plane)).assumingMemoryBound(to: UInt8.self)
        let bytes = CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane)
        XCTAssertEqual(pointer[0], plane == 0 ? 16 : 128)
        XCTAssertEqual(pointer[bytes - 1], plane == 0 ? 16 : 128)
      }
    } else if CVPixelBufferIsPlanar(image) {
      for plane in 0..<2 {
        let pointer = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, plane)).assumingMemoryBound(to: UInt16.self)
        let length = CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane) / 2
        let value: UInt16 = plane == 0 ? (type == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange ? 0 : 64 << 6) : 512 << 6
        XCTAssertEqual(pointer[0], value)
        XCTAssertEqual(pointer[length - 1], value)
      }
    } else {
      let pointer = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt32.self)
      let expected: [UInt32] = [512 | 64 << 10 | 512 << 20, 64 | 512 << 10 | 64 << 20,
        512 | 64 << 10 | 512 << 20, 64 | 512 << 10 | 64 << 20]
      for index in 0..<4 { XCTAssertEqual(pointer[index], expected[index]) }
    }
  }

  func testStandbyRationalCadenceAndLateTimerSkips() throws {
    for duration in [VideoContract.fastDuration, VideoContract.slowDuration] {
      try autoreleasepool {
        var now = CMTime(value: 60_000, timescale: 60_000)
        var timestamps: [CMTime] = []
        let camera = CameraProvider(automaticTimers: false, createNativeProvider: false, clock: { now }, output: { sample, _, _ in
          timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample))
        })
        try camera.queue.sync {
          try camera.setProperties(index: nil, frameDuration: duration)
          try camera.source.startStream()
          camera.emitStandby()
          for _ in 0..<6000 {
            now = CMTimeAdd(now, duration)
            camera.emitStandby()
          }
          XCTAssertEqual(timestamps.count, 6001)
          for index in 1..<timestamps.count {
            XCTAssertEqual(CMTimeSubtract(timestamps[index], timestamps[index - 1]), duration)
          }
          XCTAssertEqual(CMTimeSubtract(timestamps.last!, timestamps[0]), CMTimeMultiply(duration, multiplier: 6000))
          let count = timestamps.count
          now = CMTimeAdd(now, CMTimeMultiply(duration, multiplier: 10))
          camera.emitStandby()
          XCTAssertEqual(timestamps.count, count + 1, "A late timer must skip, not burst old frames")
          XCTAssertLessThanOrEqual(abs(CMTimeSubtract(timestamps.last!, now).seconds), duration.seconds)
          try camera.source.stopStream()
      }
      }
    }
  }

  func testSinkRestartIgnoresOldCompletionAndBoundsRequests() throws {
    let now = CMTime(value: 60_000, timescale: 60_000)
    var pending: [CameraSampleCompletion] = []
    var outputs = 0
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false, clock: { now }, output: { _, _, _ in outputs += 1 })
    try camera.queue.sync {
      try camera.source.startStream()
      XCTAssertThrowsError(try camera.sink.startStream(), "An unauthenticated producer cannot start")
      camera.sink.beginConsumption { pending.append($0) }
      camera.sink.consume()
      camera.sink.consume()
      XCTAssertEqual(pending.count, 1, "Only one consume request may be pending")
      camera.sink.stopConsumption()
      camera.sink.beginConsumption { pending.append($0) }
      camera.sink.consume()
      camera.sink.beginConsumption { _ in XCTFail("Duplicate starts must not replace the active consumer") }
      XCTAssertEqual(pending.count, 2)
    }
    pending[0](try sample(time: now), 1, [], false, nil)
    camera.queue.sync {
      XCTAssertTrue(camera.sink.consumePending, "Old completion cannot clear the replacement request")
      XCTAssertNil(camera.latest)
      XCTAssertEqual(outputs, 0)
    }
    pending[1](try sample(time: now), 2, [], false, nil)
    try camera.queue.sync {
      XCTAssertFalse(camera.sink.consumePending)
      XCTAssertNotNil(camera.latest)
      XCTAssertEqual(outputs, 1)
      camera.sink.stopConsumption()
      XCTAssertNil(camera.latest)
      try camera.source.stopStream()
    }
  }

  func testQueuedCompletionRetainsSampleUntilProviderQueueRuns() throws {
    var completion: CameraSampleCompletion?
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false)
    camera.queue.sync {
      camera.sink.beginConsumption { completion = $0 }
      camera.sink.consume()
    }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    camera.queue.async { entered.signal(); release.wait() }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    var frame: CMSampleBuffer? = try sample()
    weak let weakFrame = frame
    completion?(frame, 1, [], false, nil)
    frame = nil
    XCTAssertNotNil(weakFrame, "Retain callback sample while provider queue is busy")
    release.signal()
    camera.queue.sync { camera.sink.stopConsumption() }
    XCTAssertNil(weakFrame, "Release consumed callback sample after queue handling")
  }

  func testViewerCountsAndNoOutputAfterStop() throws {
    var outputs = 0
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false, output: { _, _, _ in outputs += 1 })
    try camera.queue.sync {
      try camera.source.startStream()
      try camera.source.startStream()
      XCTAssertEqual(camera.consumers, 2)
      camera.emitStandby()
      XCTAssertEqual(outputs, 1)
      try camera.source.stopStream()
      XCTAssertEqual(camera.consumers, 1)
      try camera.source.stopStream()
      try camera.source.stopStream()
      XCTAssertEqual(camera.consumers, 0)
      camera.emitStandby()
      XCTAssertEqual(outputs, 1)
    }
  }

  func testViewerRestartBeginsNewTimestampSegment() throws {
    var emittedFlags: [CMIOExtensionStream.DiscontinuityFlags] = []
    var now = CMTime(value: 60_000, timescale: 60_000)
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false, clock: { now },
      output: { _, flags, _ in emittedFlags.append(flags) })
    try camera.queue.sync {
      try camera.source.startStream()
      XCTAssertTrue(camera.receive(try sample(time: now), discontinuity: []))
      try camera.source.stopStream()
      try camera.source.startStream()
      now = CMTimeAdd(now, VideoContract.fastDuration)
      XCTAssertTrue(camera.receive(try sample(time: now), discontinuity: []))
      XCTAssertEqual(emittedFlags.count, 2)
      XCTAssertTrue(emittedFlags[1].contains(.time), "A new viewer must start a fresh output segment")
      try camera.source.stopStream()
    }
  }

  private func bufferQueue(capacity: Int32 = 3) throws -> CameraBufferQueue {
    var queue: CMSimpleQueue?
    XCTAssertEqual(CMSimpleQueueCreate(allocator: kCFAllocatorDefault, capacity: capacity, queueOut: &queue), noErr)
    return CameraBufferQueue(try XCTUnwrap(queue))
  }

  func testQueueOwnershipBackpressureRemovalAndDisconnect() throws {
    let queue = try bufferQueue(capacity: 1)
    var first: CMSampleBuffer? = try sample()
    weak let firstWeak = first
    XCTAssertTrue(try queue.send(XCTUnwrap(first)))
    first = nil
    XCTAssertNotNil(firstWeak, "Queue owns the successful enqueue retain")
    var rejected: CMSampleBuffer? = try sample()
    weak let rejectedWeak = rejected
    XCTAssertFalse(try queue.send(XCTUnwrap(rejected)))
    rejected = nil
    XCTAssertNil(rejectedWeak, "Backpressure must not retain rejected frames")
    let token = try XCTUnwrap(CMSimpleQueueDequeue(queue.queue))
    // Model the native C consumer's ownership of the successful enqueue retain.
    // Keep it explicit so a callback regression fails the weak assertion rather
    // than making a Swift ARC local later release an already-freed sample.
    let nativeOwner = Unmanaged<CMSampleBuffer>.fromOpaque(token)
    cameraSinkQueueAltered(0, UnsafeMutableRawPointer(mutating: token), nil)
    let remainsOwned = firstWeak != nil
    XCTAssertTrue(remainsOwned, "Removal notification must not release the native consumer's sample")
    if remainsOwned {
      autoreleasepool {
        XCTAssertTrue(CMSampleBufferDataIsReady(nativeOwner.takeUnretainedValue()),
          "The native consumer must still be able to read the sample after notification")
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(nativeOwner.takeUnretainedValue()),
          CMTime(value: 60_000, timescale: 60_000))
      }
      nativeOwner.release()
    }
    XCTAssertNil(firstWeak, "Native consumer releases the enqueue retain exactly once after use")
    XCTAssertEqual(CMSimpleQueueGetCount(queue.queue), 0)
    let sink = CameraSink(bufferQueue: queue, route: Self.bootstrapRoute)
    var remaining: CMSampleBuffer? = try sample()
    weak let remainingWeak = remaining
    XCTAssertTrue(try sink.send(XCTUnwrap(remaining)))
    remaining = nil
    XCTAssertNotNil(remainingWeak)
    sink.disconnect()
    XCTAssertNil(remainingWeak, "Stopped queue is drained without leaking buffers")
    XCTAssertThrowsError(try sink.send(sample()))
  }

  private func borrowedV210(width: Int = 3840, height: Int = 2160, extraStride: Int = 64) throws -> CMSampleBuffer {
    let rowBytes = ((width + 5) / 6) * 16
    let stride = rowBytes + extraStride
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: stride * height, alignment: 64)
    memset(bytes, 0xDA, stride * height)
    for row in 0..<height {
      let words = bytes.advanced(by: row * stride).assumingMemoryBound(to: UInt32.self)
      for word in 0..<(rowBytes / 4) { words[word] = UInt32((row * 65_537 + word * 97) & 0x3FFF_FFFF) }
    }
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, width, height,
      kCVPixelFormatType_422YpCbCr10, bytes, stride,
      { _, base in UnsafeMutableRawPointer(mutating: base!).deallocate() }, nil, nil, &image)
    guard status == kCVReturnSuccess, let image else {
      bytes.deallocate()
      throw VideoError.message("Cannot construct borrowed v210 image (\(status)).")
    }
    XCTAssertNil(CVPixelBufferGetIOSurface(image))
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return try VideoContract.sample(image, at: CMTime(value: 123_456, timescale: 60_000), duration: VideoContract.fastDuration)
  }

  func testStagerPassesIOSurfaceFramesThroughAndRejectsBorrowedMemory() throws {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    let shareable = try VideoContract.sample(try XCTUnwrap(image),
      at: CMTime(value: 123_456, timescale: 60_000), duration: VideoContract.fastDuration)
    let stager = CameraFrameStager()
    XCTAssertTrue(try stager.stage(shareable) === shareable, "IOSurface frames are shared as they are, never copied")
    XCTAssertThrowsError(try stager.stage(try borrowedV210()),
      "A frame without an IOSurface is an error, not a reason to copy")
  }

  func testStagerRejectsShortPackedRows() throws {
    let width = 96
    let height = 4
    let stride = width / 6 * 16 - 16
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: stride * height, alignment: 64)
    defer { bytes.deallocate() }
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, width, height,
      kCVPixelFormatType_422YpCbCr10, bytes, stride, nil, nil, nil, &image)
    if status == kCVReturnSuccess, let image {
      let malformed = try VideoContract.sample(image, at: .zero, duration: VideoContract.fastDuration)
      XCTAssertThrowsError(try CameraFrameStager().stage(malformed), "Never read beyond a packed input row")
    } else {
      XCTAssertNil(image, "CoreVideo can reject malformed strides before staging")
      XCTAssertNotEqual(status, kCVReturnSuccess)
    }
  }

}
