import AppKit
import CoreMedia
import CoreVideo
import Darwin
import SwiftUI
import Synchronization

// The live main window's main-thread cost, measured offscreen: the real view tree
// (UILiveRoot, UIMainWindowView, toolbar) over a real AppModel whose cameras run on
// scripted capture (frames at 59.94 Hz, timecode and audio with every frame, so the
// capture updates, meters and monitor surfaces run as they do with an UltraStudio).
// The window is on the main screen but invisible (`orderInvisiblyForTesting`), so the
// display link, meters and Metal surfaces tick. It reports body evaluations per second
// per view, main-thread busy time, run loop hitches and display ticks, idle and while
// the sidebar and inspector are toggled, and checks them against budgets.
// UI_PERF_ONLY=1 runs only this check; UI_PERF_CAMERAS=2,4 picks the camera counts.

/// Scripted UltraStudios: each started device gets a thread that delivers frames,
/// timecode and embedded audio at 59.94 Hz until it is stopped.
final class ScriptedLiveCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var running: Set<String> = []
  private var generation: [String: Int] = [:]
  private let buffers: [CVPixelBuffer]

  init() {
    buffers = (0..<6).compactMap { _ in
      var made: CVPixelBuffer?
      CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &made)
      if let made {
        CVBufferSetAttachment(made, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
      }
      return made
    }
  }

  func services() -> CaptureServices {
    var services = CaptureServices(
      start: { _, _, _, _ in throw CocoaError(.featureUnsupported) },
      startWithSourceAudio: { [self] device, _, frames, media, audio, _ in
        start(device, frames: frames, media: media, audio: audio)
      },
      stop: {}, connect: { _, _ in }, disconnect: {}, send: { _ in true })
    services.capturePixelFormat = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    return services
  }

  func stopAll() { lock.withLock { running.removeAll() } }

  private func start(_ device: String, frames: @escaping (CVPixelBuffer, CMTime, Bool) -> Void,
    media: @escaping (CaptureMediaStats) -> Void, audio: @escaping (CaptureRawAudio) -> Void) {
    let token = lock.withLock { () -> Int in
      running.insert(device)
      generation[device, default: 0] += 1
      return generation[device]!
    }
    let buffers = buffers
    let thread = Thread { [self] in
      var timebase = mach_timebase_info_data_t()
      mach_timebase_info(&timebase)
      let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
      let start = mach_absolute_time()
      let hz = 60_000.0 / 1001
      let samplesPerFrame = 801
      var sequence: Int64 = 0
      var phase = 0.0
      while lock.withLock({ running.contains(device) && generation[device] == token }) {
        let pts = CMTimeMultiply(VideoContract.fastDuration, multiplier: Int32(truncatingIfNeeded: sequence))
        frames(buffers[Int(sequence) % buffers.count], pts, true)
        // A 1 kHz tone whose level drifts, so the peaks and timecode change with every update.
        let level = 0.25 + 0.2 * sin(Double(sequence) / 40)
        var pcm = [Int32](repeating: 0, count: samplesPerFrame * 2)
        for frame in 0..<samplesPerFrame {
          let value = Int32(level * sin(phase) * Double(Int32.max))
          pcm[frame * 2] = value
          pcm[frame * 2 + 1] = value / 2
          phase += 2 * .pi * 1000 / 48_000
        }
        let packetTime = CMTime(value: sequence * Int64(samplesPerFrame), timescale: 48_000)
        audio(CaptureRawAudio(samples: pcm.withUnsafeBytes { Data($0) }, packetTime: packetTime,
          sampleFrames: UInt64(samplesPerFrame), channels: 2, bytesPerSample: 4))
        let seconds = Int(Double(sequence) / hz)
        let timecode = String(format: "14:%02d:%02d:%02d", (seconds / 60) % 60, seconds % 60, Int(sequence) % 60)
        media(CaptureMediaStats(timecode: timecode, audioPacketTime: packetTime, audioSampleFrames: UInt64(samplesPerFrame),
          audioChannels: 2, leftPeak: level, rightPeak: level / 2, leftRMS: level * 0.7, rightRMS: level * 0.35,
          audioBytes: UInt64(pcm.count * 4), audioPresent: true))
        sequence += 1
        // Each frame at its own time, never a burst to catch up.
        mach_wait_until(start + UInt64(Double(sequence) / hz * ticksPerSecond))
      }
    }
    thread.qualityOfService = .userInteractive
    thread.start()
  }
}

/// Main-thread CPU time, run loop busy stretches (hitches) and display ticks.
@MainActor final class MainThreadMeter: NSObject {
  private(set) var displayTicks = 0
  private var observer: CFRunLoopObserver?
  private var wokeAt: UInt64 = 0
  private(set) var stretches: [Double] = []
  private var link: CADisplayLink?

