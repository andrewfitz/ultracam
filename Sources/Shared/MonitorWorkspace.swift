import Foundation
import MonitorKitCore
import MonitorKitScopes

// App-owned monitor preferences (integration map §5). The names differ from
// the retired MonitorTools package's (`MonitorWorkspaceState`, ...): they were
// chosen while both packages were linked, when a same-named app type would have
// shadowed the imported one.

/// Monitor settings of one target (a camera feed or Program): MonitorKit tool
/// state plus the app glue MonitorKit has no field for.
///
/// Persisted under new keys (`FeedDescriptor.monitor`,
/// `AppSettingsSnapshot.programMonitor`). The old MonitorTools blob is migrated
/// from, never decoded as `MonitorState`, and kept untouched beside it.
struct MonitorFeedPreferences: Codable, Equatable, Sendable {
  static let schemaVersion = 1

  /// Ultracam's default tools: MonitorKit's, looking as MonitorTools' did
  /// (`LegacyMonitorConfiguration()`). The zebra band is 5 IRE wide (MonitorKit's
  /// `range` is the half-width), and the picture shows the output stage, the
  /// source with the burn-in LUT ("Output (LUT)").
  static let defaultState: MonitorState = {
    var value = MonitorState()
    value.zebras[0].range = 2.5
    value.pictureStage = .output
    return value
  }()

  /// The "Monitor tools" master switch. Off hides every tool and the scopes
  /// while their settings stay as they are, so turning it back on restores them.
  var toolsEnabled = false
  /// Tool settings shared by every surface of this target. `clean` and
  /// `geometry.magnification` belong to a surface and are never persisted.
  var state = Self.defaultState
  /// How this target's camera signal is read. Per target, not per surface.
  var signal = MonitorSignalDeclaration()
  var scopes = MonitorScopePreferences()
  /// This camera's monitor-only LUT (key `monitorLUT`), shown on the Monitor
  /// picture stage over the burn-in LUT and never burned in. Per camera, like
  /// the signal declaration: Reset and Copy keep it. Program has none.
  var monitorLUT: MonitorLUTChoice?

  init(toolsEnabled: Bool = false, state: MonitorState = Self.defaultState,
    signal: MonitorSignalDeclaration = MonitorSignalDeclaration(),
    scopes: MonitorScopePreferences = MonitorScopePreferences(), monitorLUT: MonitorLUTChoice? = nil) {
    self.toolsEnabled = toolsEnabled
    self.state = state
    self.signal = signal
    self.scopes = scopes
    self.monitorLUT = monitorLUT
  }

  /// Whether the monitor-only LUT is shown: `MonitorState.monitorLUT`, the
  /// switch MonitorKit's pipelines, status and scopes read. The file stays
  /// loaded while it is off, so turning it back on is immediate.
  var monitorLUTEnabled: Bool {
    get { state.monitorLUT }
    set { state.monitorLUT = newValue }
  }

  /// The settings an old MonitorTools configuration described (map §5.3).
  init(migrating legacy: LegacyMonitorConfiguration) {
    self.init()
    merge(legacy)
  }

  private enum CodingKeys: String, CodingKey { case schemaVersion, toolsEnabled, state, signal, scopes, monitorLUT }

