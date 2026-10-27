import SwiftUI

/// The signal badge in a camera strip is also the quick feed-settings control.
/// Sony exposes its HDMI timing choices here; the full Sony control sheet remains
/// available for exposure and focus settings.
struct UIFeedSettingsMenu: View {
  let camera: UICameraPresentation
  let snapshot: UICameraSnapshot?
  let sonyStore: SonyCameraStore?
  @State private var showingSonySettings = false

  private var sonyState: SonyFeedState? {
    guard let sonyStore, sonyStore.assignment(for: camera.id) != nil else { return nil }
    return sonyStore.state(for: camera.id)
  }

  var body: some View {
    Menu {
      Text(camera.inputName).font(.caption)
      if let snapshot, let format = snapshot.outputFormat {
        Text("Ultracam output · " + format).font(.caption)
      }
      Divider()
      if let sonyStore, let state = sonyState {
        if state.connected {
          sonyTimingMenu(store: sonyStore, state: state)
          Divider()
          Button("Open Sony camera settings…") { showingSonySettings = true }
        } else {
          Label("Sony camera disconnected", systemImage: "wifi.slash")
          Button("Open Sony camera settings…") { showingSonySettings = true }
        }
      } else {
        Label("HDMI timing is controlled by the camera", systemImage: "info.circle")
        if isBlackmagicInput {
          Text("Blackmagic input detected. Change output timing on the camera or in Desktop Video.")
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(camera.statusTone.color)
        Text(camera.statusBadge)
        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
      }
      .font(.uiBadge)
      .lineLimit(1)
      .padding(.horizontal, 6)
      .frame(height: 18)
      .foregroundStyle(camera.statusTone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      .background(.fill.tertiary, in: Capsule())
      .contentShape(Capsule())
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Feed settings for " + camera.name)
    .accessibilityLabel("Feed settings, " + camera.statusBadge)
    .sheet(isPresented: $showingSonySettings) {
      if let sonyStore {
        UISonyCameraSettings(feedID: camera.id, name: camera.name, store: sonyStore)
      }
    }
  }

  private var isBlackmagicInput: Bool {
    let value = camera.inputName.lowercased()
    return value.contains("blackmagic") || value.contains("ultrastudio") || value.contains("decklink")
  }

  @ViewBuilder private func sonyTimingMenu(store: SonyCameraStore, state: SonyFeedState) -> some View {
    if let resolution = state.properties.first(where: { $0.id == "hdmiResolution" }) {
      sonyPicker("Output resolution", property: resolution, store: store)
    }
    if let timing = state.properties.first(where: { $0.id == "hdmiOutput4K" }) {
      sonyPicker("Frame rate / bit depth", property: timing, store: store)
    }
    if let raw = state.properties.first(where: { $0.id == "hdmiRawFrameRate" }) {
      sonyPicker("RAW frame rate", property: raw, store: store)
    }
    // HDMI is an uncompressed feed; there is no camera-side bitrate control.
    Text("Bitrate · uncompressed HDMI")
      .foregroundStyle(.secondary)
  }

  @ViewBuilder private func sonyPicker(_ title: String, property: SonyCameraProperty,
    store: SonyCameraStore) -> some View {
    if property.writable && !property.choices.isEmpty {
      Picker(title, selection: Binding(
        get: { property.value },
        set: { value in Task { await store.set(property, value: value, feedID: camera.id) } })) {
        if !property.choices.contains(where: { $0.value == property.value }) {
          Text(property.label).tag(property.value)
        }
        ForEach(property.choices) { choice in Text(choice.label).tag(choice.value) }
      }
    } else {
      Text("\(title) · \(property.label)")
    }
  }
}

/// Bundled vector brand marks keep the header legible in both appearances.
struct UIFeedBrandMark: View {
  enum Brand { case sony, blackmagic }
  let brand: Brand

  var body: some View {
    Image(brand == .sony ? "SonyLogo" : "BlackmagicLogo")
      .resizable()
      .renderingMode(.template)
      .scaledToFit()
      .frame(width: 18, height: 18)
      .foregroundStyle(.secondary)
      .accessibilityLabel(brand == .sony ? "Sony" : "Blackmagic Design")
  }
}
