import SwiftUI

struct UISettingsDeviceSettings: View {
    let model: AppModel
    var body: some View {
        Section {
            if model.devices.isEmpty { Text("Connect an input device to see its settings.").foregroundStyle(.secondary) }
            ForEach(model.devices) { device in
                let state = model.vendorSettings.state(for: device.id)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.devices.label(for: device.id) ?? device.name).font(.headline)
                    if state.busy { ProgressView().controlSize(.small) }
                    ForEach(state.settings) { setting in
                        HStack {
                            Text(setting.localizedLabel())
                            Spacer()
                            UIControlPropertyField(property: UIVendorSettingsPresentation.property(setting), connected: true, busy: state.busy) { value in
                                guard let pluginID = try? VendorRegistry.pluginID(for: device.id), let value = vendorValue(value) else { return }
                                Task { await model.vendorSettings.apply(value, to: setting.id, deviceID: device.id, pluginID: pluginID) }
                            }
                        }
                        if let error = setting.applicationError {
                            HStack {
                                Label(error.localizedDescription, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                                Spacer()
                                Button("Retry") {
                                    guard let pluginID = try? VendorRegistry.pluginID(for: device.id) else { return }
                                    Task { await model.vendorSettings.apply(setting.value, to: setting.id, deviceID: device.id, pluginID: pluginID) }
                                }.disabled(state.busy || !setting.mutable)
                            }
                        }
                        if setting.interruptsCapture { Text("Changing this setting may briefly interrupt the input signal.").font(.caption).foregroundStyle(.secondary) }
                    }
                    if !state.busy, state.settings.isEmpty, state.message == nil { Text("This device has no adjustable settings.").font(.caption).foregroundStyle(.secondary) }
                    if let message = state.message { Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                }.padding(.vertical, 4)
            }
            if let message = model.vendorSettings.persistenceMessage { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } header: { Text("Input device settings") }
    }
    private func vendorValue(_ value: ControlValue) -> VendorSettingValue? {
        switch value {
        case .boolean(let value): return .boolean(value)
        case .integer(let value): return .signed(value)
        case .unsignedInteger(let value): return .unsigned(value)
        case .decimal(let value): return value.isFinite ? .decimal(value) : nil
        case .text(let value): return .text(value)
        case .choice(let value): return .choice(value)
        }
    }
}
