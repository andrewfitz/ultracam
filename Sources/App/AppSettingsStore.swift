import Foundation

/// Stable identity for a configured feed. The raw value is persisted instead of
/// relying on array position, so reordering feeds does not change their
/// identity. `primary` is deterministic for migration from the original
/// single-feed settings format.
struct FeedID: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
  typealias RawValue = String

  let rawValue: String

  init(rawValue: String) { self.rawValue = rawValue }

  init(uuid: UUID) { rawValue = uuid.uuidString.lowercased() }

  init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  var id: String { rawValue }

  static let primary = FeedID(rawValue: "00000000-0000-0000-0000-000000000001")
}

enum FeedOutputMode: String, Codable, Equatable, Hashable, Sendable {
  case separateCameras
  case program
}

enum SwitcherStrategy: String, Codable, Equatable, Hashable, Sendable {
  case manual
  case fixedInterval
  case naturalTalkingHead
  case dynamicAnalysis
}

struct NaturalTalkingHeadSettings: Codable, Equatable, Sendable {
  var enabled = false
  var anchorFeedID: FeedID?
  var emphasisFeedID: FeedID?
  var mode: TalkingHeadDirectorMode = .transcriptAssisted
  var minimumShotDuration = 10.0
  var cooldown = 1.5
  var emphasisHold = 5.0
  var softMaximumShotDuration = 20.0
  var maximumShotDuration = 30.0
  var forcedCutGracePeriod = 2.0
  var forcedBoundaryLookback = 1.0
  var boundaryWindow = 0.24
  var candidateDwell = 0.30
  var transcriptConfidenceThreshold: Float = 0.72
  var pauseBoundaryDuration = 0.22
  var cutThreshold: Float = 0.68
  var hysteresisMargin: Float = 0.12
  var transcriptOutputDelay = 0.35
  var manualHold = false

  private enum CodingKeys: String, CodingKey {
    case enabled, anchorFeedID, emphasisFeedID, mode, minimumShotDuration, cooldown,
      emphasisHold, softMaximumShotDuration, maximumShotDuration, forcedCutGracePeriod,
      forcedBoundaryLookback, boundaryWindow, candidateDwell, transcriptConfidenceThreshold,
      pauseBoundaryDuration, cutThreshold, hysteresisMargin, transcriptOutputDelay, manualHold
  }

