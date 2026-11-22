import CoreMedia
import SwiftUI

/// A change that asks first (one that can drop a live signal or lose something), waiting for
/// its answer. Cancel is the default.
struct UIDeviceSettingConfirmation {
    var title: String
    var message: String
    var actionTitle: String
    var action: @MainActor () -> Void
    /// Destructive for an action that loses something, as Forget Saved Sign-In does.
    var role: ButtonRole? = nil
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
        let running = device.cameras.filter { !model.canChangeCameraInput(FeedID(rawValue: $0.id)) }
        let pluginID = try? VendorRegistry.pluginID(for: device.id)
        Group {
            ForEach(state.settings) { setting in
                if let formats = setting.captureFormats {
                    UICaptureModeSettings(setting: setting, formats: formats,
                        busy: state.busy, stopReason: Self.stopReason(setting, running: running)) {
                        request(setting, $0, running: running)
                    }
                    .id(setting.value)
                } else {
                    LabeledContent {
                        HStack(spacing: 8) {
                            if let reason = Self.stopReason(setting, running: running) {
                                Text(UIControlPresentation.value(UIVendorSettingsPresentation.property(setting))).fontWeight(.semibold)
                                Text(reason).font(.uiMeta).foregroundStyle(.secondary)
                            } else {
                                UIControlPropertyField(property: UIVendorSettingsPresentation.property(setting), connected: true, busy: state.busy) { value in
                                    guard let value = Self.vendorValue(value) else { return }
                                    request(setting, value, running: running)
                                }
                                .fixedSize()
                                if setting.interruption != nil {
                                    Text("Applies on the next capture start").font(.uiMeta).foregroundStyle(.secondary)
                                } else if setting.interruptsCapture {
                                    Text("Briefly interrupts \(device.status?.connector.map(UIHardwareText.connector) ?? "the signal")")
                                        .font(.uiMeta).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } label: { Text(setting.localizedLabel()) }
                }
                if let error = setting.applicationError {
                    LabeledContent {
                        if Self.offersRetry(setting, running: running) {
                            Button("Retry") { retry(setting, running: running) }.disabled(state.busy || !setting.mutable)
                        }
                    } label: {
                        Label { Text(error.localizedDescription) } icon: { Image(systemName: UISymbol.warning).foregroundStyle(.orange) }
                    }
                }
            }
            if state.busy && state.settings.isEmpty { ProgressView().controlSize(.small) }
            if let message = state.message {
                Label { Text(message) } icon: { Image(systemName: UISymbol.warning).foregroundStyle(.orange) }
            }
        }
        .task(id: running.map(\.id)) {
            if let pluginID, !state.settings.isEmpty {
                await model.vendorSettings.refresh(deviceID: device.id, pluginID: pluginID)
            }
        }
    }

    /// A choice that can drop the signal can't change during capture (the driver refuses it).
    static func readOnlyWhileRunning(_ setting: VendorSetting) -> Bool {
        if setting.captureFormats != nil || setting.interruption != nil { return true }
        guard setting.interruptsCapture, case .choices = setting.allowedValues else { return false }
        return true
    }

    static func stopReason(_ setting: VendorSetting, running: [UIHardwareDevice.Camera]) -> String? {
        guard readOnlyWhileRunning(setting), !running.isEmpty else { return nil }
        let subject = setting.interruption == .audio ? " to change the audio input" : " to change"
        return "Stop \(names(running))" + subject
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
        guard Self.stopReason(setting, running: running) == nil else { return }
        if case .boolean(let on) = value, setting.interruptsCapture, !running.isEmpty {
            confirm(UIDeviceSettingConfirmation(
                title: "\(on ? "Turn on" : "Turn off") \(setting.localizedLabel()) for \(device.name)?",
                message: "\(cameraState(running)) Changing this setting may briefly interrupt the input signal.",
                actionTitle: on ? "Turn On" : "Turn Off", action: { apply(value, to: setting) }))
        } else { apply(value, to: setting) }
    }

    private func apply(_ value: VendorSettingValue, to setting: VendorSetting) {
        guard let pluginID = try? VendorRegistry.pluginID(for: device.id) else { return }
        Task {
            if Self.readOnlyWhileRunning(setting),
                device.cameras.contains(where: { !model.canChangeCameraInput(FeedID(rawValue: $0.id)) }) { return }
            await model.vendorSettings.apply(value, to: setting.id, deviceID: device.id, pluginID: pluginID)
        }
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

/// The Hardware row owns this draft for as long as it is visible. It never writes device state.
struct UICaptureModeDraft {
    private(set) var staged: VendorSettingValue?
    private(set) var editingCustom = false
    var customFPS = ""
    var hasChanges: Bool { staged != nil || editingCustom }

    func selection(committed: VendorSettingValue) -> VendorSettingValue { staged ?? committed }

    mutating func selectFormat(_ id: String, formats: [VendorCaptureFormat], committed: VendorSettingValue) {
        if id.isEmpty {
            stage(VendorCaptureMode.automatic, committed: committed)
        } else if let target = formats.first(where: { $0.id == id }), let first = target.rates.first {
            let current = VendorCaptureMode(selection: selection(committed: committed))
            let duration = current.flatMap { target.supports($0.duration) ? $0.duration : nil } ?? first.duration
            stage(VendorCaptureMode.value(formatID: id, duration: duration), committed: committed)
        }
    }

    mutating func stage(_ value: VendorSettingValue, committed: VendorSettingValue) {
        editingCustom = false
        staged = value == committed ? nil : value
    }

    mutating func selectCustomRate(_ initialValue: String) {
        editingCustom = true
        customFPS = initialValue
    }

    func pendingValue(formats: [VendorCaptureFormat], committed: VendorSettingValue) -> VendorSettingValue? {
        let selection = selection(committed: committed)
        if selection == VendorCaptureMode.automatic { return selection }
        guard let mode = VendorCaptureMode(selection: selection),
            let format = formats.first(where: { $0.id == mode.formatID }) else { return nil }
        let duration = editingCustom ? VendorCaptureMode.customDuration(customFPS) : mode.duration
        guard let duration, format.supports(duration) else { return nil }
        return VendorCaptureMode.value(formatID: format.id, duration: duration)
    }

    mutating func discard() { self = Self() }
}

struct UICaptureModeSettings: View {
    let setting: VendorSetting
    let formats: [VendorCaptureFormat]
    let busy: Bool
    let stopReason: String?
    let commit: (VendorSettingValue) -> Void
    @State private var draft: UICaptureModeDraft

    init(setting: VendorSetting, formats: [VendorCaptureFormat], busy: Bool, stopReason: String?,
      draft: UICaptureModeDraft = .init(), commit: @escaping (VendorSettingValue) -> Void) {
        self.setting = setting
        self.formats = formats
        self.busy = busy
        self.stopReason = stopReason
        self.commit = commit
        _draft = State(initialValue: draft)
    }

    private var mode: VendorCaptureMode? { VendorCaptureMode(selection: draft.selection(committed: setting.value)) }
    private var format: VendorCaptureFormat? { formats.first { $0.id == mode?.formatID } }
    private var disabled: Bool { busy || !setting.mutable || stopReason != nil }
    private var pendingValue: VendorSettingValue? { draft.pendingValue(formats: formats, committed: setting.value) }

    var body: some View {
        Picker("Capture Format", selection: Binding(get: { mode?.formatID ?? "" }, set: { selectFormat($0) })) {
            Text("Automatic").tag("")
            ForEach(formats) { Text($0.label).tag($0.id).selectionDisabled($0.rates.isEmpty) }
            if let mode, format == nil { Text("Saved format unavailable").tag(mode.formatID) }
        }
        .disabled(disabled)
        .onDisappear { draft.discard() }
        if let mode, let format {
            ratePicker(mode, format: format)
        } else {
            LabeledContent("Frame Rate", value: mode == nil ? "Automatic" : "Unavailable")
        }
        if let note = stopReason ?? setting.localizedAvailabilityReason() {
            Text(note).font(.uiMeta).foregroundStyle(.secondary)
        } else if draft.hasChanges {
            HStack {
                Button("Apply Capture Mode", action: applyDraft).disabled(disabled || pendingValue == nil)
                Button("Cancel") { draft.discard() }.disabled(busy)
            }
        } else {
            Text("Applies on the next capture start").font(.uiMeta).foregroundStyle(.secondary)
        }
    }

    private func selectFormat(_ id: String) {
        guard !disabled else { return }
        draft.selectFormat(id, formats: formats, committed: setting.value)
    }

    private func ratePicker(_ mode: VendorCaptureMode, format: VendorCaptureFormat) -> some View {
        let selected = VendorCaptureMode.value(formatID: format.id, duration: mode.duration)
        let options = format.rates.map { (value: VendorCaptureMode.value(formatID: format.id, duration: $0.duration), label: $0.label) }
        let custom = VendorSettingValue.choice("")
        return Group {
            Picker("Frame Rate", selection: Binding(get: { draft.editingCustom ? custom : selected }, set: { value in
                if value == custom {
                    let initial = options.contains(where: { $0.value == selected }) ? "" : "\(mode.duration.timescale)/\(mode.duration.value)"
                    draft.selectCustomRate(initial)
                } else {
                    draft.stage(value, committed: setting.value)
                }
            })) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
                if !options.contains(where: { $0.value == selected }) {
                    let suffix = format.supports(mode.duration) ? "" : " (unavailable)"
                    Text("\(mode.duration.timescale)/\(mode.duration.value) fps\(suffix)").tag(selected)
                }
                if format.allowsCustomRate { Text("Custom FPS…").tag(custom) }
            }
            .disabled(disabled)
            if draft.editingCustom && format.allowsCustomRate {
                TextField("Custom FPS", text: $draft.customFPS, prompt: Text("29.97 or 30000/1001"))
                    .onSubmit(applyDraft)
                    .disabled(disabled)
                if !draft.customFPS.isEmpty && pendingValue == nil {
                    Text("Enter a decimal or fraction in this format’s supported frame-rate ranges.")
                        .font(.uiMeta).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func applyDraft() {
        guard !disabled, let pendingValue else { return }
        if pendingValue == setting.value { draft.discard() }
        else { commit(pendingValue) }
    }
}