  /// Throws unless `state` is a genuine MonitorKit `MonitorState`; callers use
  /// `KeyedDecodingContainer.monitorPreferences(_:legacy:)`, which never throws.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(state: try c.decode(MonitorState.self, forKey: .state).persisted)
    toolsEnabled = ((try? c.decodeIfPresent(Bool.self, forKey: .toolsEnabled)) ?? nil) ?? false
    signal = ((try? c.decodeIfPresent(MonitorSignalDeclaration.self, forKey: .signal)) ?? nil)
      ?? MonitorSignalDeclaration()
    scopes = ((try? c.decodeIfPresent(MonitorScopePreferences.self, forKey: .scopes)) ?? nil)
      ?? MonitorScopePreferences()
    monitorLUT = (try? c.decodeIfPresent(MonitorLUTChoice.self, forKey: .monitorLUT)) ?? nil
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(Self.schemaVersion, forKey: .schemaVersion)
    try c.encode(toolsEnabled, forKey: .toolsEnabled)
    try c.encode(state.persisted, forKey: .state)
    try c.encode(signal, forKey: .signal)
    try c.encode(scopes, forKey: .scopes)
    try c.encodeIfPresent(monitorLUT, forKey: .monitorLUT)
  }

  /// What a surface of this target draws: the saved tools with Ultracam's
  /// rules applied. The master switch hides every tool; false colour
  /// suppresses zebra when the declared signal can show it
  /// (`falseColorDeclared`, MonitorTools' `effectiveZebraEnabled` on its
  /// normalized configuration); Program has no focus peaking and no log false
  /// colour, because its frames are not a camera's source signal.
  func surfaceState(isProgram: Bool, clean: Bool = false,
    magnification: Magnification = Magnification()) -> MonitorState {
    var value = state
    value.clean = clean
    value.geometry.magnification = magnification
    if !toolsEnabled {
      value.guides.enabled = false
      value.focus.enabled = false
      value.falseColor.mode = .off
      value.clipIndicators.enabled = false
    }
    if isProgram {
      value.focus.enabled = false
      if value.falseColor.mode.needsLogSource { value.falseColor.mode = .off }
    }
    // Suppress zebra only when false colour is actually drawn on this surface.
    // A Program cannot classify camera log encodings, so its log mode is turned
    // off above and zebra must remain available there.
    let suppressesZebra = value.falseColor.mode != .off &&
      (value.falseColor.mode.needsLogSource ? falseColorDeclared : true)
    if !toolsEnabled || suppressesZebra {
      for index in value.zebras.indices where value.zebras[index].enabled {
        value.zebras[index].enabled = false
      }
    }
    return value
  }

  /// Whether the false-colour mode can classify this target's declared signal,
  /// as MonitorTools' normalization decided: a log mode needs a declared camera
  /// profile it reads. A mode that cannot neither draws nor suppresses zebra.
  var falseColorDeclared: Bool {
    let profile = signal.logProfileID
    switch state.falseColor.mode {
    case .off: return false
    case .sonySLog3: return SonySLog3FalseColor.supports(sourceProfileID: profile)
    case .arriStyleSLog3: return SonyARRIStyleFalseColor.supports(sourceProfileID: profile)
    case .arriLogC: return profile.flatMap(ARRIFalseColorProfile.init(rawValue:)) != nil
    case .sixBand, .custom: return true
    }
  }

  /// Whether `mode` can show on a camera declared as `profile`
  /// (`falseColorDeclared` for that declaration). Off always can; on Program,
  /// whose frames are not a camera's source signal, no log mode can.
  static func falseColorModeIsAvailable(_ mode: FalseColorMode, profile: String?,
    isProgram: Bool = false) -> Bool {
    if mode == .off { return true }
    if isProgram && mode.needsLogSource { return false }
    var preferences = MonitorFeedPreferences()
    preferences.signal.logProfileID = profile
    preferences.state.falseColor.mode = mode
    return preferences.falseColorDeclared
  }

  /// The mode a false-colour toggle turns on for `profile`: Sony's Pattern 2 on
  /// S-Log3, ARRI's table on LogC, else the six display-IRE bands, which need no
  /// log source (always on Program).
  static func suggestedFalseColorMode(profile: String?, isProgram: Bool = false) -> FalseColorMode {
    if isProgram { return .sixBand }
    if SonySLog3FalseColor.supports(sourceProfileID: profile) { return .sonySLog3 }
    if profile.flatMap(ARRIFalseColorProfile.init(rawValue:)) != nil { return .arriLogC }
    return .sixBand
  }

  /// These preferences with the camera declared as `id` (the Camera log
  /// picker). False colour stays on: a log mode the new profile cannot show
  /// switches to the log mode it can; with none (or no declaration), it stays
  /// selected and explains itself. Modes that need no log source are untouched.
  func declaringCameraLog(_ id: String?) -> MonitorFeedPreferences {
    var next = self
    next.signal.logProfileID = id
    let mode = next.state.falseColor.mode
    if mode.needsLogSource, !Self.falseColorModeIsAvailable(mode, profile: id) {
      let suggested = Self.suggestedFalseColorMode(profile: id)
      if suggested.needsLogSource { next.state.falseColor.mode = suggested }
    }
    return next
  }

  /// Another camera is now on this feed: its signal declaration and exposure
  /// offset no longer apply. The false-colour mode stays selected: it shows
  /// nothing until a log source it reads is declared again (as in MonitorTools,
  /// whose normalization hid it the same way).
  mutating func forgetCameraCalibration() {
    signal = MonitorSignalDeclaration()
    state.falseColor.referenceOffsetStops = 0
  }

  /// "Reset monitor tools": every setting back to the defaults, the signal
  /// declaration included (resetting MonitorTools' configuration cleared it too).
  /// The monitor LUT and whether it shows stay.
  mutating func resetTools() {
    let lut = monitorLUT, lutEnabled = monitorLUTEnabled
    self = MonitorFeedPreferences()
    // The monitor LUT is this camera's file choice, not a tool (like the burn-in LUT).
    monitorLUT = lut
    monitorLUTEnabled = lutEnabled
  }

  /// "Copy settings from": `source`'s tools and scopes, settings MonitorTools
  /// cannot express included. This target keeps its own camera: the signal
  /// declaration, the exposure offset (map §5.3, `copySettings`) and the
  /// monitor LUT, shown or hidden as it was. A log
  /// false-colour mode this target's camera cannot show is turned off, as
  /// MonitorTools' copy did.
  mutating func copyTools(from source: MonitorFeedPreferences) {
    let offset = state.falseColor.referenceOffsetStops
    let lutEnabled = monitorLUTEnabled
    toolsEnabled = source.toolsEnabled
    state = source.state
    scopes = source.scopes
    state.falseColor.referenceOffsetStops = offset
    // The monitor LUT stays this camera's own, shown or hidden as it was.
    monitorLUTEnabled = lutEnabled
    if state.falseColor.mode.needsLogSource && !falseColorDeclared { state.falseColor.mode = .off }
  }

  /// Whether a surface of this target shows scopes.
  var scopesShown: Bool { toolsEnabled && scopes.enabled }

  /// These preferences as an old MonitorTools configuration (the shape the
  /// coordinator's legacy callbacks and the migration checks use). Normalized,
  /// except that a false-colour mode the declared signal cannot show stays
  /// selected, as it did in MonitorTools' session configuration after a camera
  /// change: its renderer normalized it away, and declaring the source again
  /// brought it back.
  var legacyConfiguration: LegacyMonitorConfiguration {
    var c = LegacyMonitorConfiguration()
    c.toolsEnabled = toolsEnabled
    c.guides.enabled = state.guides.enabled
    c.guides.thirds = state.guides.thirds
    c.guides.centerCross = state.guides.centerCross
    c.guides.safeArea = !state.guides.safeAreas.isEmpty
    c.guides.opacity = state.guides.opacity
    c.guides.contrast = state.guides.contrast
    let zebra = state.zebras.first ?? Self.defaultState.zebras[0]
    c.zebra.enabled = zebra.enabled
    c.zebra.thresholdIRE = zebra.level
    c.zebra.widthIRE = zebra.range * 2
    c.zebra.mode = zebra.mode == .band ? .band : .aboveThreshold
    c.zebra.opacity = zebra.opacity
    c.sourceProfileID = signal.logProfileID
    c.sourceCodeRange = signal.range.map { $0 == .full ? .full : .legal }
    c.sourceLogMapping = signal.transport == .fullRescaledToLegal ? .fullRescaledToLegal10Bit : .native10Bit
    switch state.falseColor.mode {
    case .sonySLog3:
      c.falseColor.mode = .sonySLog3
      c.falseColor.profileID = SonySLog3FalseColor.profileID
    case .arriLogC:
      c.falseColor.mode = .arri
      c.falseColor.profileID = signal.logProfileID.flatMap(ARRIFalseColorProfile.init(rawValue:))?.rawValue
      c.falseColor.specificationVersion = ARRIFalseColorProfile.specificationVersion
    case .off, .arriStyleSLog3, .sixBand, .custom:
      // MonitorTools can show none of these; its normalization folded the
      // ARRI-style S-Log3 mode into Sony's.
      c.falseColor.mode = .off
    }
    c.falseColor.referenceOffsetStops = state.falseColor.referenceOffsetStops
    c.focus.enabled = state.focus.enabled
    c.focus.color = LegacyMonitorConfiguration.PeakingColor(rawValue: state.focus.color.rawValue) ?? .red
    c.focus.sensitivity = state.focus.sensitivity
    c.focus.noiseRejection = state.focus.noiseRejection
    c.focus.opacity = state.focus.opacity
    c.scopes.enabled = scopes.enabled
    c.scopes.refreshHz = scopes.refreshHz
    c.scopes.mode = scopes.settings.kind == .waveform && scopes.settings.waveformMode == .luma
      ? .lumaWaveform : .rgbParade
    c.scopes.gain = scopes.settings.display.gain
    c.scopes.graticule = scopes.settings.display.showsGraticule
    c.pictureStage = state.pictureStage == .source ? .source : .processedOutput
    c.scopeStage = scopes.settings.stage == .source ? .source : .processedOutput
    var value = c.normalized()
    if value.falseColor.mode == .off && c.falseColor.mode != .off {
      value.falseColor.mode = c.falseColor.mode
      value.falseColor.profileID = c.falseColor.profileID
      value.falseColor.specificationVersion = c.falseColor.specificationVersion
    }
    return value
  }

  /// Takes every value of `legacy` that differs from what these preferences
  /// already describe (`legacyConfiguration`), field by field (map §5.3).
  /// Settings MonitorTools could not express (a second zebra, frame guides,
  /// several safe areas, display transforms, other scope kinds...) survive a
  /// change made in that shape.
  mutating func merge(_ newValue: LegacyMonitorConfiguration) {
    let new = newValue.normalized()
    let old = legacyConfiguration
    if new.toolsEnabled != old.toolsEnabled { toolsEnabled = new.toolsEnabled }

    if new.guides.enabled != old.guides.enabled { state.guides.enabled = new.guides.enabled }
    if new.guides.thirds != old.guides.thirds { state.guides.thirds = new.guides.thirds }
    if new.guides.centerCross != old.guides.centerCross {
      state.guides.centerCross = new.guides.centerCross
    }
    // The old overlay inset 5% per side: the 90% safe area.
    if new.guides.safeArea != old.guides.safeArea { state.guides.safeAreas = new.guides.safeArea ? [90] : [] }
    if new.guides.opacity != old.guides.opacity { state.guides.opacity = new.guides.opacity }
    if new.guides.contrast != old.guides.contrast { state.guides.contrast = new.guides.contrast }

    if state.zebras.isEmpty { state.zebras = Self.defaultState.zebras }
    if new.zebra.enabled != old.zebra.enabled { state.zebras[0].enabled = new.zebra.enabled }
    if new.zebra.thresholdIRE != old.zebra.thresholdIRE { state.zebras[0].level = new.zebra.thresholdIRE }
    // MonitorTools' width was the whole band, [t - w/2, t + w/2); MonitorKit's
    // range is the half-width, [level - range, level + range).
    if new.zebra.widthIRE != old.zebra.widthIRE { state.zebras[0].range = new.zebra.widthIRE / 2 }
    if new.zebra.mode != old.zebra.mode {
      state.zebras[0].mode = new.zebra.mode == .band ? .band : .lowerLimit
    }
    if new.zebra.opacity != old.zebra.opacity { state.zebras[0].opacity = new.zebra.opacity }

    // The picture stage first: MonitorTools' zebra measured the picture.
    if new.pictureStage != old.pictureStage {
      // MonitorTools' processed output is the source with the burn-in LUT:
      // MonitorKit's output stage ("Output (LUT)").
      state.pictureStage = new.pictureStage == .source ? .source : .output
      state.zebras[0].stage = new.pictureStage == .source ? .source : .output
    }

    // The signal declaration before false colour, which depends on it.
    if new.sourceProfileID != old.sourceProfileID { signal.logProfileID = new.sourceProfileID }
    if new.sourceCodeRange != old.sourceCodeRange {
      signal.range = new.sourceCodeRange.map { $0 == .full ? .full : .legal }
    }
    if new.sourceLogMapping != old.sourceLogMapping {
      signal.transport = new.sourceLogMapping == .fullRescaledToLegal10Bit ? .fullRescaledToLegal : .native
    }

    if new.falseColor.mode != old.falseColor.mode || new.falseColor.profileID != old.falseColor.profileID {
      switch new.falseColor.mode {
      // EL Zone is gone (`normalized()` turns it off); its blob still reads.
      case .off, .elZone: state.falseColor.mode = .off
      case .sonySLog3: state.falseColor.mode = .sonySLog3
      case .arri:
        // `normalized()` kept a literal ARRI mode only for a matching LogC
        // source at EI 800; the profile is now the declared signal's.
        let profile = new.falseColor.profileID.flatMap(ARRIFalseColorProfile.init(rawValue:))
        if let profile, new.sourceProfileID == profile.rawValue {
          state.falseColor.mode = .arriLogC
          signal.logProfileID = profile.rawValue
        } else {
          state.falseColor.mode = .off
        }
      }
    }
    if new.falseColor.referenceOffsetStops != old.falseColor.referenceOffsetStops {
      state.falseColor.referenceOffsetStops = new.falseColor.referenceOffsetStops
    }

    if new.focus.enabled != old.focus.enabled { state.focus.enabled = new.focus.enabled }
    if new.focus.color != old.focus.color {
      state.focus.color = PeakingColor(rawValue: new.focus.color.rawValue) ?? .red
    }
    if new.focus.sensitivity != old.focus.sensitivity { state.focus.sensitivity = new.focus.sensitivity }
    if new.focus.noiseRejection != old.focus.noiseRejection {
      state.focus.noiseRejection = new.focus.noiseRejection
    }
    if new.focus.opacity != old.focus.opacity { state.focus.opacity = new.focus.opacity }

    if new.scopes.enabled != old.scopes.enabled { scopes.enabled = new.scopes.enabled }
    if new.scopes.refreshHz != old.scopes.refreshHz { scopes.refreshHz = new.scopes.refreshHz }
    if new.scopes.mode != old.scopes.mode {
      scopes.settings.kind = .waveform
      scopes.settings.waveformMode = new.scopes.mode == .lumaWaveform ? .luma : .rgbParade
    }
    if new.scopes.gain != old.scopes.gain { scopes.settings.display.gain = new.scopes.gain }
    if new.scopes.graticule != old.scopes.graticule {
      scopes.settings.display.showsGraticule = new.scopes.graticule
    }
    if new.scopeStage != old.scopeStage {
      scopes.settings.stage = new.scopeStage == .source ? .source : .output
    }
    // MonitorKit's ranges (a ±6 stop offset) apply from here on.
    state = state.normalized()
    scopes.settings = scopes.settings.normalized()
  }
}