  init(enabled: Bool = false, anchorFeedID: FeedID? = nil, emphasisFeedID: FeedID? = nil,
       mode: TalkingHeadDirectorMode = .transcriptAssisted, minimumShotDuration: Double = 10,
       cooldown: Double = 1.5, emphasisHold: Double = 5,
       softMaximumShotDuration: Double = 20, maximumShotDuration: Double = 30,
       forcedCutGracePeriod: Double = 2, forcedBoundaryLookback: Double = 1,
       boundaryWindow: Double = 0.24, candidateDwell: Double = 0.30,
       transcriptConfidenceThreshold: Float = 0.72, pauseBoundaryDuration: Double = 0.22,
       cutThreshold: Float = 0.68, hysteresisMargin: Float = 0.12,
       transcriptOutputDelay: Double = 0.35, manualHold: Bool = false) {
    self.enabled = enabled
    self.anchorFeedID = anchorFeedID
    self.emphasisFeedID = emphasisFeedID
    self.mode = mode
    self.minimumShotDuration = minimumShotDuration
    self.cooldown = cooldown
    self.emphasisHold = emphasisHold
    self.softMaximumShotDuration = softMaximumShotDuration
    self.maximumShotDuration = maximumShotDuration
    self.forcedCutGracePeriod = forcedCutGracePeriod
    self.forcedBoundaryLookback = forcedBoundaryLookback
    self.boundaryWindow = boundaryWindow
    self.candidateDwell = candidateDwell
    self.transcriptConfidenceThreshold = transcriptConfidenceThreshold
    self.pauseBoundaryDuration = pauseBoundaryDuration
    self.cutThreshold = cutThreshold
    self.hysteresisMargin = hysteresisMargin
    self.transcriptOutputDelay = transcriptOutputDelay
    self.manualHold = manualHold
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    anchorFeedID = try values.decodeIfPresent(FeedID.self, forKey: .anchorFeedID)
    emphasisFeedID = try values.decodeIfPresent(FeedID.self, forKey: .emphasisFeedID)
    mode = try values.decodeIfPresent(TalkingHeadDirectorMode.self, forKey: .mode)
      ?? .transcriptAssisted
    let storedMinimumShotDuration = try values.decodeIfPresent(Double.self,
      forKey: .minimumShotDuration) ?? 10
    minimumShotDuration = max(10, storedMinimumShotDuration)
    cooldown = try values.decodeIfPresent(Double.self, forKey: .cooldown) ?? 1.5
    emphasisHold = try values.decodeIfPresent(Double.self, forKey: .emphasisHold) ?? 5
    softMaximumShotDuration = try values.decodeIfPresent(Double.self,
      forKey: .softMaximumShotDuration) ?? 20
    maximumShotDuration = try values.decodeIfPresent(Double.self,
      forKey: .maximumShotDuration) ?? 30
    forcedCutGracePeriod = try values.decodeIfPresent(Double.self,
      forKey: .forcedCutGracePeriod) ?? 2
    forcedBoundaryLookback = try values.decodeIfPresent(Double.self,
      forKey: .forcedBoundaryLookback) ?? 1
    boundaryWindow = try values.decodeIfPresent(Double.self, forKey: .boundaryWindow) ?? 0.24
    candidateDwell = try values.decodeIfPresent(Double.self, forKey: .candidateDwell) ?? 0.30
    transcriptConfidenceThreshold = try values.decodeIfPresent(Float.self,
      forKey: .transcriptConfidenceThreshold) ?? 0.72
    pauseBoundaryDuration = try values.decodeIfPresent(Double.self,
      forKey: .pauseBoundaryDuration) ?? 0.22
    cutThreshold = try values.decodeIfPresent(Float.self, forKey: .cutThreshold) ?? 0.68
    hysteresisMargin = try values.decodeIfPresent(Float.self, forKey: .hysteresisMargin) ?? 0.12
    transcriptOutputDelay = try values.decodeIfPresent(Double.self,
      forKey: .transcriptOutputDelay) ?? 0.35
    manualHold = try values.decodeIfPresent(Bool.self, forKey: .manualHold) ?? false
  }
}

extension NaturalTalkingHeadSettings {
  /// Produces finite, ordered values before crossing the Rust configuration
  /// boundary. Preferences are user-editable JSON, so runtime validation must
  /// not depend on the UI having already visited every field.
  mutating func normalizeForRuntime() {
    func nonNegative(_ value: Double, _ fallback: Double) -> Double {
      value.isFinite ? max(0, value) : fallback
    }
    minimumShotDuration = nonNegative(minimumShotDuration, 10)
    cooldown = nonNegative(cooldown, 1.5)
    emphasisHold = nonNegative(emphasisHold, 5)
    softMaximumShotDuration = nonNegative(softMaximumShotDuration, 20)
    maximumShotDuration = nonNegative(maximumShotDuration, 30)
    maximumShotDuration = max(maximumShotDuration,
      max(minimumShotDuration + 0.001, cooldown + 0.001))
    softMaximumShotDuration = min(softMaximumShotDuration, maximumShotDuration)
    forcedCutGracePeriod = nonNegative(forcedCutGracePeriod, 2)
    forcedBoundaryLookback = nonNegative(forcedBoundaryLookback, 1)
    boundaryWindow = nonNegative(boundaryWindow, 0.24)
    candidateDwell = nonNegative(candidateDwell, 0.30)
    pauseBoundaryDuration = nonNegative(pauseBoundaryDuration, 0.22)
    transcriptOutputDelay = nonNegative(transcriptOutputDelay, 0.35)
    func unit(_ value: Float, _ fallback: Float) -> Float {
      value.isFinite ? min(1, max(0, value)) : fallback
    }
    transcriptConfidenceThreshold = unit(transcriptConfidenceThreshold, 0.72)
    cutThreshold = unit(cutThreshold, 0.68)
    hysteresisMargin = unit(hysteresisMargin, 0.12)
  }
}

