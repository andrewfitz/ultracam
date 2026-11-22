import AppKit
import CoreMedia
import CoreVideo
import Darwin
import MonitorKitUI
import SwiftUI
import Synchronization

// The live main window's main-thread cost, measured offscreen: the real view tree
// (UILiveRoot, UIMainWindowView, toolbar) over a real AppModel whose cameras run on
// scripted capture (frames at 59.94 Hz, timecode and audio with every frame, so the
// capture updates, meters and monitor surfaces run as they do with an UltraStudio).
// The window is on the main screen but invisible (`orderInvisiblyForTesting`), so the
// display link, meters and Metal surfaces tick. It reports body evaluations per second
// per view, main-thread busy time, run loop hitches and display ticks, idle and while
// the inspector is toggled, and checks them against budgets.
// UI_PERF_ONLY=1 runs only this check; UI_PERF_CAMERAS=2,4 picks the camera counts.

/// Scripted UltraStudios deliver frames, timecode and audio at 59.94 Hz.
final class ScriptedLiveCapture: @unchecked Sendable {
  /// The serial timer queue owns all callbacks and cadence state. The lifecycle
  /// methods only activate or cancel the timer and publish its atomic counters.
  private final class Run: @unchecked Sendable {
    private static let period: UInt64 = 16_683_333
    private let timer: DispatchSourceTimer
    private let buffers: [CapturedPixelBuffer]
    private let frames: (CVPixelBuffer, CMTime, Bool) -> Void
    private let media: (CaptureMediaStats) -> Void
    private let audio: (CaptureRawAudio) -> Void
    private let cancelled = Atomic(false)
    private let offered = Atomic(0)
    private var sequence: Int64 = 0
    private var lastOffer: UInt64?

    init(device: String, buffers: [CapturedPixelBuffer], frames: @escaping (CVPixelBuffer, CMTime, Bool) -> Void,
      media: @escaping (CaptureMediaStats) -> Void, audio: @escaping (CaptureRawAudio) -> Void) {
      let queue = DispatchQueue(label: "ui-verify.capture.\(device)", qos: .userInteractive)
      timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
      self.buffers = buffers
      self.frames = frames
      self.media = media
      self.audio = audio
    }

