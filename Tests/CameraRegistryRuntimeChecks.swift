import CoreMedia
import CoreMediaIO
import CoreVideo
import XCTest

@objcMembers final class CameraRegistryRuntimeChecks: XCTestCase {
  @MainActor
  func testRegistryPublisherDoesNotBlockMainActorAndCoalescesPendingIntent() {
    let started = expectation(description: "First publication started")
    let latest = expectation(description: "Latest publication applied")
    let release = DispatchSemaphore(value: 0)
    let publisher = VirtualCameraRegistryPublisher(observeTopology: false) { snapshot in
      XCTAssertFalse(Thread.isMainThread)
      if snapshot.generation == 1 {
        started.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
      } else {
        XCTAssertEqual(snapshot.generation, 3, "Superseded intent must not replay")
        latest.fulfill()
      }
    }
    let begin = ProcessInfo.processInfo.systemUptime
    publisher.publish(VirtualCameraRegistrySnapshot(generation: 1))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 0.5)
    wait(for: [started], timeout: 2)
    publisher.publish(VirtualCameraRegistrySnapshot(generation: 2))
    publisher.publish(VirtualCameraRegistrySnapshot(generation: 3))
    release.signal()
    wait(for: [latest], timeout: 2)
    withExtendedLifetime(publisher) {}
  }

  @MainActor
  func testRegistryPublisherReportsSynchronizationFailure() {
    let reported = expectation(description: "Publication error on the main actor")
    let publisher = VirtualCameraRegistryPublisher(observeTopology: false) { _ in
      throw VideoError.message("Injected failure")
    }
    publisher.onSynchronizationResult = { result in
      guard case .failure(let error) = result else { return XCTFail("Expected a failure") }
      XCTAssertEqual(error.localizedDescription, "Injected failure")
      reported.fulfill()
    }
    publisher.publish(VirtualCameraRegistrySnapshot(generation: 1))
    wait(for: [reported], timeout: 2)
    withExtendedLifetime(publisher) {}
  }

  func testQueuedPublicationCannotRebaseIntentSupersededByCapture() throws {
    let group = "group.org.ultracam.registry-intent-test.\(UUID().uuidString)"
    let old = VirtualCameraRegistrySnapshot(generation: 1, appGroupIdentifier: group, devices: [
      .feed(feedID: FeedID.primary.rawValue, displayName: "Old")])
    let newest = VirtualCameraRegistrySnapshot(generation: 2, appGroupIdentifier: group, devices: [
      .feed(feedID: FeedID.primary.rawValue, displayName: "Newest")])
    VirtualCameraRegistryTransport.recordIntent(old)
    // Capture records its current intent before acquiring the transport lock.
    VirtualCameraRegistryTransport.recordIntent(newest)
    // A capture that obtained its snapshot before the edit cannot replace the
    // newer local intent when it eventually reaches transport admission.
    VirtualCameraRegistryTransport.recordIntent(old)
    var provider = newest
    provider.generation = 40
    XCTAssertNil(try VirtualCameraRegistryTransport.publicationUpdate(old, after: provider))
    XCTAssertNil(try VirtualCameraRegistryTransport.publicationUpdate(newest, after: provider))
    provider.devices = old.devices
    let update = try VirtualCameraRegistryTransport.publicationUpdate(newest, after: provider)
    XCTAssertEqual(update?.devices, newest.devices)
    XCTAssertEqual(update?.generation, 41)
  }

  private func applyControl(_ snapshot: VirtualCameraRegistrySnapshot, to camera: CameraProvider) throws {
    let properties = CMIOExtensionProviderProperties(dictionary: [:])
    properties.setPropertyState(CMIOExtensionPropertyState(
      value: try VirtualCameraRegistryWire.encode(snapshot) as NSString,
      attributes: nil), forProperty: VirtualCameraRegistryWire.property)
    try camera.setProviderProperties(properties)
  }