struct SwitcherSettings: Codable, Equatable, Sendable {
  var selectedFeedID: FeedID?
  var automatic = false
  var intervalSeconds = 5.0
  var strategy: SwitcherStrategy = .manual
  var naturalTalkingHead = NaturalTalkingHeadSettings()

  init(selectedFeedID: FeedID? = nil, automatic: Bool = false,
    intervalSeconds: Double = 5.0, strategy: SwitcherStrategy = .manual,
    naturalTalkingHead: NaturalTalkingHeadSettings = .init()) {
    self.selectedFeedID = selectedFeedID
    self.automatic = automatic
    self.intervalSeconds = intervalSeconds
    self.strategy = strategy
    self.naturalTalkingHead = naturalTalkingHead
  }

  private enum CodingKeys: String, CodingKey {
    case selectedFeedID, automatic, intervalSeconds, strategy, naturalTalkingHead
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    selectedFeedID = try values.decodeIfPresent(FeedID.self, forKey: .selectedFeedID)
    automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
    intervalSeconds = try values.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? 5.0
    strategy = try values.decodeIfPresent(SwitcherStrategy.self, forKey: .strategy) ?? .manual
    naturalTalkingHead = try values.decodeIfPresent(NaturalTalkingHeadSettings.self,
      forKey: .naturalTalkingHead) ?? .init()
  }
}

struct AppSettings: Codable, Equatable, Sendable {
  var version = 1
  var selectedDevice = ""
  var applyLUT = false
  var downscale = true
  var convertTo420 = true
  var reduceFrameRate = false
  var gamut = "S-Gamut3.Cine / S-Log3"
  var pipelineEnabled = true
  var previewEnabled = true
  var lutBookmark: Data?
  // Optional on disk to migrate v1 preferences without losing the saved LUT.
  var automaticFeed: Bool?

  var configuration: PipelineConfiguration {
    PipelineConfiguration(applyLUT: applyLUT, downscale: downscale,
      convertTo420: convertTo420, reduceFrameRate: reduceFrameRate)
  }
}

/// Persisted settings for one feed. This is deliberately independent from
/// `AppModel`, which still owns the one-feed runtime path for now.
struct FeedDescriptor: Codable, Equatable, Sendable, Identifiable {
  var version = 1
  var id: FeedID
  var name: String
  var selectedDevice = ""
  var applyLUT = false
  var downscale = true
  var convertTo420 = true
  var reduceFrameRate = false
  var gamut = "S-Gamut3.Cine / S-Log3"
  var pipelineEnabled = true
  var previewEnabled = true
  var lutBookmark: Data?
  var automaticFeed = false
  var enabled = true
  /// Monitor tools for this feed's surfaces (key `monitor`).
  var monitor = MonitorFeedPreferences()
  /// The MonitorTools configuration an earlier build saved (key
  /// `monitorConfiguration`), written back untouched so a downgrade still finds
  /// its tools. Only migrated from, never decoded as a `MonitorState`.
  var legacyMonitorConfiguration: PreservedJSON?

  /// The monitor-only LUT's saved bookmark. It lives in the monitor preferences
  /// (`monitor.monitorLUT`, under the key `monitor`), which every save path
  /// carries whole, so `version` stays 1. The burn-in LUT is `lutBookmark`.
  var monitorLUTBookmark: Data? { monitor.monitorLUT?.bookmark }

