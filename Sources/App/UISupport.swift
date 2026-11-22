import AppKit
import AVFoundation
import MonitorKitCore
import Observation
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

  /// One entry per destination volume. Time left uses the combined rate of takes on the volume.
  static func drives(for folders: [URL?], recordingRates: [(URL, Double)], assignedRates: [(URL, Double)] = [],
    fallbackMegabits: Double = displayMegabits(codec: .proRes42210Bit)) -> [UIDrive] {
    // Each folder's volume, read once inside its security scope: the folders come from
    // security-scoped bookmarks, and a sandboxed read of a volume needs the grant held.
    var volumeIDs: [String: String] = [:]
    var groups: [String: (name: String, folders: [URL])] = [:]
    var order: [String] = []
    for case let folder? in folders where volumeIDs[folder.path] == nil {
      let accessed = folder.startAccessingSecurityScopedResource()
      let (id, name) = volume(for: folder)
      if accessed { folder.stopAccessingSecurityScopedResource() }
      volumeIDs[folder.path] = id
      if groups[id] == nil { order.append(id) }
      groups[id, default: (name, [])].folders.append(folder)
    }
    func sums(_ rates: [(URL, Double)]) -> [String: Double] {
      var totals: [String: Double] = [:]
      for (url, rate) in rates {
        if let id = volumeIDs[url.path] { totals[id, default: 0] += rate }
      }
      return totals
    }
    let rolling = sums(recordingRates)
    let assigned = sums(assignedRates)
    return order.compactMap { id in
      guard let group = groups[id] else { return nil }
      var drive = UIDrive(name: group.name, availableBytes: 0, totalBytes: 0, secondsLeft: nil, volumeID: id,
        folders: group.folders.map(\.path))
      let rate = rolling[id] ?? 0
      let estimate = assigned[id] ?? 0
      let megabits = rate > 0 ? rate : estimate > 0 ? estimate : fallbackMegabits
      var capacityError: Error?
      for folder in group.folders {
        do {
          guard let (available, total) = try capacity(at: folder) else { continue }
          drive.availableBytes = available
          drive.totalBytes = total
          drive.secondsLeft = available > 0 && megabits > 0 ? Double(available) * 8 / (megabits * 1_000_000) : nil
          return drive
        } catch {
          if capacityError == nil { capacityError = error }
        }
      }
      if let capacityError { logUnreadable(id: id, name: drive.name, capacityError) }
      return drive
    }
  }

  private static func capacity(at folder: URL) throws -> (Int64, Int64)? {
    // Capacity reads also need the bookmarked grant.
    let accessed = folder.startAccessingSecurityScopedResource()
    defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
    guard let available = try VolumeFreeSpace.bytes(at: folder) else { return nil }
    let values = try folder.resourceValues(forKeys: [.volumeTotalCapacityKey])
    return (available, Int64(values.volumeTotalCapacity ?? 0))
  }

  private static let driveLog = Logger(subsystem: "org.ultracam.app", category: "recording")
  private static let unreadableLogged = Mutex<Set<String>>([])

  /// Once per volume per run: why its free space couldn't be read.
  private static func logUnreadable(id: String, name: String, _ error: Error) {
    guard unreadableLogged.withLock({ $0.insert(id).inserted }) else { return }
    driveLog.error("Free space of \(name, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
  }

  struct RecentMovie: Sendable {
    var take: UITake
    let scope: URL
    var checkedAt: Date?
  }

  /// Enumerate under the bookmarked grants on a worker. Only the newest movies
  /// go on to have their movie headers and sidecars read.
  static func newestMovies(in folders: [URL], limit: Int = 5) -> [RecentMovie] {
    guard limit > 0 else { return [] }
    let manager = FileManager.default
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
    var newest: [RecentMovie] = []
    var visited = Set<URL>()
    func entries(_ folder: URL) -> [URL] {
      (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles])) ?? []
    }
    func consider(_ url: URL, scope: URL) {
      guard ["mov", "mp4"].contains(url.pathExtension.lowercased()),
        !newest.contains(where: { $0.take.url == url.standardizedFileURL }),
        let values = try? url.resourceValues(forKeys: keys), values.isDirectory != true else { return }
      let date = values.contentModificationDate ?? .distantPast
      let take = UITake(url: url.standardizedFileURL, name: url.lastPathComponent, date: date)
      let position = newest.firstIndex {
        date > $0.take.date || (date == $0.take.date && take.url.path < $0.take.url.path)
      } ?? newest.count
      guard position < limit else { return }
      newest.insert(RecentMovie(take: take, scope: scope), at: position)
      if newest.count > limit { newest.removeLast() }
    }
    for folder in folders where visited.insert(folder.standardizedFileURL).inserted {
      let accessed = folder.startAccessingSecurityScopedResource()
      defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
      for entry in entries(folder) {
        if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
          for movie in entries(entry) { consider(movie, scope: folder) }
        } else {
          consider(entry, scope: folder)
        }
      }
    }
    return newest
  }
}