  init(view: NSView) {
    super.init()
    link = view.displayLink(target: self, selector: #selector(tick))
    link?.add(to: .main, forMode: .common)
    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
      true, 0) { [weak self] _, activity in
      MainActor.assumeIsolated {
        guard let self else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if activity == .afterWaiting { self.wokeAt = now } else if self.wokeAt != 0 {
          self.stretches.append(Double(now - self.wokeAt) / 1e6)
          self.wokeAt = 0
        }
      }
    }
    self.observer = observer
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
  }

  @objc private func tick() { displayTicks += 1 }

  func stop() {
    link?.invalidate()
    if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
  }

  func reset() {
    displayTicks = 0
    stretches = []
  }

  /// CPU time of the calling (main) thread, in seconds.
  static func mainThreadCPU() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
  }

  /// CPU time of the whole process, in seconds.
  static func processCPU() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
  }
}

/// One measured interval.
struct LivePerformanceSample {
  var seconds: Double
  var busy: Double
  var process: Double
  var bodies: [String: Double]
  var displayHz: Double
  var hitches8: Int
  var hitches16: Int
  var longest: Double

  func rate(_ name: String) -> Double { bodies[name] ?? 0 }

  var summary: String {
    let views = bodies.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.1f", $0.value))" }.joined(separator: " ")
    return String(format: "main %.1f%% process %.0f%% display %.0f Hz hitches>8ms %d >16ms %d longest %.1f ms | bodies/s ", busy * 100, process * 100,
      displayHz, hitches8, hitches16, longest) + views
  }
}

@MainActor enum LivePerformanceVerify {
  /// Views that must not re-evaluate while nothing but telemetry changes.
  static let structural = ["UILiveRoot", "UIMainWindowView", "UISessionSidebarView", "UISessionSidebarViewContent",
    "UIInspectorView", "UIInspectorViewContent", "UIToolbarContent", "UICameraColumnView", "UICameraPictureView",
    "UIChannelStripView", "UIStatusBarView"]

  static func run(verifier: Verifier) {
    let counts = (ProcessInfo.processInfo.environment["UI_PERF_CAMERAS"] ?? "2,4").split(separator: ",").compactMap { Int($0) }
    for cameras in counts {
      // With live meters (as in the app), then with the meters showing fixed readings: MonitorKit's
      // LevelMeterView redraws at the display rate in a TimelineView, and each of its frames lays out,
      // renders and commits the whole window's SwiftUI graph, so the second run measures the rest.
      let meters = ProcessInfo.processInfo.environment["UI_PERF_METERS"] ?? "live,fixed"
      if meters.contains("live") { measure(cameras: cameras, liveMeters: true, verifier: verifier) }
      if meters.contains("fixed") { measure(cameras: cameras, liveMeters: false, verifier: verifier) }
    }
  }