  /// Whether the monitor-only LUT is shown (`MonitorState.monitorLUT`).
  var monitorLUTEnabled: Bool {
    get { monitor.monitorLUTEnabled }
    set { monitor.monitorLUTEnabled = newValue }
  }

  init(id: FeedID = .primary, name: String = "Camera 1", selectedDevice: String = "",
    applyLUT: Bool = false, downscale: Bool = true, convertTo420: Bool = true,
    reduceFrameRate: Bool = false, gamut: String = "S-Gamut3.Cine / S-Log3",
    pipelineEnabled: Bool = true, previewEnabled: Bool = true, lutBookmark: Data? = nil,
    automaticFeed: Bool = false, enabled: Bool = true,
    monitor: MonitorFeedPreferences = MonitorFeedPreferences(),
    legacyMonitorConfiguration: PreservedJSON? = nil) {
    self.id = id
    self.name = name
    self.selectedDevice = selectedDevice
    self.applyLUT = applyLUT
    self.downscale = downscale
    self.convertTo420 = convertTo420
    self.reduceFrameRate = reduceFrameRate
    self.gamut = gamut
    self.pipelineEnabled = pipelineEnabled
    self.previewEnabled = previewEnabled
    self.lutBookmark = lutBookmark
    self.automaticFeed = automaticFeed
    self.enabled = enabled
    self.monitor = monitor
    self.legacyMonitorConfiguration = legacyMonitorConfiguration
  }

  init(legacy settings: AppSettings, id: FeedID = .primary, name: String = "Camera 1") {
    self.init(id: id, name: name, selectedDevice: settings.selectedDevice,
      applyLUT: settings.applyLUT, downscale: settings.downscale,
      convertTo420: settings.convertTo420, reduceFrameRate: settings.reduceFrameRate,
      gamut: settings.gamut, pipelineEnabled: settings.pipelineEnabled,
      previewEnabled: settings.previewEnabled, lutBookmark: settings.lutBookmark,
      automaticFeed: settings.automaticFeed ?? false)
  }

  var configuration: PipelineConfiguration {
    PipelineConfiguration(applyLUT: applyLUT, downscale: downscale,
      convertTo420: convertTo420, reduceFrameRate: reduceFrameRate)
  }

  var displayName: String {
    get { name }
    set { name = newValue }
  }

  var deviceID: String {
    get { selectedDevice }
    set { selectedDevice = newValue }
  }

  var appSettings: AppSettings {
    AppSettings(selectedDevice: selectedDevice, applyLUT: applyLUT, downscale: downscale,
      convertTo420: convertTo420, reduceFrameRate: reduceFrameRate, gamut: gamut,
      pipelineEnabled: pipelineEnabled, previewEnabled: previewEnabled,
      lutBookmark: lutBookmark, automaticFeed: automaticFeed)
  }