#if ULTRACAM_TEST_SUPPORT
  func testStreamLifecycleUsesOwningQueueAcrossIndependentRuntimes() throws {
    let first = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false)
    let second = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false)
    let secondQueue = second.queue
    second.queue.sync {
      second.makeGPUStandbyProducerForTesting = {
        dispatchPrecondition(condition: .onQueue(secondQueue))
        throw VideoError.message("Injected preparation refusal")
      }
      second.source.authorizeSourceForTesting(clientID: UUID())
      second.onDemandChange = { dispatchPrecondition(condition: .onQueue(secondQueue)) }
    }
    try first.queue.sync {
      XCTAssertThrowsError(try second.source.startStream())
    }
    second.queue.sync { second.source.authorizeSourceForTesting(clientID: UUID()) }
    try first.queue.sync { try second.source.stopStream() }
    XCTAssertEqual(second.consumers, 0)
  }

  func testStreamLifecycleAllowsRuntimesSharingOneQueue() throws {
    let queue = DispatchQueue(label: "org.ultracam.shared-runtime-test")
    let first = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false, queue: queue)
    let second = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false, queue: queue)
    try queue.sync {
      XCTAssertThrowsError(try first.sink.startStream())
      try first.source.stopStream()
      XCTAssertThrowsError(try second.sink.startStream())
      try second.source.stopStream()
    }
  }

