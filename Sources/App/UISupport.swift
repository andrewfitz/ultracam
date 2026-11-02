import AppKit
import AVFoundation
import CoreMediaIO
import MonitorKitCore
import os
import Synchronization

/// Recording destinations: free space, time left and recent takes.
enum UIRecordingLibrary {
  /// Shares the recorder's nominal disk estimate until a take has a measured rate.
  static func nominalMegabits(codec: RecordingCodec, fast: Bool) -> Double {
    nominalMegabits(codec: codec, width: 3840, height: 2160,
      frameDuration: CMTime(value: 1001, timescale: fast ? 60000 : 30000)) ?? 0
  }

  static func nominalMegabits(codec: RecordingCodec, width: Int, height: Int,
    frameDuration: CMTime, bitDepth: Int = 10) -> Double? {
    RecordingSizeEstimator(codec: codec.sizeEstimatorCodec, width: width, height: height,
      frameDuration: frameDuration, bitDepth: bitDepth)?.megabitsPerSecond
  }

  /// What HEVC really writes here, about 11 times under the recorder's figure. Display only:
  /// `RecordingSizeEstimator` stays the cautious number that guards free space.
  static let displayHEVCBytesPerPixel = 0.014
  /// Embedded PCM stays 24-bit at 48 kHz, whatever the camera sends.
  static func pcmMegabits(channels: Int) -> Double { Double(max(0, channels)) * 48_000 * 24 / 1_000_000 }

  /// One camera's rate as an estimate, video plus PCM, until a take measures it.
  static func displayMegabits(codec: RecordingCodec, width: Int = 3840, height: Int = 2160,
    frameDuration: CMTime = CMTime(value: 1001, timescale: 60000), audioChannels: Int = 2) -> Double {
    let pcm = pcmMegabits(channels: audioChannels)
    switch codec.sizeEstimatorCodec {
    case .hevcMain, .hevcMain10, .hevcMain10_422:
      guard frameDuration.isNumeric, frameDuration.seconds > 0 else { return pcm }
      return Double(width) * Double(height) / frameDuration.seconds * displayHEVCBytesPerPixel * 8 / 1_000_000 + pcm
    case .proResLT, .proRes422, .proRes422HQ, .proRes4444:
      return (nominalMegabits(codec: codec, width: width, height: height, frameDuration: frameDuration) ?? 0) + pcm
    }
  }

  /// A rolling take's rate: what it measures, plus its PCM. Its first sample measures
  /// nothing yet, so that one keeps the estimate instead of reading as no rate at all.
  static func rollingMegabits(measuredVideo: Double?, estimate: Double, audioChannels: Int) -> Double {
    guard let measuredVideo, measuredVideo > 0 else { return estimate }
    return measuredVideo + pcmMegabits(channels: audioChannels)
  }

  /// What a volume read found: its UUID, mount point and name, each if it said.
  typealias VolumeFacts = (uuid: String?, mount: String?, name: String?)