  static func measure(cameras: Int, liveMeters: Bool, verifier: Verifier) {
    let name = "perf \(cameras) cameras\(liveMeters ? "" : ", fixed meters")"
    let suiteName = "org.ultracam.ui-verify-perf.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { return verifier.check("perf: defaults suite", false) }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let ids = (1...cameras).map { FeedID(rawValue: "ui-verify-perf-\($0)") }
    let settings = AppSettingsStore(defaults: defaults)
    settings.saveSnapshot(AppSettingsSnapshot(feeds: ids.enumerated().map { index, id in
      FeedDescriptor(id: id, name: "Camera \(index + 1)", selectedDevice: "perf-dev-\(index + 1)", applyLUT: false,
        automaticFeed: false)
    }, selectedFeedID: ids[0], outputMode: .separateCameras))
    let capture = ScriptedLiveCapture()
    var hardware = AppHardware.offline
    hardware.devices = { (1...cameras).map { InputDevice(id: "perf-dev-\($0)", name: "UltraStudio \($0)") } }
    hardware.captureServices = { _ in capture.services() }
    let model = AppModel(settingsStore: settings, lutLoader: LUTFileLoader(scopedBookmarks: false),
      registryStore: VirtualCameraRegistryStore(defaults: defaults), registryPublisher: PerfRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults),
      installer: ExtensionInstaller(services: ExtensionInstaller.Services(
        preflight: { ExtensionInstallPreflight(developerSigned: true, hasInstallEntitlement: true) },
        makeRequest: { _ in .activationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main) },
        submit: { _ in })),
      hardware: hardware)
    let interface = UIInterfaceState(defaults: defaults)
    interface.layout = cameras > 2 ? .fourUp : .sideBySide
    interface.sidebarVisible = true
    for id in ids { model.startCamera(id) }
    defer {
      for id in ids { model.stopCamera(id) }
      capture.stopAll()
      MainLoop.run(seconds: 0.3)
    }
    let live = { ids.allSatisfy { (model.cameraUpdate($0)?.frames ?? 0) > 30 && model.cameraUpdate($0)?.timecode != nil } }
    let deadline = Date().addingTimeInterval(8)
    while !live() && Date() < deadline { MainLoop.run(seconds: 0.05) }
    verifier.check("\(name): scripted capture goes live", live(),
      ids.map { model.cameraUpdate($0)?.input ?? "nil" }.joined(separator: ", "))

    let window = PerfWindow(UILiveRoot(model: model, interface: interface) { context in
      UIMainWindowView(context: context).toolbar { UIToolbarContent(context: context) }
        // Without a tap source the meters draw the status peaks as fixed readings.
        .environment(\.uiAudioMeters, liveMeters ? UIAudioMeterSource { model.audioMeterTap(for: FeedID(rawValue: $0)) } : nil)
    }, size: CGSize(width: 1320, height: 860))
    defer { window.close() }
    let meter = MainThreadMeter(view: window.host)
    defer { meter.stop() }
    MainLoop.run(seconds: 2)

    func sample(_ seconds: Double, during action: () -> Void = {}) -> LivePerformanceSample {
      UIRenderProbe.reset()
      meter.reset()
      let cpu = MainThreadMeter.mainThreadCPU()
      let processCPU = MainThreadMeter.processCPU()
      let start = Date()
      action()
      let end = start.addingTimeInterval(seconds)
      while Date() < end { MainLoop.run(seconds: min(0.05, max(0.001, end.timeIntervalSinceNow))) }
      let elapsed = Date().timeIntervalSince(start)
      let busy = (MainThreadMeter.mainThreadCPU() - cpu) / elapsed
      return LivePerformanceSample(seconds: elapsed, busy: busy, process: (MainThreadMeter.processCPU() - processCPU) / elapsed,
        bodies: UIRenderProbe.counts.mapValues { Double($0) / elapsed }, displayHz: Double(meter.displayTicks) / elapsed,
        hitches8: meter.stretches.filter { $0 > 1000.0 / 120 }.count, hitches16: meter.stretches.filter { $0 > 1000.0 / 60 }.count,
        longest: meter.stretches.max() ?? 0)
    }

    // Nothing that builds the session (the window's root, its columns, the menus, the menu bar
    // icon) depends on telemetry: capture updates and meters run without telling it.
    let bridge = UISessionBridge.live(model: model, interface: interface)
    let rebuilt = Mutex(false)
    withObservationTracking {
      _ = bridge.snapshot()
      _ = bridge.context()
    } onChange: { rebuilt.withLock { $0 = true } }

    let before = ids.map { model.cameraUpdate($0)?.frames ?? 0 }
    // UI_PERF_IDLE stretches the idle interval, e.g. to attach Instruments to this process.
    let idle = sample(Double(ProcessInfo.processInfo.environment["UI_PERF_IDLE"] ?? "") ?? 4)
    let after = ids.map { model.cameraUpdate($0)?.frames ?? 0 }
    print("PERF \(name) idle: \(idle.summary)")
    verifier.check("\(name): the window is on a display and ticks", idle.displayHz > 50, "\(idle.displayHz) Hz")
    verifier.check("\(name): every camera delivers frames while measured",
      zip(before, after).allSatisfy { $1 > $0 + 150 }, "\(before) -> \(after)")
    verifier.check("\(name): the session snapshot and context follow no capture update", !rebuilt.withLock { $0 })
    check(idle, "idle", name: name, verifier: verifier, liveMeters: liveMeters)

    // The split view's own sidebar animation, as the toolbar's sidebar button runs it.
    if let split = window.splitViewController {
      let hide = sample(1.2) { split.toggleSidebar(nil) }
      let show = sample(1.2) { split.toggleSidebar(nil) }
      print("PERF \(name) sidebar hide: \(hide.summary)")
      print("PERF \(name) sidebar show: \(show.summary)")
      for (step, value) in [("sidebar hide", hide), ("sidebar show", show)] {
        checkToggle(value, step, name: name, verifier: verifier, liveMeters: liveMeters)
      }
    } else {
      verifier.check("\(name): the main window has a split view controller", false)
    }
    // UI_PERF_PROFILE_INSPECTOR=n toggles the inspector n times first, to profile its animation.
    for _ in 0..<(Int(ProcessInfo.processInfo.environment["UI_PERF_PROFILE_INSPECTOR"] ?? "") ?? 0) {
      _ = sample(0.8) { bridge.send(.toggleInspector) }
    }
    // The inspector, as the toolbar's Inspector button opens and closes it; and live with it open.
    let open = sample(1.2) { bridge.send(.toggleInspector) }
    print("PERF \(name) inspector open: \(open.summary)")
    checkToggle(open, "inspector open", name: name, verifier: verifier, liveMeters: liveMeters)
    let inspecting = sample(3)
    print("PERF \(name) idle with the inspector open: \(inspecting.summary)")
    check(inspecting, "idle with the inspector open", name: name, verifier: verifier, liveMeters: liveMeters)
    // The leaves still follow: the inspector's timecode with the selected camera's updates (4 Hz).
    verifier.check("\(name): the inspector's timecode follows capture updates",
      inspecting.rate("UILiveCamera(capture)") >= 3, inspecting.summary)
    let close = sample(1.2) { bridge.send(.toggleInspector) }
    print("PERF \(name) inspector close: \(close.summary)")
    checkToggle(close, "inspector close", name: name, verifier: verifier, liveMeters: liveMeters)
    let afterToggles = sample(3)
    print("PERF \(name) idle after toggles: \(afterToggles.summary)")
    check(afterToggles, "idle after toggles", name: name, verifier: verifier, liveMeters: liveMeters)
  }


  /// Budgets while only telemetry changes: no structural view re-evaluates, the run loop never
  /// stalls as the whole-window rebuilds did, and without live meters the main thread stays
  /// nearly idle (an unoptimized build).
  static func check(_ value: LivePerformanceSample, _ step: String, name: String, verifier: Verifier, liveMeters: Bool) {
    for view in structural {
      verifier.check("\(name), \(step): \(view) is not re-evaluated", value.rate(view) * value.seconds < 1,
        String(format: "%.1f per second", value.rate(view)))
    }
    // The rebuilds on every capture update stalled it 40–100 ms several times a second. Shorter
    // stalls are reported, not budgeted: they depend on the machine and what else runs on it.
    verifier.check("\(name), \(step): no run loop stall past 50 ms", value.longest < 50, value.summary)
    if !liveMeters {
      verifier.check("\(name), \(step): main thread under 25% busy", value.busy < 0.25, value.summary)
    }
  }

  /// Budgets while a side column opens or closes: the window re-evaluates a few times for the
  /// change (the column's state, the strips' measured heights), never once per frame of the
  /// animation, and no frame stalls as the 50 ms rebuilds on every capture update did.
  static func checkToggle(_ value: LivePerformanceSample, _ step: String, name: String, verifier: Verifier, liveMeters: Bool) {
    for view in ["UILiveRoot", "UIMainWindowView", "UISessionSidebarViewContent", "UIInspectorViewContent", "UIChannelStripView"] {
      let total = value.rate(view) * value.seconds
      verifier.check("\(name), \(step): \(view) evaluated a few times, not per frame", total <= 10,
        String(format: "%.0f times", total))
    }
    // Opening the inspector builds its form, once: the longest pass, about 50 ms unoptimized.
    verifier.check("\(name), \(step): no run loop stall past 120 ms", value.longest < 120, value.summary)
  }
}