#endif

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
    for exhausted in [UInt64.max - 1, UInt64.max] {
      XCTAssertThrowsError(try VirtualCameraRegistryWire.update(desired,
        after: snapshot(current.devices, generation: exhausted)))
    }
  }

  func testFailedNativeAdditionRollsBackAndRetriesTheWholeUpdate() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "existing")
    let initial = snapshot([feed])
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: initial)
    let next = snapshot([feed, .feed(feedID: "added"), .program()], generation: 2)
    var attempts = 0
    camera.addDeviceForTesting = { _ in
      attempts += 1
      if attempts == 2 { throw VideoError.message("Native addition failed") }
    }
    XCTAssertThrowsError(try camera.reconcile(next))
    XCTAssertEqual(camera.snapshot, initial)
    XCTAssertEqual(camera.descriptors, [feed])
    for descriptor in next.devices.dropFirst() { XCTAssertNil(camera.runtime(for: descriptor.id)) }
    try camera.reconcile(next)
    XCTAssertEqual(camera.descriptors, next.devices)
    XCTAssertEqual(attempts, 4)
  }

  func testDelayedRemovalCallbackCannotRetireReplacementRuntime() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "republished")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let original = try XCTUnwrap(camera.runtime(for: feed.id))
    let replacement = try camera.queue.sync {
      original.onDemandChange?()
      try camera.reconcile(snapshot([], generation: 2))
      try camera.reconcile(snapshot([feed], generation: 3))
      let replacement = try XCTUnwrap(camera.runtime(for: feed.id))
      replacement.source.authorizeSourceForTesting(clientID: UUID())
      try camera.reconcile(snapshot([], generation: 4))
      return replacement
    }
    camera.queue.sync {}
    XCTAssertTrue(camera.runtime(for: feed.id) === replacement)
    XCTAssertFalse(original === replacement)
  }

  func testFailedNativeRemovalRetainsRuntimeUntilRegistryRetry() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "removal-failure")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let retainedRuntime = { [weak runtime = camera.runtime(for: feed.id)] in runtime }
    var attempts = 0
    camera.removeDeviceForTesting = { _ in
      attempts += 1
      if attempts == 1 { throw VideoError.message("Native removal failed") }
    }
    let removed = snapshot([], generation: 2)
    try camera.reconcile(removed)
    XCTAssertNotNil(retainedRuntime(), "Published sources still require their unowned runtime")
    XCTAssertNotNil(camera.runtime(for: feed.id))
    XCTAssertEqual(camera.devices.count, 1)
    try camera.reconcile(removed)
    XCTAssertEqual(attempts, 2)
    XCTAssertNil(camera.runtime(for: feed.id))
    XCTAssertNil(retainedRuntime())
    XCTAssertTrue(camera.devices.isEmpty)
  }

  func testNativeRemovalFailureRetriesWithoutAnotherRegistryWrite() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "automatic-removal-retry")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let removed = expectation(description: "Idle device removed on retry")
    var attempts = 0
    camera.removeDeviceForTesting = { _ in
      attempts += 1
      if attempts == 1 { throw VideoError.message("Native removal failed") }
      removed.fulfill()
    }
    try camera.reconcile(snapshot([], generation: 2))
    wait(for: [removed], timeout: 4)
    camera.queue.sync {
      XCTAssertNil(camera.runtime(for: feed.id))
      XCTAssertTrue(camera.devices.isEmpty)
      XCTAssertEqual(attempts, 2)
    }
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

  func testRetiredSinkCompletionDoesNotDereferenceReleasedRuntime() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "retired-sink")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    var runtime: CameraDeviceRuntime? = try XCTUnwrap(camera.runtime(for: feed.id))
    weak let retired = runtime
    let sink: CameraStream = try XCTUnwrap(runtime).sink
    var completion: CameraSampleCompletion?
    camera.queue.sync {
      sink.beginConsumption { completion = $0 }
      sink.consume()
      sink.stopConsumption()
    }
    try camera.reconcile(snapshot([], generation: 2))
    camera.queue.sync {}
    runtime = nil
    XCTAssertNil(retired, "A saved callback and sink must not permanently retain its retired runtime")
    let stale = try XCTUnwrap(completion)
    stale(nil, 1, [], false, nil)
    camera.queue.sync {}
    XCTAssertNil(retired)
    XCTAssertTrue(camera.devices.isEmpty)
  }

  func testCompletionQueuedBeforeRemovalRetainsRuntimeOnlyUntilHandlingFinishes() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "callback-removal-race")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    var runtime: CameraDeviceRuntime? = try XCTUnwrap(camera.runtime(for: feed.id))
    weak let retired = runtime
    let sink: CameraStream = try XCTUnwrap(runtime).sink
    var completion: CameraSampleCompletion?
    camera.queue.sync {
      sink.beginConsumption { completion = $0 }
      sink.consume()
      sink.stopConsumption()
    }
    // Drain the demand notification first, so it cannot accidentally retain the
    // runtime and hide a missing callback lifetime lease in this regression.
    camera.queue.sync {}
    try camera.queue.sync {
      let submitted = try XCTUnwrap(completion)
      // The callback resolves its owner before teardown, then queues handling
      // behind this serial block. Teardown must not invalidate that strong lease.
      submitted(nil, 1, [], false, nil)
      try camera.reconcile(snapshot([], generation: 2))
      runtime = nil
      XCTAssertNotNil(retired)
    }
    camera.queue.sync {}
    XCTAssertNil(retired, "The temporary callback lease must not form an owner/stream cycle")
    XCTAssertTrue(camera.devices.isEmpty)
  }