extension MonitorState {
  /// This state without what belongs to one surface: Clean View and magnification.
  var persisted: MonitorState {
    guard clean || geometry.magnification != Magnification() else { return self }
    var value = self
    value.clean = false
    value.geometry.magnification = Magnification()
    return value
  }
}

/// A camera's monitor-only LUT file: its read-only security-scoped bookmark
/// (as saved for the burn-in LUT; the contents are never persisted) and the
/// file name the interface shows while the bookmark is not resolved.
struct MonitorLUTChoice: Codable, Equatable, Sendable {
  var bookmark: Data
  var fileName: String
  /// One choice of the file in the interface. Bookmarks for the same file are
  /// byte-identical (also after it is edited in place), so choosing it again
  /// gets a new pick: the preferences change and the feed host reads the file
  /// again. Saved, so a relaunch does not reload; nil in older saves.
  var pick: UUID?

  init(bookmark: Data, fileName: String, pick: UUID? = nil) {
    self.bookmark = bookmark
    self.fileName = fileName
    self.pick = pick
  }

  private enum CodingKeys: String, CodingKey { case bookmark, fileName, pick }

  /// Throws without a bookmark; a missing name reads as empty.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    bookmark = try c.decode(Data.self, forKey: .bookmark)
    guard !bookmark.isEmpty else {
      throw DecodingError.dataCorruptedError(forKey: .bookmark, in: c, debugDescription: "empty bookmark")
    }
    fileName = ((try? c.decodeIfPresent(String.self, forKey: .fileName)) ?? nil) ?? ""
    pick = (try? c.decodeIfPresent(UUID.self, forKey: .pick)) ?? nil
  }
}

