import AppKit
import AVFoundation
import CoreMediaIO
import MonitorKitCore

/// Recording destinations: free space, time left and recent takes.
enum UIRecordingLibrary {
  /// Nominal ProRes 422 UHD rates when no take is running to measure.
  static func nominalMegabits(codec: RecordingCodec, fast: Bool) -> Double {
    switch codec {
    case .proRes42210Bit: return fast ? 707 : 354
    case .hevcMain10_422: return fast ? 160 : 100
    }
  }

  static func volumeName(for url: URL) -> String {
    (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.pathComponents.dropFirst().first ?? "Disk"
  }

  /// One entry per destination volume. Time left divides free space by the
  /// combined bitrate of the takes recording to that volume, or one nominal
  /// take when nothing is recording there.
  @MainActor private static var takeCache: (key: [String], date: Date, takes: [UITake])?

  /// `recentTakes(in:)` cached for a few seconds; folder scans are not free.
  @MainActor static func cachedRecentTakes(in folders: [URL]) -> [UITake] {
    let key = folders.map(\.path)
    if let cache = takeCache, cache.key == key, Date().timeIntervalSince(cache.date) < 3 { return cache.takes }
    let takes = recentTakes(in: folders)
    takeCache = (key, Date(), takes)
    return takes
  }

  static func drives(for folders: [URL?], recordingRates: [(URL, Double)], fallbackMegabits: Double = 707) -> [UIDrive] {
    var seen: [String: UIDrive] = [:]
    var order: [String] = []
    for case let folder? in folders {
      let name = volumeName(for: folder)
      guard seen[name] == nil else { continue }
      let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey, .volumeTotalCapacityKey])
      // Some volumes (network, non-APFS) don't report the "important usage" figure; a missing
      // value must not read as a full drive.
      let reported = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
      let available = reported ?? 0
      // An unreadable free figure leaves the size unknown too, so the drive isn't shown as full.
      let total = reported == nil ? 0 : Int64(values?.volumeTotalCapacity ?? 0)
      let rate = recordingRates.filter { volumeName(for: $0.0) == name }.map(\.1).reduce(0, +)
      let megabits = rate > 0 ? rate : fallbackMegabits
      let seconds = available > 0 ? Double(available) * 8 / (megabits * 1_000_000) : nil
      seen[name] = UIDrive(name: name, availableBytes: available, totalBytes: total, secondsLeft: seconds)
      order.append(name)
    }
    return order.compactMap { seen[$0] }
  }

  /// Finished movies in the recording folders (and one level of camera
  /// subfolders), newest first. Hidden partial files are skipped.
  static func recentTakes(in folders: [URL], limit: Int = 5) -> [UITake] {
    var takes: [UITake] = []
    var visited = Set<String>()
    let manager = FileManager.default
    for folder in folders where visited.insert(folder.path).inserted {
      var candidates: [URL] = []
      let entries = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles])) ?? []
      for entry in entries {
        if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
          candidates += (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        } else {
          candidates.append(entry)
        }
      }
      for url in candidates where url.pathExtension.lowercased() == "mov" {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        takes.append(UITake(url: url, name: url.lastPathComponent, date: date, duration: UITakeDurations.duration(for: url)))
      }
    }
    return Array(takes.sorted { $0.date > $1.date }.prefix(limit))
  }
}

/// Bridges the interface to the monitor tools, which are per camera.
@MainActor
enum UIMonitorBridge {
  /// Presenters of the pictures currently on screen, so menu commands can act on the selected camera.
  private static var presenters: [String: MonitorSurfacePresenter] = [:]

  static func register(_ presenter: MonitorSurfacePresenter, cameraID: String) { presenters[cameraID] = presenter }
  static func unregister(cameraID: String, presenter: MonitorSurfacePresenter) {
    if presenters[cameraID] === presenter { presenters[cameraID] = nil }
  }
  static func presenter(for cameraID: String) -> MonitorSurfacePresenter? { presenters[cameraID] }

  /// The tools shown as on: none while the master switch is off.
  static func activeTools(_ preferences: MonitorFeedPreferences) -> Set<UIMonitorTool> {
    guard preferences.toolsEnabled else { return [] }
    let state = preferences.state
    var tools: Set<UIMonitorTool> = []
    if state.guides.enabled { tools.insert(.guides) }
    if state.zebras.contains(where: \.enabled) { tools.insert(.zebra) }
    if state.falseColor.mode != .off { tools.insert(.falseColor) }
    if state.focus.enabled { tools.insert(.focus) }
    if preferences.scopes.enabled { tools.insert(.scopes) }
    return tools
  }

  /// Source profile for a camera's declared LUT input, used when false color is
  /// turned on before a source profile was chosen.
  static func sourceProfile(forGamut gamut: String) -> String {
    gamut.contains("Cine") ? "sony-slog3-sgamut3cine" : "sony-slog3-sgamut3"
  }