/// One scan and at most one movie metadata read at a time, across window and menu requests.
@MainActor @Observable final class RecentTakeCache {
  typealias ReadDetails = @Sendable (URL, URL) async -> (duration: TimeInterval?, lostFrames: UInt64?)
  private let readDetails: ReadDetails
  @ObservationIgnored private var requested: [URL] = []
  @ObservationIgnored private var refreshing = false
  @ObservationIgnored private var finishedAt = Date.distantPast
  private var shownFolders: [URL] = []
  private var movies: [UIRecordingLibrary.RecentMovie] = []

  init(readDetails: @escaping ReadDetails = { await UITakeDurations.read($0, scope: $1) }) {
    self.readDetails = readDetails
  }

  func takes(in folders: [URL]) -> [UITake] {
    requested = folders
    if !refreshing && (shownFolders != folders || Date().timeIntervalSince(finishedAt) >= 3) {
      refreshing = true
      Task { await refresh() }
    }
    return shownFolders == folders ? movies.map(\.take) : []
  }

  private func refresh() async {
    defer { refreshing = false }
    while true {
      let folders = requested
      var newest = await Task.detached(priority: .utility) {
        UIRecordingLibrary.newestMovies(in: folders)
      }.value
      guard folders == requested else { continue }
      for index in newest.indices {
        if let cached = movies.first(where: {
          $0.take.url == newest[index].take.url && $0.take.date == newest[index].take.date
        }) {
          newest[index].take = cached.take
          newest[index].checkedAt = cached.checkedAt
        }
      }
      shownFolders = folders
      movies = newest
      for (index, movie) in newest.enumerated() {
        // An unfinished movie may not have a readable header yet.
        if movie.take.duration != nil || movie.checkedAt.map({ Date().timeIntervalSince($0) < 30 }) == true { continue }
        let readDetails = self.readDetails
        let details = await Task.detached(priority: .utility) {
          await readDetails(movie.take.url, movie.scope)
        }.value
        guard folders == requested else { break }
        movies[index].take.duration = details.duration
        movies[index].take.lostFrames = details.lostFrames
        movies[index].checkedAt = Date()
      }
      if folders == requested { finishedAt = Date(); return }
    }
  }
}

/// `UIMonitorBridge`'s presenters, observed.
@MainActor @Observable final class UIMonitorPresenterRegistry {
  var presenters: [String: MonitorSurfacePresenter] = [:]
}

/// Bridges the interface to the monitor tools, which are per camera.
@MainActor
enum UIMonitorBridge {
  /// Presenters of the main window's pictures currently on screen (cameras and Program), so
  /// menu commands act on the selected camera and a Scopes window finds its picture's scope.
  /// Observed: a view that reads one updates when its picture appears or goes.
  private static let registry = UIMonitorPresenterRegistry()
  private static var presenters: [String: MonitorSurfacePresenter] { registry.presenters }

  static func register(_ presenter: MonitorSurfacePresenter, cameraID: String) {
    if registry.presenters[cameraID] !== presenter { registry.presenters[cameraID] = presenter }
  }
  static func unregister(cameraID: String, presenter: MonitorSurfacePresenter) {
    if registry.presenters[cameraID] === presenter { registry.presenters[cameraID] = nil }
  }
  static func presenter(for cameraID: String) -> MonitorSurfacePresenter? { registry.presenters[cameraID] }

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

enum UITakeDurations {
  static func read(_ url: URL, scope: URL) async -> (duration: TimeInterval?, lostFrames: UInt64?) {
    let accessed = scope.startAccessingSecurityScopedResource()
    defer { if accessed { scope.stopAccessingSecurityScopedResource() } }
    let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
    return (seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }, lostFrames(sidecarOf: url))
  }

  /// Device skips are already inside `sourceVideoLost`. Older sidecars have no count, and
  /// a movie with no sidecar has nothing to say: both show nothing.
  static func lostFrames(sidecarOf movie: URL) -> UInt64? {
    (try? RecordingTakeSidecar.readSnapshot(for: movie))?.counters["recording.sourceVideoLost"]
  }
}
