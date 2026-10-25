import MonitorKitAudio
import MonitorKitUI
import SwiftUI

/// Finds a camera's broadcast audio meters. The app looks up the camera's
/// existing capture (never creating one); fixtures and previews have none and
/// show the plain level meter instead.
@MainActor struct UIAudioMeterSource {
  let tap: @MainActor (_ cameraID: String) -> AudioMeterTap?
}

private struct UIAudioMeterSourceKey: EnvironmentKey {
  static let defaultValue: UIAudioMeterSource? = nil
}

extension EnvironmentValues {
  var uiAudioMeters: UIAudioMeterSource? {
    get { self[UIAudioMeterSourceKey.self] }
    set { self[UIAudioMeterSourceKey.self] = newValue }
  }
}

/// A camera's embedded audio on MonitorKit's full broadcast panel: true-peak
/// bars with each channel's maximum and the over latch, the EBU R 128 panel
/// in LUFS (M, S, I, LRA, Max TP, PLR) and phase correlation. One standard
/// meter, no meter-type picker. Without a live meter (fixtures, previews) the
/// camera's status peaks stand in on the same scale.
struct UIAudioMeterPanel: View {
  let cameraID: String
  var name: String? = nil
  /// The camera's status levels: whether audio is present, and the fallback readings.
  let levels: UIAudioLevels
  @Environment(\.uiAudioMeters) private var source

  var body: some View {
    Group {
      if let tap = source?.tap(cameraID) {
        // A new capture (camera removed and added again) is a new tap: a new view pairs attach and detach.
        UIAudioMeterTapView(tap: tap, present: levels.present, name: name).id(ObjectIdentifier(tap))
      } else {
        LevelMeterView(snapshot: levels.meterSnapshot, style: .full, present: levels.present, name: name)
      }
    }
    .frame(height: 210)
  }
}

/// The meters of one tap. Metering runs only while this view is shown, each
/// showing on the meter `attach` hands it (a new one when metering starts).
private struct UIAudioMeterTapView: View {
  let tap: AudioMeterTap
  let present: Bool
  let name: String?
  @State private var meter: AudioMeter?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Group {
        if let meter { AudioMeterView(meter: meter, present: present, name: name) } else { Color.clear }
      }
      Text("Click OVER to reset the peaks; right-click to reset loudness. Loudness is measured while shown or recording.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .onAppear { meter = tap.attach() }
    .onDisappear { tap.detach() }
  }
}

/// A camera's level meter (the expanded strip's, the collapsed strip's, the
/// menu bar card's) on MonitorKit's `LevelMeterView`: true peak on the
/// broadcast scale, drawn at the display rate from the camera's live meter
/// while one exists. The status levels, published a few times a second, say
/// whether audio is present and stand in where there's no meter (fixtures,
/// previews, a camera not capturing). Showing the meter names the camera and
/// timecode in the tap's over log.
struct UILiveAudioMeter: View {
  let cameraID: String
  let name: String
  var timecode: String? = nil
  let audio: UIAudioLevels
  var style: LevelMeterStyle = .strip
  @Environment(\.uiAudioMeters) private var source

  var body: some View {
    if let tap = source?.tap(cameraID) {
      // A new capture is a new tap: a new view pairs attach and detach.
      UILiveAudioMeterTapView(tap: tap, name: name, timecode: timecode, audio: audio, style: style)
        .id(ObjectIdentifier(tap))
    } else {
      LevelMeterView(snapshot: audio.meterSnapshot, style: style, present: audio.present, name: name)
    }
  }
}

/// Meters one tap while shown; the tap meters off the capture thread only while a view attaches.
private struct UILiveAudioMeterTapView: View {
  let tap: AudioMeterTap
  let name: String
  let timecode: String?
  let audio: UIAudioLevels
  let style: LevelMeterStyle
  @State private var meter: AudioMeter?

  var body: some View {
    Group {
      if let meter {
        LevelMeterView(meter: meter, style: style, present: audio.present, name: name)
      } else {
        LevelMeterView(snapshot: audio.meterSnapshot, style: style, present: audio.present, name: name)
      }
    }
    .onAppear {
      meter = tap.attach()
      tap.setLogContext(camera: name, timecode: timecode)
    }
    .onChange(of: timecode) { tap.setLogContext(camera: name, timecode: timecode) }
    .onDisappear {
      tap.detach()
      meter = nil
    }
  }
}

extension UIAudioLevels {
  /// The status peaks as meter readings, for a camera without a live meter.
  var meterSnapshot: AudioMeterSnapshot { AudioMeterTap.snapshot(statusPeaks: [peakLeft, peakRight]) }
}
