import SwiftUI

/// How many channels a camera's strip meter shows. As Detected is measured, because a capture
/// device reports only its maximum: the smallest of 2, 4, 8 or 16 that covers the highest pair
/// that has carried signal while metered since capture started. Hidden channels are still
/// metered and recorded, and an over on one still shows. Collapsed strips always show 1–2.
enum UIChannelsShown: Int, CaseIterable, Identifiable, Sendable {
  case asDetected = 0
  case two = 2
  case four = 4
  case eight = 8
  case sixteen = 16

  var id: Int { rawValue }
  var title: String { self == .asDetected ? "As Detected" : "\(rawValue)" }

  static let tiers = [2, 4, 8, 16]

  /// The smallest tier that covers `channels`: 2 before anything is detected.
  static func tier(covering channels: Int) -> Int { tiers.first { $0 >= channels } ?? 16 }

  /// The channels to show: the fixed choice or the detected tier, never more than the source
  /// has (`available`, nil while it isn't known).
  func count(detected: Int, available: Int?) -> Int {
    let wanted = self == .asDetected ? Self.tier(covering: detected) : rawValue
    guard let available, available > 0 else { return wanted }
    return min(wanted, available)
  }

  /// "Showing 2 of 8" for a running camera, "Stopped" for one that isn't.
  static func status(shown: Int, of available: Int?) -> String {
    guard let available, available > 0 else { return "Stopped" }
    return "Showing \(shown) of \(available)"
  }
}

/// Settings › Audio's true-peak warning: overs count and log from this level, and a take's note
/// warns at it. A meeting mix and a broadcast deliverable want different levels.
enum UITruePeakWarning {
  static let levels: [Double] = [-1, -2, -3]
  /// "−1 dBTP", with a minus sign as the meters print levels.
  static func title(_ level: Double) -> String { "\(String(Int(level.rounded())).replacingOccurrences(of: "-", with: "−")) dBTP" }
}

/// Settings › Audio: Channels Shown per camera, and the true-peak warning level.
struct UISettingsAudioPane: View {
  let model: AppModel
  @Bindable var interface: UIInterfaceState

  var body: some View {
    let cameras = interface.ordered(model.feedDescriptors, id: \.id.rawValue)
    UISettingsPane {
      Section {
        // The detected count and the source's count change while running: read once a second.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
          ForEach(Array(cameras.enumerated()), id: \.element.id) { index, descriptor in
            channelsRow(number: index + 1, descriptor: descriptor)
          }
        }
        if cameras.isEmpty { Text("Add a camera to choose its channels.").foregroundStyle(.secondary) }
      } header: {
        UISettingsHeader("Channels Shown", info: "As Detected shows the smallest of 2, 4, 8 or 16 that covers the highest pair that has carried signal while metered since capture started. Signal is a true peak above −90 dBTP. It only grows, and starts over with each capture.")
      } footer: {
        UISettingsFootnote("Hidden channels are still recorded, and still trigger OVER.")
      }

      Section("Level Warning") {
        Picker("True-peak warning", selection: $interface.truePeakWarning) {
          ForEach(UITruePeakWarning.levels, id: \.self) { Text(UITruePeakWarning.title($0)).tag($0) }
        }
      }
    }
  }

  private func channelsRow(number: Int, descriptor: FeedDescriptor) -> some View {
    let id = descriptor.id
    let available = model.isCameraRunning(id) ? model.liveCameraUpdate(id).flatMap { $0.audioPresent ? $0.audioChannels : nil } : nil
    let choice = interface.channelsShown(for: id.rawValue)
    let shown = choice.count(detected: model.audioMeterTap(for: id)?.detectedChannels ?? 0, available: available)
    return LabeledContent {
      Picker("Channels shown for \(descriptor.name)", selection: Binding(get: { choice },
        set: { interface.setChannelsShown($0, for: id.rawValue) })) {
        ForEach(UIChannelsShown.allCases) { Text($0.title).tag($0) }
      }
      .labelsHidden()
      .fixedSize()
    } label: {
      HStack(spacing: 6) {
        UINumberCapsule(number: number)
        Text(descriptor.name)
      }
      Text(UIChannelsShown.status(shown: shown, of: available))
    }
  }
}