  /// What tells a folder's volume apart from every other: its UUID, else its mount point.
  /// Names repeat; a second "8TB" mounts at "/Volumes/8TB 1". A folder that can't be read
  /// (its drive unmounted, no grant, not made yet) keeps the volume it last resolved to,
  /// so a brief unmount doesn't make it another drive; never read, it's on the volume its
  /// path names: `/Volumes/<name>`, or the startup volume.
  /// The caller holds the folder's security scope: sandboxed, the read fails without it.
  static func volume(for url: URL) -> (id: String, name: String) {
    volume(for: url) { candidate in
      (try? candidate.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey, .volumeNameKey]))
        .map { (uuid: $0.volumeUUIDString, mount: $0.volume?.path, name: $0.volumeName) }
    }
  }

  static func volume(for url: URL, read: (URL) -> VolumeFacts?) -> (id: String, name: String) {
    let parts = url.standardizedFileURL.pathComponents
    let external = parts.count >= 3 && parts[1] == "Volumes"
    let mount = external ? "/Volumes/" + parts[2] : "/"
    let pathName = external ? parts[2] : nil
    // The folder, else its mount point (a folder not made yet), if that's the volume's own.
    let facts = read(url) ?? read(URL(fileURLWithPath: mount, isDirectory: true)).flatMap { $0.mount == mount ? $0 : nil }
    if let facts, let id = facts.uuid ?? facts.mount {
      let found = (id: id, name: facts.name ?? pathName ?? "Disk")
      resolvedVolumes.withLock { $0[url.path] = found; $0[facts.mount ?? mount] = found }
      return found
    }
    if let known = resolvedVolumes.withLock({ $0[url.path] ?? $0[mount] }) { return known }
    return (mount, pathName ?? "Disk")
  }

  /// Each folder's and mount point's last resolved volume.
  private static let resolvedVolumes = Mutex<[String: (id: String, name: String)]>([:])

  /// One entry per destination volume. Time left divides free space by the combined
  /// rate of the takes recording to that volume, or with none, of every camera assigned
  /// to it, since Record All fills it that fast. Rates are `displayMegabits` figures.
  @MainActor private static var takeCache: (key: [String], date: Date, takes: [UITake])?

  /// `recentTakes(in:)` cached for a few seconds; folder scans are not free.
  @MainActor static func cachedRecentTakes(in folders: [URL]) -> [UITake] {
    let key = folders.map(\.path)
    if let cache = takeCache, cache.key == key, Date().timeIntervalSince(cache.date) < 3 { return cache.takes }
    let takes = recentTakes(in: folders)
    takeCache = (key, Date(), takes)
    return takes
  }

  static func drives(for folders: [URL?], recordingRates: [(URL, Double)], assignedRates: [(URL, Double)] = [],
    fallbackMegabits: Double = displayMegabits(codec: .proRes42210Bit)) -> [UIDrive] {
    // Each folder's volume, read once inside its security scope: the folders come from
    // security-scoped bookmarks, and a sandboxed read of a volume needs the grant held.
    var volumes: [String: (id: String, name: String)] = [:]
    for case let folder? in folders where volumes[folder.path] == nil {
      let accessed = folder.startAccessingSecurityScopedResource()
      volumes[folder.path] = volume(for: folder)
      if accessed { folder.stopAccessingSecurityScopedResource() }
    }
    func volumeID(_ url: URL) -> String? { volumes[url.path]?.id }
    var seen: [String: UIDrive] = [:]
    var order: [String] = []
    for case let folder? in folders {
      guard let volume = volumes[folder.path] else { continue }
      let (id, name) = (volume.id, volume.name)
      guard seen[id] == nil else {
        if seen[id]?.folders.contains(folder.path) == false { seen[id]?.folders.append(folder.path) }
        continue
      }
      // Its capacity, too, needs the grant held, or it fails and the drive reads as empty.
      let accessed = folder.startAccessingSecurityScopedResource()
      defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
      var reported: Int64?
      var values: URLResourceValues?
      do {
        reported = try VolumeFreeSpace.bytes(at: folder)
        values = try folder.resourceValues(forKeys: [.volumeTotalCapacityKey])
      } catch {
        // Either read failing leaves the drive unknown, not full.
        reported = nil
        values = nil
        Self.logUnreadable(name, error)
      }
      let available = reported ?? 0
      // An unreadable free figure leaves the size unknown too, so the drive isn't shown as full.
      let total = reported == nil ? 0 : Int64(values?.volumeTotalCapacity ?? 0)
      func sum(_ rates: [(URL, Double)]) -> Double { rates.filter { volumeID($0.0) == id }.map(\.1).reduce(0, +) }
      let rate = sum(recordingRates)
      let assigned = sum(assignedRates)
      let megabits = rate > 0 ? rate : assigned > 0 ? assigned : fallbackMegabits
      let seconds = available > 0 ? Double(available) * 8 / (megabits * 1_000_000) : nil
      seen[id] = UIDrive(name: name, availableBytes: available, totalBytes: total, secondsLeft: seconds, volumeID: id,
        folders: [folder.path])
      order.append(id)
    }
    return order.compactMap { seen[$0] }
  }

  private static let driveLog = Logger(subsystem: "org.ultracam.app", category: "recording")
  nonisolated(unsafe) private static var unreadableLogged = Set<String>()

  /// Once per volume per run: why its free space couldn't be read.
  private static func logUnreadable(_ name: String, _ error: Error) {
    guard unreadableLogged.insert(name).inserted else { return }
    driveLog.error("Free space of \(name, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
  }

  /// Finished movies in the recording folders (and one level of camera
  /// subfolders), newest first. Hidden partial files are skipped.
  static func recentTakes(in folders: [URL], limit: Int = 5) -> [UITake] {
    var takes: [UITake] = []
    var visited = Set<String>()
    let manager = FileManager.default
    for folder in folders where visited.insert(folder.path).inserted {
      let accessed = folder.startAccessingSecurityScopedResource()
      defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
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
        takes.append(UITake(url: url, name: url.lastPathComponent, date: date, duration: UITakeDurations.duration(for: url, scope: folder)))
      }
    }
    return takes.sorted { $0.date > $1.date }.prefix(limit).map { take in
      var take = take
      take.lostFrames = UITakeDurations.lostFrames(for: take.url)
      return take
    }
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
  static func sourceProfile(forGamut gamut: String) -> String? {
    switch gamut {
    case "S-Gamut3.Cine / S-Log3": return "sony-slog3-sgamut3cine"
    case "S-Gamut3 / S-Log3": return "sony-slog3-sgamut3"
    default: return nil
    }
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
/// A movie that can't be read yet (a take still recording has no movie
/// header) is tried again at most every 30 s, not on every refresh.
enum UITakeDurations {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var known: [URL: TimeInterval] = [:]
  nonisolated(unsafe) private static var loading: Set<URL> = []
  nonisolated(unsafe) private static var failedAt: [URL: TimeInterval] = [:]
  nonisolated(unsafe) private static var lost: [URL: UInt64] = [:]
  static let retryInterval: TimeInterval = 30

  static func duration(for url: URL, scope: URL? = nil) -> TimeInterval? {
    lock.lock()
    if let value = known[url] { lock.unlock(); return value }
    if let failed = failedAt[url], ProcessInfo.processInfo.systemUptime - failed < retryInterval { lock.unlock(); return nil }
    let start = loading.insert(url).inserted
    lock.unlock()
    if start {
      Task.detached(priority: .utility) {
        // Keep the bookmarked parent grant for the entire asynchronous movie/sidecar read.
        let accessed = scope?.startAccessingSecurityScopedResource() ?? false
        defer { if accessed { scope?.stopAccessingSecurityScopedResource() } }
        let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
        let frames = lostFrames(sidecarOf: url)
        lock.withLock {
          if let seconds, seconds.isFinite, seconds > 0 {
            known[url] = seconds
            lost[url] = frames
            failedAt[url] = nil
          } else {
            failedAt[url] = ProcessInfo.processInfo.systemUptime
          }
          loading.remove(url)
        }
      }
    }
    return nil
  }

  /// A take's lost frames, read with its duration. Nil for a take without the count.
  static func lostFrames(for url: URL) -> UInt64? { lock.withLock { lost[url] } }

  /// Device skips are already inside `sourceVideoLost`. Older sidecars have no count, and
  /// a movie with no sidecar has nothing to say: both show nothing.
  static func lostFrames(sidecarOf movie: URL) -> UInt64? {
    (try? RecordingTakeSidecar.readSnapshot(for: movie))?.counters["recording.sourceVideoLost"]
  }
}
