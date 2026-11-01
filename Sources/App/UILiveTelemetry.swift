import Foundation
import SwiftUI

// The views that show running values; the models' side is LiveTelemetry.swift.
import Observation

// MARK: - Running values in the session snapshot

extension UISessionBridge {
  /// A camera's running capture values: timecode and audio levels.
  static func applyCapture(_ update: CaptureUpdate?, withinLossHold: Bool = false, to camera: inout UICameraSnapshot) {
    camera.timecode = update?.timecode
    camera.signal = UIFormatLabels.signal(running: camera.running, deviceAvailable: camera.deviceAvailable,
      update: update, withinLossHold: withinLossHold)
    // Only a camera that had a picture has lost one.
    if case .lost(let since)? = update?.signal, !withinLossHold, update?.frames ?? 0 > 0 {
      camera.signalLostSince = since
      camera.signalLostFor = ProcessInfo.processInfo.systemUptime - since
    } else {
      camera.signalLostSince = nil
      camera.signalLostFor = nil
    }
    if let update {
      camera.audioChannels = update.audioChannels
      camera.audioSampleRate = update.audioSampleRate
      camera.audio = UIAudioLevels(present: update.audioPresent, peakLeft: update.audioPeakLeft,
        peakRight: update.audioPeakRight, rmsLeft: update.audioRMSLeft, rmsRight: update.audioRMSRight)
    }
  }

  /// A take's running values: clock, size, rate, drops, its audio so far and the time left on its drive.
  func applyTake(_ id: FeedID, statistics stats: RecordingStatistics?, drives: [UIDrive], to rec: inout UICameraRecording) {
    rec.elapsed = stats?.elapsed ?? 0
    rec.fileBytes = Int64(stats?.fileBytes ?? 0)
    rec.megabitsPerSecond = stats?.videoMegabitsPerSecond ?? 0
    rec.droppedFrames = Int(clamping: stats?.droppedVideoFrames ?? 0)
    rec.sourceGaps = Int(clamping: stats?.sourceGaps ?? 0)
    rec.systemCompatibilityFrames = stats?.systemCompatibilityFrames ?? 0
    rec.compatibilityConversionActive = stats?.compatibilityConversionActive ?? false
    // The running take's audio so far, then the finished take's (cleared when the next starts).
    rec.audio = model.takeAudioSoFar(id) ?? model.takeAudio[id]
    rec.savedDuration = rec.savedURL != nil ? stats?.elapsed : nil
    // The drive read found each folder's volume (inside its security scope); the path can't say.
    let folder = model.recordingModel.outputFolder(for: id)?.path
    let drive = folder.flatMap { path in drives.first { $0.folders.contains(path) } }
    rec.volumeID = drive?.id
    rec.secondsLeft = drive?.secondsLeft
  }

  /// Free space and recording time left on every camera's drive, read at most every two seconds,
  /// each judged low by Settings › Alerts' Low Space.
  func currentDrives() -> [UIDrive] {
    // Free space isn't observable: views follow a drive becoming low or full (`UIDriveLevels`),
    // and the views that show the figures re-read them on a timer.
    _ = UIDriveLevels.shared.revision
    let recording = model.recordingModel
    let folders = model.feedDescriptors.map { recording.outputFolder(for: $0.id) }
    return Self.cachedDrives(for: folders, lowSeconds: interface.lowSpaceSeconds) {
      var rolling: [(URL, Double)] = []
      var assigned: [(URL, Double)] = []
      for descriptor in model.feedDescriptors {
        guard let folder = recording.outputFolder(for: descriptor.id) else { continue }
        let channels = model.cameraUpdate(descriptor.id).map { $0.audioChannels > 0 ? $0.audioChannels : 2 } ?? 2
        let estimate = displayRate(descriptor.id, audioChannels: channels)
        assigned.append((folder, estimate))
        if let state = recording.feeds.first(where: { $0.id == descriptor.id }),
          state.status == .recording || state.status == .paused {
          rolling.append((folder, UIRecordingLibrary.rollingMegabits(measuredVideo: state.statistics?.videoMegabitsPerSecond,
            estimate: estimate, audioChannels: channels)))
        }
      }
      return UIRecordingLibrary.drives(for: folders, recordingRates: rolling, assignedRates: assigned,
        fallbackMegabits: UIRecordingLibrary.displayMegabits(codec: recording.codec))
    }
  }

  /// The camera's own format once it's known, so a 1080p camera isn't counted as UHD, and
  /// the codec that actually records it: a fallback can be 50 times the data.
  private func displayRate(_ id: FeedID, audioChannels: Int) -> Double {
    let recording = model.recordingModel
    let state = recording.feeds.first { $0.id == id }
    let source = model.cameraUpdate(id)?.sourceFormat
    let codec = (state?.isActive == true ? state?.takeCodec : nil) ?? recording.codec.resolved(for: source)
    guard let format = source else {
      return UIRecordingLibrary.displayMegabits(codec: codec, audioChannels: audioChannels)
    }
    return UIRecordingLibrary.displayMegabits(codec: codec, width: format.width, height: format.height,
      frameDuration: format.rate.nominal, audioChannels: audioChannels)
  }
}

