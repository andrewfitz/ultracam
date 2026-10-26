import Foundation
import SwiftUI

// The views that show running values; the models' side is LiveTelemetry.swift.
import Observation

// MARK: - Running values in the session snapshot

extension UISessionBridge {
  /// A camera's running capture values: timecode and audio levels.
  static func applyCapture(_ update: CaptureUpdate?, to camera: inout UICameraSnapshot) {
    camera.timecode = update?.timecode
    if let update {
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
    // The running take's audio so far, then the finished take's (cleared when the next starts).
    rec.audio = model.takeAudioSoFar(id) ?? model.takeAudio[id]
    rec.savedDuration = rec.savedURL != nil ? stats?.elapsed : nil
    let folder = model.recordingModel.outputFolder(for: id)
    rec.secondsLeft = folder.flatMap { url in drives.first { $0.name == UIRecordingLibrary.volumeName(for: url) }?.secondsLeft }
  }

  /// Free space and recording time left on every camera's drive, read at most every two seconds.
  func currentDrives() -> [UIDrive] {
    // Free space isn't observable: views follow a drive becoming low or full (`UIDriveLevels`),
    // and the views that show the figures re-read them on a timer.
    _ = UIDriveLevels.shared.revision
    let recording = model.recordingModel
    let folders = model.feedDescriptors.map { recording.outputFolder(for: $0.id) }
    return Self.cachedDrives(for: folders) {
      UIRecordingLibrary.drives(for: folders,
        recordingRates: model.feedDescriptors.compactMap { descriptor -> (URL, Double)? in
          guard let folder = recording.outputFolder(for: descriptor.id),
            let state = recording.feeds.first(where: { $0.id == descriptor.id }),
            state.status == .recording || state.status == .paused else { return nil }
          return (folder, state.statistics?.videoMegabitsPerSecond ?? UIRecordingLibrary.nominalMegabits(codec: recording.codec, fast: true))
        })
    }
  }
}

// MARK: - Live values for the views that show them

/// Brings a snapshot's running values up to date from the live models, for the view that
/// calls it: that view (and only it) then follows those values. The app's root puts one in
/// the environment; fixtures have none and show their snapshots as they are.
@MainActor final class UILiveSource {
  private let bridge: UISessionBridge

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
      UISessionBridge.applyCapture(camera.running ? model.liveCameraUpdate(id) : nil, to: &camera)
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
/// re-reads them on a timer, for free space that changes while nothing records.
struct UILiveSession<Content: View>: View {
  let context: UIContext
  var refresh: TimeInterval? = nil
  /// The name the offscreen performance check counts this view's evaluations under.
  var probe = "UILiveSession"
  @ViewBuilder let content: (UISessionSnapshot, UISessionPresentation) -> Content
  @Environment(\.uiLive) private var live

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
      content(context.session, context.presentation)
    } else {
      let session = context.liveSession(live, follows: .take)
      content(session, UIPresentationBuilder.session(session))
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
  let context: UIContext

  var body: some View {
    UILiveSession(context: context, refresh: 5, probe: "UILiveSession(drive)") { session, _ in
      UIDriveRow(drive: session.drives.first { $0.id == drive.id } ?? drive)
    }
  }
}

/// Which drives are full or have under 30 minutes left: what the session shows as state
/// (a warning, the disk-full strip). Bumped only when a drive crosses one of those, so the
/// window follows that and not the free space itself.
@MainActor @Observable final class UIDriveLevels {
  static let shared = UIDriveLevels()
  private(set) var revision = 0
  @ObservationIgnored private var levels: [String: Int] = [:]

  func update(_ drives: [UIDrive]) {
    let next = Dictionary(drives.map { drive in
      (drive.name, UIPresentationBuilder.isFull(drive) ? 2 : (drive.secondsLeft ?? .infinity) < 30 * 60 ? 1 : 0)
    }, uniquingKeysWith: { first, _ in first })
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
