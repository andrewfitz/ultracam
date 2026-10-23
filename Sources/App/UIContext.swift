import AppKit
import MonitorKitCore
import SwiftUI

struct UIInput: Identifiable, Sendable, Equatable {
  var id: String
  var name: String
}

/// Supplies live pictures. The app version shows the selected camera through
/// its native preview and other cameras through monitor surfaces; fixtures
/// draw a stand-in so screens can be rendered and tested without hardware.
@MainActor protocol UIPictureProviding {
  /// `zoom` magnifies the picture about its centre (1 is Fit), in this view only.
  func picture(cameraID: String, compact: Bool, zoom: Double) -> AnyView
  func programPicture() -> AnyView
}

extension UIPictureProviding {
  func picture(cameraID: String, compact: Bool) -> AnyView { picture(cameraID: cameraID, compact: compact, zoom: 1) }
}

/// Per-camera monitor tool settings: MonitorKit tool state, the camera's signal
/// declaration and its scopes.
@MainActor protocol UIMonitorSettingsProviding {
  func preferences(for cameraID: String) -> MonitorFeedPreferences
  func setPreferences(_ preferences: MonitorFeedPreferences, for cameraID: String)
  /// Where the camera's monitor-only LUT file stands (loading, shown, failed).
  func monitorLUTState(for cameraID: String) -> MonitorFeedHost.MonitorLUTState
  /// What the camera's scope measures: the shown picture's signal (nil before a
  /// frame) and whether a LUT is on the scope's stage.
  func scopeMeasurement(for cameraID: String) -> (signal: SignalDescription?, stageLUT: Bool)
}

extension UIMonitorSettingsProviding {
  /// Fixtures have no feed host: no monitor LUT is loading or loaded.
  func monitorLUTState(for cameraID: String) -> MonitorFeedHost.MonitorLUTState { .none }
  /// Fixtures have no picture: no signal yet and no LUT.
  func scopeMeasurement(for cameraID: String) -> (signal: SignalDescription?, stageLUT: Bool) { (nil, false) }
}

/// Everything a view in the new interface needs: the derived presentation,
/// the raw session for details, and one way to act.
@MainActor
struct UIContext {
  var session: UISessionSnapshot
  var presentation: UISessionPresentation
  var inputs: [UIInput] = []
  var send: @MainActor (UIAction) -> Void
  var pictures: any UIPictureProviding
  var monitor: any UIMonitorSettingsProviding
  /// A confirmation waiting for an answer (Stop Camera while recording, …).
  var confirmation: (message: String, action: UIAction)? = nil
  var confirm: @MainActor () -> Void = {}
  var cancelConfirmation: @MainActor () -> Void = {}
  /// Rebuilds the context from the live models. Views hosted in their own column
  /// (inspector, sidebar) call this inside `body` so Observation tracks the models
  /// there too. Fixtures leave it nil.
  var refreshed: (@MainActor () -> UIContext)? = nil

  /// The freshest context available: rebuilt from the models in the app, unchanged in fixtures.
  var current: UIContext { refreshed?() ?? self }

  func camera(_ id: String) -> UICameraPresentation? { presentation.cameras.first { $0.id == id } }
  func snapshot(_ id: String) -> UICameraSnapshot? { session.cameras.first { $0.id == id } }

  /// A context built from a fixed session, for tests, previews and offscreen rendering.
  static func fixture(_ session: UISessionSnapshot, inputs: [UIInput] = UIFixtures.inputs,
    send: @escaping @MainActor (UIAction) -> Void = { _ in }) -> UIContext {
    UIContext(session: session, presentation: UIPresentationBuilder.session(session), inputs: inputs, send: send,
      pictures: UIFixturePictures(), monitor: UIFixtureMonitorSettings(session: session))
  }
}

private struct UIContextKey: EnvironmentKey {
  static let defaultValue: UIContext? = nil
}