  private enum CodingKeys: String, CodingKey {
    case version, id, name, selectedDevice, applyLUT, downscale, convertTo420,
      reduceFrameRate, gamut, pipelineEnabled, previewEnabled, lutBookmark,
      automaticFeed, enabled, monitor
    case legacyMonitorConfiguration = "monitorConfiguration"
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
    id = try values.decodeIfPresent(FeedID.self, forKey: .id) ?? .primary
    let savedName = try values.decodeIfPresent(String.self, forKey: .name) ?? "Camera 1"
    // Untouched default names from before the interface used "Camera" become "Camera N".
    if savedName.hasPrefix("Feed "), let number = Int(savedName.dropFirst(5)) { name = "Camera \(number)" }
    else { name = savedName }
    selectedDevice = try values.decodeIfPresent(String.self, forKey: .selectedDevice) ?? ""
    applyLUT = try values.decodeIfPresent(Bool.self, forKey: .applyLUT) ?? false
    downscale = try values.decodeIfPresent(Bool.self, forKey: .downscale) ?? true
    convertTo420 = try values.decodeIfPresent(Bool.self, forKey: .convertTo420) ?? true
    reduceFrameRate = try values.decodeIfPresent(Bool.self, forKey: .reduceFrameRate) ?? false
    gamut = try values.decodeIfPresent(String.self, forKey: .gamut) ?? "S-Gamut3.Cine / S-Log3"
    pipelineEnabled = try values.decodeIfPresent(Bool.self, forKey: .pipelineEnabled) ?? true
    previewEnabled = try values.decodeIfPresent(Bool.self, forKey: .previewEnabled) ?? true
    lutBookmark = try values.decodeIfPresent(Data.self, forKey: .lutBookmark)
    automaticFeed = try values.decodeIfPresent(Bool.self, forKey: .automaticFeed) ?? false
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    // New keys only: `version` stays 1, since `validated()` rejects any other
    // and a rejected snapshot loses every feed.
    monitor = values.monitorPreferences(.monitor, legacy: .legacyMonitorConfiguration)
    legacyMonitorConfiguration = values.preservedJSON(.legacyMonitorConfiguration)
  }
}

struct AppSettingsSnapshot: Codable, Equatable, Sendable {
  static let currentVersion = 2

  var version = AppSettingsSnapshot.currentVersion
  var feeds: [FeedDescriptor]
  var selectedFeedID: FeedID
  var outputMode: FeedOutputMode = .separateCameras
  var switcher = SwitcherSettings()
  /// Monitor tools for Program's surfaces (key `programMonitor`).
  var programMonitor = MonitorFeedPreferences()
  /// Program's MonitorTools configuration from an earlier build (key
  /// `programMonitorConfiguration`), kept untouched like the feeds'.
  var legacyProgramMonitorConfiguration: PreservedJSON?
  /// Key `monitorWorkspace`, the same JSON as before.
  var monitorWorkspacePreferences = MonitorWorkspacePreferences()
  var virtualCameraRegistryVersion = 1

  init(feeds: [FeedDescriptor] = [FeedDescriptor()], selectedFeedID: FeedID? = nil,
    outputMode: FeedOutputMode = .separateCameras, switcher: SwitcherSettings = SwitcherSettings(),
    virtualCameraRegistryVersion: Int = 1,
    programMonitor: MonitorFeedPreferences = MonitorFeedPreferences(),
    legacyProgramMonitorConfiguration: PreservedJSON? = nil,
    monitorWorkspace: MonitorWorkspacePreferences = MonitorWorkspacePreferences()) {
    self.feeds = feeds
    self.selectedFeedID = selectedFeedID ?? feeds.first?.id ?? .primary
    self.outputMode = outputMode
    self.switcher = switcher
    self.virtualCameraRegistryVersion = virtualCameraRegistryVersion
    self.programMonitor = programMonitor
    self.legacyProgramMonitorConfiguration = legacyProgramMonitorConfiguration
    self.monitorWorkspacePreferences = monitorWorkspace
  }

  var selectedFeed: FeedDescriptor? {
    feeds.first(where: { $0.id == selectedFeedID }) ?? feeds.first
  }

  /// Returns a complete, safe snapshot while preserving descriptor ordering.
  /// Invalid IDs or an empty collection indicate corrupt v2 data and are
  /// rejected so the store can fall back to the v1 migration path.
  func validated() -> AppSettingsSnapshot? {
    guard version == Self.currentVersion, !feeds.isEmpty else { return nil }
    var seen = Set<FeedID>()
    for feed in feeds {
      guard feed.version == 1, !feed.id.rawValue.isEmpty, seen.insert(feed.id).inserted else { return nil }
    }
    // Persistence preserves a valid descriptor ID even when that feed is
    // currently disabled. Runtime coordinators choose an enabled fallback
    // when they start; rewriting the snapshot here would lose the user's
    // stable selection and break round-trip fidelity.
    return self
  }