/// How a target's frames are to be read, declared by the user per feed.
/// Everything left nil comes from the frame's own attachments.
struct MonitorSignalDeclaration: Codable, Equatable, Sendable {
  /// A camera log profile (`LogEncoding.profileID`, e.g.
  /// "sony-slog3-sgamut3cine"); nil reads the transfer from the frame's tags.
  var logProfileID: String?
  /// The code range; nil takes it from the pixel format.
  var range: CodeRange?
  /// How the camera's log codes were carried.
  var transport: LogTransport = .native

  init(logProfileID: String? = nil, range: CodeRange? = nil, transport: LogTransport = .native) {
    self.logProfileID = logProfileID
    self.range = range
    self.transport = transport
  }

  /// The declared log encoding, nil when none (or an unknown profile) is declared.
  var logEncoding: LogEncoding? { logProfileID.flatMap { LogEncoding(profileID: $0, transport: transport) } }

  /// `signal` with this declaration applied.
  func applied(to signal: SignalDescription) -> SignalDescription {
    var value = signal
    if let range { value.range = range }
    if let logEncoding { value.encoding = .log(logEncoding) }
    return value
  }

  private enum CodingKeys: String, CodingKey { case logProfileID, range, transport }
  init(from decoder: Decoder) throws {
    self.init()
    guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
    logProfileID = (try? c.decodeIfPresent(String.self, forKey: .logProfileID)) ?? nil
    range = (try? c.decodeIfPresent(CodeRange.self, forKey: .range)) ?? nil
    transport = ((try? c.decodeIfPresent(LogTransport.self, forKey: .transport)) ?? nil) ?? .native
  }
}

