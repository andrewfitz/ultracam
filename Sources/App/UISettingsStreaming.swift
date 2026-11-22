import MonitorKitAudio
import SwiftUI

/// Draft credentials stay in this form. Session snapshots carry only the operator's destination name.
struct UISettingsStreamingPane: View {
  let model: AppModel
  @State private var draft = ProgramStreamConfiguration()
  @State private var key = ""
  @State private var feedback: String?
  @State private var failed = false

  private var savedKeyForServer: Bool {
    model.streamSnapshot.configured &&
      draft.server.trimmingCharacters(in: .whitespacesAndNewlines) == model.streamConfiguration.server
  }

  var body: some View {
    UISettingsPane {
      Section {
        TextField("Destination name", text: $draft.name, prompt: Text("My broadcast"))
        TextField("RTMPS server", text: $draft.server, prompt: Text("rtmps://…"))
          .autocorrectionDisabled()
        SecureField("Stream key", text: $key,
          prompt: Text(savedKeyForServer ? "Saved in Keychain" : "Stream key"))
      } header: { Text("Destination") } footer: {
        UISettingsFootnote("Copy the server and stream key from your streaming service.")
      }
      UIStreamVideoSettings(format: $draft.format)
      Section {
        Picker("Audio input", selection: Binding(get: { draft.audioFeedID }, set: {
          draft.audioFeedID = $0
          draft.firstChannel = 0
        })) {
          Text("Video only").tag(nil as String?)
          ForEach(model.feedDescriptors.filter(\.enabled)) { feed in
            let audio = model.captureVendor(for: feed.selectedDevice)?.captureAudio ?? .embedded
            Text("\(feed.name) · \(audio.title)").tag(Optional(feed.id.rawValue))
          }
          if let id = draft.audioFeedID, !model.feedDescriptors.contains(where: { $0.enabled && $0.id.rawValue == id }) {
            Text("Unavailable camera").tag(Optional(id))
          }
        }
        if let id = draft.audioFeedID {
          channels(for: FeedID(rawValue: id))
          LabeledContent("Audio format", value: "Stereo AAC · 48 kHz · 160 kb/s")
        }
      } header: { Text(draft.audioFeedID.map { audioKind(for: FeedID(rawValue: $0)).title } ?? "Audio") } footer: {
        if draft.audioFeedID != nil { UISettingsFootnote("This input stays on the stream across Program cuts.") }
      }
    } trailing: {
      if feedback == nil {
        if model.streamSnapshot.active { Text("Saved changes apply to the next stream.").font(.uiMeta) }
        else if !model.programAvailable { Text("Enable two cameras to start a Program stream.").font(.uiMeta) }
      }
      if let feedback { Text(feedback).font(.uiMeta).foregroundStyle(failed ? Color.orange : .secondary) }
      Button("Save") {
        do {
          try model.saveProgramStream(draft, key: key)
          draft = model.streamConfiguration
          key = ""
          feedback = model.streamSnapshot.active ? "Saved for the next stream." : "Stream settings saved."
          failed = false
        } catch {
          feedback = error.localizedDescription
          failed = true
        }
      }
    }
    .onAppear {
      draft = model.streamConfiguration
      if !model.streamSnapshot.configured && draft.audioFeedID == nil {
        draft.audioFeedID = model.feedDescriptors.first(where: \.enabled)?.id.rawValue
      }
    }
    .onDisappear { key = "" }
  }

  private func audioKind(for feed: FeedID) -> CaptureAudioKind {
    guard let device = model.descriptor(for: feed)?.selectedDevice else { return .embedded }
    return model.captureVendor(for: device)?.captureAudio ?? .embedded
  }