@MainActor private final class PerfRegistryPublisher: AppVirtualCameraRegistryPublishing {
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) {}
}

/// A titled main window on the main screen, never seen: `orderInvisiblyForTesting`.
@MainActor final class PerfWindow {
  let window: NSWindow
  let host: NSView

  init<V: View>(_ view: V, size: CGSize) {
    window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(rootView: view)
    hosting.sizingOptions = []
    hosting.sceneBridgingOptions = [.toolbars, .title]
    host = hosting
    window.contentView = hosting
    window.setContentSize(size)
    if let screen = NSScreen.main { window.setFrameOrigin(screen.visibleFrame.origin) }
    window.orderInvisiblyForTesting()
  }

  /// The NavigationSplitView's controller (the split view's delegate).
  var splitViewController: NSSplitViewController? {
    func find(_ view: NSView) -> NSSplitView? {
      if let split = view as? NSSplitView { return split }
      for child in view.subviews { if let found = find(child) { return found } }
      return nil
    }
    guard let root = window.contentView, let split = find(root) else { return nil }
    return split.delegate as? NSSplitViewController
  }

  func close() {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }
}

extension NSWindow {
  /// Orders a test window in without the user ever seeing it: fully transparent,
  /// click-through, no shadow or open animation, never key, and out of the window
  /// cycle. It is still on a screen, so display links, drawables and occlusion
  /// behave as for a shown window. (The same as Tests/TestWindows.swift.)
  func orderInvisiblyForTesting() {
    alphaValue = 0
    ignoresMouseEvents = true
    hasShadow = false
    animationBehavior = .none
    collectionBehavior = [.transient, .ignoresCycle]
    orderFrontRegardless()
  }
}