/// Scope scheduling and look for one target. MonitorKit leaves scheduling to the host.
struct MonitorScopePreferences: Codable, Equatable, Sendable {
  static let refreshRates = [10, 15, 30]
  var enabled = false
  /// Scope redraws per second: 10, 15 or 30.
  var refreshHz = 15
  /// MonitorTools' look by default: an RGB parade of the output, 768 × 256, −10…110 IRE.
  var settings = ScopeSettings.plainWaveform()

  init(enabled: Bool = false, refreshHz: Int = 15, settings: ScopeSettings = .plainWaveform()) {
    self.enabled = enabled
    self.refreshHz = Self.refreshRates.contains(refreshHz) ? refreshHz : 15
    self.settings = settings
  }

  private enum CodingKeys: String, CodingKey { case enabled, refreshHz, settings }
  init(from decoder: Decoder) throws {
    self.init()
    guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
    enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? false
    let rate = ((try? c.decodeIfPresent(Int.self, forKey: .refreshHz)) ?? nil) ?? 15
    refreshHz = Self.refreshRates.contains(rate) ? rate : 15
    settings = ((try? c.decodeIfPresent(ScopeSettings.self, forKey: .settings)) ?? nil) ?? .plainWaveform()
    // MonitorKit 0.1.0 renamed the trace palette "ultracamLegacy" to "plain"
    // and reads a name it does not know as standard; a scope saved by an older
    // build keeps its plain colours (the Classic look). Saved again as "plain".
    let saved = (try? c.decodeIfPresent(SavedScopePalette.self, forKey: .settings)) ?? nil
    if saved?.display?.palette == "ultracamLegacy" { settings.display.palette = .plain }
  }

  /// Only the palette name of saved scope settings, as written.
  private struct SavedScopePalette: Decodable {
    struct Display: Decodable { var palette: String? }
    var display: Display?
  }
}