  /// Turns one tool on or off. The master switch follows the tools: it is on
  /// while any tool is on, and turning tools back on never resurrects tools that
  /// were left enabled underneath it.
  static func toggled(_ tool: UIMonitorTool, in preferences: MonitorFeedPreferences,
    defaultSourceProfile: String? = nil, isProgram: Bool = false) -> MonitorFeedPreferences {
    var next = preferences
    let active = activeTools(preferences).contains(tool)
    if !preferences.toolsEnabled { next.hideAllTools() }
    switch tool {
    case .guides: next.state.guides.enabled = !active
    case .zebra:
      // As the detached tool bar: off clears every zebra set, on shows the first.
      for index in next.state.zebras.indices { next.state.zebras[index].enabled = !active && index == 0 }
    case .falseColor:
      if active {
        next.state.falseColor.mode = .off
      } else {
        if !isProgram, next.signal.logProfileID == nil, let defaultSourceProfile {
          next.signal.logProfileID = defaultSourceProfile
        }
        // Sony's Pattern 2 on S-Log3, ARRI's table on LogC, else (and always
        // on Program) the six display-IRE bands, which need no log source.
        next.state.falseColor.mode = UIFalseColorChoices.suggestedMode(profile: next.signal.logProfileID,
          isProgram: isProgram)
      }
    case .focus: next.state.focus.enabled = !active
    case .scopes: next.scopes.enabled = !active
    }
    next.toolsEnabled = next.anyToolOn
    return next
  }

  /// Whether clip indicators show (they are not one of the interface's tools).
  static func clipIndicatorsOn(_ preferences: MonitorFeedPreferences) -> Bool {
    preferences.toolsEnabled && preferences.state.clipIndicators.enabled
  }

  /// Clip indicators on or off, with the master-switch rules of `toggled`.
  static func toggledClipIndicators(in preferences: MonitorFeedPreferences) -> MonitorFeedPreferences {
    var next = preferences
    let active = clipIndicatorsOn(preferences)
    if !preferences.toolsEnabled { next.hideAllTools() }
    next.state.clipIndicators.enabled = !active
    next.toolsEnabled = next.anyToolOn
    return next
  }

  static func toggle(_ tool: UIMonitorTool, for cameraID: String, coordinator: MonitorCoordinator,
    defaultSourceProfile: String? = nil) {
    let target = MonitorTargetID(cameraID)
    coordinator.setPreferences(toggled(tool, in: coordinator.preferences(for: target),
      defaultSourceProfile: defaultSourceProfile, isProgram: target.isProgram), for: target)
  }

  static func perform(_ action: UIAction, coordinator: MonitorCoordinator) {
    switch action {
    case .freeze(let id):
      guard let presenter = presenters[id] else { return }
      if presenter.isFreezePending { presenter.cancelPendingFreeze() } else { presenter.toggleFreeze() }
    case .toggleClean(let id):
      presenters[id]?.toggleClean()
    case .detachMonitor(let id):
      MonitorDetachedWindows.open(coordinator: coordinator, target: MonitorTargetID(id))
    default:
      break
    }
  }
}

@MainActor
enum UIPanels {
  static func chooseFolder(model: AppModel, cameraID: FeedID?) {
    let recording = model.recordingModel
    let panel = NSOpenPanel()
    let name = cameraID.flatMap { id in model.feedDescriptors.first { $0.id == id }?.name }
    panel.title = name.map { "Choose recording folder for \($0)" } ?? "Choose default recording folder"
    panel.directoryURL = cameraID.flatMap { recording.outputFolder(for: $0) } ?? recording.outputFolder
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if let cameraID { recording.setOutputFolder(url, for: cameraID) } else { recording.outputFolder = url }
  }
}

/// Detects whether the Ultracam camera extension is installed and active by
/// looking for one of its devices in Core Media I/O. Cached briefly so the
/// interface can ask on every refresh.
@MainActor
enum UIExtensionDetector {
  private static var cached: (date: Date, installed: Bool)?

  static func isInstalled() -> Bool {
    if let cached, Date().timeIntervalSince(cached.date) < 5 { return cached.installed }
    let installed = scan()
    cached = (Date(), installed)
    return installed
  }

  private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: UInt32(selector), mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
      mElement: UInt32(kCMIOObjectPropertyElementMain))
  }

  private static func scan() -> Bool {
    var property = address(kCMIOHardwarePropertyDevices)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &property, 0, nil, &size) == noErr,
      size % 4 == 0, size <= 64 * 1024 else { return false }
    var devices = [CMIOObjectID](repeating: 0, count: Int(size) / 4)
    guard !devices.isEmpty, devices.withUnsafeMutableBytes({
      CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &property, 0, nil, size, &size, $0.baseAddress!)
    }) == noErr else { return false }
    return devices.contains { device in
      var nameProperty = address(kCMIOObjectPropertyName)
      var value: Unmanaged<CFString>?
      var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      guard CMIOObjectGetPropertyData(device, &nameProperty, 0, nil, valueSize, &valueSize, &value) == noErr else { return false }
      let name = value?.takeRetainedValue() as String? ?? ""
      return name.hasPrefix(VideoContract.cameraName)
    }
  }
}

/// Durations of finished takes, read from the movie files in the background and
/// cached. The first lookup returns nil; the next refresh shows the duration.
enum UITakeDurations {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var known: [URL: TimeInterval] = [:]
  nonisolated(unsafe) private static var loading: Set<URL> = []

  static func duration(for url: URL) -> TimeInterval? {
    lock.lock()
    if let value = known[url] { lock.unlock(); return value }
    let start = loading.insert(url).inserted
    lock.unlock()
    if start {
      Task.detached(priority: .utility) {
        let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
        lock.withLock {
          if let seconds, seconds.isFinite, seconds > 0 { known[url] = seconds }
          loading.remove(url)
        }
      }
    }
    return nil
  }
}