  private func channels(for feed: FeedID) -> some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      let running = model.isCameraRunning(feed)
      let update = running ? model.cameraUpdate(feed) : nil
      let count = update.flatMap { $0.audioPresent && $0.audioChannels > 0 ? $0.audioChannels : nil }
      let pairs = max(1, min(count ?? 16, 64) / 2)
      let firstChannel = draft.firstChannel
      let validSelection = (0..<64).contains(firstChannel) && firstChannel.isMultiple(of: 2)
      let selectionShown = validSelection && firstChannel / 2 < pairs
      Picker("Channels", selection: $draft.firstChannel) {
        ForEach(0..<pairs, id: \.self) { pair in
          let index = pair * 2
          Text(count == 1 ? "1 (mono)" : "\(index + 1)–\(index + 2)").tag(index)
        }
        if !validSelection {
          Text("Unavailable selection").tag(firstChannel)
        } else if !selectionShown {
          Text("\(firstChannel + 1)–\(firstChannel + 2)\(count == nil ? "" : " (unavailable)")").tag(firstChannel)
        }
      }
      if count == nil {
        Text("Waiting for \(audioKind(for: feed).label)").font(.uiMeta).foregroundStyle(.secondary)
      } else if !selectionShown {
        Text("Choose a channel pair carried by this input.").font(.uiMeta).foregroundStyle(.orange)
      } else if let tap = model.audioMeterTap(for: feed) {
        UIStreamInputPeak(tap: tap, firstChannel: draft.firstChannel).id(tap.identity)
      }
    }
  }

  static func level(_ peak: Float) -> String {
    guard peak.isFinite, peak > 0 else { return "−∞ dBFS" }
    return String(format: "%.1f dBFS", 20 * log10(peak))
  }
}

struct UIStreamVideoSettings: View {
  @Binding var format: ProgramStreamFormat

  var body: some View {
    Section {
      Picker("Output size", selection: $format.size) {
        ForEach(ProgramStreamFormat.sizes, id: \.self) { Text($0.title).tag($0) }
      }
      .help("Source size uses the Program picture size at the start of the stream.")
      Picker("Aspect", selection: $format.scalingMode) {
        Text("Fit").tag(ProgramScalingMode.fit)
        Text("Crop").tag(ProgramScalingMode.crop)
      }
      if format.scalingMode == .fit {
        Toggle("Allow upscaling", isOn: $format.allowUpscale)
      }
      Picker("Frame rate", selection: $format.rate) {
        ForEach(ProgramStreamFormat.rates, id: \.self) { Text("\($0.title) fps").tag($0) }
      }
      Picker("Video codec", selection: Binding(get: { format.codec }, set: { codec in
        var next = format
        next.codec = codec
        if !next.supportedColorSpaceIDs.contains(next.colorSpaceID) { next.colorSpaceID = "rec709-video" }
        format = next
      })) {
        ForEach(ProgramStreamVideoCodec.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      Picker("Color space", selection: $format.colorSpaceID) {
        ForEach(UIProgramColor.choices.filter { format.supportedColorSpaceIDs.contains($0.id) }, id: \.id) {
          Text($0.title).tag($0.id)
        }
      }
      UISettingsVideoQuality(rate: $format.videoMbps, streaming: true)
    } header: { Text("Stream Video") } footer: {
      if format.codec != .h264 {
        UISettingsFootnote("Your streaming service must accept this codec over Enhanced RTMP.")
      }
    }
  }
}

extension ProgramStreamFormat {
  var pictureDescription: String {
    let color = UIProgramColor.choices.first { $0.id == colorSpaceID }?.title ?? colorSpaceID
    return "\(size.title) · \(rate.title) fps · \(color)"
  }
  var encoderDescription: String { "\(codec.title) · \(videoMbps) Mbps" }
}

/// The camera only meters these readings while the input form is visible.
private struct UIStreamInputPeak: View {
  let tap: AudioMeterTap
  let firstChannel: Int
  @State private var attachment: AudioMeterTap.Attachment?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
      LabeledContent("Input peak", value: reading).monospacedDigit()
    }
    .onAppear { if attachment == nil { attachment = AudioMeterTap.Attachment(tap: tap) } }
    .onDisappear { attachment?.close(); attachment = nil }
  }

  private var reading: String {
    guard let snapshot = attachment?.meter?.snapshot(),
      firstChannel >= 0, firstChannel < snapshot.channelCount else { return "—" }
    let right = min(firstChannel + 1, snapshot.channelCount - 1)
    let peak = max(snapshot.channels[firstChannel].samplePeak, snapshot.channels[right].samplePeak)
    return peak.isFinite ? String(format: "%.1f dBFS", peak) : "−∞ dBFS"
  }
}