extension EnvironmentValues {
  var uiContext: UIContext? {
    get { self[UIContextKey.self] }
    set { self[UIContextKey.self] = newValue }
  }
}

// MARK: - Fixtures

/// A stand-in picture: a soft gradient with the camera's name, never a real frame.
@MainActor struct UIFixturePictures: UIPictureProviding {
  func picture(cameraID: String, compact: Bool, zoom: Double) -> AnyView {
    AnyView(UIFixturePicture(seed: cameraID).scaleEffect(max(1, zoom)).clipped())
  }
  func programPicture() -> AnyView { AnyView(UIFixturePicture(seed: "program")) }
}

struct UIFixturePicture: View {
  let seed: String
  var body: some View {
    let hue = Double(abs(seed.hashValue % 360)) / 360
    LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.45), Color(hue: hue + 0.08, saturation: 0.25, brightness: 0.25)],
      startPoint: .topLeading, endPoint: .bottomTrailing)
      .overlay(Image(systemName: "person.crop.rectangle").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.white.opacity(0.35)))
      .accessibilityHidden(true)
  }
}

@MainActor final class UIFixtureMonitorSettings: UIMonitorSettingsProviding {
  private var values: [String: MonitorFeedPreferences] = [:]
  init(session: UISessionSnapshot) {
    for camera in session.cameras {
      var preferences = MonitorFeedPreferences()
      for tool in camera.activeTools {
        preferences = UIMonitorBridge.toggled(tool, in: preferences)
      }
      values[camera.id] = preferences
    }
  }
  func preferences(for cameraID: String) -> MonitorFeedPreferences { values[cameraID] ?? MonitorFeedPreferences() }
  func setPreferences(_ preferences: MonitorFeedPreferences, for cameraID: String) { values[cameraID] = preferences }
}

/// Representative sessions for every screen. Tests and the offscreen renderer use these.
enum UIFixtures {
  static let inputs = [UIInput(id: "mini-recorder-12g", name: "UltraStudio Mini Recorder 12G"),
    UIInput(id: "ultrastudio-4k-mini", name: "UltraStudio 4K Mini")]

  static func camera(_ index: Int, recording: UIRecordingStatus = .recording, elapsed: TimeInterval = 751,
    inUse: Bool = false, signal: UISignal = .live(format: "2160p 59.94")) -> UICameraSnapshot {
    var camera = UICameraSnapshot(id: "camera-\(index)", name: "Camera \(index)")
    camera.inputName = inputs[(index - 1) % inputs.count].name
    camera.running = true
    camera.signal = signal
    camera.outputFormat = "1080p 29.97"
    camera.inUse = inUse
    camera.effects = index == 1 ? [true, true, true, true] : [false, true, true, false]
    camera.lutName = index == 1 ? "FX3_SLog3_to_709.cube" : nil
    camera.timecode = "14:22:31:12"
    camera.audio = UIAudioLevels(present: true, peakLeft: 0.52, peakRight: 0.48, rmsLeft: 0.31, rmsRight: 0.28)
    camera.activeTools = index == 1 ? [.guides, .zebra] : [.scopes]
    var rec = UICameraRecording()
    rec.status = recording
    rec.elapsed = recording == .idle ? 0 : elapsed
    rec.fileBytes = recording == .idle ? 0 : Int64(elapsed * 88_000_000)
    rec.megabitsPerSecond = recording == .idle ? 0 : (index == 1 ? 707 : 354)
    rec.folderPath = index == 1 ? "/Volumes/8TB/Takes/Camera 1" : "/Volumes/Archive/B-cam"
    rec.folderIsCustom = index != 1
    rec.secondsLeft = index == 1 ? 6720 : 20400
    camera.recording = rec
    return camera
  }

