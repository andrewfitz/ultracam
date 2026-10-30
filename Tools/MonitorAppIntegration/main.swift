import AppKit
import CoreMedia
import CoreVideo
import MonitorKit
import SwiftUI
import XCTest

/// Captures the registry payload emitted by the real AppModel without opening
/// the installed camera provider or registering CMIO listeners.
@MainActor private final class CapturingRegistryPublisher: AppVirtualCameraRegistryPublishing {
  private(set) var snapshots: [VirtualCameraRegistrySnapshot] = []
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) { snapshots.append(snapshot) }
}

@MainActor @objcMembers final class MonitorAppIntegrationChecks: XCTestCase {
  private let alpha = FeedID(rawValue: "monitor-integration-alpha")
  private let beta = FeedID(rawValue: "monitor-integration-beta")

  /// One camera's controller, through the model's private coordinator.
  private func controller(_ model: AppModel, _ id: FeedID) throws -> CaptureController {
    let coordinator = try XCTUnwrap(Mirror(reflecting: model).children.lazy.compactMap { $0.value as? FeedCoordinator }.first)
    return try XCTUnwrap(coordinator.capturePool.existingController(for: id))
  }

  func testRemovingIdleFeedRefreshesMonitorAndRegistryProjections() throws {
    for removeSelected in [false, true] {
      let suiteName = "org.ultracam.monitor-app-integration.\(UUID().uuidString)"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }
      let settings = AppSettingsStore(defaults: defaults)
      let registry = VirtualCameraRegistryStore(defaults: defaults)
      let publisher = CapturingRegistryPublisher()
      let removed = removeSelected ? alpha : beta
      let retained = removeSelected ? beta : alpha
      let removedTarget = MonitorTargetID(removed.rawValue)
      let retainedTarget = MonitorTargetID(retained.rawValue)
      var workspace = MonitorWorkspacePreferences()
      workspace.isConfigured = true
      workspace.tileBindings = [removedTarget.rawValue, retainedTarget.rawValue, nil, nil]
      let feeds = [
        FeedDescriptor(id: alpha, name: "Integration Wide", selectedDevice: "integration-device-a",
          applyLUT: false, automaticFeed: false),
        FeedDescriptor(id: beta, name: "Integration Tight", selectedDevice: "integration-device-b",
          applyLUT: false, automaticFeed: false),
      ]
      settings.saveSnapshot(AppSettingsSnapshot(feeds: feeds, selectedFeedID: alpha,
        outputMode: .separateCameras, monitorWorkspace: workspace))
      let model = AppModel(settingsStore: settings, registryStore: registry,
        registryPublisher: publisher, recordingFolderStore: RecordingFolderStore(defaults: defaults),
        hardware: .offline)
      // Every camera is wired at launch, selected or not.
      for id in [alpha, beta] {
        XCTAssertNotNil(try controller(model, id).onUpdate, "\(id.rawValue) is wired at launch")
      }
      let removedUpdate = try XCTUnwrap(try controller(model, removed).onUpdate)
      let coordinator = model.monitorCoordinator
      let removedID = UUID()
      let retainedID = UUID()
      let removedPresenter = coordinator.surface(id: removedID, target: removedTarget)
      let removedSink = coordinator.captureSink(for: removedTarget)
      var demand: Set<MonitorTargetID> = []
      let modelDemandChanged = coordinator.onDemandChange
      coordinator.onDemandChange = { next in
        modelDemandChanged?(next)
        demand = next
      }
      coordinator.registerSurface(id: removedID, target: removedTarget,
        isVisible: true, scopeVisible: false)
      coordinator.registerSurface(id: retainedID, target: retainedTarget,
        isVisible: true, scopeVisible: false)
      defer {
        coordinator.unregisterSurface(id: removedID)
        coordinator.unregisterSurface(id: retainedID)
      }
      XCTAssertEqual(demand, [removedTarget, retainedTarget])
      XCTAssertTrue(removedSink.hasConsumers)
      let publishedBefore = try XCTUnwrap(publisher.snapshots.last)
      XCTAssertEqual(publishedBefore.devices.count, 2)
      XCTAssertFalse(model.running)
      XCTAssertTrue(model.recordingModel.feeds.allSatisfy { $0.status == .idle })

      XCTAssertTrue(model.removeFeed(removed))

      XCTAssertEqual(model.feedDescriptors.map(\.id), [retained])
      XCTAssertEqual(model.selectedFeedID, retained)
      XCTAssertEqual(coordinator.targets.map(\.id), [retainedTarget],
        "The real removeFeed path must immediately retire the old chooser option")
      XCTAssertEqual(demand, [retainedTarget])
      XCTAssertFalse(removedSink.hasConsumers)
      XCTAssertEqual(removedPresenter.status, "Missing feed")
      XCTAssertEqual(coordinator.workspace.tileBindings[0], removedTarget.rawValue,
        "A removed feed remains visibly missing instead of silently rebinding")
      let persisted = settings.loadSnapshot()
      XCTAssertEqual(persisted.feeds.map(\.id), [retained])
      XCTAssertEqual(persisted.monitorWorkspacePreferences.tileBindings[0], removedTarget.rawValue)
      let publishedAfter = try XCTUnwrap(publisher.snapshots.last)
      XCTAssertEqual(publishedAfter.devices.compactMap(\.feedID), [retained.rawValue],
        "AppModel must publish its new topology to the camera transport boundary")
      XCTAssertGreaterThan(publishedAfter.generation, publishedBefore.generation)
      XCTAssertEqual(registry.load()?.devices, publishedAfter.devices)
      do {
        // Selected or not, a removed camera's late stop changes nothing.
        removedUpdate(CaptureUpdate(message: "Late stop from removed feed", stopped: true))
        XCTAssertEqual(removedPresenter.status, "Missing feed",
          "A queued stop from a removed controller must not overwrite the missing target")
        XCTAssertEqual(demand, [retainedTarget])
        XCTAssertEqual(coordinator.targets.map(\.id), [retainedTarget])
      }
      XCTAssertFalse(model.running)
      XCTAssertTrue(model.recordingModel.feeds.allSatisfy { $0.status == .idle })
    }
  }

  /// The burn-in LUT reaches the camera's feed host through the real AppModel
  /// wiring (`installCaptureUpdateHandler` hands the controller's `burnInLUT`
  /// to the coordinator): the very `MonitorLUT` the controller burns in while
  /// Apply LUT is on, nil while it is off, and nil at once when the feed is
  /// removed. The controller is started with `.offline` services, whose start
  /// fails before any device or camera is touched; the burn-in decision is
  /// made before that.
  func testBurnInLUTReachesTheFeedHostThroughAppModel() throws {
    let suiteName = "org.ultracam.monitor-app-integration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettingsStore(defaults: defaults)
    let feeds = [
      FeedDescriptor(id: alpha, name: "Integration Wide", selectedDevice: "integration-device-a",
        applyLUT: false, automaticFeed: false),
      FeedDescriptor(id: beta, name: "Integration Tight", selectedDevice: "integration-device-b",
        applyLUT: false, automaticFeed: false),
    ]
    settings.saveSnapshot(AppSettingsSnapshot(feeds: feeds, selectedFeedID: alpha, outputMode: .separateCameras))
    let model = AppModel(settingsStore: settings, registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: CapturingRegistryPublisher(), recordingFolderStore: RecordingFolderStore(defaults: defaults),
      hardware: .offline)
    let controller = try controller(model, alpha)
    defer { controller.stop() }
    let coordinator = model.monitorCoordinator
    let target = MonitorTargetID(alpha.rawValue)
    let host = coordinator.captureSink(for: target)
    let surfaceID = UUID()
    let presenter = coordinator.surface(id: surfaceID, target: target)
    defer { coordinator.unregisterSurface(id: surfaceID) }
    /// What the feed host shows after an encode reads the camera's LUT. A test
    /// probe: `refreshBurnInLUT` runs on the render thread in the app, but only
    /// reads the source and sets the host's LUT under their locks.
    func shown() -> MonitorLUT? {
      presenter.refreshBurnInLUT()
      return host.burnInLUT
    }
    XCTAssertNil(shown(), "Nothing loaded: no burn-in LUT")

    let lut = try LUTProcessor.makeLUT(CubeLUT(text: MonitorCoordinatorChecks.identityCube))
    let loaded = expectation(description: "LUT loaded")
    controller.load(lut) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
      loaded.fulfill()
    }
    wait(for: [loaded], timeout: 5)
    let off = PipelineConfiguration(applyLUT: false, downscale: false, convertTo420: false)
    var on = off
    on.applyLUT = true

    controller.start(feedID: FeedID(rawValue: "test"), deviceID: "monitor-integration-offline", configuration: on)
    XCTAssertTrue(spinUntil { controller.burnInLUT === lut }, "Apply LUT on burns the loaded LUT in")
    let withLUT = shown()
    XCTAssertNotNil(withLUT, "Apply LUT on: the feed host has the burn-in LUT")
    XCTAssertTrue(withLUT === controller.burnInLUT, "The feed host shows the very LUT the camera burns in")

    controller.start(feedID: FeedID(rawValue: "test"), deviceID: "monitor-integration-offline", configuration: off)
    XCTAssertTrue(spinUntil { controller.burnInLUT == nil }, "Apply LUT off burns nothing in")
    XCTAssertNil(shown(), "Apply LUT off: the feed host has no burn-in LUT")

    controller.start(feedID: FeedID(rawValue: "test"), deviceID: "monitor-integration-offline", configuration: on)
    XCTAssertTrue(spinUntil { controller.burnInLUT === lut })
    XCTAssertTrue(shown() === lut)
    XCTAssertFalse(model.running)
    XCTAssertTrue(model.removeFeed(alpha))
    XCTAssertNil(host.burnInLUT, "Removing the feed clears its burn-in LUT at once")
    XCTAssertNil(shown(), "A removed feed's surfaces no longer read the old controller")
  }

  /// Every camera on automatic start, at launch, whichever is selected: its saved
  /// LUT restores, then a visible picture's demand starts it, and real frames flow
  /// from the controller to a drawn picture. The picture's Output stage draws the
  /// LUT (MonitorKit's own account of what it drew), as the camera's output does.
  func testEveryCameraRestoredBeforeAutomaticStartDrawsItsLUT() throws {
    guard (try? MonitorCoordinator.sharedGPU.core()) != nil else { throw XCTSkip("No Metal 4 device") }
    let suiteName = "org.ultracam.monitor-app-integration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-lut-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var lattice = ["TITLE \"Integration LUT\"", "LUT_3D_SIZE 2"]
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { lattice.append("\(1 - Float(r)) \(1 - Float(g)) \(1 - Float(b))") } } }
    let cube = folder.appendingPathComponent("integration.cube")
    try lattice.joined(separator: "\n").write(to: cube, atomically: true, encoding: .utf8)
    let settings = AppSettingsStore(defaults: defaults)
    settings.saveSnapshot(AppSettingsSnapshot(feeds: [
      FeedDescriptor(id: alpha, name: "Integration Wide", selectedDevice: "fake:fixture-a",
        applyLUT: false, automaticFeed: true),
      FeedDescriptor(id: beta, name: "Integration Tight", selectedDevice: "fake:fixture-b",
        applyLUT: false, automaticFeed: true),
    ], selectedFeedID: alpha, outputMode: .separateCameras))
    let fixture = try AppHardwareSyntheticFixture(duration: VideoContract.slowDuration, deviceIDs: ["fake:fixture-a", "fake:fixture-b"])
    fixture.connect()
    let hardware = fixture.hardware
    let pattern = try fixture.makePattern()
    defer { fixture.stop() }
    func makeModel() -> AppModel {
      AppModel(settingsStore: settings, lutLoader: LUTFileLoader(scopedBookmarks: false),
        registryStore: VirtualCameraRegistryStore(defaults: defaults), registryPublisher: fixture.publisher,
        recordingFolderStore: RecordingFolderStore(defaults: defaults), hardware: hardware)
    }
    do {
      let setup = makeModel()
      setup.loadLUT(url: cube, feedID: alpha)
      XCTAssertTrue(spinUntil(seconds: 10) { setup.lutState(alpha).loaded }, "The LUT is saved for Camera 1")
      setup.loadLUT(url: cube, feedID: beta)
      XCTAssertTrue(spinUntil(seconds: 10) { setup.descriptor(for: beta)?.applyLUT == true }, "The LUT is saved for Camera 2")
    }
    // The same for either selection: selection never changes a camera's pipeline.
    for selected in [alpha, beta] {
      let label = selected == alpha ? "Camera 1 selected" : "Camera 2 selected"
      var snapshot = settings.loadSnapshot()
      snapshot.selectedFeedID = selected
      settings.saveSnapshot(snapshot)
      let sessionsBefore = fixture.plugin.sessions.count
      let model = makeModel()
      let coordinator = model.monitorCoordinator
      // Both pictures are on screen at launch while both cameras restore their LUTs.
      let (windowA, presenterA, idA) = pictureWindow(coordinator, target: MonitorTargetID(alpha.rawValue),
        points: CGSize(width: 480, height: 270))
      let (windowB, presenterB, idB) = pictureWindow(coordinator, target: MonitorTargetID(beta.rawValue),
        points: CGSize(width: 480, height: 270))
      defer {
        coordinator.unregisterSurface(id: idA)
        coordinator.unregisterSurface(id: idB)
        windowA.close()
        windowB.close()
        model.stopCamera(beta)
        model.stopCamera(alpha)
      }
      XCTAssertTrue(spinUntil(seconds: 10) {
        model.isCameraRunning(alpha) && model.isCameraRunning(beta) &&
          model.burnInLUT(for: alpha) != nil && model.burnInLUT(for: beta) != nil
      }, "Both cameras start on demand with their LUTs burned in (\(label))")
      XCTAssertTrue(spinUntil(seconds: 5) { fixture.plugin.sessions.count >= sessionsBefore + 2 })
      var index = 0
      func drawsLUT(_ presenter: MonitorSurfacePresenter) -> Bool {
        presenter.shownStatus.activeLabels.contains { $0.hasPrefix("LUT") }
      }
      let drawn = spinUntil(seconds: 10) {
        index += 1
        do {
          let emitted = try fixture.emit(pattern, index: Int32(index))
          XCTAssertGreaterThanOrEqual(emitted, 2)
        }
        catch { XCTFail("Typed synthetic source failed: \(error)") }
        RunLoop.main.run(until: Date().addingTimeInterval(1 / 30))
        return drawsLUT(presenterA) && drawsLUT(presenterB)
      }
      XCTAssertTrue(drawn)
      XCTAssertTrue(drawsLUT(presenterA), "Camera 1's Output stage draws its LUT (\(label)): \(presenterA.shownStatus.activeLabels)")
      XCTAssertTrue(drawsLUT(presenterB), "Camera 2's Output stage draws its LUT (\(label)): \(presenterB.shownStatus.activeLabels)")
      for id in [alpha, beta] {
        XCTAssertEqual(coordinator.preferences(for: MonitorTargetID(id.rawValue)).state.pictureStage, .output)
      }
    }
  }

  func testDetachedWindowCanClearAndRebindTheTargetUsedByItsChooser() throws {
    let alphaTarget = MonitorTargetID(alpha.rawValue)
    let betaTarget = MonitorTargetID(beta.rawValue)
    let coordinator = MonitorCoordinator()
    coordinator.updateTargets(feeds: [
      FeedDescriptor(id: alpha, name: "Integration Wide"),
      FeedDescriptor(id: beta, name: "Integration Tight"),
    ], programAvailable: false)
    let workspaceBefore = coordinator.workspace
    var demand: Set<MonitorTargetID> = []
    coordinator.onDemandChange = { demand = $0 }
    let owner = MonitorDetachedWindows.open(coordinator: coordinator, target: alphaTarget)
    let detached = owner.window
    defer { detached.close() }
    XCTAssertTrue(spinUntil { demand == [alphaTarget] })
    XCTAssertEqual(detached.title, "Monitor · Integration Wide")
    XCTAssertGreaterThan(try XCTUnwrap(detached.contentView).fittingSize.height, 100)

    // The actual target picker binds directly to this window-owned state.
    owner.target = nil

    XCTAssertTrue(spinUntil { demand.isEmpty }, "Clearing a detached tile must retire its old surface")
    XCTAssertFalse(coordinator.captureSink(for: alphaTarget).hasConsumers)
    detached.contentView?.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(try XCTUnwrap(detached.contentView).fittingSize.height, 100,
      "An empty detached monitor must retain its chooser and visible empty-state picture")
    XCTAssertEqual(detached.title, "Monitor · Choose a feed")

    owner.target = betaTarget

    XCTAssertTrue(spinUntil { demand == [betaTarget] })
    XCTAssertFalse(coordinator.captureSink(for: alphaTarget).hasConsumers)
    // OS occlusion may suspend pixel work while the new presented target's
    // capture intent remains active; demand is the rebind contract here.
    XCTAssertEqual(detached.title, "Monitor · Integration Tight")
    XCTAssertGreaterThan(try XCTUnwrap(detached.contentView).fittingSize.height, 100)
    XCTAssertEqual(coordinator.workspace, workspaceBefore,
      "Detached choices must remain independent of main workspace bindings")
    detached.close()
    XCTAssertTrue(spinUntil { demand.isEmpty })
  }

  // MARK: - Surfaces in a window

  /// A window showing `target`'s picture (and scope), drawn by its display link.
  private func pictureWindow(
    _ coordinator: MonitorCoordinator, target: MonitorTargetID, points: CGSize, scope: Bool = false
  ) -> (NSWindow, MonitorSurfacePresenter, UUID) {
    MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = true
    let id = UUID()
    let presenter = coordinator.surface(id: id, target: target)
    let scopeHeight = scope ? 128.0 : 0
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: CGSize(width: points.width, height: points.height + scopeHeight)),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: VStack(spacing: 0) {
        MonitorNativePicture(presenter: presenter).frame(width: points.width, height: points.height)
        if scope { MonitorNativeScope(presenter: presenter).frame(width: points.width, height: scopeHeight) }
      })
    // Invisible and never key: these runs must not flash windows or take focus.
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.hasShadow = false
    window.animationBehavior = .none
    window.collectionBehavior = [.transient, .ignoresCycle]
    window.orderFrontRegardless()
    coordinator.registerSurface(id: id, target: target, isVisible: true, scopeVisible: scope)
    return (window, presenter, id)
  }

  /// Scopes obey the saved 10/15/30 Hz ceiling while the picture keeps every
  /// source frame. Scopes use their own display link and never hold the picture
  /// back, even when analysis updates less often than the video.
  func testScopesDrawAtTheirRateBesideThePicture() throws {
    guard (try? MonitorCoordinator.sharedGPU.core()) != nil else { throw XCTSkip("No Metal 4 device") }
    let coordinator = MonitorCoordinator()
    coordinator.updateTargets(feeds: [FeedDescriptor(id: alpha, name: "Integration Wide")], programAvailable: false)
    let target = MonitorTargetID(alpha.rawValue)
    var tools = coordinator.preferences(for: target)
    tools.toolsEnabled = true
    tools.scopes.enabled = true
    coordinator.setPreferences(tools, for: target)
    let (window, presenter, id) = pictureWindow(
      coordinator, target: target, points: CGSize(width: 640, height: 360), scope: true)
    defer {
      coordinator.unregisterSurface(id: id)
      window.close()
    }
    let host = coordinator.captureSink(for: target)
    let buffers = try pool(6, width: 3840, height: 2160, format: kCVPixelFormatType_422YpCbCr10)
    let pictureHz = 30.0
    let source = SyntheticSource(host: host, buffers: buffers, hz: pictureHz, generation: 1)
    source.start()
    defer { source.stop() }
    let displayHz = Double(window.screen?.maximumFramesPerSecond ?? 60)
    // Each saved rate caps scope updates independently of picture delivery.
    for hz in MonitorScopePreferences.refreshRates {
      tools.scopes.refreshHz = hz
      coordinator.setPreferences(tools, for: target)
      RunLoop.main.run(until: Date().addingTimeInterval(0.6))
      let rounds = 3
      var round = 0
      var settled = false
      while round < rounds && !settled {
        round += 1
        let start = presenter.statistics, offeredAtStart = source.count
        let t0 = ProcessInfo.processInfo.systemUptime
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let end = presenter.statistics, offeredAtEnd = source.count
        let elapsed = ProcessInfo.processInfo.systemUptime - t0
        let offered = Double(offeredAtEnd - offeredAtStart)
        let scopes = Double(end.scopeUpdates - start.scopeUpdates)
        let presented = Double(end.presentedFrames - start.presentedFrames)
        let scopeFPS = scopes / elapsed
        let presentedFPS = presented / elapsed
        let refreshesFPS = Double(end.refreshes - start.refreshes) / elapsed
        let scopeTicks = Double(end.scopeRefreshes - start.scopeRefreshes)
        let skipped = (end.scopeSkippedBusy - start.scopeSkippedBusy, end.scopeSkippedNoDrawable - start.scopeSkippedNoDrawable)
        print(
          String(
            format: "MONITOR_SURFACE_MEASURE scopes (selected ceiling %d Hz) beside a %.0f Hz picture, round %d (%.1f refreshes/s on a %.0f Hz display, scope link %.1f ticks/s): drawn %.2f fps, picture %.2f fps, skipped busy %llu no drawable %llu, GPU per scope %@",
            hz, pictureHz, round, refreshesFPS, displayHz, scopeTicks / elapsed, scopeFPS, presentedFPS, skipped.0,
            skipped.1, end.scopeGPUMilliseconds.map { String(format: "%.3f ms", $0) } ?? "n/a"))
        // A scope is drawn only on a callback of the scope's own display link
        // (`MonitorSurfaceStatistics.scopeRefreshes`), at most one per callback.
        XCTAssertLessThanOrEqual(scopes, scopeTicks + 2, "A scope is drawn on at most one scope-link tick each")
        // At most one scope per drawn picture (a picture already scoped is never
        // redrawn): the physical ceiling. The tolerance is the window's edges: a
        // scope pending at its start and the picture count's own edge.
        XCTAssertLessThanOrEqual(scopes, presented + 3, "Scopes never draw faster than new pictures arrive")
        XCTAssertEqual(end.failures, 0)
        // The rate checks below depend on the render thread getting its display
        // links' callbacks, which a loaded machine delays (both links run on that
        // one thread), so a round that misses any of them is re-measured, up to
        // three rounds, and they are asserted together once a round meets them all
        // or on the last. The ceiling and the failure count above hold in every round.
        //
        // The useful floor follows the selected ceiling or the available
        // pictures, whichever is slower. Allow display-grid scheduling jitter.
        let scopeFloor = 0.85 * min(Double(hz) * elapsed, presented)
        XCTAssertLessThanOrEqual(scopes, Double(hz) * elapsed + 2,
          "Scopes obey the selected \(hz) Hz ceiling, allowing interval edges")
        let scopeRateMet = scopes >= scopeFloor
        let skipsMet = skipped.0 + skipped.1 <= 2
        // Strict: a 30 Hz picture has every frame presented while scopes draw. A
        // frame goes unpresented only if the display link delivered no refresh for
        // a whole picture interval, at least displayHz / pictureHz - 1 refreshes in
        // a row (the render thread starved). So a picture miss is re-measured only
        // when the refreshes the link failed to deliver account for every
        // unpresented frame; otherwise it fails at once.
        let pictureMet = presentedFPS > 28
        let missedRefreshes = max(0, displayHz * elapsed - refreshesFPS * elapsed)
        let starved = max(0, offered - presented) * (displayHz / pictureHz - 1) <= missedRefreshes
        if (pictureMet && scopeRateMet && skipsMet) || (!pictureMet && !starved) || round == rounds {
          XCTAssertGreaterThanOrEqual(scopes, scopeFloor,
            "Scopes reach the selected \(hz) Hz rate or picture rate in one of \(rounds) rounds (the last shown)")
          XCTAssertGreaterThan(scopeFPS, 0.85 * min(Double(hz), pictureHz),
            "Scopes sustain their selected rate in one of \(rounds) rounds (the last shown)")
          XCTAssertLessThanOrEqual(skipped.0 + skipped.1, 2,
            "Scopes are rarely skipped in one of \(rounds) rounds (the last shown)")
          XCTAssertGreaterThan(presentedFPS, 28, "The picture keeps every frame while scopes draw: scopes never hold it back")
          settled = true
        }
      }
    }
  }

  /// Offers synthetic frames at `hz` from a delivery thread of their own, as a camera does.
  private final class SyntheticSource: @unchecked Sendable {
    private let host: MonitorFeedHost
    private let buffers: [CVPixelBuffer]
    private let hz: Double
    private let generation: UInt64
    private let lock = NSLock()
    private var running = true
    private(set) var offered = 0
    /// Each source is a capture generation of its own (a camera start).
    init(host: MonitorFeedHost, buffers: [CVPixelBuffer], hz: Double, generation: UInt64) {
      self.host = host
      self.buffers = buffers
      self.hz = hz
      self.generation = generation
    }
    /// The largest interval between two offers, in seconds: a late offer would
    /// make the next two land on one refresh.
    private(set) var maximumGap = 0.0
    func start() {
      let thread = Thread { [self] in
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
        // A capture thread's scheduling: a real-time period of one frame, so the
        // test process's timer coalescing never bunches frames.
        var policy = thread_time_constraint_policy_data_t(
          period: UInt32(ticksPerSecond / hz), computation: UInt32(ticksPerSecond * 0.001),
          constraint: UInt32(ticksPerSecond * 0.004), preemptible: 1)
        let count = mach_msg_type_number_t(
          MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &policy) {
          $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
          }
        }
        let start = mach_absolute_time()
        var sequence: UInt64 = 0
        var last = ProcessInfo.processInfo.systemUptime
        while lock.withLock({ running }) {
          sequence += 1
          let buffer = buffers[Int(sequence) % buffers.count]
          host.offer(buffer, pts: CMTime(value: CMTimeValue(sequence), timescale: CMTimeScale(hz.rounded())),
            captureGeneration: generation, sequence: sequence)
          let now = ProcessInfo.processInfo.systemUptime
          lock.withLock {
            offered += 1
            if sequence > 1 { maximumGap = max(maximumGap, now - last) }
          }
          last = now
          // A camera's cadence: each frame at its own time, never a burst to catch up.
          mach_wait_until(start + UInt64(Double(sequence) / hz * ticksPerSecond))
        }
      }
      thread.qualityOfService = .userInteractive
      thread.start()
    }
    var gap: Double { lock.withLock { maximumGap } }
    func stop() { lock.withLock { running = false } }
    var count: Int { lock.withLock { offered } }
  }

  private func pool(_ count: Int, width: Int, height: Int, format: OSType, tag: ((CVPixelBuffer) -> Void)? = nil)
    throws -> [CVPixelBuffer]
  {
    try (0..<count).map { _ in
      var made: CVPixelBuffer?
      XCTAssertEqual(
        CVPixelBufferCreate(nil, width, height, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made),
        kCVReturnSuccess)
      let buffer = try XCTUnwrap(made)
      tag?(buffer)
      return buffer
    }
  }

  /// Every frame of an offline synthetic source is accounted for: each offered
  /// frame is presented or counted as replaced before a refresh. A 30 Hz and a
  /// 60 Hz source on a faster display have every frame presented and none
  /// replaced; a source at the display's own rate is presented on most of the
  /// refreshes the display link delivers, and the link delivers 90% of the
  /// display's refreshes with a 4K picture's GPU time inside one refresh.
  func testSyntheticSourcePresentsEveryFrameAtTheSourceRate() throws {
    guard (try? MonitorCoordinator.sharedGPU.core()) != nil else { throw XCTSkip("No Metal 4 device") }
    let coordinator = MonitorCoordinator()
    coordinator.updateTargets(feeds: [FeedDescriptor(id: alpha, name: "Integration Wide")], programAvailable: false)
    let target = MonitorTargetID(alpha.rawValue)
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let (window, presenter, id) = pictureWindow(coordinator, target: target, points: CGSize(width: 1920 / scale, height: 1080 / scale))
    defer {
      coordinator.unregisterSurface(id: id)
      window.close()
    }
    let host = coordinator.captureSink(for: target)
    let buffers = try pool(6, width: 3840, height: 2160, format: kCVPixelFormatType_422YpCbCr10)
    let refresh = Double(window.screen?.maximumFramesPerSecond ?? 60)
    // A 30 Hz and a 60 Hz camera, and one at the display's own rate.
    let rates = refresh > 60 ? [30.0, 60, refresh] : [30.0, refresh]
    for (index, hz) in rates.enumerated() {
      let source = SyntheticSource(host: host, buffers: buffers, hz: hz, generation: UInt64(index + 1))
      let before = presenter.statistics
      source.start()
      // Settle, then measure over three seconds. The rate checks depend on how many
      // refreshes a loaded machine's display link delivers (and, for a display-rate
      // source, on its phase against the source), so a round that misses them is
      // re-measured, up to three rounds, as described below; the accounting and
      // the ceiling hold in every round.
      RunLoop.main.run(until: Date().addingTimeInterval(1))
      let rounds = 3
      var round = 0
      var floorsMet = false
      while round < rounds && !floorsMet {
        round += 1
        let start = presenter.statistics, offeredAtStart = source.count
        let t0 = ProcessInfo.processInfo.systemUptime
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let end = presenter.statistics, offeredAtEnd = source.count
        let elapsed = ProcessInfo.processInfo.systemUptime - t0
        let offered = offeredAtEnd - offeredAtStart
        let accepted = Int(end.acceptedFrames - start.acceptedFrames)
        let presented = Int(end.presentedFrames - start.presentedFrames)
        let superseded = Int(end.supersededFrames - start.supersededFrames)
        let refreshes = Int(end.refreshes - start.refreshes)
        let presentedFPS = Double(presented) / elapsed
        let offeredFPS = Double(offered) / elapsed
        let refreshesFPS = Double(refreshes) / elapsed
        print(
          String(
            format: "MONITOR_SURFACE_MEASURE source %.2f Hz on a %.0f Hz display, round %d (%.1f refreshes/s, largest offer gap %.1f ms): offered %.2f fps, accepted %d of %d, presented %.2f fps, superseded %d, failures %llu, GPU per picture %@",
            hz, refresh, round, refreshesFPS, source.gap * 1000, offeredFPS, accepted, offered, presentedFPS, superseded,
            end.failures - before.failures, end.pictureGPUMilliseconds.map { String(format: "%.3f ms", $0) } ?? "n/a"))
        XCTAssertEqual(end.failures, before.failures, "No monitor failure")
        XCTAssertGreaterThan(offeredFPS, hz * 0.9, "The synthetic source kept its rate")
        // No frame is lost, at any load: every offered frame is accepted, and every
        // accepted frame is presented or counted as replaced before a refresh took
        // it. The tolerance is the one frame that may be in flight at each end of
        // the window (the surface's newest-frame slot, and the source's count
        // read racing an offer).
        XCTAssertLessThanOrEqual(abs(accepted - offered), 2, "Every offered frame reaches the surface")
        XCTAssertLessThanOrEqual(abs(presented + superseded - accepted), 2,
          "Every accepted frame is presented or counted as superseded: none is lost")
        // The physical maximum: one new picture per delivered refresh, and none the
        // source did not offer.
        let ceiling = min(offered, refreshes)
        XCTAssertLessThanOrEqual(presented, ceiling + 2, "At most one new picture per refresh and per offered frame")
        if hz < refresh {
          // Strict: every frame presented, none replaced. A frame of a source slower
          // than the display goes unpresented only if the display link delivered no
          // refresh for a whole source interval, at least refresh / hz - 1
          // refreshes in a row (three at 60 Hz on a 240 Hz display): the render
          // thread was starved. So a miss is re-measured, up to three rounds, only
          // when the refreshes the link failed to deliver account for every
          // unpresented frame (offered, not superseded, so an uncounted loss is
          // never excused); otherwise it fails at once.
          let strictMet = abs(presentedFPS - offeredFPS) <= max(1, offeredFPS * 0.03) && superseded <= 2
          let missedRefreshes = max(0, refresh * elapsed - Double(refreshes))
          let starved = Double(max(0, offered - presented)) * (refresh / hz - 1) <= missedRefreshes
          if strictMet || !starved || round == rounds {
            XCTAssertEqual(presentedFPS, offeredFPS, accuracy: max(1, offeredFPS * 0.03), "Every source frame is presented")
            XCTAssertLessThanOrEqual(superseded, 2, "A refresh faster than the source replaces no frame")
            floorsMet = true
          }
        } else {
          // The display link itself is the regression check. It calls back only
          // when it has a drawable, so a picture path that takes longer than a
          // refresh (render thread or GPU), or a link capped below the display's
          // rate, delivers fewer refreshes and presents one picture on each: the
          // floors relative to delivered refreshes would hold, and the frames it
          // cannot take are superseded, which the accounting above also balances.
          // So the link must deliver 90% of the display's refreshes (an idle
          // machine delivers 98-100%; a picture path of 5 ms on a 240 Hz display
          // delivers 83%), and a 4K picture's GPU time must fit in one refresh
          // (about 0.3 ms measured). A loaded machine delivers fewer, so a round
          // under them is re-measured.
          let refreshFloor = 0.9 * refresh
          let gpuBudget = 1000 / refresh
          let gpuMilliseconds = end.pictureGPUMilliseconds ?? .infinity
          // A source at the refresh rate is phase-bound: when offer or callback
          // jitter straddles the display link's tick, one refresh finds no new
          // frame and the next finds two (the older is superseded, and counted
          // above). With jitter shorter than a refresh and independent from one to
          // the next, a refresh is empty only when its own frame is late and the
          // one before was not, q(1 - q) <= 1/4 of them, so a correct presenter
          // fills at least 3/4 at any phase (idle rounds fill 86-100%); a presenter
          // that took only every other refresh fills at most 1/2. A loaded
          // machine's late callbacks come in bursts and fill less (58% has been
          // seen at 229 refreshes/s); such a round is re-measured. The floor sits
          // midway between a presenter that drops one frame in three (2/3) and the
          // model's worst correct phase (3/4, about 0.71 of the ceiling): the
          // dropping presenter fails it, as one taking every other refresh does,
          // and a correct one at the worst phase keeps a margin for sampling noise.
          let presentationFloor = (2.0 / 3.0 + 3.0 / 4.0) / 2 * Double(ceiling)
          floorsMet = Double(presented) >= presentationFloor && refreshesFPS >= refreshFloor
            && gpuMilliseconds < gpuBudget
          if !floorsMet && round == rounds {
            XCTAssertGreaterThanOrEqual(Double(presented), presentationFloor,
              "A display-rate source fills most refreshes in one of \(rounds) rounds (the last shown)")
            XCTAssertGreaterThanOrEqual(refreshesFPS, refreshFloor,
              "The display link delivers 90% of the display's refreshes in one of \(rounds) rounds (the last shown)")
            XCTAssertLessThan(gpuMilliseconds, gpuBudget,
              "A 4K picture's GPU time fits in one refresh in one of \(rounds) rounds (the last shown)")
          }
        }
      }
      source.stop()
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
  }

  /// HLG and PQ frames switch the picture layer to EDR with their own colour
  /// space (BT.709 primaries kept), and SDR frames switch it back.
  func testHLGAndPQFramesSwitchThePictureLayer() throws {
    guard (try? MonitorCoordinator.sharedGPU.core()) != nil else { throw XCTSkip("No Metal 4 device") }
    let coordinator = MonitorCoordinator()
    coordinator.updateTargets(feeds: [FeedDescriptor(id: beta, name: "Integration Tight")], programAvailable: false)
    let target = MonitorTargetID(beta.rawValue)
    let (window, presenter, id) = pictureWindow(coordinator, target: target, points: CGSize(width: 320, height: 180))
    defer {
      coordinator.unregisterSurface(id: id)
      window.close()
    }
    let host = coordinator.captureSink(for: target)
    func tagged(transfer: CFString?, primaries: CFString, matrix: CFString) throws -> [CVPixelBuffer] {
      try pool(3, width: 64, height: 36, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) { buffer in
        if let transfer { CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate) }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
      }
    }
    let cases: [(String, [CVPixelBuffer], MTLPixelFormat, CFString, Bool)] = [
      ("HLG BT.2020", try tagged(transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
        primaries: kCVImageBufferColorPrimaries_ITU_R_2020, matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020),
        .rgba16Float, CGColorSpace.itur_2100_HLG, true),
      ("PQ BT.2020", try tagged(transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
        primaries: kCVImageBufferColorPrimaries_ITU_R_2020, matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020),
        .rgba16Float, CGColorSpace.itur_2100_PQ, true),
      ("HLG BT.709", try tagged(transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
        primaries: kCVImageBufferColorPrimaries_ITU_R_709_2, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        .rgba16Float, CGColorSpace.itur_709_HLG, true),
      ("SDR BT.709", try tagged(transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
        primaries: kCVImageBufferColorPrimaries_ITU_R_709_2, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        .bgr10a2Unorm, CGColorSpace.itur_709, false),
    ]
    var generation: UInt64 = 0
    for (name, buffers, format, space, edr) in cases {
      generation += 1
      let source = SyntheticSource(host: host, buffers: buffers, hz: 30, generation: generation)
      source.start()
      let switched = spinUntil(seconds: 3) {
        guard let layer = presenter.pictureLayer else { return false }
        return layer.pixelFormat == format && layer.colorspace?.name == space
          && layer.wantsExtendedDynamicRangeContent == edr && (layer.edrMetadata != nil) == edr
      }
      source.stop()
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
      let layer = presenter.pictureLayer
      print("MONITOR_SURFACE_MEASURE layer for \(name): \(layer.map { "\($0.pixelFormat.rawValue) \($0.colorspace?.name as String? ?? "nil") EDR \($0.wantsExtendedDynamicRangeContent)" } ?? "no layer")")
      XCTAssertTrue(switched, "\(name) frames tag the picture layer")
    }
    XCTAssertEqual(presenter.statistics.failures, 0)
  }

  private func spinUntil(seconds: Double, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
      if predicate() { return true }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    } while Date() < deadline
    return predicate()
  }

  private func spinUntil(_ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(2)
    repeat {
      if predicate() { return true }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    } while Date() < deadline
    return predicate()
  }

}

// Frames on a camera's cadence: no App Nap timer coalescing in this test process.
let activity = ProcessInfo.processInfo.beginActivity(
  options: [.userInitiated, .latencyCritical], reason: "Monitor presentation timing checks")
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.finishLaunching()

let suite = XCTestSuite(name: "Ultracam App monitor integration")
suite.addTest(XCTestSuite(forTestCaseClass: MonitorAppIntegrationChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: MonitorCoordinatorChecks.self))
suite.run()
guard let run = suite.testRun, run.executionCount > 0 else { exit(2) }
ProcessInfo.processInfo.endActivity(activity)
exit(run.hasSucceeded ? 0 : 1)