// MARK: - Live values for the views that show them

/// Brings a snapshot's running values up to date from the live models, for the view that
/// calls it: that view (and only it) then follows those values. The app's root puts one in
/// the environment; fixtures have none and show their snapshots as they are.
@MainActor final class UILiveSource {
  private let bridge: UISessionBridge
  private var ingestActivity: [String: (count: UInt64, lastChange: TimeInterval)] = [:]

  init(model: AppModel, interface: UIInterfaceState) {
    bridge = UISessionBridge(model: model, interface: interface)
  }

  /// What a view follows: a camera's capture updates (timecode, levels), its take's statistics, or both.
  struct Follows: OptionSet, Sendable {
    let rawValue: Int
    static let capture = Follows(rawValue: 1)
    static let take = Follows(rawValue: 2)
    static let all: Follows = [.capture, .take]
  }

  /// One camera's running values, now.
  func camera(_ camera: UICameraSnapshot, follows: Follows, drives: [UIDrive]) -> UICameraSnapshot {
    let model = bridge.model
    let id = FeedID(rawValue: camera.id)
    var camera = camera
    if follows.contains(.capture) {
      let update = camera.running ? model.liveCameraUpdate(id) : nil
      UISessionBridge.applyCapture(update, withinLossHold: model.signalWithinLossHold(id), to: &camera)
      let count = update?.ingestCPUCopyFrames ?? 0
      let now = ProcessInfo.processInfo.systemUptime
      let previous = ingestActivity[camera.id]
      let changed = count > 0 && (previous == nil || previous!.count != count)
      let lastChange = changed ? now : (previous?.lastChange ?? -.infinity)
      ingestActivity[camera.id] = (count, lastChange)
      camera.ingestCPUCopyFrames = count
      camera.ingestCPUCopyActive = camera.running && count > 0 && now - lastChange < 1

    }
    if follows.contains(.take) {
      bridge.applyTake(id, statistics: model.recordingModel.liveStatistics(id), drives: drives, to: &camera.recording)
    }
    return camera
  }

  /// The drives' free space, now (read at most every two seconds; not observable).
  func drives() -> [UIDrive] { bridge.currentDrives() }
}

private struct UILiveSourceKey: EnvironmentKey {
  static let defaultValue: UILiveSource? = nil
}

extension EnvironmentValues {
  var uiLive: UILiveSource? {
    get { self[UILiveSourceKey.self] }
    set { self[UILiveSourceKey.self] = newValue }
  }
}

extension UIContext {
  /// The session with running values brought up to date: one camera's (`only`), or every
  /// camera's take values and the drives (`only: nil`).
  func liveSession(_ live: UILiveSource?, only cameraID: String? = nil, follows: UILiveSource.Follows) -> UISessionSnapshot {
    guard let live else { return session }
    var session = session
    session.drives = live.drives()
    for index in session.cameras.indices where cameraID == nil || session.cameras[index].id == cameraID {
      session.cameras[index] = live.camera(session.cameras[index], follows: follows, drives: session.drives)
    }
    if let started = session.shot.startedAt { session.shot.currentShot = Date().timeIntervalSince(started) }
    let uptime = ProcessInfo.processInfo.systemUptime
    for index in session.cameras.indices {
      if let since = session.cameras[index].signalLostSince { session.cameras[index].signalLostFor = uptime - since }
    }
    return session
  }
}

/// A camera's running values as a view shows them.
struct UILiveCameraValues {
  var camera: UICameraPresentation
  var snapshot: UICameraSnapshot?
}

/// Shows a camera's running values (timecode, levels, its take's clock, size, drops and
/// time left) from a presentation brought up to date in this view's body, so only this
/// view follows them. Keep its content small: it is evaluated with every update it follows.
struct UILiveCamera<Content: View>: View {
  let camera: UICameraPresentation
  let context: UIContext
  var follows: UILiveSource.Follows = .all
  /// Also re-read on a timer: free space changes while nothing records.
  var refresh: TimeInterval? = nil
  @ViewBuilder let content: (UILiveCameraValues) -> Content
  @Environment(\.uiLive) private var live

  var body: some View {
    let _ = UIRenderProbe.count(follows == .take ? "UILiveCamera(take)" : follows == .capture ? "UILiveCamera(capture)" : "UILiveCamera")
    Group {
      if let refresh, live != nil {
        TimelineView(.periodic(from: .now, by: refresh)) { _ in
          content(Self.values(camera, context: context, live: live, follows: follows))
        }
      } else {
        content(Self.values(camera, context: context, live: live, follows: follows))
      }
    }
    // Running values never animate, even inside an animated container.
    .transaction { $0.animation = nil }
  }

  static func values(_ camera: UICameraPresentation, context: UIContext, live: UILiveSource?,
    follows: UILiveSource.Follows) -> UILiveCameraValues {
    guard live != nil, let index = context.session.cameras.firstIndex(where: { $0.id == camera.id }) else {
      return UILiveCameraValues(camera: camera, snapshot: context.snapshot(camera.id))
    }
    let session = context.liveSession(live, only: camera.id, follows: follows)
    let snapshot = session.cameras[index]
    return UILiveCameraValues(camera: UIPresentationBuilder.camera(snapshot, index: index, in: session), snapshot: snapshot)
  }
}

