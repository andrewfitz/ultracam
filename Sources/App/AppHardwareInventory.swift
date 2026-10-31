import Foundation
import Observation

/// What Ultracam knows about its hardware between driver lists: each capture device's cached
/// status, the nickname it was given on this Mac and the last name it was seen with, so a unit
/// that's unplugged at launch keeps its name, not "Input device".
///
/// Status is kept apart from the device list on purpose: a list change re-runs every device's
/// vendor settings, a status change must not. Idle status is read only while someone is
/// looking (`beginWatching`), every `interval`, on each plugin's own queue.
@MainActor @Observable final class HardwareInventory {
  static let nicknamesKey = "ui.hardware.nicknames.v1"
  static let lastKnownNamesKey = "ui.hardware.lastKnownNames.v1"
  static let pollInterval: Duration = .seconds(2)

  private(set) var statuses: [String: CaptureDeviceStatus] = [:]
  /// Names given on this Mac, by device ID. Never written to the hardware: other apps
  /// share the device's own label, and this is a local preference.
  private(set) var nicknames: [String: String]
  /// The driver's name for every device seen, by device ID.
  private(set) var lastKnownNames: [String: String]
  /// True while the idle reader runs.
  private(set) var polling = false
  @ObservationIgnored private var watchers = 0
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var observation: Any?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let interval: Duration
  @ObservationIgnored private let status: (String) -> CaptureDeviceStatus?
  @ObservationIgnored private let refresh: () -> Void

  init(defaults: UserDefaults, hardware: AppHardware, interval: Duration = HardwareInventory.pollInterval) {
    self.defaults = defaults
    self.interval = interval
    status = hardware.deviceStatus
    refresh = hardware.refreshIdleStatus
    nicknames = defaults.dictionary(forKey: Self.nicknamesKey) as? [String: String] ?? [:]
    lastKnownNames = defaults.dictionary(forKey: Self.lastKnownNamesKey) as? [String: String] ?? [:]
    observation = hardware.observeDeviceStatus { [weak self] id, status in self?.statuses[id] = status }
  }

  /// The cached status, from the observer or, before its first delivery, the plugin's cache.
  func status(for deviceID: String) -> CaptureDeviceStatus? { statuses[deviceID] ?? status(deviceID) }

  func nickname(for deviceID: String) -> String? { nicknames[deviceID] }

  /// An empty name removes the nickname, and the driver's label comes back.
  func setNickname(_ name: String?, for deviceID: String) {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let next = trimmed.isEmpty ? nil : String(trimmed.prefix(64))
    guard nicknames[deviceID] != next else { return }
    nicknames[deviceID] = next
    defaults.set(nicknames, forKey: Self.nicknamesKey)
  }

  /// Saves names that changed; called whenever the driver lists devices.
  func recordNames(_ names: [String: String]) {
    let merged = lastKnownNames.merging(names) { _, new in new }
    guard merged != lastKnownNames else { return }
    lastKnownNames = merged
    defaults.set(merged, forKey: Self.lastKnownNamesKey)
  }

  /// A window that shows hardware appeared (the main window, Settings › Hardware). Each
  /// call is paired with `endWatching`; the reader runs while any is open.
  func beginWatching() {
    watchers += 1
    guard watchers == 1 else { return }
    polling = true
    pollTask = Task { @MainActor [weak self, interval] in
      while !Task.isCancelled {
        guard let self, self.polling else { return }
        self.refresh()
        do { try await Task.sleep(for: interval) } catch { return }
      }
    }
  }

  func endWatching() {
    guard watchers > 0 else { return }
    watchers -= 1
    guard watchers == 0 else { return }
    polling = false
    pollTask?.cancel()
    pollTask = nil
  }

  /// Settings › Advanced › Reset: forget names given and seen.
  func reset() {
    nicknames = [:]; lastKnownNames = [:]
    defaults.removeObject(forKey: Self.nicknamesKey)
    defaults.removeObject(forKey: Self.lastKnownNamesKey)
  }
}