#if ULTRACAM_TEST_SUPPORT
  func testUnqualifiedStopBalancesActiveStartWhilePendingClientWaitsForDisconnect() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "active-stop-with-pending-client")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let runtime = try XCTUnwrap(camera.runtime(for: feed.id))
    let active = UUID(), pending = UUID()
    try camera.queue.sync {
      runtime.enableGPUStandbyForTesting { _, _ in }
      runtime.source.authorizeSourceForTesting(clientID: active)
      try runtime.source.startStream()
      runtime.source.authorizeSourceForTesting(clientID: pending)
      try runtime.source.stopStream()
      XCTAssertEqual(runtime.consumers, 0, "Native stop balances a completed start, not an unrelated authorization")
      XCTAssertTrue(runtime.source.hasPendingStart)
    }
    try camera.reconcile(snapshot([], generation: 2))
    XCTAssertTrue(camera.runtime(for: feed.id) === runtime)
    camera.queue.sync { runtime.source.disconnectSourceForTesting(clientID: pending) }
    camera.queue.sync {}
    XCTAssertNil(camera.runtime(for: feed.id))
  }

  func testPendingAuthorizationDisconnectCompletesDeferredRemoval() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "pending-disconnect")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let runtime = try XCTUnwrap(camera.runtime(for: feed.id))
    let clientID = UUID()
    camera.queue.sync { runtime.source.authorizeSourceForTesting(clientID: clientID) }
    let removed = snapshot([], generation: 2)
    try camera.reconcile(removed)
    XCTAssertTrue(camera.runtime(for: feed.id) === runtime)
    camera.queue.sync {
      XCTAssertTrue(runtime.inUse)
      XCTAssertEqual(runtime.consumers, 0)
      runtime.source.disconnectSourceForTesting(clientID: clientID)
    }
    camera.queue.sync {}
    XCTAssertNil(camera.runtime(for: feed.id))
    XCTAssertTrue(camera.devices.isEmpty)
    try camera.reconcile(removed)
    XCTAssertTrue(camera.devices.isEmpty, "An identical registry retry must not be needed to release the runtime")
  }

  func testStopBeforeStartCompletesDeferredRemoval() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "single-pending-stop")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let runtime = try XCTUnwrap(camera.runtime(for: feed.id))
    camera.queue.sync { runtime.source.authorizeSourceForTesting(clientID: UUID()) }
    try camera.reconcile(snapshot([], generation: 2))
    XCTAssertTrue(camera.runtime(for: feed.id) === runtime)
    try camera.queue.sync { try runtime.source.stopStream() }
    camera.queue.sync {}
    XCTAssertNil(camera.runtime(for: feed.id))
    XCTAssertTrue(camera.devices.isEmpty)
  }

  func testPendingDisconnectPreservesOtherActiveSourceLease() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "mixed-source-leases")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let runtime = try XCTUnwrap(camera.runtime(for: feed.id))
    let active = UUID(), pending = UUID()
    try camera.queue.sync {
      // Install a non-hardware standby lifecycle; no frame is requested.
      runtime.enableGPUStandbyForTesting { _, _ in }
      runtime.source.authorizeSourceForTesting(clientID: active)
      try runtime.source.startStream()
      runtime.source.authorizeSourceForTesting(clientID: pending)
    }
    try camera.reconcile(snapshot([], generation: 2))
    camera.queue.sync {
      runtime.source.disconnectSourceForTesting(clientID: pending)
      XCTAssertEqual(runtime.consumers, 1)
      XCTAssertFalse(runtime.source.hasPendingStart)
    }
    camera.queue.sync {}
    XCTAssertTrue(camera.runtime(for: feed.id) === runtime)
    camera.queue.sync { runtime.source.disconnectSourceForTesting(clientID: active) }
    camera.queue.sync {}
    XCTAssertEqual(runtime.consumers, 0)
    XCTAssertNil(camera.runtime(for: feed.id))
  }

  func testStopBeforeStartReleasesOnlyItsPendingLeaseAndRemovesAfterLastRelease() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "pending-stop")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let runtime = try XCTUnwrap(camera.runtime(for: feed.id))
    let first = UUID(), second = UUID()
    camera.queue.sync {
      runtime.source.authorizeSourceForTesting(clientID: first)
      runtime.source.authorizeSourceForTesting(clientID: second)
    }
    try camera.reconcile(snapshot([], generation: 2))
    try camera.queue.sync {
      try runtime.source.stopStream()
      XCTAssertTrue(runtime.source.hasPendingStart, "A stop must not release another client's pending authorization")
      XCTAssertEqual(runtime.consumers, 0)
    }
    camera.queue.sync {}
    XCTAssertTrue(camera.runtime(for: feed.id) === runtime)
    camera.queue.sync { runtime.source.disconnectSourceForTesting(clientID: second) }
    camera.queue.sync {}
    XCTAssertNil(camera.runtime(for: feed.id))
  }

  // CMIO may call start/stop once per client. The second viewer stops and
  // then disconnects; the first viewer is still streaming throughout.
  func testSecondViewerStopThenDisconnectKeepsFirstViewerDemand() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "second-viewer-stop-disconnect")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let runtime = try XCTUnwrap(camera.runtime(for: feed.id))
    let first = UUID(), second = UUID()
    try camera.queue.sync {
      runtime.enableGPUStandbyForTesting { _, _ in }
      runtime.source.streamingSourceClientIDsForTesting = [first]
      runtime.source.authorizeSourceForTesting(clientID: first)
      try runtime.source.startStream()
      runtime.source.streamingSourceClientIDsForTesting = [first, second]
      runtime.source.authorizeSourceForTesting(clientID: second)
      try runtime.source.startStream()
      XCTAssertEqual(runtime.consumers, 2)
      // CMIO has already dropped the stopping client from streamingClients.
      runtime.source.streamingSourceClientIDsForTesting = [first]
      try runtime.source.stopStream()
      XCTAssertEqual(runtime.consumers, 1, "The stop releases the client that left the streaming list")
      runtime.source.disconnectSourceForTesting(clientID: second)
      XCTAssertEqual(runtime.consumers, 1, "A lease released by stop must not be released again by disconnect")
      runtime.source.streamingSourceClientIDsForTesting = []
      try runtime.source.stopStream()
      XCTAssertEqual(runtime.consumers, 0)
      runtime.source.disconnectSourceForTesting(clientID: first)
      XCTAssertEqual(runtime.consumers, 0)
      XCTAssertFalse(runtime.inUse)
    }
  }

  // The same sequence when streamingClients has not caught up with the stop:
  // the stop cannot tell which viewer left, so the disconnect must repair it.
  func testSecondViewerStopWithStaleStreamingListKeepsFirstViewerDemand() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "second-viewer-stale-list")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let runtime = try XCTUnwrap(camera.runtime(for: feed.id))
    let first = UUID(), second = UUID()
    try camera.queue.sync {
      runtime.enableGPUStandbyForTesting { _, _ in }
      runtime.source.streamingSourceClientIDsForTesting = [first, second]
      runtime.source.authorizeSourceForTesting(clientID: first)
      try runtime.source.startStream()
      runtime.source.authorizeSourceForTesting(clientID: second)
      try runtime.source.startStream()
      try runtime.source.stopStream()
      XCTAssertEqual(runtime.consumers, 1)
      runtime.source.streamingSourceClientIDsForTesting = [first]
      runtime.source.disconnectSourceForTesting(clientID: second)
      XCTAssertEqual(runtime.consumers, 1, "The viewer still listed as streaming keeps demand")
      runtime.source.streamingSourceClientIDsForTesting = []
      try runtime.source.stopStream()
      XCTAssertEqual(runtime.consumers, 0)
      runtime.source.disconnectSourceForTesting(clientID: first)
      XCTAssertEqual(runtime.consumers, 0)
      XCTAssertFalse(runtime.inUse)
    }
  }

  // CMIO may call start only for the first client and stop only for the last.
  // The second viewer is then authorized and streaming without a start.
  func testStartedViewerDisconnectKeepsDemandForStreamingViewerWithoutStart() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "streaming-without-start")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let runtime = try XCTUnwrap(camera.runtime(for: feed.id))
    let started = UUID(), joined = UUID()
    try camera.queue.sync {
      runtime.enableGPUStandbyForTesting { _, _ in }
      runtime.source.streamingSourceClientIDsForTesting = [started]
      runtime.source.authorizeSourceForTesting(clientID: started)
      try runtime.source.startStream()
      runtime.source.authorizeSourceForTesting(clientID: joined)
      // The list still names the departing client when its disconnect arrives.
      runtime.source.streamingSourceClientIDsForTesting = [started, joined]
      runtime.source.disconnectSourceForTesting(clientID: started)
      XCTAssertEqual(runtime.consumers, 1, "A viewer that is still streaming keeps demand")
      XCTAssertFalse(runtime.source.hasPendingStart)
      // The last client stopping is the one stop callback CMIO delivers.
      runtime.source.streamingSourceClientIDsForTesting = []
      try runtime.source.stopStream()
      XCTAssertEqual(runtime.consumers, 0)
      runtime.source.disconnectSourceForTesting(clientID: joined)
      XCTAssertEqual(runtime.consumers, 0)
      XCTAssertFalse(runtime.inUse)
    }
  }

  func testStopTrailingDisconnectDoesNotReleaseRemainingViewer() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "stop-after-disconnect")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let runtime = try XCTUnwrap(camera.runtime(for: feed.id))
    let departed = UUID(), remaining = UUID()
    try camera.queue.sync {
      runtime.enableGPUStandbyForTesting { _, _ in }
      runtime.source.streamingSourceClientIDsForTesting = [departed, remaining]
      runtime.source.authorizeSourceForTesting(clientID: departed)
      try runtime.source.startStream()
      runtime.source.authorizeSourceForTesting(clientID: remaining)
      try runtime.source.startStream()
      runtime.source.streamingSourceClientIDsForTesting = [remaining]
      runtime.source.disconnectSourceForTesting(clientID: departed)
      XCTAssertEqual(runtime.consumers, 1)
      try runtime.source.stopStream()
      XCTAssertEqual(runtime.consumers, 1, "A stop for the disconnected client must not take the remaining viewer's lease")
      runtime.source.streamingSourceClientIDsForTesting = []
      try runtime.source.stopStream()
      XCTAssertEqual(runtime.consumers, 0)
    }
  }

  func testTrailingStopWhileStreamingListIsEmptyKeepsRemainingStartedViewer() throws {
    let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false)
    let departed = UUID(), remaining = UUID()
    try runtime.queue.sync {
      runtime.enableGPUStandbyForTesting { _, _ in }
      runtime.source.streamingSourceClientIDsForTesting = [departed, remaining]
      for id in [departed, remaining] {
        runtime.source.authorizeSourceForTesting(clientID: id)
        try runtime.source.startStream()
      }
      runtime.source.streamingSourceClientIDsForTesting = []
      runtime.source.disconnectSourceForTesting(clientID: departed)
      try runtime.source.stopStream()
      XCTAssertEqual(runtime.consumers, 1)
      runtime.source.observeStreamingClientsForTesting([remaining])
      XCTAssertEqual(runtime.consumers, 1)
      runtime.source.streamingSourceClientIDsForTesting = []
      try runtime.source.stopStream()
      XCTAssertFalse(runtime.inUse)
    }
  }

  func testRealFinalStopWithNoTrailingDisconnectCallbackSettlesFromMembership() throws {
    for stopFirst in [false, true] {
      let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false)
      let departed = UUID(), remaining = UUID()
      try runtime.queue.sync {
        runtime.enableGPUStandbyForTesting { _, _ in }
        runtime.source.streamingSourceClientIDsForTesting = [departed, remaining]
        for id in [departed, remaining] {
          runtime.source.authorizeSourceForTesting(clientID: id)
          try runtime.source.startStream()
        }
        runtime.source.streamingSourceClientIDsForTesting = [remaining]
        runtime.source.disconnectSourceForTesting(clientID: departed)
        if stopFirst { try runtime.source.stopStream() }
        runtime.source.observeStreamingClientsForTesting([])
        if !stopFirst {
          XCTAssertEqual(runtime.consumers, 1, "A list change alone cannot release a completed start")
          try runtime.source.stopStream()
        }
        XCTAssertFalse(runtime.inUse)
      }
    }
  }

  func testDelayedListRestoresAStartedViewerAfterAMisattributedStop() throws {
    let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false)
    let remaining = UUID(), leaving = UUID()
    try runtime.queue.sync {
      runtime.enableGPUStandbyForTesting { _, _ in }
      runtime.source.streamingSourceClientIDsForTesting = [remaining, leaving]
      for id in [remaining, leaving] {
        runtime.source.authorizeSourceForTesting(clientID: id)
        try runtime.source.startStream()
      }
      try runtime.source.stopStream()
      runtime.source.streamingSourceClientIDsForTesting = []
      runtime.source.disconnectSourceForTesting(clientID: leaving)
      runtime.source.observeStreamingClientsForTesting([remaining])
      XCTAssertEqual(runtime.consumers, 1)
      runtime.source.streamingSourceClientIDsForTesting = []
      try runtime.source.stopStream()
      XCTAssertFalse(runtime.inUse)
    }
  }

  func testLateMembershipRestoresAuthorizedViewerWithoutAnotherStart() throws {
    let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false)
    let departed = UUID(), remaining = UUID()
    try runtime.queue.sync {
      runtime.enableGPUStandbyForTesting { _, _ in }
      runtime.source.authorizeSourceForTesting(clientID: departed)
      try runtime.source.startStream()
      runtime.source.authorizeSourceForTesting(clientID: remaining)
      runtime.source.streamingSourceClientIDsForTesting = []
      runtime.source.disconnectSourceForTesting(clientID: departed)
      try runtime.source.stopStream()
      XCTAssertTrue(runtime.source.hasPendingStart)
      runtime.source.observeStreamingClientsForTesting([departed, remaining])
      XCTAssertEqual(runtime.consumers, 1)
      XCTAssertFalse(runtime.source.hasPendingStart)
      runtime.source.observeStreamingClientsForTesting([remaining])
      XCTAssertEqual(runtime.consumers, 1)
      runtime.source.streamingSourceClientIDsForTesting = []
      try runtime.source.stopStream()
      XCTAssertFalse(runtime.inUse)
    }
  }

  // CameraProvider fans every client's disconnect out to every runtime. A
  // process that never used this camera can leave while streamingClients
  // still names a viewer whose stop has already released its lease; that
  // disconnect must not hand the stopped viewer a new lease.
  func testUnrelatedClientDisconnectDoesNotRegrantAStoppedViewerLease() throws {
    let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false)
    let viewer = UUID(), unrelated = UUID()
    try runtime.queue.sync {
      runtime.enableGPUStandbyForTesting { _, _ in }
      runtime.source.streamingSourceClientIDsForTesting = [viewer]
      runtime.source.authorizeSourceForTesting(clientID: viewer)
      try runtime.source.startStream()
      XCTAssertEqual(runtime.consumers, 1)
      // The list has not caught up with the viewer's stop.
      try runtime.source.stopStream()
      XCTAssertEqual(runtime.consumers, 0)
      runtime.source.disconnectSourceForTesting(clientID: unrelated)
      XCTAssertEqual(runtime.consumers, 0, "An unrelated disconnect must not restart demand for a stopped viewer")
      runtime.source.observeStreamingClientsForTesting([])
      XCTAssertEqual(runtime.consumers, 0)
      XCTAssertFalse(runtime.inUse)
    }
  }

  func testFailedPreparationReleasesPendingLeaseWithoutAdmittingDemand() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "pending-failed-start")
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: snapshot([feed]))
    let runtime = try XCTUnwrap(camera.runtime(for: feed.id))
    camera.queue.sync {
      runtime.source.authorizeSourceForTesting(clientID: UUID())
      runtime.makeGPUStandbyProducerForTesting = { throw VideoError.message("Injected preparation refusal") }
    }
    try camera.reconcile(snapshot([], generation: 2))
    try camera.queue.sync {
      XCTAssertThrowsError(try runtime.source.startStream())
      XCTAssertEqual(runtime.consumers, 0)
      XCTAssertFalse(runtime.source.hasPendingStart)
    }
    camera.queue.sync {}
    XCTAssertNil(camera.runtime(for: feed.id))
  }
#endif

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
    // These fixed SDR luma fixtures model the shipped producer's explicit
    // Rec.709 metadata, independently of the registry/routing behavior tested.
    for (key, value) in [(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
      (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
      (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
      CVBufferSetAttachment(image, key, value, .shouldPropagate)
    }
    return try VideoContract.sample(image, at: time, duration: VideoContract.fastDuration)
  }
}
