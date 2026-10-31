import SwiftUI

/// One capture device's own settings, as its vendor's plugin declares them (input connector,
/// HDR advertisement and the like). Settings › Hardware shows them under the device.
struct UISettingsDeviceSettings: View {
    let model: AppModel
    let device: InputDevice
    var body: some View {
        let state = model.vendorSettings.state(for: device.id)
        if state.busy { ProgressView().controlSize(.small) }
        ForEach(state.settings) { setting in
            LabeledContent {
                UIControlPropertyField(property: UIVendorSettingsPresentation.property(setting), connected: true, busy: state.busy) { value in
                    guard let pluginID = try? VendorRegistry.pluginID(for: device.id), let value = vendorValue(value) else { return }
                    Task { await model.vendorSettings.apply(value, to: setting.id, deviceID: device.id, pluginID: pluginID) }
                }
            } label: {
                Text(setting.localizedLabel())
                if setting.interruptsCapture { Text("Changing this may briefly interrupt the input signal.") }
            }
            if let error = setting.applicationError {
                LabeledContent {
                    Button("Retry") {
                        guard let pluginID = try? VendorRegistry.pluginID(for: device.id) else { return }
                        Task { await model.vendorSettings.apply(setting.value, to: setting.id, deviceID: device.id, pluginID: pluginID) }
                    }.disabled(state.busy || !setting.mutable)
                } label: {
                    Label(error.localizedDescription, systemImage: UISymbol.warning).foregroundStyle(.orange)
                }
            }
        }
        if let message = state.message {
            Label(message, systemImage: UISymbol.warning).foregroundStyle(.orange)
        }
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