  private enum CodingKeys: String, CodingKey {
    case version, feeds, selectedFeedID, outputMode, switcher, virtualCameraRegistryVersion, programMonitor
    case legacyProgramMonitorConfiguration = "programMonitorConfiguration"
    case monitorWorkspacePreferences = "monitorWorkspace"
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
    feeds = try values.decodeIfPresent([FeedDescriptor].self, forKey: .feeds) ?? []
    selectedFeedID = try values.decodeIfPresent(FeedID.self, forKey: .selectedFeedID)
      ?? feeds.first?.id ?? .primary
    outputMode = try values.decodeIfPresent(FeedOutputMode.self, forKey: .outputMode) ?? .separateCameras
    switcher = try values.decodeIfPresent(SwitcherSettings.self, forKey: .switcher) ?? SwitcherSettings()
    virtualCameraRegistryVersion = try values.decodeIfPresent(Int.self, forKey: .virtualCameraRegistryVersion) ?? 1
    programMonitor = values.monitorPreferences(.programMonitor, legacy: .legacyProgramMonitorConfiguration)
    legacyProgramMonitorConfiguration = values.preservedJSON(.legacyProgramMonitorConfiguration)
    monitorWorkspacePreferences = try values.decodeIfPresent(MonitorWorkspacePreferences.self,
      forKey: .monitorWorkspacePreferences) ?? MonitorWorkspacePreferences()
  }
}

// Small preferences stay on the main actor. Video state, frame buffers and LUT
// contents are never serialized into defaults.
@MainActor
final class AppSettingsStore {
  static let hideFromDockKey = "ultracam.hideFromDock"
  static let advertiseHDRKey = "ultracam.advertiseHDRToCameras"
  static let key = "ultracam.settings.v1"
  static let snapshotKey = "ultracam.settings.v2"
  static let v2Key = snapshotKey
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  /// Removes every saved Ultracam preference: feeds, switcher, monitor tools,
  /// Dock visibility, HDR advertisement, interface layout and recording-folder
  /// bookmarks.
  /// Recordings and their recovery journals on disk are not touched.
  func resetAll() {
    let names = defaults.dictionaryRepresentation().keys.filter {
      $0 == Self.hideFromDockKey || $0 == Self.advertiseHDRKey || $0 == Self.key || $0 == Self.snapshotKey ||
        $0.hasPrefix("ui.") || $0.hasPrefix("recordingFolderBookmark")
    }
    for name in names { defaults.removeObject(forKey: name) }
  }

  var hideFromDock: Bool {
    get { defaults.bool(forKey: Self.hideFromDockKey) }
    set { defaults.set(newValue, forKey: Self.hideFromDockKey) }
  }

  /// "Advertise HLG to cameras" (the driver default already has SDR and PQ). Off when never saved.
  var advertiseHDRToCameras: Bool {
    get { defaults.bool(forKey: Self.advertiseHDRKey) }
    set { defaults.set(newValue, forKey: Self.advertiseHDRKey) }
  }

  func load() -> AppSettings {
    if let snapshot = loadV2() { return snapshot.selectedFeed?.appSettings ?? AppSettings() }
    guard let legacy = loadLegacy() else { return AppSettings() }
    saveSnapshot(AppSettingsSnapshot(feeds: [FeedDescriptor(legacy: legacy)], selectedFeedID: .primary))
    return legacy
  }

  /// Loads the v2 collection and migrates the original one-feed record on the
  /// first read. The v1 value is intentionally retained until a v2 snapshot is
  /// successfully encoded and stored, allowing recovery after a failed write.
  func loadSnapshot() -> AppSettingsSnapshot {
    if let snapshot = loadV2() { return snapshot }
    guard let legacy = loadLegacy() else { return AppSettingsSnapshot() }
    let migrated = AppSettingsSnapshot(feeds: [FeedDescriptor(legacy: legacy)], selectedFeedID: .primary)
    saveSnapshot(migrated)
    return migrated
  }