    func start() {
      timer.setEventHandler { [weak self] in self?.emit() }
      timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(Self.period)), leeway: .nanoseconds(0))
      timer.activate()
    }

    func cancel() {
      cancelled.store(true, ordering: .releasing)
      timer.cancel()
    }

    var offeredFrames: Int { offered.load(ordering: .relaxed) }

    private func emit() {
      guard !cancelled.load(ordering: .acquiring) else { return }
      // Dispatch merges missed timer fires. Preserve their gap in source time
      // while delivering at most the newest frame. Drop a compressed next wake.
      sequence += Int64(max(1, timer.data))
      let index = sequence - 1
      let now = DispatchTime.now().uptimeNanoseconds
      if let lastOffer, now - lastOffer < Self.period / 2 { return }
      lastOffer = now
      let pts = CMTime(value: index * 1001, timescale: 60_000)
      offered.add(1, ordering: .relaxed)
      frames(buffers[Int(index) % buffers.count].value, pts, true)
      // A 1 kHz tone whose level drifts so meter and timecode changes are visible.
      let audioStart = index * 1001 * 48_000 / 60_000
      let audioEnd = sequence * 1001 * 48_000 / 60_000
      let sampleFrames = Int(audioEnd - audioStart)
      let level = 0.25 + 0.2 * sin(Double(index) / 40)
      let phaseStep = 2 * Double.pi / 48
      var phase = Double(audioStart % 48) * phaseStep
      var pcm = [Int32](repeating: 0, count: sampleFrames * 2)
      for frame in 0..<sampleFrames {
        let value = Int32(level * sin(phase) * Double(Int32.max))
        pcm[frame * 2] = value
        pcm[frame * 2 + 1] = value / 2
        phase += phaseStep
      }
      let packetTime = CMTime(value: audioStart, timescale: 48_000)
      audio(CaptureRawAudio(samples: pcm.withUnsafeBytes { Data($0) }, packetTime: packetTime,
        sampleFrames: UInt64(sampleFrames), channels: 2, bytesPerSample: 4))
      let seconds = index * 1001 / 60_000
      let timecode = String(format: "14:%02d:%02d:%02d", Int32(seconds / 60 % 60), Int32(seconds % 60), Int32(index % 60))
      media(CaptureMediaStats(timecode: timecode, audioPacketTime: packetTime, audioSampleFrames: UInt64(sampleFrames),
        audioChannels: 2, leftPeak: level, rightPeak: level / 2, leftRMS: level * 0.7, rightRMS: level * 0.35,
        audioBytes: UInt64(pcm.count * 4), audioPresent: true))
    }
  }

  private let lock = NSLock()
  private var runs: [String: Run] = [:]
  // Attachments are initialized once; producers and consumers only read these images.
  private let buffers: [CapturedPixelBuffer]

  init() throws {
    buffers = (0..<6).compactMap { _ in
      var made: CVPixelBuffer?
      CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &made)
      if let made {
        CVBufferSetAttachment(made, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
      }
      return made.map { CapturedPixelBuffer(immutable: $0) }
    }
    guard buffers.count == 6 else { throw CocoaError(.fileReadUnknown) }
  }

  func services(deviceID: String?) -> CaptureServices {
    var services = CaptureServices(
      start: { _, _, _, _ in throw CocoaError(.featureUnsupported) },
      startWithSourceAudio: { [self] device, _, frames, media, audio, _ in
        guard device == deviceID else { throw CocoaError(.featureUnsupported) }
        let run = Run(device: device, buffers: buffers, frames: frames, media: media, audio: audio)
        lock.withLock {
          runs.updateValue(run, forKey: device)?.cancel()
          run.start()
        }
      },
      stop: { [self] in
        guard let deviceID else { return }
        lock.withLock {
          if let run = runs.removeValue(forKey: deviceID) { run.cancel() }
        }
      }, connect: { _, _ in }, disconnect: {}, send: { _ in true })
    services.capturePixelFormat = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    return services
  }

  func offeredFrames(for deviceIDs: [String]) -> [Int] {
    lock.withLock { deviceIDs.map { runs[$0]?.offeredFrames ?? 0 } }
  }

  func stopAll() {
    lock.withLock {
      for run in runs.values { run.cancel() }
      runs.removeAll()
    }
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
    let activities: CFRunLoopActivity = [.entry, .afterWaiting, .beforeWaiting, .exit]
    let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { [weak self] _, activity in
      MainActor.assumeIsolated {
        guard let self else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if activity == .afterWaiting || activity == .entry {
          if self.wokeAt == 0 { self.wokeAt = now }
        } else if self.wokeAt != 0 {
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
    wokeAt = 0
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
  var bodies: [String: Int]
  var displayHz: Double
  var hitches8: Int
  var hitches16: Int
  var longest: Double

  func count(_ name: String) -> Int { bodies[name] ?? 0 }
  func rate(_ name: String) -> Double { Double(count(name)) / seconds }

  var summary: String {
    let views = bodies.keys.sorted().map { "\($0)=\(String(format: "%.1f", rate($0)))" }.joined(separator: " ")
    return String(format: "main %.1f%% process %.0f%% display %.0f Hz hitches>8ms %d >16ms %d longest %.1f ms | bodies/s ", busy * 100, process * 100,
      displayHz, hitches8, hitches16, longest) + views
  }
}

@MainActor enum LivePerformanceVerify {
  /// Views that must not re-evaluate while nothing but telemetry changes.
  static let structural = ["UILiveRoot", "UIMainWindowView",
    "UIInspectorView", "UIInspectorViewContent", "UIToolbarContent", "UICameraColumnView", "UICameraPictureView",
    "UIChannelStripView", "UIStatusBarView", "UIAppSurfacePicture"]

  /// While the detail settles its cells scale in the render pass (`visualEffect`); the native
  /// pictures in them (NSViews) must scale with them, not keep their laid-out size.
  static func nativeViewsScaleWithVisualEffect(verifier: Verifier) {
    final class Probe: NSView {}
    struct Native: NSViewRepresentable {
      let view: Probe
      func makeNSView(context: Context) -> Probe { view }
      func updateNSView(_ view: Probe, context: Context) {}
    }
    let probe = Probe()
    let hosted = HostedView(Native(view: probe).frame(width: 400, height: 225)
      .visualEffect { content, _ in content.scaleEffect(0.5, anchor: .top) }
      .frame(width: 600, height: 400), size: CGSize(width: 600, height: 400), dark: false)
    defer { hosted.close() }
    let shown = probe.convert(probe.bounds, to: nil)
    verifier.check("perf: a native picture scales with its cell while the detail settles",
      abs(shown.width - 200) < 2 && abs(shown.height - 112.5) < 2, "\(shown)")
  }

  static func run(verifier: Verifier) {
    nativeViewsScaleWithVisualEffect(verifier: verifier)
    let requestedCounts = (ProcessInfo.processInfo.environment["UI_PERF_CAMERAS"] ?? "2,4").split(separator: ",", omittingEmptySubsequences: false)
    let counts = requestedCounts.compactMap { Int($0) }
    guard counts.count == requestedCounts.count, !counts.isEmpty,
      counts.allSatisfy({ $0 > 0 && $0 <= FeedLifecycleDemandPolicy.maximumCameras }) else {
      return verifier.check("perf: UI_PERF_CAMERAS contains supported positive camera counts", false)
    }
    let meters = (ProcessInfo.processInfo.environment["UI_PERF_METERS"] ?? "live,fixed").split(separator: ",", omittingEmptySubsequences: false)
    guard !meters.isEmpty, meters.allSatisfy({ $0 == "live" || $0 == "fixed" }) else {
      return verifier.check("perf: UI_PERF_METERS contains live or fixed", false)
    }
    let environment = ProcessInfo.processInfo.environment
    let idleSeconds = Double(environment["UI_PERF_IDLE"] ?? "4")
    guard let idleSeconds, idleSeconds.isFinite, idleSeconds > 0 else {
      return verifier.check("perf: UI_PERF_IDLE is a finite positive duration", false)
    }
    let profileToggles = Int(environment["UI_PERF_PROFILE_INSPECTOR"] ?? "0")
    guard let profileToggles, profileToggles >= 0 else {
      return verifier.check("perf: UI_PERF_PROFILE_INSPECTOR is a nonnegative integer", false)
    }
    for cameras in counts {
      // With live meters (as in the app), then with the meters showing fixed readings, which never
      // tick: the difference is what the meters' display-rate drawing costs the window.
      if meters.contains("live") { measure(cameras: cameras, liveMeters: true, idleSeconds: idleSeconds, profileToggles: profileToggles, verifier: verifier) }
      if meters.contains("fixed") { measure(cameras: cameras, liveMeters: false, idleSeconds: idleSeconds, profileToggles: profileToggles, verifier: verifier) }
    }
  }

  static func measure(cameras: Int, liveMeters: Bool, idleSeconds: Double, profileToggles: Int, verifier: Verifier) {
    let name = "perf \(cameras) cameras\(liveMeters ? "" : ", fixed meters")"
    let suiteName = "org.ultracam.ui-verify-perf.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { return verifier.check("perf: defaults suite", false) }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let ids = (1...cameras).map { FeedID(rawValue: "ui-verify-perf-\($0)") }
    let deviceIDs = (1...cameras).map { "perf-dev-\($0)" }
    let settings = AppSettingsStore(defaults: defaults)
    settings.saveSnapshot(AppSettingsSnapshot(feeds: ids.enumerated().map { index, id in
      FeedDescriptor(id: id, name: "Camera \(index + 1)", selectedDevice: deviceIDs[index], applyLUT: false,
        automaticFeed: false, frameRateTarget: .fps5994)
    }, selectedFeedID: ids[0], outputMode: .separateCameras))
    let capture: ScriptedLiveCapture
    do { capture = try ScriptedLiveCapture() }
    catch { return verifier.check("\(name): allocate scripted capture buffers", false, "\(error)") }
    var hardware = AppHardware.offline
    hardware.devices = { deviceIDs.enumerated().map { InputDevice(id: $0.element, name: "UltraStudio \($0.offset + 1)") } }
    hardware.captureServices = { id in capture.services(deviceID: ids.firstIndex(of: id).map { deviceIDs[$0] }) }
    let model = AppModel(settingsStore: settings, lutLoader: LUTFileLoader(scopedBookmarks: false),
      registryStore: VirtualCameraRegistryStore(defaults: defaults), registryPublisher: PerfRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults),
      installer: ExtensionInstaller(services: ExtensionInstaller.Services(
        preflight: { ExtensionInstallPreflight(developerSigned: true, hasInstallEntitlement: true) },
        makeRequest: { _ in .activationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main) },
        submit: { _ in })),
      hardware: hardware)
    let interface = UIInterfaceState(defaults: defaults)
    switch cameras {
    case 1: interface.layout = .single
    case 2: interface.layout = .sideBySide
    default: interface.layout = .fourUp
    }
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
      let start = ProcessInfo.processInfo.systemUptime
      action()
      let end = start + seconds
      var remaining = end - ProcessInfo.processInfo.systemUptime
      while remaining > 0 {
        MainLoop.run(seconds: min(0.05, remaining))
        remaining = end - ProcessInfo.processInfo.systemUptime
      }
      let elapsed = ProcessInfo.processInfo.systemUptime - start
      let busy = (MainThreadMeter.mainThreadCPU() - cpu) / elapsed
      return LivePerformanceSample(seconds: elapsed, busy: busy, process: (MainThreadMeter.processCPU() - processCPU) / elapsed,
        bodies: UIRenderProbe.counts, displayHz: Double(meter.displayTicks) / elapsed,
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

    /// Selecting another camera and cutting to one: the click's own main-thread time, then the
    /// longest stall while the window catches up. Both are the wait before the click shows.
    func react(_ where: String) {
      guard ids.count > 1 else { return }
      let other = ids[1]
      let back = ids[0]
      for (step, action) in [("select another camera", UIAction.select(cameraID: other.rawValue)),
        ("select back", .select(cameraID: back.rawValue)),
        ("cut to another camera", .cut(cameraID: other.rawValue)), ("cut back", .cut(cameraID: back.rawValue))] {
        var clickMS = 0.0
        let value = sample(1.0) {
          let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
          bridge.send(action)
          clickMS = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
        }
        print(String(format: "PERF \(name) \(step) \(`where`): click %.1f ms | ", clickMS) + value.summary)
        verifier.check("\(name), \(step) \(`where`): the click takes under 50 ms", clickMS < 50, String(format: "%.1f ms", clickMS))
        verifier.check("\(name), \(step) \(`where`): no run loop stall past 250 ms", value.longest < 250, value.summary)
        if case .cut(let id) = action {
          verifier.check("\(name), \(step) \(`where`): the cut lands", model.switcherSelectedFeedID?.rawValue == id,
            model.switcherSelectedFeedID?.rawValue ?? "nil")
        }
      }
    }

    let before = ids.map { model.cameraUpdate($0)?.frames ?? 0 }
    let offeredBefore = capture.offeredFrames(for: deviceIDs)
    // UI_PERF_IDLE stretches the idle interval, e.g. to attach Instruments to this process.
    let meterTicks = MeterDiagnostics.displayTicks
    let idle = sample(idleSeconds)
    let after = ids.map { model.cameraUpdate($0)?.frames ?? 0 }
    let offered = zip(capture.offeredFrames(for: deviceIDs), offeredBefore).map { $0 - $1 }
    let accepted = zip(after, before).map { $0 - $1 }
    let rates = offered.map { String(format: "%.1f", Double($0) / idle.seconds) }
    let meterHz = Double(MeterDiagnostics.displayTicks - meterTicks) / idle.seconds
    print("PERF \(name) idle: \(idle.summary) | meter frames/s \(Int(meterHz)) | offered frames \(offered) (\(rates.joined(separator: ", ")) Hz), accepted frames \(accepted)")
    // Each camera's strip meter draws on every display frame, without SwiftUI.
    if liveMeters {
      verifier.check("\(name): the live meters draw at the display rate",
        meterHz > Double(cameras) * idle.displayHz * 0.8, "\(Int(meterHz)) meter frames/s at \(Int(idle.displayHz)) Hz")
    } else {
      verifier.check("\(name): fixed meters never tick", meterHz == 0, "\(meterHz)")
    }
    verifier.check("\(name): the window is on a display and ticks", idle.displayHz > 50, "\(idle.displayHz) Hz")
    verifier.check("\(name): every camera delivers frames while measured",
      accepted.allSatisfy { Double($0) > idle.seconds * 40 }, "offered \(offered), accepted \(accepted)")
    verifier.check("\(name): the session snapshot and context follow no capture update", !rebuilt.withLock { $0 })
    check(idle, "idle", name: name, verifier: verifier, liveMeters: liveMeters)

    // UI_PERF_PROFILE_INSPECTOR=n toggles the inspector n times first, to profile its animation.
    for _ in 0..<profileToggles {
      _ = sample(0.8) { bridge.send(.toggleInspector) }
    }
    if profileToggles % 2 != 0 {
      _ = sample(0.8) { bridge.send(.toggleInspector) }
    }
    // The inspector, as the toolbar's Inspector button opens and closes it; and live with it open.
    let open = sample(1.2) { bridge.send(.toggleInspector) }
    let shrank = UIRenderProbe.samples.withLock { $0["cells scale"] ?? [] }
    print("PERF \(name) inspector open: \(open.summary)")
    checkToggle(open, "inspector open", name: name, verifier: verifier, liveMeters: liveMeters)
    let inspecting = sample(3)
    print("PERF \(name) idle with the inspector open: \(inspecting.summary)")
    check(inspecting, "idle with the inspector open", name: name, verifier: verifier, liveMeters: liveMeters)
    // The leaves still follow: the inspector's timecode with the selected camera's updates (4 Hz).
    verifier.check("\(name): the inspector's timecode follows capture updates",
      inspecting.rate("UILiveCamera(capture)") >= 3, inspecting.summary)
    react("with the inspector open")
    let close = sample(1.2) { bridge.send(.toggleInspector) }
    let grew = UIRenderProbe.samples.withLock { $0["cells scale"] ?? [] }
    print("PERF \(name) inspector close: \(close.summary)")
    checkToggle(close, "inspector close", name: name, verifier: verifier, liveMeters: liveMeters)
    // The inspector is a panel of the content and opens at once. The pictures follow the
    // detail's new size scaled, in the render pass, until that size settles, and are then laid
    // out at 1: never a frame at the old size beside the panel.
    verifier.check("\(name): the pictures shrink with the detail as the inspector opens",
      shrank.contains { $0 < 0.99 } && shrank.last == 1, shrank.map { String(format: "%.2f", $0) }.joined(separator: " "))
    verifier.check("\(name): the pictures grow with the detail as the inspector closes",
      grew.contains { $0 > 1.01 } && grew.last == 1, grew.map { String(format: "%.2f", $0) }.joined(separator: " "))
    let afterToggles = sample(3)
    print("PERF \(name) idle after toggles: \(afterToggles.summary)")
    check(afterToggles, "idle after toggles", name: name, verifier: verifier, liveMeters: liveMeters)
    react("with the inspector closed")
  }


  /// Budgets while only telemetry changes: no structural view re-evaluates, the run loop never
  /// stalls as the whole-window rebuilds did, and the main thread stays nearly idle, live
  /// meters or not (an unoptimized build).
  static func check(_ value: LivePerformanceSample, _ step: String, name: String, verifier: Verifier, liveMeters: Bool) {
    for view in structural {
      verifier.check("\(name), \(step): \(view) is not re-evaluated", value.count(view) == 0,
        String(format: "%.1f per second", value.rate(view)))
    }
    // The rebuilds on every capture update stalled it 40–100 ms several times a second. Shorter
    // stalls are reported, not budgeted: they depend on the machine and what else runs on it.
    verifier.check("\(name), \(step): no run loop stall past 50 ms", value.longest < 50, value.summary)
    // Live meters included: they move layers on their own display link and re-evaluate nothing.
    verifier.check("\(name), \(step): main thread under 25% busy", value.busy < 0.25, value.summary)
  }

  /// Budgets while a side column opens or closes: the window re-evaluates a few times for the
  /// change (the column's state, the strips' measured heights), never once per frame of the
  /// animation, and no frame stalls as the 50 ms rebuilds on every capture update did.
  static func checkToggle(_ value: LivePerformanceSample, _ step: String, name: String, verifier: Verifier, liveMeters: Bool) {
    for view in ["UILiveRoot", "UIMainWindowView", "UIInspectorViewContent", "UIChannelStripView"] {
      let total = value.count(view)
      verifier.check("\(name), \(step): \(view) evaluated a few times, not per frame", total <= 10,
        "\(total) times")
    }
    // Opening the inspector builds its form, once: the longest pass, 50–120 ms unoptimized.
    verifier.check("\(name), \(step): no run loop stall past 250 ms", value.longest < 250, value.summary)
    statusBarBuildsOneLiveSession(value, step, name: name, verifier: verifier)
  }

  /// The status bar brings the session up to date once per evaluation of the bar (plus its own
  /// refresh), not once per density it measures: each hidden copy wrapped its segments in its own
  /// live session, so a statistics tick built the presentation (problems and all) 12 times.
  static func statusBarBuildsOneLiveSession(_ value: LivePerformanceSample, _ step: String, name: String, verifier: Verifier) {
    let bar = value.count("UIStatusBarView")
    let live = value.count("UILiveSession(status)")
    verifier.check("\(name), \(step): the status bar builds one live session, not one per measured copy",
      live <= bar + 2, "\(live) live sessions for \(bar) bars")
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
