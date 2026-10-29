import Foundation
import Observation

typealias VendorSettingsSnapshot = VendorSettingsPolicy
@MainActor protocol VendorSettingsPersisting {
    func load() throws -> VendorSettingsSnapshot
    func save(_ snapshot: VendorSettingsSnapshot) throws
}

/// The only vendor-specific migration: keep the legacy fallback for future
/// arrivals, and never replace an already recorded per-device override.
@MainActor final class VendorSettingsPreferences: VendorSettingsPersisting {
    static let key = VendorSettingsKeys.preferences
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() throws -> VendorSettingsSnapshot {
        var snapshot: VendorSettingsSnapshot
        if let data = defaults.data(forKey: Self.key) {
            snapshot = try JSONDecoder().decode(VendorSettingsSnapshot.self, from: data)
            guard snapshot.version == 1 else { throw PluginError.unsupported("Unsupported vendor settings version") }
        } else { snapshot = .init() }
        let setting = "decklink:advertiseHDRToCameras"
        if snapshot.inheritedByPlugin["decklink"]?[setting] == nil {
            snapshot.inheritedByPlugin["decklink", default: [:]][setting] = .boolean(defaults.bool(forKey: "ultracam.advertiseHDRToCameras"))
            try save(snapshot)
        }
        return snapshot
    }
    func save(_ snapshot: VendorSettingsSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        defaults.set(data, forKey: Self.key)
        guard let written = defaults.data(forKey: Self.key),
            try JSONDecoder().decode(VendorSettingsSnapshot.self, from: written) == snapshot else {
            throw PluginError.failed("Vendor settings could not be verified in preferences")
        }
    }
}

@MainActor @Observable final class VendorSettingsDeviceState {
    var settings: [VendorSetting] = []
    var busy = false
    var message: String?
}

/// SDK calls run asynchronously; only an acknowledged value from a fresh
/// settings snapshot becomes a persisted per-device preference.
@MainActor @Observable final class VendorSettingsStore {
    private(set) var policy = VendorSettingsPolicy()
    private(set) var persistenceMessage: String?
    private var states: [String: VendorSettingsDeviceState] = [:]
    @ObservationIgnored private let plugins: [String: any VendorSettingsProviding]
    @ObservationIgnored private let persistence: any VendorSettingsPersisting
    private var writable = true
    private var closed = false
    private var generation: UInt64 = 0
    init(plugins: [String: any VendorSettingsProviding], persistence: any VendorSettingsPersisting = VendorSettingsPreferences()) {
        self.plugins = plugins; self.persistence = persistence
        do { policy = try persistence.load() }
        catch { writable = false; persistenceMessage = error.localizedDescription }
    }
    func state(for deviceID: String) -> VendorSettingsDeviceState {
        if let state = states[deviceID] { return state }
        let state = VendorSettingsDeviceState(); states[deviceID] = state; return state
    }
    func restore(deviceID: String, pluginID: String) async {
        let state = state(for: deviceID)
        guard !closed, !state.busy, let plugin = plugins[pluginID] else { return }
        let generation = self.generation
        state.busy = true; state.message = nil
        defer { if valid(generation) { state.busy = false } }
        do {
            let settings = try await plugin.settings(deviceID: deviceID)
            guard valid(generation), !Task.isCancelled else { return }
            state.settings = settings
            let inherited = policy.inheritedByPlugin[pluginID] ?? [:]
            let desired = policy.desiredByDevice[deviceID] ?? [:]
            var verified: [String: VendorSettingValue] = [:]
            for setting in settings {
                guard let value = desired[setting.id] ?? inherited[setting.id] else { continue }
                try value.validate()
                if value != setting.value || setting.applicationError != nil {
                    try validate(value, setting: setting)
                    try await plugin.apply(value, to: setting.id, deviceID: deviceID)
                    guard valid(generation), !Task.isCancelled else { return }
                }
                guard valid(generation), !Task.isCancelled else { return }
                let fresh = try await plugin.settings(deviceID: deviceID)
                guard valid(generation), !Task.isCancelled else { return }
                state.settings = fresh
                if let error = fresh.first(where: { $0.id == setting.id })?.applicationError { throw error }
                guard fresh.first(where: { $0.id == setting.id })?.value == value else {
                    throw PluginError.failed("The device did not confirm the requested setting")
                }
                verified[setting.id] = value
            }
            if !verified.isEmpty {
                var next = policy
                for (id, value) in verified { next.desiredByDevice[deviceID, default: [:]][id] = value }
                try persist(next)
            }
        } catch { if valid(generation), !Task.isCancelled { state.message = error.localizedDescription } }
    }
    func apply(_ value: VendorSettingValue, to settingID: String, deviceID: String, pluginID: String) async {
        let state = state(for: deviceID)
        guard !closed, !state.busy, let plugin = plugins[pluginID] else { return }
        let generation = self.generation
        state.busy = true; state.message = nil
        defer { if valid(generation) { state.busy = false } }
        do {
            guard let setting = state.settings.first(where: { $0.id == settingID }) else {
                throw PluginError.unsupported("This device does not expose that setting")
            }
            try validate(value, setting: setting)
            if value != setting.value || setting.applicationError != nil {
                try await plugin.apply(value, to: settingID, deviceID: deviceID)
                guard valid(generation), !Task.isCancelled else { return }
            }
            guard valid(generation), !Task.isCancelled else { return }
            let fresh = try await plugin.settings(deviceID: deviceID)
            guard valid(generation), !Task.isCancelled else { return }
            state.settings = fresh
            if let error = fresh.first(where: { $0.id == settingID })?.applicationError { throw error }
            guard fresh.first(where: { $0.id == settingID })?.value == value else {
                throw PluginError.failed("The device did not confirm the requested setting")
            }
            var next = policy
            next.desiredByDevice[deviceID, default: [:]][settingID] = value
            try persist(next)
        } catch { if valid(generation), !Task.isCancelled { state.message = error.localizedDescription } }
    }
    func reset() {
        closed = true; generation &+= 1; policy = .init()
        for state in states.values { state.settings = []; state.busy = false; state.message = nil }
    }
    private func valid(_ generation: UInt64) -> Bool { !closed && generation == self.generation }
    private func persist(_ next: VendorSettingsPolicy) throws {
        guard !closed else { throw PluginError.invalidState("Vendor settings store is closed") }
        guard writable else { throw PluginError.failed(persistenceMessage ?? "Vendor settings preferences are unavailable") }
        guard next != policy else { return }
        try persistence.save(next)
        policy = next; persistenceMessage = nil
    }
    private func validate(_ value: VendorSettingValue, setting: VendorSetting) throws {
        try value.validate()
        guard setting.mutable else { throw PluginError.unsupported(setting.availabilityReason ?? "Setting is read-only") }
        let allowed: Bool
        switch (setting.allowedValues, value) {
        case (.unrestricted, _):
            switch (setting.value, value) {
            case (.boolean, .boolean), (.signed, .signed), (.unsigned, .unsigned), (.decimal, .decimal), (.text, .text), (.choice, .choice): allowed = true
            default: allowed = false
            }
        case (.choices(let choices), .choice(let id)): allowed = choices.contains { $0.id == id }
        case (.signed(let range), .signed(let number)): allowed = range.contains(number)
        case (.unsigned(let range), .unsigned(let number)): allowed = range.contains(number)
        case (.decimal(let range), .decimal(let number)): allowed = range.contains(number)
        default: allowed = false
        }
        guard allowed else { throw PluginError.unsupported("Setting value is outside the supported values") }
    }
}