/// The picture's VoiceOver label, which names the take's clock: brought up to date in this
/// modifier, so the picture itself is not re-evaluated with the clock.
struct UILiveCameraAccessibilityLabel: ViewModifier {
  let camera: UICameraPresentation
  let context: UIContext
  @Environment(\.uiLive) private var live

  func body(content: Content) -> some View {
    content.accessibilityLabel(UILiveCamera<EmptyView>.values(camera, context: context, live: live, follows: .take).camera.accessibilityLabel)
  }
}

/// Shows session values that run (the takes' clocks, the drives' free space, the shot clock)
/// from a session and presentation brought up to date in this view's body. `refresh` also
/// re-reads them on a timer, for free space that changes while nothing records. A content
/// that takes the session alone builds no presentation (with `problems()`, the costly part).
struct UILiveSession<Content: View>: View {
  let context: UIContext
  var refresh: TimeInterval? = nil
  /// The name the offscreen performance check counts this view's evaluations under.
  var probe = "UILiveSession"
  private let presents: Bool
  private let content: (UISessionSnapshot, UISessionPresentation?) -> Content
  @Environment(\.uiLive) private var live

  init(context: UIContext, refresh: TimeInterval? = nil, probe: String = "UILiveSession",
    @ViewBuilder content: @escaping (UISessionSnapshot, UISessionPresentation) -> Content) {
    self.context = context
    self.refresh = refresh
    self.probe = probe
    presents = true
    self.content = { session, presentation in content(session, presentation ?? UIPresentationBuilder.session(session)) }
  }

  /// The session alone: nothing here builds a presentation.
  init(context: UIContext, refresh: TimeInterval? = nil, probe: String = "UILiveSession",
    @ViewBuilder content: @escaping (UISessionSnapshot) -> Content) {
    self.context = context
    self.refresh = refresh
    self.probe = probe
    presents = false
    self.content = { session, _ in content(session) }
  }

  var body: some View {
    let _ = UIRenderProbe.count(probe)
    Group {
      if let refresh, live != nil {
        TimelineView(.periodic(from: .now, by: refresh)) { _ in current }
      } else {
        current
      }
    }
    // Running values never animate, even inside an animated container.
    .transaction { $0.animation = nil }
  }

  @ViewBuilder private var current: some View {
    if live == nil {
      content(context.session, presents ? context.presentation : nil)
    } else {
      let session = context.liveSession(live, follows: .take)
      content(session, presents ? UIPresentationBuilder.session(session) : nil)
    }
  }
}

extension UIShotTiming {
  /// When the shot started: the model's start, or (fixtures) the snapshot's shot length back from now.
  var anchor: Date? { startedAt ?? currentShot.map { Date().addingTimeInterval(-$0) } }
}

/// A drive's free space and time left, re-read here every few seconds and as the takes run.
struct UILiveDriveRow: View {
  let drive: UIDrive
  var cameras: [UICameraPresentation] = []
  let context: UIContext

  var body: some View {
    UILiveSession(context: context, refresh: 5, probe: "UILiveSession(drive)") { (session: UISessionSnapshot) in
      UIDriveRow(drive: session.drives.first { $0.id == drive.id } ?? drive, cameras: cameras)
    }
  }
}

/// Which drives are full or low (under Settings › Alerts' Low Space): what the session shows as
/// state (a warning, the disk-full strip, the alert). Bumped only when a drive crosses one of
/// those, so the window and the alerts follow that and not the free space itself.
@MainActor @Observable final class UIDriveLevels {
  static let shared = UIDriveLevels()
  private(set) var revision = 0
  @ObservationIgnored private var levels: [String: Int] = [:]

  /// 2 full, 1 low, 0 neither: the drive's own `isFull` and `isLow`, so its Low Space level.
  nonisolated static func level(_ drive: UIDrive) -> Int {
    UIPresentationBuilder.isFull(drive) ? 2 : UIPresentationBuilder.isLow(drive) ? 1 : 0
  }

  func update(_ drives: [UIDrive]) {
    let next = Dictionary(drives.map { ($0.id, Self.level($0)) }, uniquingKeysWith: { first, _ in first })
    guard next != levels else { return }
    levels = next
    // Read while a view's body builds its snapshot: tell its observers after this update.
    DispatchQueue.main.async { self.revision &+= 1 }
  }
}

/// A target's monitor diagnostics, re-read in this view alone when the coordinator
/// refreshes them (once a second while they change).
struct MonitorLiveDiagnostics<Content: View>: View {
  let coordinator: MonitorCoordinator
  let target: MonitorTargetID
  @ViewBuilder let content: (MonitorDiagnostics) -> Content
  @State private var revision = 0

  var body: some View {
    let _ = revision
    content(coordinator.diagnostics(for: target))
      .onReceive(coordinator.diagnosticsPublisher) { revision &+= 1 }
  }
}