  func save(_ settings: AppSettings) {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: Self.key)
  }

  func saveSnapshot(_ snapshot: AppSettingsSnapshot) {
    // Never replace a valid on-disk configuration with a fresh default when a
    // caller hands us malformed data. The old behavior silently reset all
    // feeds and routing after a validation failure, which is data loss and
    // makes a transient/corrupt update indistinguishable from a user reset.
    guard let snapshot = snapshot.validated(),
      let data = try? JSONEncoder().encode(snapshot) else { return }
    defaults.set(data, forKey: Self.snapshotKey)
  }

  private func loadLegacy() -> AppSettings? {
    guard let data = defaults.data(forKey: Self.key),
      let settings = try? JSONDecoder().decode(AppSettings.self, from: data),
      settings.version == 1 else { return nil }
    return settings
  }

  private func loadV2() -> AppSettingsSnapshot? {
    guard let data = defaults.data(forKey: Self.snapshotKey),
      let snapshot = try? JSONDecoder().decode(AppSettingsSnapshot.self, from: data) else { return nil }
    return snapshot.validated()
  }
}

struct LoadedLUT: Sendable {
  let cube: CubeLUT
  let bookmark: Data
  let fileName: String
  /// The file the bookmark resolved to, symlinks resolved: two bookmarks with
  /// different bytes (a refreshed one, another camera's) name the same LUT.
  let path: String
}

// File access and cube parsing run off the main actor. Every security-scope
// lease spans the read only; the GPU receives the parsed immutable cube.
actor LUTFileLoader {
  private let scopedBookmarks: Bool

  init(scopedBookmarks: Bool = true) { self.scopedBookmarks = scopedBookmarks }

  func load(url: URL) throws -> LoadedLUT {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let bookmark = try url.bookmarkData(options: scopedBookmarks
      ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : [.minimalBookmark],
      includingResourceValuesForKeys: nil, relativeTo: nil)
    return LoadedLUT(cube: try read(url), bookmark: bookmark, fileName: url.lastPathComponent,
      path: url.resolvingSymlinksInPath().path)
  }

  func restore(bookmark: Data) throws -> LoadedLUT {
    var stale = false
    let url = try URL(resolvingBookmarkData: bookmark,
      options: scopedBookmarks ? [.withSecurityScope, .withoutUI] : [.withoutUI],
      relativeTo: nil, bookmarkDataIsStale: &stale)
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let cube = try read(url)
    let refreshed = stale ? try url.bookmarkData(options: scopedBookmarks
      ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : [.minimalBookmark],
      includingResourceValuesForKeys: nil, relativeTo: nil) : bookmark
    return LoadedLUT(cube: cube, bookmark: refreshed, fileName: url.lastPathComponent,
      path: url.resolvingSymlinksInPath().path)
  }

  private func read(_ url: URL) throws -> CubeLUT {
    let limit = 32 * 1024 * 1024
    let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw VideoError.message("Choose a regular .cube file.")
    }
    guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= limit else {
      throw VideoError.message("LUT file exceeds 32 MB.")
    }
    // Bound the actual read as well as the preflight size: a file can grow
    // between stat and read, and an unbounded String initializer allocates it
    // before the parser can enforce its own limit.
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var bytes = Data()
    while bytes.count <= limit {
      let chunk = try handle.read(upToCount: min(1024 * 1024, limit + 1 - bytes.count))
      guard let chunk, !chunk.isEmpty else { break }
      bytes.append(chunk)
    }
    guard bytes.count <= limit else { throw VideoError.message("LUT file exceeds 32 MB.") }
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw VideoError.message("LUT file must contain valid UTF-8 text.")
    }
    return try CubeLUT(text: text,
      fallbackTitle: url.deletingPathExtension().lastPathComponent)
  }
}