/// The monitor workspace: layout, tile bindings and split. The same JSON as
/// MonitorTools' `MonitorWorkspaceState`; a binding is a target's raw ID (a
/// feed ID or "program").
struct MonitorWorkspacePreferences: Codable, Equatable, Sendable {
  enum Layout: String, Codable, Sendable, CaseIterable {
    case single, sideBySide, fourUp
    var tileCount: Int {
      switch self {
      case .single: return 1
      case .sideBySide: return 2
      case .fourUp: return 4
      }
    }
  }

  var schemaVersion = 1
  var isConfigured = false
  var layout: Layout = .single
  var tileBindings: [String?] = [nil, nil, nil, nil]
  var splitRatio = 0.5
  init() {}

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, isConfigured, layout, tileBindings, splitRatio
  }
  init(from decoder: Decoder) throws {
    self.init()
    do {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
      guard schemaVersion == 1 else {
        self = MonitorWorkspacePreferences()
        return
      }
      isConfigured = try c.decodeIfPresent(Bool.self, forKey: .isConfigured) ?? false
      layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? .single
      tileBindings = try c.decodeIfPresent([String?].self, forKey: .tileBindings) ?? tileBindings
      if tileBindings.count < 4 {
        tileBindings += Array(repeating: nil, count: 4 - tileBindings.count)
      }
      splitRatio = try c.decodeIfPresent(Double.self, forKey: .splitRatio) ?? 0.5
      splitRatio = normalizedSplitRatio
    } catch {
      self = MonitorWorkspacePreferences()
    }
  }

  var normalizedSplitRatio: Double {
    splitRatio.isFinite ? min(0.8, max(0.2, splitRatio)) : 0.5
  }
}

/// A JSON value kept exactly as it was read, so a blob this version no longer
/// interprets (the MonitorTools `monitorConfiguration`) is written back
/// unchanged and an older build still finds it.
enum PreservedJSON: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([PreservedJSON])
  case object([String: PreservedJSON])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let value = try? c.decode(Bool.self) { self = .bool(value) }
    else if let value = try? c.decode(Int64.self) { self = .integer(value) }
    else if let value = try? c.decode(Double.self) { self = .number(value) }
    else if let value = try? c.decode(String.self) { self = .string(value) }
    else if let value = try? c.decode([PreservedJSON].self) { self = .array(value) }
    else { self = .object(try c.decode([String: PreservedJSON].self)) }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let value): try c.encode(value)
    case .integer(let value): try c.encode(value)
    case .number(let value): try c.encode(value)
    case .string(let value): try c.encode(value)
    case .array(let value): try c.encode(value)
    case .object(let value): try c.encode(value)
    }
  }
}

extension KeyedDecodingContainer {
  /// The preferences under `key`; else those migrated from the MonitorTools
  /// configuration under `legacyKey`; else the defaults. Never throws, and
  /// never reads the old blob as a `MonitorState` (map §5.2).
  func monitorPreferences(_ key: Key, legacy legacyKey: Key) -> MonitorFeedPreferences {
    if let value = (try? decodeIfPresent(MonitorFeedPreferences.self, forKey: key)) ?? nil { return value }
    if let legacy = (try? decodeIfPresent(LegacyMonitorConfiguration.self, forKey: legacyKey)) ?? nil {
      return MonitorFeedPreferences(migrating: legacy)
    }
    return MonitorFeedPreferences()
  }

  /// The JSON under `key` as it was, or nil.
  func preservedJSON(_ key: Key) -> PreservedJSON? {
    guard contains(key), let value = try? decode(PreservedJSON.self, forKey: key), value != .null else {
      return nil
    }
    return value
  }
}