  static func baseSession() -> UISessionSnapshot {
    var session = UISessionSnapshot()
    session.drives = [UIDrive(name: "8TB", availableBytes: 595_000_000_000, totalBytes: 8_000_000_000_000, secondsLeft: 6720),
      UIDrive(name: "Archive", availableBytes: 3_000_000_000_000, totalBytes: 4_000_000_000_000, secondsLeft: 20400)]
    session.recentTakes = [UITake(url: URL(fileURLWithPath: "/Volumes/8TB/Takes/Camera 1/Camera 1_2026-10-21_08-02-11_001.mov"),
      name: "Camera 1_2026-10-21_08-02-11_001.mov", date: Date(timeIntervalSince1970: 1_792_400_000), duration: 2292)]
    session.interruptedTakes = [UIInterruptedTake(id: "/Volumes/8TB/Takes/.journal", title: "Camera 1_2026-10-19_11-15-02_001.mov")]
    session.defaultFolderPath = "/Volumes/8TB/Takes"
    return session
  }

  /// Two cameras in a Program meeting, both recording, Camera 1 on air and selected.
  static func programMeeting() -> UISessionSnapshot {
    var session = baseSession()
    session.outputMode = .program
    session.cameras = [camera(1), camera(2, signal: .live(format: "2160p 29.97"))]
    session.selectedID = "camera-1"
    session.programInUse = true
    session.onAirID = "camera-1"
    session.autoSwitching = true
    session.strategyTitle = "Natural talking head"
    session.shot = UIShotTiming(currentShot: 8.2)
    session.recentCuts = [UICutRecord(at: Date(timeIntervalSince1970: 1_792_405_343), cameraID: "camera-1", cameraName: "Camera 1", automatic: true),
      UICutRecord(at: Date(timeIntervalSince1970: 1_792_405_318), cameraID: "camera-2", cameraName: "Camera 2", automatic: false)]
    return session
  }

  /// One camera used by a meeting app, recording a backup.
  static func singleMeeting() -> UISessionSnapshot {
    var session = baseSession()
    session.cameras = [camera(1, inUse: true)]
    session.selectedID = "camera-1"
    session.drives = [session.drives[0]]
    session.layout = .single
    return session
  }

  /// Two cameras recording with no meeting: Camera 2 paused.
  static func standalone() -> UISessionSnapshot {
    var session = baseSession()
    session.cameras = [camera(1), camera(2, recording: .paused, elapsed: 252, signal: .live(format: "2160p 29.97"))]
    session.selectedID = "camera-1"
    return session
  }

  /// Four cameras in Separate mode, Camera 1 in use, Camera 3 without a signal.
  static func fourUp() -> UISessionSnapshot {
    var session = baseSession()
    var third = camera(3, recording: .idle, signal: .noSignal)
    third.inputName = "DeckLink Mini Recorder 4K"
    session.cameras = [camera(1, inUse: true), camera(2), third, camera(4, recording: .paused, elapsed: 252)]
    session.selectedID = "camera-2"
    session.layout = .fourUp
    session.sidebarVisible = false
    return session
  }

  /// Problems: a preview error on Camera 1, a LUT that couldn't be restored and a
  /// failed automatic start on Camera 2, and the camera extension not installed.
  static func problems() -> UISessionSnapshot {
    var session = baseSession()
    var one = camera(1, recording: .idle)
    one.previewError = "The preview stopped responding."
    var two = camera(2, recording: .idle)
    two.running = false
    two.signal = .none
    two.automaticStart = true
    two.automaticStartFailed = true
    two.automaticStatus = "Couldn't start: the UltraStudio is in use by another app."
    two.lutError = "Saved LUT could not be restored: the file was moved."
    session.cameras = [one, two]
    session.selectedID = "camera-2"
    session.install = UIInstallState(canRequestChanges: true, pending: false, status: "", unavailableReason: nil, installed: false)
    return session
  }

  /// Nothing running yet.
  static func stopped() -> UISessionSnapshot {
    var session = baseSession()
    var one = camera(1, recording: .idle)
    one.running = false
    one.signal = .none
    session.cameras = [one]
    session.selectedID = "camera-1"
    session.layout = .single
    return session
  }
}
