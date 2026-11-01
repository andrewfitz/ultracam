import SwiftUI

/// A live change that can drop the signal, waiting for its answer. Cancel is the default.
struct UIDeviceSettingConfirmation {
    var title: String
    var message: String
    var actionTitle: String
    var action: @MainActor () -> Void
}

/// One capture device's own settings, as its vendor's plugin declares them (input connector,
/// HDR advertisement and the like), on its Settings › Hardware row.
///
/// A setting that can drop the signal is handled by kind while a camera uses the device (J 6):
/// a choice (the connector) is read-only with its reason, since the driver refuses it during
/// capture; a switch (Advertise HDR) works live, so it asks first, with Cancel as default.
struct UISettingsDeviceSettings: View {
    let model: AppModel
    let device: UIHardwareDevice
    /// Asks before a live change. One dialog for the pane, so each device's settings hand it up.
    var confirm: (UIDeviceSettingConfirmation) -> Void = { $0.action() }

    var body: some View {
        let state = model.vendorSettings.state(for: device.id)
        let running = device.runningCameras
        Group {
            ForEach(state.settings) { setting in
                LabeledContent {
                    HStack(spacing: 8) {
                        if Self.readOnlyWhileRunning(setting), !running.isEmpty {
                            Text(UIControlPresentation.value(UIVendorSettingsPresentation.property(setting))).fontWeight(.semibold)
                            Text("Stop \(Self.names(running)) to change").font(.uiMeta).foregroundStyle(.secondary)
                        } else {
                            UIControlPropertyField(property: UIVendorSettingsPresentation.property(setting), connected: true, busy: state.busy) { value in
                                guard let value = Self.vendorValue(value) else { return }
                                request(setting, value, running: running)
                            }
                            .fixedSize()
                            if setting.interruptsCapture {
                                Text("Briefly interrupts \(device.status?.connector.map(UIHardwareText.connector) ?? "the signal")")
                                    .font(.uiMeta).foregroundStyle(.secondary)
                            }
                        }
                    }
                } label: { Text(setting.localizedLabel()) }
                if let error = setting.applicationError {
                    LabeledContent {
                        if Self.offersRetry(setting, running: running) {
                            Button("Retry") { retry(setting, running: running) }.disabled(state.busy || !setting.mutable)
                        }
                    } label: {
                        Label(error.localizedDescription, systemImage: UISymbol.warning).foregroundStyle(.orange)
                    }
                }
            }
            if state.busy && state.settings.isEmpty { ProgressView().controlSize(.small) }
            if let message = state.message {
                Label(message, systemImage: UISymbol.warning).foregroundStyle(.orange)
            }
        }
    }

    /// A choice that can drop the signal can't change during capture (the driver refuses it).
    static func readOnlyWhileRunning(_ setting: VendorSetting) -> Bool {
        guard setting.interruptsCapture, case .choices = setting.allowedValues else { return false }
        return true
    }

    /// Retry is a change like any other: hidden where the setting is read-only, and asking
    /// first where it can drop a running camera's signal.
    static func offersRetry(_ setting: VendorSetting, running: [UIHardwareDevice.Camera]) -> Bool {
        !(readOnlyWhileRunning(setting) && !running.isEmpty)
    }

    /// The Retry button's action.
    func retry(_ setting: VendorSetting, running: [UIHardwareDevice.Camera]) {
        guard Self.offersRetry(setting, running: running) else { return }
        request(setting, setting.value, running: running)
    }

    static func names(_ cameras: [UIHardwareDevice.Camera]) -> String {
        ListFormatter.localizedString(byJoining: cameras.map(\.name))
    }


    private func cameraState(_ running: [UIHardwareDevice.Camera]) -> String {
        let recording = running.filter { camera in
            model.recordingModel.feeds.first { $0.id.rawValue == camera.id }.map { $0.status == .recording || $0.status == .paused } == true
        }
        if !recording.isEmpty { return "\(Self.names(recording)) \(recording.count == 1 ? "is" : "are") recording." }
        return "\(Self.names(running)) \(running.count == 1 ? "is" : "are") running."
    }

    private func request(_ setting: VendorSetting, _ value: VendorSettingValue, running: [UIHardwareDevice.Camera]) {
        if case .boolean(let on) = value, setting.interruptsCapture, !running.isEmpty {
            confirm(UIDeviceSettingConfirmation(
                title: "\(on ? "Turn on" : "Turn off") \(setting.localizedLabel()) for \(device.name)?",
                message: "\(cameraState(running)) Changing this setting may briefly interrupt the input signal.",
                actionTitle: on ? "Turn On" : "Turn Off", action: { apply(value, to: setting) }))
        } else { apply(value, to: setting) }
    }

    private func apply(_ value: VendorSettingValue, to setting: VendorSetting) {
        guard let pluginID = try? VendorRegistry.pluginID(for: device.id) else { return }
        Task { await model.vendorSettings.apply(value, to: setting.id, deviceID: device.id, pluginID: pluginID) }
    }

    static func vendorValue(_ value: ControlValue) -> VendorSettingValue? {
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