/// MonitorTools' `MonitorConfiguration` (MonitorToolsCore/MonitorConfiguration.swift),
/// copied verbatim with its nested types and `normalized()`, to read saved
/// settings without importing MonitorTools. Read only to migrate.
struct LegacyMonitorConfiguration: Codable, Equatable, Sendable {
  enum SourceLogMapping: String, Codable, Sendable, CaseIterable {
    case native10Bit, fullRescaledToLegal10Bit
  }
  enum CodeRange: String, Codable, Sendable { case full, legal }
  enum Stage: String, Codable, Sendable, CaseIterable { case source, processedOutput }
  /// `elZone` stays so an old blob that chose it still reads (as off, see
  /// `normalized()`) instead of failing and losing every other setting.
  enum FalseColorMode: String, Codable, Sendable, CaseIterable {
    case off, elZone, sonySLog3, arri
  }
  enum ScopeMode: String, Codable, Sendable, CaseIterable {
    case rgbParade, lumaWaveform
  }
  enum ZebraMode: String, Codable, Sendable, CaseIterable { case aboveThreshold, band }
  enum PeakingColor: String, Codable, Sendable, CaseIterable {
    case red, green, blue, yellow, white
  }
  struct GuideSettings: Codable, Equatable, Sendable {
    var enabled = false
    var thirds = true
    var centerCross = false
    var safeArea = false
    var opacity = 0.65
    var contrast = 1.0
    init() {}
    private enum CodingKeys: String, CodingKey {
      case enabled, thirds, centerCross, safeArea, opacity, contrast
    }
    init(from decoder: Decoder) throws {
      self.init()
      let c = try decoder.container(keyedBy: CodingKeys.self)
      enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
      thirds = try c.decodeIfPresent(Bool.self, forKey: .thirds) ?? thirds
      centerCross = try c.decodeIfPresent(Bool.self, forKey: .centerCross) ?? centerCross
      safeArea = try c.decodeIfPresent(Bool.self, forKey: .safeArea) ?? safeArea
      opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
      contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
    }
  }
  struct ZebraSettings: Codable, Equatable, Sendable {
    var enabled = false
    var thresholdIRE = 95.0
    var widthIRE = 5.0
    var mode: ZebraMode = .aboveThreshold
    var opacity = 0.65
    init() {}
    private enum CodingKeys: String, CodingKey { case enabled, thresholdIRE, widthIRE, mode, opacity }
    init(from decoder: Decoder) throws {
      self.init()
      let c = try decoder.container(keyedBy: CodingKeys.self)
      enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
      thresholdIRE = try c.decodeIfPresent(Double.self, forKey: .thresholdIRE) ?? thresholdIRE
      widthIRE = try c.decodeIfPresent(Double.self, forKey: .widthIRE) ?? widthIRE
      mode = try c.decodeIfPresent(ZebraMode.self, forKey: .mode) ?? mode
      opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
    }
  }
  struct FalseColorSettings: Codable, Equatable, Sendable {
    var mode: FalseColorMode = .off
    var profileID: String?
    var specificationVersion: String?
    var exposureIndex = 800
    var referenceOffsetStops = 0.0
    init() {}
    private enum CodingKeys: String, CodingKey {
      case mode, profileID, specificationVersion, exposureIndex, referenceOffsetStops
    }
    init(from decoder: Decoder) throws {
      self.init()
      let c = try decoder.container(keyedBy: CodingKeys.self)
      mode = try c.decodeIfPresent(FalseColorMode.self, forKey: .mode) ?? mode
      profileID = try c.decodeIfPresent(String.self, forKey: .profileID) ?? profileID
      specificationVersion =
        try c.decodeIfPresent(String.self, forKey: .specificationVersion) ?? specificationVersion
      exposureIndex = try c.decodeIfPresent(Int.self, forKey: .exposureIndex) ?? exposureIndex
      referenceOffsetStops =
        try c.decodeIfPresent(Double.self, forKey: .referenceOffsetStops) ?? referenceOffsetStops
    }
  }
  struct FocusSettings: Codable, Equatable, Sendable {
    var enabled = false
    var color: PeakingColor = .red
    var sensitivity = 0.5
    var noiseRejection = 0.02
    var opacity = 0.85
    init() {}
    private enum CodingKeys: String, CodingKey {
      case enabled, color, sensitivity, noiseRejection, opacity
    }
    init(from decoder: Decoder) throws {
      self.init()
      let c = try decoder.container(keyedBy: CodingKeys.self)
      enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
      color = try c.decodeIfPresent(PeakingColor.self, forKey: .color) ?? color
      sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? sensitivity
      noiseRejection = try c.decodeIfPresent(Double.self, forKey: .noiseRejection) ?? noiseRejection
      opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
    }
  }
  struct ScopeSettings: Codable, Equatable, Sendable {
    var enabled = false
    var mode: ScopeMode = .rgbParade
    var gain = 1.0
    var graticule = true
    var refreshHz = 15
    init() {}
    private enum CodingKeys: String, CodingKey { case enabled, mode, gain, graticule, refreshHz }
    init(from decoder: Decoder) throws {
      self.init()
      let c = try decoder.container(keyedBy: CodingKeys.self)
      enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
      mode = try c.decodeIfPresent(ScopeMode.self, forKey: .mode) ?? mode
      gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? gain
      graticule = try c.decodeIfPresent(Bool.self, forKey: .graticule) ?? graticule
      refreshHz = try c.decodeIfPresent(Int.self, forKey: .refreshHz) ?? refreshHz
    }
  }

