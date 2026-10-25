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

/// A camera's embedded audio on broadcast meters: per-channel bars (true peak by
/// default; sample peak, RMS, VU or PPM on request) and the EBU R 128 loudness
/// panel (M, S, I, LRA, Max TP). Falls back to the plain peak/RMS meter where no
/// meters are available.
struct UIAudioMeterPanel: View {
  let cameraID: String
  /// The camera's status levels: whether audio is present, and the fallback meter.
  let levels: UIAudioLevels
  @Environment(\.uiAudioMeters) private var source

  var body: some View {
    if let tap = source?.tap(cameraID) {
      // A new capture (camera removed and added again) is a new tap: a new view pairs attach and detach.
      UIAudioMeterTapView(tap: tap, present: levels.present).id(ObjectIdentifier(tap))
    } else {
      UIAudioMeter(audio: levels)
    }
  }
}

/// The meters of one tap. Metering runs only while this view is shown, each
/// showing on the meter `attach` hands it (a new one when metering starts).
private struct UIAudioMeterTapView: View {
  let tap: AudioMeterTap
  let present: Bool
  @State private var kind: AudioMeterBarKind = .truePeak
  @State private var meter: AudioMeter?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker("Meter", selection: $kind) {
        ForEach(AudioMeterBarKind.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .help("Meter scale for the channel bars. Loudness is EBU R 128 (−23 LUFS target).")
      Group {
        if let meter { AudioMeterView(meter: meter, kind: kind) } else { Color.clear }
      }
      .frame(height: 160)
      .opacity(present ? 1 : 0.4)
      .overlay {
        if !present {
          Text("No embedded audio").font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
      }
      Text("Click the bars to reset peaks; right-click to reset loudness. Loudness is measured while shown.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onAppear { meter = tap.attach() }
    .onDisappear { tap.detach() }
  }
}

/// A camera's level meter (the strip's, the collapsed strip's, the menu bar's) at the
/// display rate: it shows the camera's live meter while one exists and draws it on every
/// display refresh, reading the meter's lock-free latest readings. The status levels,
/// published a few times a second, only say whether audio is present (and stand in
/// where there's no meter: fixtures, previews, a camera not capturing).
struct UILiveAudioMeter: View {
  let cameraID: String
  let audio: UIAudioLevels
  var compact = false
  @Environment(\.uiAudioMeters) private var source

  var body: some View {
    if let tap = source?.tap(cameraID) {
      // A new capture is a new tap: a new view pairs attach and detach.
      UILiveAudioMeterTapView(tap: tap, audio: audio, compact: compact).id(ObjectIdentifier(tap))
    } else {
      UIAudioMeter(audio: audio, compact: compact)
    }
  }
}

/// Meters one tap while shown; the tap meters off the capture thread only while a view attaches.
private struct UILiveAudioMeterTapView: View {
  let tap: AudioMeterTap
  let audio: UIAudioLevels
  let compact: Bool
  @State private var meter: AudioMeter?

  var body: some View {
    UIAudioMeter(audio: audio, compact: compact, meter: meter)
      .onAppear { meter = tap.attach() }
      .onDisappear {
        tap.detach()
        meter = nil
      }
  }
}
