import CoreMedia
import CoreVideo
import MonitorToolsCore
import MonitorToolsMetal
import XCTest

@MainActor @objcMembers final class MonitorCoordinatorChecks: XCTestCase {
  private let alpha = MonitorTargetID("alpha")
  private let beta = MonitorTargetID("beta")
  private func coordinator() -> MonitorCoordinator {
    let value = MonitorCoordinator()
    value.updateTargets(
      feeds: [
        FeedDescriptor(id: FeedID(rawValue: "alpha"), name: "Wide"),
        FeedDescriptor(id: FeedID(rawValue: "beta"), name: "Tight"),
      ], programAvailable: false)
    return value
  }

  func testFreezingTheOnlySurfacePreservesDemandUntilHideOrClose() throws {
    let value = coordinator()
    var policy = AutomaticFeedPolicy()
    var demand: Set<MonitorTargetID> = []
    value.onDemandChange = {
      demand = $0
      policy.previewDemand($0.contains(self.alpha))
    }
    let id = UUID()
    let presenter = value.surface(id: id, target: alpha)
    value.registerSurface(id: id, target: alpha, isVisible: true, scopeVisible: false)
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA,
      nil, &pixelBuffer), kCVReturnSuccess)
    let copied = expectation(description: "synthetic owned freeze picture")
    let service = CleanPreviewService()
    let stamp = MonitorFrameStamp(target: alpha, generation: 1, sequence: 1,
      sourcePTS: 0, hostTime: ProcessInfo.processInfo.systemUptime, configurationRevision: 1)
    XCTAssertTrue(service.offer(MonitorFrameBundle(stamp: stamp, source: try XCTUnwrap(pixelBuffer))) {
      result in
      if let clean = try? result.get() {
        presenter.accept(MonitorDisplayResult(clean: clean, configuration: MonitorConfiguration()))
      } else { XCTFail("Synthetic clean copy failed") }
      copied.fulfill()
    })
    wait(for: [copied], timeout: 3)
    presenter.setClean(false)
    presenter.toggleFreeze()
    XCTAssertTrue(presenter.isFrozen)
    value.registerSurface(id: id, target: alpha, isVisible: true, scopeVisible: false)
    XCTAssertEqual(demand, [alpha])
    XCTAssertNil(policy.action(ready: true, running: true))
    XCTAssertFalse(value.captureSink(for: alpha).needsOutput, "Freeze holds display without pixel work")
    value.setPreviewEnabled(false, for: alpha)
    XCTAssertTrue(demand.isEmpty)
    XCTAssertEqual(policy.action(ready: true, running: true), .stop)
    value.setPreviewEnabled(true, for: alpha)
    XCTAssertEqual(demand, [alpha])
    value.unregisterSurface(id: id)
    XCTAssertTrue(demand.isEmpty)
  }

  func testPausedDiagnosticsAndLayoutCapsFollowCurrentState() throws {
    var saved = MonitorWorkspaceState()
    saved.layout = .fourUp
    let restored = MonitorCoordinator(workspace: saved)
    XCTAssertEqual(restored.diagnostics(for: alpha).requestedPictureHz, 0)
    restored.workspace.layout = .sideBySide
    XCTAssertEqual(restored.diagnostics(for: alpha).requestedPictureHz, 0)
    let value = coordinator()
    let id = UUID()
    let presenter = value.surface(id: id, target: alpha)
    value.registerSurface(id: id, target: alpha, isVisible: true, scopeVisible: false)
    let sink = value.captureSink(for: alpha)
    var monitor = MonitorConfiguration()
    monitor.pictureStage = .source
    monitor.toolsEnabled = false
    sink.configure(monitor, consumers: [presenter], scopeVisible: false)
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &image),
      kCVReturnSuccess)
    let buffer = try XCTUnwrap(image)
    let frame = CMTime(value: 1001, timescale: 60_000)
    sink.offer(source: buffer, output: nil, pts: .zero, captureGeneration: 1, sequence: 1,
      processingRevision: 0, sourceOnly: true)
    sink.offer(source: buffer, output: nil, pts: frame, captureGeneration: 1, sequence: 2,
      processingRevision: 0, sourceOnly: true)
    let cameraHz = 1 / frame.seconds
    XCTAssertEqual(sink.observedSourceFrameHz, cameraHz, accuracy: 0.05)
    for layout in MonitorWorkspaceLayout.allCases {
      value.workspace.layout = layout
      XCTAssertEqual(value.diagnostics(for: alpha).requestedPictureHz, cameraHz, accuracy: 0.05)
    }
    value.workspace.layout = .single
    XCTAssertEqual(value.diagnostics(for: alpha).requestedPictureHz, cameraHz, accuracy: 0.05)
    presenter.onVisibilityChange?(true, false)
    XCTAssertEqual(value.diagnostics(for: alpha).availability, .paused)
    presenter.onVisibilityChange?(true, true)
    XCTAssertNotEqual(value.diagnostics(for: alpha).availability, .paused)
    value.setPreviewEnabled(false, for: alpha)
    XCTAssertEqual(value.diagnostics(for: alpha).availability, .paused)
  }

  func testWindowVisibilityFreezeAndPreviewHideHaveIndependentDemand() {
    let value = coordinator()
    var demand: Set<MonitorTargetID> = []
    value.onDemandChange = { demand = $0 }
    let a = UUID()
    let b = UUID()
    let first = value.surface(id: a, target: alpha)
    value.registerSurface(id: a, target: alpha, isVisible: true, scopeVisible: false)
    value.registerSurface(id: b, target: beta, isVisible: true, scopeVisible: false)
    XCTAssertEqual(demand, [alpha, beta])
    first.onVisibilityChange?(true, false)
    XCTAssertEqual(demand, [alpha, beta], "Occlusion preserves presented capture intent")
    XCTAssertFalse(value.captureSink(for: alpha).needsOutput, "Occlusion suspends pixel work")
    first.onVisibilityChange?(true, true)
    XCTAssertTrue(value.captureSink(for: alpha).needsOutput)
    value.registerSurface(id: a, target: alpha, isVisible: false, scopeVisible: false)
    XCTAssertEqual(demand, [beta], "Hiding one surface leaves the other feed live")
    value.setPreviewEnabled(false, for: beta)
    XCTAssertEqual(demand, [])
    XCTAssertFalse(value.captureSink(for: beta).needsOutput)
    XCTAssertTrue(value.isPreviewEnabled(for: alpha))
  }

  func testRebindingSurfaceReleasesOldSinkAndIgnoresOldTeardown() {
    let value = coordinator()
    let id = UUID()
    value.registerSurface(id: id, target: alpha, isVisible: true, scopeVisible: false)
    let previous = value.surface(id: id, target: alpha)
    XCTAssertTrue(value.captureSink(for: alpha).needsOutput)
    value.registerSurface(id: id, target: beta, isVisible: true, scopeVisible: false)
    XCTAssertFalse(value.captureSink(for: alpha).needsOutput)
    XCTAssertTrue(value.captureSink(for: beta).needsOutput)
    value.unregisterSurface(id: id, target: alpha)
    previous.onVisibilityChange?(false, false)
    XCTAssertTrue(
      value.captureSink(for: beta).needsOutput,
      "Late teardown/visibility from the old target must not remove its replacement")
  }

  func testNativeToolsAndHiddenPreviewTransitionsPreserveIndependentDemand() {
    let value = coordinator()
    let a = UUID()
    let b = UUID()
    var demand: Set<MonitorTargetID> = []
    value.onDemandChange = { demand = $0 }
    value.registerSurface(
      id: a, target: alpha, isVisible: true, scopeVisible: false,
      usesNativePreview: true)
    value.registerSurface(id: b, target: beta, isVisible: true, scopeVisible: false)
    XCTAssertEqual(demand, [alpha, beta])
    XCTAssertFalse(
      value.captureSink(for: alpha).needsOutput,
      "The native tools-off path must not introduce owned-copy work")
    var config = value.configuration(for: alpha)
    config.toolsEnabled = true
    config.zebra.enabled = true
    value.setConfiguration(config, for: alpha)
    value.registerSurface(id: a, target: alpha, isVisible: true, scopeVisible: false)
    XCTAssertTrue(value.captureSink(for: alpha).needsOutput)
    config.toolsEnabled = false
    value.setConfiguration(config, for: alpha)
    value.registerSurface(
      id: a, target: alpha, isVisible: true, scopeVisible: false,
      usesNativePreview: true)
    XCTAssertFalse(value.captureSink(for: alpha).needsOutput)
    XCTAssertEqual(demand, [alpha, beta])
    value.setPreviewEnabled(false, for: alpha)
    XCTAssertEqual(demand, [beta])
    value.setPreviewEnabled(true, for: alpha)
    value.registerSurface(id: a, target: alpha, isVisible: false, scopeVisible: false)
    XCTAssertEqual(demand, [beta], "A hidden surface cannot stop another live feed")
    XCTAssertTrue(value.captureSink(for: beta).needsOutput)
  }

  func testUnavailableTargetCannotReactivateMonitorConsumers() {
    let value = coordinator()
    let id = UUID()
    value.registerSurface(id: id, target: alpha, isVisible: true, scopeVisible: false)
    var disabled = FeedDescriptor(id: FeedID(rawValue: "alpha"), name: "Wide")
    disabled.enabled = false
    value.updateTargets(feeds: [disabled], programAvailable: false)
    value.registerSurface(id: id, target: alpha, isVisible: true, scopeVisible: false)
    XCTAssertFalse(value.captureSink(for: alpha).needsOutput)
  }

  func testRemovedAndDisabledTargetsReleaseOutputConsumersImmediately() {
    let value = coordinator()
    let a = UUID()
    let b = UUID()
    value.registerSurface(id: a, target: alpha, isVisible: true, scopeVisible: false)
    value.registerSurface(id: b, target: beta, isVisible: true, scopeVisible: false)
    XCTAssertTrue(value.captureSink(for: alpha).needsOutput)
    XCTAssertTrue(value.captureSink(for: beta).needsOutput)
    var disabled = FeedDescriptor(id: FeedID(rawValue: "alpha"), name: "Wide")
    disabled.enabled = false

    value.updateTargets(feeds: [disabled], programAvailable: false)

    XCTAssertFalse(value.captureSink(for: alpha).needsOutput,
      "Disabling a target must release consumers without waiting for another view event")
    XCTAssertFalse(value.captureSink(for: beta).needsOutput,
      "Removing a target must release consumers without waiting for another view event")
  }

  func testLocalScopeVisibilityUnionsDemandWithoutChangingFeedSettings() {
    let value = coordinator()
    var config = value.configuration(for: alpha)
    config.toolsEnabled = true
    config.pictureStage = .source
    config.scopes.enabled = true
    config.scopeStage = .processedOutput
    value.setConfiguration(config, for: alpha)
    var demand: Set<MonitorTargetID> = []
    value.onDemandChange = { demand = $0 }
    let a = UUID()
    let b = UUID()
    value.registerSurface(id: a, target: alpha, isVisible: true, scopeVisible: false)
    XCTAssertFalse(value.captureSink(for: alpha).needsOutput)
    value.registerSurface(id: b, target: alpha, isVisible: true, scopeVisible: true)
    XCTAssertTrue(value.captureSink(for: alpha).needsOutput,
      "One visible scope consumer keeps shared processed-scope work active")
    value.registerSurface(id: b, target: alpha, isVisible: true, scopeVisible: false)
    XCTAssertFalse(value.captureSink(for: alpha).needsOutput)
    XCTAssertEqual(demand, [alpha], "Hiding scopes must preserve live picture demand")
    XCTAssertTrue(value.configuration(for: alpha).scopes.enabled,
      "Local visibility must not change persisted per-feed analysis settings")
    value.registerSurface(id: a, target: alpha, isVisible: true, scopeVisible: true)
    XCTAssertTrue(value.captureSink(for: alpha).needsOutput)
    value.registerSurface(id: b, target: alpha, isVisible: false, scopeVisible: false)
    XCTAssertTrue(value.captureSink(for: alpha).needsOutput,
      "Hiding the other surface must leave this live scope consumer active")
    value.registerSurface(id: a, target: alpha, isVisible: false, scopeVisible: true)
    XCTAssertFalse(value.captureSink(for: alpha).needsOutput)
    XCTAssertEqual(demand, [])
  }

  func testExplicitlyEmptyWorkspaceIsNotRepopulatedByPreferenceUpdates() {
    let value = coordinator()
    value.workspace.tileBindings = [nil, nil, nil, nil]
    value.updateTargets(
      feeds: [FeedDescriptor(id: FeedID(rawValue: "alpha"), name: "Wide")],
      programAvailable: false)
    XCTAssertEqual(value.workspace.tileBindings, [nil, nil, nil, nil])
    let restored = MonitorCoordinator(workspace: value.workspace)
    restored.updateTargets(
      feeds: [FeedDescriptor(id: FeedID(rawValue: "alpha"), name: "Wide")],
      programAvailable: false)
    XCTAssertEqual(restored.workspace.tileBindings, [nil, nil, nil, nil])
  }

  func testCopySettingsPreservesDestinationCameraCalibration() {
    let value = coordinator()
    var source = MonitorConfiguration()
    source.toolsEnabled = true
    source.zebra.enabled = true
    source.zebra.thresholdIRE = 85
    source.sourceProfileID = "arri-logc3-ei800"
    source.sourceCodeRange = .full
    var destination = MonitorConfiguration()
    destination.sourceProfileID = "sony-slog3-sgamut3cine"
    destination.sourceCodeRange = .legal
    destination.sourceLogMapping = .fullRescaledToLegal10Bit
    destination.falseColor.referenceOffsetStops = 1
    value.setConfiguration(source, for: alpha)
    value.setConfiguration(destination, for: beta)
    value.copySettings(from: alpha, to: beta)
    let copied = value.configuration(for: beta)
    XCTAssertTrue(copied.zebra.enabled)
    XCTAssertEqual(copied.zebra.thresholdIRE, 85)
    XCTAssertEqual(copied.sourceProfileID, destination.sourceProfileID)
    XCTAssertEqual(copied.sourceCodeRange, destination.sourceCodeRange)
    XCTAssertEqual(copied.sourceLogMapping, destination.sourceLogMapping)
    XCTAssertEqual(copied.falseColor.referenceOffsetStops, 1)
    XCTAssertEqual(value.configuration(for: alpha), source)
  }

  func testCopyFalseColorModeUsesItsProfileWhilePreservingDestinationCalibration() {
    for mode in [MonitorFalseColorMode.sonySLog3, .elZone] {
      let value = coordinator()
      var source = MonitorConfiguration()
      source.toolsEnabled = true
      source.sourceProfileID = "sony-slog3-sgamut3cine"
      source.falseColor.mode = mode
      source = source.normalized()
      var destination = MonitorConfiguration()
      destination.sourceProfileID = "sony-slog3-sgamut3"
      destination.sourceCodeRange = .legal
      destination.sourceLogMapping = .fullRescaledToLegal10Bit
      destination.falseColor.mode = mode == .elZone ? .sonySLog3 : .elZone
      destination.falseColor.referenceOffsetStops = 1.25
      destination.falseColor.exposureIndex = 1600
      value.setConfiguration(source, for: alpha)
      value.setConfiguration(destination, for: beta)
      value.copySettings(from: alpha, to: beta)
      let copied = value.configuration(for: beta)
      XCTAssertEqual(copied.falseColor.mode, mode)
      XCTAssertEqual(copied.falseColor.profileID, source.falseColor.profileID)
      XCTAssertEqual(copied.falseColor.specificationVersion, source.falseColor.specificationVersion)
      XCTAssertEqual(copied.sourceProfileID, destination.sourceProfileID)
      XCTAssertEqual(copied.sourceCodeRange, destination.sourceCodeRange)
      XCTAssertEqual(copied.sourceLogMapping, destination.sourceLogMapping)
      XCTAssertEqual(copied.falseColor.referenceOffsetStops, 1.25)
      XCTAssertEqual(copied.falseColor.exposureIndex, 1600)
    }
  }

  #if CAPTURE_LIFECYCLE_TESTS
    func testNativePreviewRejectsLateFramesAfterSourceRebinding() throws {
      let renderer = VideoPreviewRenderer(renderWhenUnattached: true)
      var image: CVPixelBuffer?
      XCTAssertEqual(
        CVPixelBufferCreate(
          nil, 16, 16,
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
      let sample = try VideoContract.sample(
        try XCTUnwrap(image), at: .zero,
        duration: VideoContract.fastDuration)
      renderer.bindSource("alpha")
      renderer.enqueue(sample, sourceID: "alpha")
      XCTAssertEqual(renderer.diagnosticsSnapshot().received, 1)
      renderer.bindSource("beta")
      renderer.enqueue(sample, sourceID: "alpha")
      XCTAssertEqual(
        renderer.diagnosticsSnapshot().received, 0,
        "Already executing old-source processing must not cross the new native binding")
      renderer.enqueue(sample, sourceID: "beta")
      XCTAssertEqual(renderer.diagnosticsSnapshot().received, 1)
    }
  #endif

  func testProgramMonitoringPreservesProcessingRevisionAndSelectedPixels() throws {
    let route = ProgramOutputRoute(feedIDs: [FeedID(rawValue: "alpha"), FeedID(rawValue: "beta")])
    var observed: [(String, UInt64, Bool)] = []
    route.onMonitorFrame = { id, frame, _, _, cut in
      observed.append((id.rawValue, frame.metadata.processingRevision, cut))
    }
    func frame(revision: UInt64) throws -> ProcessedFrame<CVPixelBuffer> {
      var buffer: CVPixelBuffer?
      XCTAssertEqual(
        CVPixelBufferCreate(
          nil, 16, 16, kCVPixelFormatType_32BGRA,
          nil, &buffer), kCVReturnSuccess)
      return ProcessedFrame(
        payload: try XCTUnwrap(buffer),
        metadata: ProcessedFrameMetadata(
          presentationTime: .zero, duration: VideoContract.fastDuration, width: 16,
          height: 16, pixelFormat: kCVPixelFormatType_32BGRA, processingRevision: revision))
    }
    _ = route.ingest(feedID: FeedID(rawValue: "alpha"), frame: try frame(revision: 7))
    _ = route.ingest(feedID: FeedID(rawValue: "beta"), frame: try frame(revision: 8))
    XCTAssertEqual(observed.count, 1)
    XCTAssertEqual(observed.first?.1, 7)
    _ = route.requestCut(to: FeedID(rawValue: "beta"))
    _ = route.ingest(feedID: FeedID(rawValue: "beta"), frame: try frame(revision: 8))
    XCTAssertEqual(observed.last?.0, "beta")
    XCTAssertEqual(observed.last?.1, 8)
    XCTAssertEqual(observed.last?.2, true)
  }
}