  var schemaVersion = 1
  var toolsEnabled = false
  var guides = GuideSettings()
  var zebra = ZebraSettings()
  var falseColor = FalseColorSettings()
  var focus = FocusSettings()
  var scopes = ScopeSettings()
  var pictureStage: Stage = .processedOutput
  var scopeStage: Stage = .processedOutput
  var sourceProfileID: String?
  var sourceCodeRange: CodeRange?
  var sourceLogMapping: SourceLogMapping = .native10Bit
  init() {}
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, toolsEnabled, guides, zebra, falseColor, focus, scopes, pictureStage,
      scopeStage, sourceProfileID, sourceCodeRange, sourceLogMapping
  }
  init(from decoder: Decoder) throws {
    self.init()
    do {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
      guard schemaVersion == 1 else {
        self = LegacyMonitorConfiguration()
        return
      }
      toolsEnabled = try c.decodeIfPresent(Bool.self, forKey: .toolsEnabled) ?? false
      guides = try c.decodeIfPresent(GuideSettings.self, forKey: .guides) ?? guides
      zebra = try c.decodeIfPresent(ZebraSettings.self, forKey: .zebra) ?? zebra
      falseColor =
        try c.decodeIfPresent(FalseColorSettings.self, forKey: .falseColor) ?? falseColor
      focus = try c.decodeIfPresent(FocusSettings.self, forKey: .focus) ?? focus
      scopes = try c.decodeIfPresent(ScopeSettings.self, forKey: .scopes) ?? scopes
      pictureStage = try c.decodeIfPresent(Stage.self, forKey: .pictureStage) ?? pictureStage
      scopeStage = try c.decodeIfPresent(Stage.self, forKey: .scopeStage) ?? scopeStage
      sourceProfileID = try c.decodeIfPresent(String.self, forKey: .sourceProfileID)
      sourceCodeRange = try c.decodeIfPresent(CodeRange.self, forKey: .sourceCodeRange)
      sourceLogMapping =
        try c.decodeIfPresent(SourceLogMapping.self, forKey: .sourceLogMapping)
        ?? .native10Bit
      self = normalized()
    } catch {
      // A monitor preference must never invalidate the containing feed/camera preferences.
      self = LegacyMonitorConfiguration()
    }
  }
  /// Safe immutable snapshot for persistence and shader parameter construction.
  func normalized() -> LegacyMonitorConfiguration {
    guard schemaVersion == 1 else { return LegacyMonitorConfiguration() }
    var value = self
    func bounded(_ input: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
      input.isFinite ? min(range.upperBound, max(range.lowerBound, input)) : fallback
    }
    value.guides.opacity = bounded(guides.opacity, 0...1, fallback: 0.65)
    value.guides.contrast = bounded(guides.contrast, 0...1, fallback: 1)
    value.zebra.opacity = bounded(zebra.opacity, 0...1, fallback: 0.65)
    value.zebra.thresholdIRE = bounded(zebra.thresholdIRE, -20...120, fallback: 95)
    value.zebra.widthIRE = bounded(zebra.widthIRE, 0...30, fallback: 5)
    value.focus.sensitivity = bounded(focus.sensitivity, 0...1, fallback: 0.5)
    value.focus.noiseRejection = bounded(focus.noiseRejection, 0...1, fallback: 0.02)
    value.focus.opacity = bounded(focus.opacity, 0...1, fallback: 0.85)
    value.scopes.gain = bounded(scopes.gain, 0.25...4, fallback: 1)
    value.scopes.refreshHz = [10, 15, 30].contains(scopes.refreshHz) ? scopes.refreshHz : 15
    value.falseColor.referenceOffsetStops = bounded(
      falseColor.referenceOffsetStops, -10...10, fallback: 0)
    value.falseColor.exposureIndex = min(12800, max(100, falseColor.exposureIndex))
    if value.falseColor.mode == .arri,
      value.falseColor.profileID == SonyARRIStyleFalseColor.profileID
    {
      value.falseColor.mode = .sonySLog3
      value.falseColor.profileID = SonySLog3FalseColor.profileID
      value.falseColor.specificationVersion = SonySLog3FalseColor.specificationVersion
    }
    if value.falseColor.mode == .sonySLog3 {
      if !SonySLog3FalseColor.supports(sourceProfileID: sourceProfileID)
        || (value.falseColor.profileID != nil
          && value.falseColor.profileID != SonySLog3FalseColor.profileID)
      {
        value.falseColor.mode = .off
      } else {
        value.falseColor.profileID = SonySLog3FalseColor.profileID
        value.falseColor.specificationVersion = SonySLog3FalseColor.specificationVersion
      }
    }
    // Ultracam no longer has EL Zone false colour: a saved EL Zone selection
    // (profile "ultracam-elzone-public-chart-v1" or the public chart's
    // "elzone-panasonic-varicam-fw9-public-chart") reads as off, and the rest
    // of the configuration is kept.
    if value.falseColor.mode == .elZone {
      value.falseColor.mode = .off
      value.falseColor.profileID = nil
      value.falseColor.specificationVersion = nil
    }
    if value.falseColor.mode == .arri, let profile = value.falseColor.profileID {
      if profile == SonyARRIStyleFalseColor.profileID {
        // EI800 belongs to the fixed reference transform, not the source camera.
        if !SonyARRIStyleFalseColor.supports(sourceProfileID: sourceProfileID) {
          value.falseColor.mode = .off
        }
      } else if ARRIFalseColorProfile(rawValue: profile) == nil || sourceProfileID != profile
        || falseColor.exposureIndex != 800
      {
        value.falseColor.mode = .off
      }
    }
    return value
  }
}
