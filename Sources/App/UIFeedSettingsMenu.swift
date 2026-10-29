import SwiftUI

/// The feed badge opens camera-provided output properties and generic settings.
struct UIFeedSettingsMenu: View {
    let camera: UICameraPresentation
    let snapshot: UICameraSnapshot?
    let controlStore: CameraControlStore?
    var viewFactories: [String: ControlViewFactory] = [:]
    @State private var showingSettings = false
    private var state: CameraControlFeedState? {
        guard let controlStore, controlStore.assignment(for: camera.id) != nil else { return nil }
        return controlStore.state(for: camera.id)
    }
    var body: some View {
        Menu {
            Text(camera.inputName).font(.caption)
            if let format = snapshot?.outputFormat { Text("Ultracam output · " + format).font(.caption) }
            Divider()
            if let controlStore, let state {
                if state.connected {
                    ForEach(state.properties.filter { $0.role == .outputTiming }) { property in
                        if property.writable, !property.options.isEmpty {
                            Picker(property.localizedLabel(), selection: Binding(get: { property.value }, set: { value in
                                Task { await controlStore.set(property, value: value, feedID: camera.id) }
                            })) {
                                if !property.options.contains(where: { $0.value == property.value }) {
                                    Text(UIControlPresentation.value(property)).tag(property.value)
                                }
                                ForEach(property.options) { Text($0.localizedLabel()).tag($0.value) }
                            }.disabled(state.busy)
                        } else { Text("\(property.localizedLabel()) · \(UIControlPresentation.value(property))") }
                    }
                } else { Label("Control camera disconnected", systemImage: "wifi.slash") }
                Button("Open camera settings…") { showingSettings = true }
            } else { Label("Output timing is controlled by the source", systemImage: "info.circle") }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(camera.statusTone.color)
                Text(camera.statusBadge)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }.font(.uiBadge).lineLimit(1).padding(.horizontal, 6).frame(height: 18)
                .foregroundStyle(camera.statusTone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .background(.fill.tertiary, in: Capsule()).contentShape(Capsule())
        }.menuStyle(.borderlessButton).fixedSize().help("Feed settings for " + camera.name)
            .accessibilityLabel("Feed settings, " + camera.statusBadge)
            .sheet(isPresented: $showingSettings) {
                if let controlStore { UICameraControlSettings(feedID: camera.id, name: camera.name, store: controlStore, viewFactories: viewFactories) }
            }
    }
}

struct UIFeedBrandMark: View {
    let descriptor: VendorDescriptor
    var body: some View {
        Group {
            switch UIControlPresentation.badge(descriptor, assetAvailable: { NSImage(named: NSImage.Name($0)) != nil }) {
            case .asset(let name):
                Image(name).resizable().renderingMode(.template).scaledToFit().frame(width: 18, height: 18)
            case .text(let text):
                Text(text).font(.system(size: 8, weight: .bold)).lineLimit(1)
            }
        }.foregroundStyle(.secondary).accessibilityLabel(descriptor.localizedDisplayName())
    }
}
