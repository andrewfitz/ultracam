import SwiftUI

/// The camera's signal badge: its state, the dropouts since Start when there are any, and a
/// menu naming both links (capture device and camera body) with the body's output properties.
struct UIFeedSettingsMenu: View {
    let camera: UICameraPresentation
    let snapshot: UICameraSnapshot?
    let controlStore: CameraControlStore?
    var viewFactories: [String: ControlViewFactory] = [:]
    /// Settings › Hardware, at a device's or body's row.
    var openHardware: (String?) -> Void = { _ in }
    @State private var showingSettings = false
    private var state: CameraControlFeedState? {
        guard let controlStore, controlStore.assignment(for: camera.id) != nil else { return nil }
        return controlStore.state(for: camera.id)
    }
    private var live: Bool { camera.statusTone == .positive }
    var body: some View {
        Menu {
            Button { openHardware(snapshot?.inputID) } label: {
                Label(camera.inputName, systemImage: UISymbol.input)
            }
            .badge(snapshot?.inputConnector.map { Text($0) })
            if let format = snapshot?.outputFormat {
                Label("Ultracam · \(camera.name)", systemImage: UISymbol.virtualCamera(inUse: camera.outputInUse)).badge(Text(format))
            }
            Divider()
            if let controlStore, let state, let assignment = controlStore.assignment(for: camera.id) {
                Label(assignment.camera.name, systemImage: UISymbol.cameraBody)
                    .badge(Text(state.connected ? "Connected" : "Disconnected"))
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
                        } else {
                            Text(property.localizedLabel()).badge(Text(UIControlPresentation.value(property)))
                        }
                    }
                }
                Divider()
            } else {
                Label("Output timing is controlled by the source", systemImage: UISymbol.information)
            }
            if let controlStore, controlStore.available {
                if controlStore.assignment(for: camera.id) != nil {
                    Button("Camera Control…", systemImage: UISymbol.cameraControl) { showingSettings = true }
                } else {
                    Button("Assign Camera Body…", systemImage: UISymbol.cameraBody) { openHardware(nil) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if live {
                    UIStateGlyph(state: .healthy, size: 6)
                } else if camera.statusTone == .warning {
                    UIStateGlyph(state: .warning)
                } else {
                    UIStateGlyph(state: .inactive, size: 6)
                }
                Text(camera.statusBadge)
                UICountChip(count: camera.signalDropouts, one: "drop", many: "drops",
                    help: "The signal dropped \(camera.signalDropouts == 1 ? "once" : "\(camera.signalDropouts) times") since Start")
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.uiBadge).lineLimit(1).padding(.horizontal, 6).frame(height: 18)
            .foregroundStyle(camera.statusTone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .background(.fill.tertiary, in: Capsule()).contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(help)
        .accessibilityLabel("\(camera.name) signal, \(camera.statusBadge)")
        .accessibilityValue(camera.signalDropouts > 0 ? "\(camera.signalDropouts) signal dropouts since Start" : "")
        .sheet(isPresented: $showingSettings) {
            if let controlStore {
                UICameraControlSettings(feedID: camera.id, name: camera.name, store: controlStore, viewFactories: viewFactories,
                    openHardware: { openHardware(nil) })
            }
        }
    }

    private var help: String {
        var help = live ? "Signal arriving from \(camera.inputName)" : camera.statusBadge
        if camera.signalDropouts > 0 {
            help += ". \(camera.signalDropouts) signal dropout\(camera.signalDropouts == 1 ? "" : "s") since Start"
        }
        return help
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
