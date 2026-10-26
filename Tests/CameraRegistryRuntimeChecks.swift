import CoreMedia
import CoreMediaIO
import CoreVideo
import XCTest

@objcMembers final class CameraRegistryRuntimeChecks: XCTestCase {
  private func applyControl(_ snapshot: VirtualCameraRegistrySnapshot, to camera: CameraProvider) throws {
    let properties = CMIOExtensionProviderProperties(dictionary: [:])
    properties.setPropertyState(CMIOExtensionPropertyState(
      value: try VirtualCameraRegistryWire.encode(snapshot) as NSString,
      attributes: nil), forProperty: VirtualCameraRegistryWire.property)
    try camera.setProviderProperties(properties)
  }

  func testLiveRegistryControlReplacesBootstrapWithoutSharedPreferences() throws {
    // The system service has no access to the host user's defaults. Start it
    // first, exactly as macOS does on a fresh extension installation.
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false)
    XCTAssertEqual(camera.descriptors.first?.feedID, "default")
    let feed = VirtualCameraDescriptor.feed(feedID: FeedID.primary.rawValue, displayName: "Ultracam · Feed 1")
    let desired = snapshot([feed])
    try applyControl(desired, to: camera)
    XCTAssertEqual(camera.descriptors, [feed])
    XCTAssertEqual(camera.devices.count, 1)
    XCTAssertEqual(camera.descriptors[0].deviceUID, CameraSinkRoute(feedID: .primary).deviceUID)
    let properties = try camera.providerProperties(forProperties: [VirtualCameraRegistryWire.property])
    let text = try XCTUnwrap(properties.propertiesDictionary[VirtualCameraRegistryWire.property]?.value as? String)
    XCTAssertEqual(try VirtualCameraRegistryWire.decode(text), desired)
    // A lost acknowledgement must not create a new device on retry.
    let runtime = camera.runtime(for: feed.id)
    try applyControl(desired, to: camera)
    XCTAssertTrue(camera.runtime(for: feed.id) === runtime)
  }

  func testLiveRegistryControlChangesToProgramWhilePreservingActiveFeedClient() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "wide")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let runtime = try XCTUnwrap(camera.runtime(for: feed.id))
    try runtime.source.startStream()
    let program = VirtualCameraDescriptor.program()
    try applyControl(snapshot([program], generation: 2), to: camera)
    XCTAssertNotNil(camera.runtime(for: program.id))
    XCTAssertTrue(camera.runtime(for: feed.id) === runtime)
    try runtime.source.stopStream()
    camera.queue.sync {}
    XCTAssertNil(camera.runtime(for: feed.id))
    XCTAssertEqual(camera.descriptors, [program])
    // The provider property still works with no published camera devices.
    try applyControl(snapshot([], generation: 3), to: camera)
    XCTAssertTrue(camera.devices.isEmpty)
    try applyControl(snapshot([feed], generation: 4), to: camera)
    XCTAssertEqual(camera.descriptors, [feed])
  }

  func testRegistryControlRejectsForeignMalformedStaleAndOversizedUpdates() throws {
    let initial = snapshot([.feed(feedID: "wide")], generation: 5)
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false, registrySnapshot: initial)
    XCTAssertThrowsError(try applyControl(snapshot([.program()], generation: 4), to: camera))
    var foreign = snapshot([.program()], generation: 6)
    foreign.appGroupIdentifier = "group.foreign"
    XCTAssertThrowsError(try applyControl(foreign, to: camera))
    let properties = CMIOExtensionProviderProperties(dictionary: [:])
    for text in ["{truncated", String(repeating: "x", count: VirtualCameraRegistryWire.maximumBytes + 1)] {
      properties.setPropertyState(CMIOExtensionPropertyState(value: text as NSString, attributes: nil),
        forProperty: VirtualCameraRegistryWire.property)
      XCTAssertThrowsError(try camera.setProviderProperties(properties))
    }
    XCTAssertThrowsError(try VirtualCameraRegistryWire.encode(snapshot((0...32).map { .feed(feedID: "\($0)") })))
    XCTAssertEqual(camera.snapshot, initial)
    XCTAssertEqual(camera.descriptors, initial.devices)
  }

  func testRegistryHandshakeRebasesHostAfterServiceHasNewerGeneration() throws {
    let desired = snapshot([.program()], generation: 2)
    let current = snapshot([.feed(feedID: "wide")], generation: 20)
    let update = try XCTUnwrap(VirtualCameraRegistryWire.update(desired, after: current))
    XCTAssertEqual(update.generation, 21)
    XCTAssertEqual(update.devices, desired.devices)
    XCTAssertNil(try VirtualCameraRegistryWire.update(desired, after: update))
    XCTAssertThrowsError(try VirtualCameraRegistryWire.update(desired,
      after: snapshot(current.devices, generation: UInt64.max)))
  }

  private func snapshot(_ devices: [VirtualCameraDescriptor], generation: UInt64 = 1)
    -> VirtualCameraRegistrySnapshot {
    VirtualCameraRegistrySnapshot(generation: generation, devices: devices)
  }

  func testPublishesStableDescriptorDevicesAndReusesRuntimeOnReconcile() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "alpha")
    let program = VirtualCameraDescriptor.program()
    let first = snapshot([feed, program])
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: first)
    XCTAssertEqual(camera.descriptors.map(\.id), [feed.id, program.id])
    XCTAssertEqual(camera.devices.count, 2)
    let feedRuntime = try XCTUnwrap(camera.runtime(for: feed.id))
    let programRuntime = try XCTUnwrap(camera.runtime(for: program.id))
    XCTAssertEqual(feedRuntime.descriptor.deviceUID, feed.deviceUID)
    XCTAssertEqual(programRuntime.descriptor.sourceStreamID, program.sourceStreamID)

    let renamed = VirtualCameraDescriptor.feed(feedID: "alpha", displayName: "Camera Alpha")
    let next = snapshot([renamed, program], generation: 2)
    try camera.reconcile(next)
    XCTAssertTrue(camera.runtime(for: renamed.id) === feedRuntime,
      "Identity changes must update metadata in place")
    XCTAssertTrue(camera.runtime(for: program.id) === programRuntime)
    XCTAssertEqual(camera.runtime(for: renamed.id)?.descriptor.displayName, "Camera Alpha")
  }

  func testDemandAndRemovalAreIndependentPerDevice() throws {
    let firstFeed = VirtualCameraDescriptor.feed(feedID: "alpha")
    let secondFeed = VirtualCameraDescriptor.feed(feedID: "beta")
    let first = snapshot([firstFeed, secondFeed])
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: first)
    let firstRuntime = try XCTUnwrap(camera.runtime(for: firstFeed.id))
    let secondRuntime = try XCTUnwrap(camera.runtime(for: secondFeed.id))
    try firstRuntime.source.startStream()
    XCTAssertEqual(firstRuntime.consumers, 1)
    XCTAssertEqual(secondRuntime.consumers, 0)

    let next = snapshot([secondFeed], generation: 2)
    try camera.reconcile(next)
    XCTAssertEqual(camera.devices.count, 2,
      "An in-use device remains published until its client releases demand")
    try firstRuntime.source.stopStream()
    camera.queue.sync { }
    XCTAssertEqual(camera.devices.count, 1)
    XCTAssertNil(camera.runtime(for: firstFeed.id))
    XCTAssertEqual(secondRuntime.consumers, 0)
  }

  func testPublishedFeedRuntimesForwardIndependentFrames() throws {
    let firstFeed = VirtualCameraDescriptor.feed(feedID: "alpha")
    let secondFeed = VirtualCameraDescriptor.feed(feedID: "beta")
    var outputLuma: [UInt8] = []
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      output: { sample, _, _ in
        guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
        XCTAssertEqual(CVPixelBufferLockBaseAddress(image, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return }
        outputLuma.append(base.assumingMemoryBound(to: UInt8.self).pointee)
      }, registrySnapshot: snapshot([firstFeed, secondFeed]))
    let firstRuntime = try XCTUnwrap(camera.runtime(for: firstFeed.id))
    let secondRuntime = try XCTUnwrap(camera.runtime(for: secondFeed.id))

    try firstRuntime.source.startStream()
    try secondRuntime.source.startStream()
    let firstSample = try sample(luma: 32, at: CMTime(value: 60_000, timescale: 60_000))
    let secondSample = try sample(luma: 224, at: CMTime(value: 60_000, timescale: 60_000))
    XCTAssertTrue(firstRuntime.receive(firstSample, discontinuity: []))
    XCTAssertTrue(secondRuntime.receive(secondSample, discontinuity: []))
    XCTAssertTrue(firstRuntime.latest === CMSampleBufferGetImageBuffer(firstSample))
    XCTAssertTrue(secondRuntime.latest === CMSampleBufferGetImageBuffer(secondSample))
    XCTAssertEqual(outputLuma, [32, 224],
      "Each published feed must forward its own frame without cross-feed reuse")

    try firstRuntime.source.stopStream()
    XCTAssertEqual(firstRuntime.consumers, 0)
    XCTAssertEqual(secondRuntime.consumers, 1)
    try secondRuntime.source.stopStream()
  }

  func testProgramRuntimeFollowsSwitcherAtFrameBoundary() throws {
    let firstFeed = VirtualCameraDescriptor.feed(feedID: "alpha")
    let secondFeed = VirtualCameraDescriptor.feed(feedID: "beta")
    let program = VirtualCameraDescriptor.program()
    var outputLuma: [UInt8] = []
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      output: { sample, _, _ in
        guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
        XCTAssertEqual(CVPixelBufferLockBaseAddress(image, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return }
        outputLuma.append(base.assumingMemoryBound(to: UInt8.self).pointee)
      }, registrySnapshot: snapshot([firstFeed, secondFeed, program]))
    let programRuntime = try XCTUnwrap(camera.runtime(for: program.id))
    try programRuntime.source.startStream()

    let alpha = FeedID(rawValue: "alpha")
    let beta = FeedID(rawValue: "beta")
    var switcher = SwitcherCoordinator(feedIDs: [alpha, beta])
    let firstTime = CMTime(value: 0, timescale: 60_000)
    let duration = VideoContract.fastDuration
    if case .accepted = switcher.ingest(ProgramSourceFrame(sourceID: alpha,
      sourceTime: firstTime, duration: duration)) {
      XCTAssertTrue(programRuntime.receive(try sample(luma: 40, at: firstTime), discontinuity: []))
    } else {
      XCTFail("Initial selected feed must establish the program timeline")
    }

    guard case .queued = switcher.requestManualCut(to: beta) else {
      return XCTFail("A cut to the second feed should queue")
    }
    if case let .accepted(mapped) = switcher.ingest(ProgramSourceFrame(sourceID: alpha,
      sourceTime: CMTime(value: 1_001, timescale: 60_000), duration: duration)) {
      // The old source stays on air until the target's first frame lands.
      XCTAssertTrue(programRuntime.receive(try sample(luma: 40, at: mapped.programTime), discontinuity: []))
    } else {
      XCTFail("The on-air source must keep flowing while the cut is pending")
    }
    if case let .cutApplied(mapped) = switcher.ingest(ProgramSourceFrame(sourceID: beta,
      sourceTime: firstTime, duration: duration)) {
      XCTAssertEqual(mapped.programTime, CMTime(value: 2_002, timescale: 60_000))
      XCTAssertTrue(programRuntime.receive(try sample(luma: 208, at: mapped.programTime),
        discontinuity: CMIOExtensionStream.DiscontinuityFlags.time))
    } else {
      XCTFail("The target source frame must apply the queued cut")
    }
    XCTAssertEqual(outputLuma, [40, 40, 208])
    XCTAssertEqual(switcher.selectedFeedID, beta)
    try programRuntime.source.stopStream()
  }

  func testReconcileRemovalAndReenablePublishesFreshRuntime() throws {
    let firstFeed = VirtualCameraDescriptor.feed(feedID: "alpha")
    let secondFeed = VirtualCameraDescriptor.feed(feedID: "beta")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([firstFeed, secondFeed]))
    let original = try XCTUnwrap(camera.runtime(for: firstFeed.id))
    try camera.reconcile(snapshot([secondFeed], generation: 2))
    XCTAssertNil(camera.runtime(for: firstFeed.id))
    XCTAssertEqual(camera.devices.count, 1)

    try camera.reconcile(snapshot([firstFeed, secondFeed], generation: 3))
    let replacement = try XCTUnwrap(camera.runtime(for: firstFeed.id))
    XCTAssertFalse(replacement === original,
      "A removed feed must not retain stale stream ownership when re-added")
    XCTAssertEqual(camera.descriptors.map(\.id), [firstFeed.id, secondFeed.id])
  }

  func testInvalidStartupRegistryFallsBackToLegacyDefaultFeed() throws {
    let invalid = VirtualCameraRegistrySnapshot(generation: 7,
      devices: [.program(), .program()])
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: invalid)
    let fallback = try XCTUnwrap(camera.descriptors.first)
    XCTAssertEqual(camera.descriptors.count, 1)
    XCTAssertEqual(fallback.kind, .feed)
    XCTAssertEqual(fallback.feedID, "default")
    XCTAssertEqual(fallback.deviceUID, "org.ultracam.camera.device")
    XCTAssertTrue(camera.device(for: fallback.id) === camera.device)
    let fallbackRuntime = try XCTUnwrap(camera.runtime(for: fallback.id))
    XCTAssertTrue(camera.source === fallbackRuntime.source)
    XCTAssertTrue(camera.sink === fallbackRuntime.sink)
  }

  private func sample(luma: UInt8, at time: CMTime) throws -> CMSampleBuffer {
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image)
    guard status == kCVReturnSuccess, let image else {
      throw VideoError.message("Cannot create camera registry frame with status \(status).")
    }
    XCTAssertEqual(CVPixelBufferLockBaseAddress(image, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(image, []) }
    if let y = CVPixelBufferGetBaseAddressOfPlane(image, 0) {
      memset(y, Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(image, 0) *
        CVPixelBufferGetHeightOfPlane(image, 0))
    }
    if let chroma = CVPixelBufferGetBaseAddressOfPlane(image, 1) {
      memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(image, 1) *
        CVPixelBufferGetHeightOfPlane(image, 1))
    }
    return try VideoContract.sample(image, at: time, duration: VideoContract.fastDuration)
  }
}
