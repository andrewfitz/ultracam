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
      let selectedControllers = Mirror(reflecting: model).children.compactMap {
        $0.value as? CaptureController
      }
      XCTAssertEqual(selectedControllers.count, 1)
      let oldSelectedUpdate = try XCTUnwrap(selectedControllers.first?.onUpdate)
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
      if removeSelected {
        oldSelectedUpdate(CaptureUpdate(message: "Late stop from removed feed", stopped: true))
        XCTAssertEqual(removedPresenter.status, "Missing feed",
          "A queued stop from a removed controller must not overwrite the missing target")
        XCTAssertEqual(demand, [retainedTarget])
        XCTAssertEqual(coordinator.targets.map(\.id), [retainedTarget])
      }
      XCTAssertFalse(model.running)
      XCTAssertTrue(model.recordingModel.feeds.allSatisfy { $0.status == .idle })
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
    window.makeKeyAndOrderFront(nil)
    coordinator.registerSurface(id: id, target: target, isVisible: true, scopeVisible: scope)
    return (window, presenter, id)
  }

  /// Scopes beside the picture draw at their own rate (10, 15 or 30 Hz, at most
  /// the source's), with MonitorKit's legacy-look scope in a framebufferOnly
  /// layer, never more than two on the GPU, and the picture keeps every frame.
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
    let source = SyntheticSource(host: host, buffers: buffers, hz: 30, generation: 1)
    source.start()
    defer { source.stop() }
    for hz in MonitorScopePreferences.refreshRates {
      tools.scopes.refreshHz = hz
      coordinator.setPreferences(tools, for: target)
      RunLoop.main.run(until: Date().addingTimeInterval(0.6))
      let start = presenter.statistics
      let t0 = ProcessInfo.processInfo.systemUptime
      RunLoop.main.run(until: Date().addingTimeInterval(2))
      let end = presenter.statistics
      let elapsed = ProcessInfo.processInfo.systemUptime - t0
      let scopeFPS = Double(end.scopeUpdates - start.scopeUpdates) / elapsed
      let presentedFPS = Double(end.presentedFrames - start.presentedFrames) / elapsed
      let skipped = (end.scopeSkippedBusy - start.scopeSkippedBusy, end.scopeSkippedNoDrawable - start.scopeSkippedNoDrawable)
      print(
        String(
          format: "MONITOR_SURFACE_MEASURE scopes at %d Hz beside a 30 Hz picture: drawn %.2f fps, picture %.2f fps, skipped busy %llu no drawable %llu, GPU per scope %@",
          hz, scopeFPS, presentedFPS, skipped.0, skipped.1,
          end.scopeGPUMilliseconds.map { String(format: "%.3f ms", $0) } ?? "n/a"))
      let expected = Double(min(hz, 30))
      XCTAssertEqual(scopeFPS, expected, accuracy: max(1.5, expected * 0.15), "Scopes keep the chosen rate")
      XCTAssertGreaterThan(presentedFPS, 28, "The picture keeps every frame while scopes draw")
      XCTAssertLessThanOrEqual(skipped.0 + skipped.1, 2, "Scopes are rarely skipped on an idle GPU")
      XCTAssertEqual(end.failures, 0)
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

  /// Every frame of an offline synthetic source reaches the screen: the presented
  /// rate equals the source rate (a 30 Hz and a display-rate source on the
  /// display's own refresh), nothing is replaced before a refresh at 30 Hz, and
  /// the GPU time per 4K picture is reported.
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
      // Settle, then measure over three seconds.
      RunLoop.main.run(until: Date().addingTimeInterval(1))
      let start = presenter.statistics, offeredAtStart = source.count
      let t0 = ProcessInfo.processInfo.systemUptime
      RunLoop.main.run(until: Date().addingTimeInterval(3))
      let end = presenter.statistics, offeredAtEnd = source.count
      let elapsed = ProcessInfo.processInfo.systemUptime - t0
      source.stop()
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      let presentedFPS = Double(end.presentedFrames - start.presentedFrames) / elapsed
      let offeredFPS = Double(offeredAtEnd - offeredAtStart) / elapsed
      let superseded = end.supersededFrames - start.supersededFrames
      let refreshes = Double(end.refreshes - start.refreshes) / elapsed
      print(
        String(
          format: "MONITOR_SURFACE_MEASURE source %.2f Hz on a %.0f Hz display (%.1f refreshes/s, largest offer gap %.1f ms): offered %.2f fps, presented %.2f fps, superseded %llu, failures %llu, GPU per picture %@",
          hz, refresh, refreshes, source.gap * 1000, offeredFPS, presentedFPS, superseded, end.failures - before.failures,
          end.pictureGPUMilliseconds.map { String(format: "%.3f ms", $0) } ?? "n/a"))
      XCTAssertEqual(end.failures, before.failures, "No monitor failure")
      XCTAssertGreaterThan(offeredFPS, hz * 0.9, "The synthetic source kept its rate")
      if hz < refresh {
        XCTAssertEqual(presentedFPS, offeredFPS, accuracy: max(1, offeredFPS * 0.03), "Every source frame is presented")
        XCTAssertLessThanOrEqual(superseded, 2, "A refresh faster than the source replaces no frame")
      } else {
        XCTAssertGreaterThan(presentedFPS, offeredFPS * 0.9, "A display-rate source is presented at its rate")
      }
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
