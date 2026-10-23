import MonitorKit
import MonitorKitCore
import SwiftUI

/// A tool on a monitor tile's toolbar.
///
/// Most edit `MonitorState`. Scopes and Freeze belong to the host (the scope
/// settings and the freeze state machine live there), so the toolbar reports
/// them through callbacks and shows the state the host passes in.
public enum MonitorTileTool: String, CaseIterable, Sendable, Identifiable {
  case guides, zebra, falseColor, focusPeaking, clipIndicators, scopes, magnify, clean, freeze

  public var id: String { rawValue }

  /// The tools a tile shows by default, in order. Scopes and Freeze appear only
  /// when the host handles them.
  public static let standard: [MonitorTileTool] = [
    .guides, .zebra, .falseColor, .focusPeaking, .scopes, .magnify, .freeze,
  ]

  public var title: String {
    switch self {
    case .guides: return "Guides"
    case .zebra: return "Zebra"
    case .falseColor: return "False Colour"
    case .focusPeaking: return "Focus Peaking"
    case .clipIndicators: return "Clip Indicators"
    case .scopes: return "Scopes"
    case .magnify: return "Magnify"
    case .clean: return "Clean"
    case .freeze: return "Freeze"
    }
  }

  /// An SF Symbol name.
  public var systemImage: String {
    switch self {
    case .guides: return "squareshape.split.3x3"
    case .zebra: return "line.diagonal"
    case .falseColor: return "paintpalette"
    case .focusPeaking: return "scope"
    case .clipIndicators: return "exclamationmark.triangle"
    case .scopes: return "waveform.path.ecg"
    case .magnify: return "plus.magnifyingglass"
    case .clean: return "eye.slash"
    case .freeze: return "snowflake"
    }
  }

  /// The surface status entries that say why the tool, while on, is not drawn.
  var statusTools: [MonitorTool] {
    switch self {
    case .guides: return [.guides]
    case .zebra: return [.zebra1, .zebra2]
    case .falseColor: return [.falseColor]
    case .focusPeaking: return [.focusPeaking]
    case .clipIndicators: return [.clipIndicators]
    case .magnify: return [.magnification]
    case .scopes, .clean, .freeze: return []
    }
  }

  /// Whether the tool is on in `state`; nil for Scopes and Freeze, which the host owns.
  public func isOn(in state: MonitorState) -> Bool? {
    switch self {
    case .guides: return state.guides.enabled
    case .zebra:
      var i = 0
      while i < state.zebras.count {
        if state.zebras[i].enabled { return true }
        i += 1
      }
      return false
    case .falseColor: return state.falseColor.mode != .off
    case .focusPeaking: return state.focus.enabled
    case .clipIndicators: return state.clipIndicators.enabled
    case .magnify: return state.geometry.magnification.isActive
    case .clean: return state.clean
    case .scopes, .freeze: return nil
    }
  }

  /// `state` with the tool switched, normalized; nil for Scopes and Freeze.
  ///
  /// - Zebra on turns on the first set; off turns both off.
  /// - False colour on selects `falseColorMode` (`.off` selects `.sixBand`,
  ///   which needs no log source).
  /// - Magnify on applies `magnify`; off returns to fit.
  public func toggled(
    _ state: MonitorState, falseColorMode: FalseColorMode = .sixBand, magnify: MonitorMagnifyChoice = .zoom(2)
  ) -> MonitorState? {
    guard let on = isOn(in: state) else { return nil }
    var s = state.normalized()
    switch self {
    case .guides: s.guides.enabled = !on
    case .zebra:
      var i = 0
      while i < s.zebras.count {
        s.zebras[i].enabled = !on && i == 0
        i += 1
      }
    case .falseColor: s.falseColor.mode = on ? .off : (falseColorMode == .off ? .sixBand : falseColorMode)
    case .focusPeaking: s.focus.enabled = !on
    case .clipIndicators: s.clipIndicators.enabled = !on
    case .magnify:
      s.geometry.magnification =
        on
        ? MonitorMagnifier.reset(s.geometry.magnification)
        : (magnify == .fit ? MonitorMagnifyChoice.zoom(2) : magnify).applied(to: s.geometry.magnification)
    case .clean: s.clean = !on
    case .scopes, .freeze: return nil
    }
    return s.normalized()
  }

  /// The false-colour mode a tile turns on when none was chosen before: Sony
  /// Pattern 2 on S-Log3 (any gamut: its thresholds are native S-Log3 IRE, the
  /// rule the pass draws by), the ARRI table on LogC3 or LogC4, otherwise the
  /// six display-IRE bands, which need no log source.
  public static func suggestedFalseColorMode(for signal: SignalDescription?) -> FalseColorMode {
    guard let log = signal?.encoding.log else { return .sixBand }
    switch log.curve {
    case .sLog3: return .sonySLog3
    case .arriLogC3, .arriLogC4: return .arriLogC
    }
  }

  /// Whether the pass classifies `mode` on `signal`, by its source rule
  /// (`MonitorPass.resolveFalseColor`): Sony Pattern 2 on S-Log3 in any gamut,
  /// EL Zone and the ARRI-style bands on S-Log3 in S-Gamut3 or S-Gamut3.Cine
  /// (`FalseColorLegend.classifies`), the ARRI table on a curve it has a
  /// literal table for (`FalseColorTable.arriProfile`). Six band and custom
  /// need no log source. Without a signal nothing is judged (true).
  static func draws(_ mode: FalseColorMode, on signal: SignalDescription?) -> Bool {
    guard let signal else { return true }
    let log = signal.encoding.log
    guard FalseColorLegend.classifies(mode, log: log) else { return false }
    if mode == .arriLogC { return log.flatMap { FalseColorTable.arriProfile(for: $0.curve) } != nil }
    return true
  }

  /// The mode a false-colour toggle turns on: `remembered` when `signal` can
  /// draw it and the host allows it, else the signal's suggestion when allowed,
  /// else six band, else the first other allowed mode; nil when none is.
  /// `allowed` nil allows every mode.
  static func falseColorModeToTurnOn(
    remembered: FalseColorMode?, signal: SignalDescription?, allowed: [FalseColorMode]?
  ) -> FalseColorMode? {
    func isAllowed(_ m: FalseColorMode) -> Bool { m != .off && (allowed?.contains(m) ?? true) }
    if let remembered, isAllowed(remembered), draws(remembered, on: signal) { return remembered }
    let suggested = suggestedFalseColorMode(for: signal)
    if isAllowed(suggested) { return suggested }
    if isAllowed(.sixBand) { return .sixBand }
    return FalseColorMode.allCases.first { isAllowed($0) && draws($0, on: signal) }
      ?? FalseColorMode.allCases.first(where: isAllowed)
  }

  /// The false-colour modes a menu lists: `.off`, then the `allowed` ones in
  /// `FalseColorMode` order (nil: all), plus `current` when it is not one of
  /// them, so a restored or host-set mode keeps its tag.
  public static func falseColorChoices(allowed: [FalseColorMode]?, current: FalseColorMode) -> [FalseColorMode] {
    var out: [FalseColorMode] = []
    for m in FalseColorMode.allCases where m == .off || m == current || (allowed?.contains(m) ?? true) {
      out.append(m)
    }
    return out
  }
}

/// The host's freeze state, which the Freeze button shows.
public enum MonitorFreezeState: String, Sendable, CaseIterable {
  /// Live picture.
  case live
  /// A freeze is requested and waits for the next frame.
  case pending
  /// The picture is frozen.
  case frozen

  /// What the picture is, for VoiceOver: "Live", "Freeze pending" (still
  /// live, waiting for the next frame), "Frozen".
  public var accessibilityValue: String {
    switch self {
    case .live: return "Live"
    case .pending: return "Freeze pending"
    case .frozen: return "Frozen"
    }
  }

  /// What pressing the button does: "Freeze", "Cancel Freeze", "Unfreeze".
  public var actionTitle: String {
    switch self {
    case .live: return "Freeze"
    case .pending: return "Cancel Freeze"
    case .frozen: return "Unfreeze"
    }
  }
}

/// A magnification a tile offers.
public enum MonitorMagnifyChoice: Hashable, Sendable {
  /// The whole picture.
  case fit
  /// One picture pixel per display pixel.
  case pixelExact
  /// A zoom factor over fit.
  case zoom(Double)

  /// Fit, 1:1 and the zooms both devices' magnify buttons step through.
  public static let standard: [MonitorMagnifyChoice] = [.fit, .pixelExact, .zoom(2), .zoom(4), .zoom(8)]

  /// The choice `m` shows.
  public init(_ m: Magnification) {
    if m.pixelExact {
      self = .pixelExact
    } else if m.zoom > 1 {
      self = .zoom(m.zoom)
    } else {
      self = .fit
    }
  }

  /// `m` at this choice; the centre and navigator stay (fit recentres).
  public func applied(to m: Magnification) -> Magnification {
    var v = m
    switch self {
    case .fit: return MonitorMagnifier.reset(m)
    case .pixelExact: v.pixelExact = true
    case .zoom(let z):
      v.pixelExact = false
      let range = MonitorMagnifier.zoomRange
      v.zoom = z.isFinite ? min(range.upperBound, max(range.lowerBound, z)) : 1
    }
    return v
  }

  public var title: String {
    switch self {
    case .fit: return "Fit"
    case .pixelExact: return "1:1"
    case .zoom(let z): return MonitorFormat.zoom(z)
    }
  }

  /// The standard choices, plus `current` when it is not one of them (a pinch zoom).
  public static func choices(current: MonitorMagnifyChoice) -> [MonitorMagnifyChoice] {
    standard.contains(current) ? standard : standard + [current]
  }
}

/// Where a tile toolbar sits.
public enum MonitorTileToolbarPlacement: Sendable, Equatable {
  /// In window chrome: a system material that follows the light or dark appearance.
  case chrome
  /// Over the picture: a dark capsule in the dark appearance, readable over any video.
  case overPicture

  /// The appearance the bar forces; nil follows the system.
  public var forcedColorScheme: ColorScheme? { self == .overPicture ? .dark : nil }
}

/// What a toolbar remembers between toggles: the false-colour mode and the
/// magnification to turn back on. Pure, so the toggles are testable without a view.
struct MonitorTileMemory: Equatable {
  var falseColor: FalseColorMode?
  var magnify: MonitorMagnifyChoice = .zoom(2)

  /// Toggles `tool` in `state`, remembering what it turns off. False colour
  /// turns back on with the remembered mode only when `signal` can draw it and
  /// it is `allowedFalseColor` (nil: every mode); otherwise with the signal's
  /// suggestion, or six band (`MonitorTileTool.falseColorModeToTurnOn`).
  mutating func toggle(
    _ tool: MonitorTileTool, in state: inout MonitorState, signal: SignalDescription?,
    allowedFalseColor: [FalseColorMode]? = nil
  ) {
    switch tool {
    case .falseColor:
      if state.falseColor.mode != .off {
        falseColor = state.falseColor.mode
        if let next = tool.toggled(state) { state = next }
        return
      }
      guard
        let mode = MonitorTileTool.falseColorModeToTurnOn(
          remembered: falseColor, signal: signal, allowed: allowedFalseColor)
      else { return }
      if let next = tool.toggled(state, falseColorMode: mode) { state = next }
    case .magnify:
      let current = MonitorMagnifyChoice(state.geometry.magnification)
      if current != .fit { magnify = current }
      if let next = tool.toggled(state, magnify: magnify) { state = next }
    default:
      if let next = tool.toggled(state) { state = next }
    }
  }

  /// A mode picked from a menu: stored, and remembered when it is not off.
  mutating func select(_ mode: FalseColorMode, in state: inout MonitorState) {
    if mode != .off { falseColor = mode }
    var s = state
    s.falseColor.mode = mode
    state = s.normalized()
  }
}

/// A compact toolbar for a monitor tile: a split button per tool (the icon
/// toggles it, the chevron opens its settings), collapsing into one menu when
/// the tile is too narrow. It edits `MonitorState` through the binding, using
/// the library's controls (`GuideControls`, `ZebraControls`,
/// `FalseColorControls`, `PeakingControls`, `ClipIndicatorControls`,
/// `GeometryControls`) for the settings, and hands Scopes and Freeze to the host.
///
/// `unavailable` disables tools for this tile with the reason as help (for
/// example focus peaking on a programme feed); `falseColorModes` narrows false
/// colour to some modes (on a programme feed, the ones that need no log
/// source: `FalseColorMode.allCases.filter { !$0.needsLogSource }`); `status`
/// marks a tool that is on but not drawn. In `.chrome` placement it uses system
/// materials and label colours, so it follows the light or dark appearance.
public struct MonitorTileToolbar<ScopeSettingsContent: View>: View {
  @Binding var state: MonitorState
  let name: String
  let signal: SignalDescription?
  let status: MonitorStatus?
  let tools: [MonitorTileTool]
  let unavailable: [MonitorTileTool: String]
  let falseColorModes: [FalseColorMode]?
  let layout: PixelLayout?
  let placement: MonitorTileToolbarPlacement
  let scopesEnabled: Bool
  let onScopes: (@MainActor (Bool) -> Void)?
  let freeze: MonitorFreezeState
  let onFreeze: (@MainActor () -> Void)?
  let scopeSettings: ScopeSettingsContent
  @State private var openTool: MonitorTileTool?
  /// Whether `openTool` was opened from the collapsed menu, whose label then
  /// anchors the popover (the bar's buttons are not on screen).
  @State private var openFromMenu = false
  @State private var memory = MonitorTileMemory()

  /// - Parameters:
  ///   - state: the tile's monitor state.
  ///   - name: the tile's source, for help and VoiceOver ("Monitor tools for Camera 1").
  ///   - signal: the shown signal; picks the false-colour mode to suggest and the legend's table.
  ///   - status: the surface's status; marks tools that are on but not drawn.
  ///   - tools: the tools to show, in order.
  ///   - unavailable: tools disabled on this tile, with the reason.
  ///   - falseColorModes: the false-colour modes this tile offers and turns on
  ///     (`.off` is always offered); nil offers every mode.
  ///   - layout: the shown frame's pixel layout; picks the ARRI legend's range
  ///     as the pass does (a float container classifies full range).
  ///   - scopesEnabled, onScopes: the host's scope switch; no Scopes button without `onScopes`.
  ///   - freeze, onFreeze: the host's freeze state and toggle; no Freeze button without `onFreeze`.
  ///   - scopeSettings: the host's scope settings, shown from the Scopes chevron.
  public init(
    state: Binding<MonitorState>, name: String = "", signal: SignalDescription? = nil, status: MonitorStatus? = nil,
    tools: [MonitorTileTool] = MonitorTileTool.standard, unavailable: [MonitorTileTool: String] = [:],
    falseColorModes: [FalseColorMode]? = nil, layout: PixelLayout? = nil,
    placement: MonitorTileToolbarPlacement = .chrome,
    scopesEnabled: Bool = false, onScopes: (@MainActor (Bool) -> Void)? = nil,
    freeze: MonitorFreezeState = .live, onFreeze: (@MainActor () -> Void)? = nil,
    @ViewBuilder scopeSettings: () -> ScopeSettingsContent
  ) {
    _state = state
    self.name = name
    self.signal = signal
    self.status = status
    self.tools = tools
    self.unavailable = unavailable
    self.falseColorModes = falseColorModes
    self.layout = layout
    self.placement = placement
    self.scopesEnabled = scopesEnabled
    self.onScopes = onScopes
    self.freeze = freeze
    self.onFreeze = onFreeze
    self.scopeSettings = scopeSettings()
  }

  /// The tools shown: `tools` in order, once each, without Scopes or Freeze
  /// when the host does not handle them.
  static func visibleTools(_ tools: [MonitorTileTool], scopes: Bool, freeze: Bool) -> [MonitorTileTool] {
    var out: [MonitorTileTool] = []
    for t in tools where !out.contains(t) {
      if t == .scopes && !scopes { continue }
      if t == .freeze && !freeze { continue }
      out.append(t)
    }
    return out
  }

  var visible: [MonitorTileTool] { Self.visibleTools(tools, scopes: onScopes != nil, freeze: onFreeze != nil) }

  /// Whether `tool` shows as on.
  func isOn(_ tool: MonitorTileTool) -> Bool {
    switch tool {
    case .scopes: return scopesEnabled
    case .freeze: return freeze != .live
    default: return tool.isOn(in: state) ?? false
    }
  }

  /// Why `tool`, while on, is not drawn on this surface.
  func statusReason(_ tool: MonitorTileTool) -> MonitorUnavailableReason? {
    guard let status else { return nil }
    for t in tool.statusTools {
      if let r = status.reason(for: t) { return r }
    }
    return nil
  }

  func hasSettings(_ tool: MonitorTileTool) -> Bool {
    switch tool {
    case .clean, .freeze: return false
    case .scopes: return ScopeSettingsContent.self != EmptyView.self
    default: return true
    }
  }

  /// The tools whose settings the collapsed menu lists, in bar order.
  var settingsTools: [MonitorTileTool] { visible.filter { hasSettings($0) } }

  /// VoiceOver's value for `tool`: Freeze says what the picture is (a pending
  /// freeze is still live), the others on or off.
  func accessibilityValue(_ tool: MonitorTileTool) -> String {
    tool == .freeze ? freeze.accessibilityValue : (isOn(tool) ? "On" : "Off")
  }

  /// Whether VoiceOver marks `tool` selected: Freeze only once frozen.
  func isSelected(_ tool: MonitorTileTool) -> Bool { tool == .freeze ? freeze == .frozen : isOn(tool) }

  /// The button's action; a disabled tool does nothing.
  func toggle(_ tool: MonitorTileTool) {
    guard unavailable[tool] == nil else { return }
    switch tool {
    case .scopes: onScopes?(!scopesEnabled)
    case .freeze: onFreeze?()
    default:
      var s = state
      memory.toggle(tool, in: &s, signal: signal, allowedFalseColor: falseColorModes)
      state = s
    }
  }

  public var body: some View {
    ViewThatFits(in: .horizontal) {
      bar
      menu
    }
    .modifier(TileToolbarBackground(placement: placement))
  }

  private var bar: some View {
    HStack(spacing: 2) {
      ForEach(visible) { tool in
        TileToolButton(
          tool: tool, isOn: isOn(tool), title: tool == .freeze ? freeze.actionTitle : tool.title,
          value: accessibilityValue(tool), isSelected: isSelected(tool),
          pulses: tool == .freeze && freeze == .pending,
          disabledReason: unavailable[tool], statusReason: isOn(tool) ? statusReason(tool)?.description : nil,
          hasSettings: hasSettings(tool), toggle: { toggle(tool) },
          openSettings: {
            openFromMenu = false
            openTool = tool
          }
        )
        .popover(
          isPresented: Binding(
            get: { openTool == tool && !openFromMenu }, set: { if !$0 && openTool == tool { openTool = nil } }),
          arrowEdge: .bottom
        ) {
          settings(tool)
        }
      }
    }
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityName)
  }

  private var accessibilityName: String { name.isEmpty ? "Monitor tools" : "Monitor tools for \(name)" }

  private var activeTitles: [String] { visible.filter { isOn($0) }.map(\.title) }

  private var menu: some View {
    Menu {
      ForEach(visible) { tool in
        menuItem(tool)
      }
      if !settingsTools.isEmpty {
        Divider()
        // The bar's chevrons are not shown when collapsed, so the settings are
        // reached from here; the popover hangs off the menu's button.
        Menu("Settings") {
          ForEach(settingsTools) { tool in
            Button(tool.title) {
              openFromMenu = true
              openTool = tool
            }
          }
        }
      }
    } label: {
      Image(
        systemName: activeTitles.isEmpty ? "slider.horizontal.3" : "slider.horizontal.below.square.filled.and.square")
        .font(.callout.weight(.medium))
        .frame(width: 28, height: 24)
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(activeTitles.isEmpty ? "Monitor tools" : "Monitor tools: " + activeTitles.joined(separator: ", "))
    .accessibilityLabel(accessibilityName)
    .popover(
      isPresented: Binding(
        get: { openTool != nil && openFromMenu },
        set: {
          if !$0 {
            openTool = nil
            openFromMenu = false
          }
        }),
      arrowEdge: .bottom
    ) {
      if let tool = openTool { settings(tool) }
    }
  }

  @ViewBuilder private func menuItem(_ tool: MonitorTileTool) -> some View {
    switch tool {
    case .freeze:
      Button(freeze.actionTitle) { toggle(.freeze) }
        .disabled(unavailable[tool] != nil)
    case .falseColor:
      Picker(tool.title, selection: falseColorSelection) {
        ForEach(falseColorChoices, id: \.self) { m in
          Text(m.title).tag(m).disabled(!isFalseColorModeAllowed(m))
        }
      }
      .disabled(unavailable[tool] != nil)
    case .magnify:
      Picker(tool.title, selection: magnifySelection) {
        ForEach(MonitorMagnifyChoice.choices(current: MonitorMagnifyChoice(state.geometry.magnification)), id: \.self) {
          Text($0.title).tag($0)
        }
      }
      .disabled(unavailable[tool] != nil)
    default:
      Toggle(tool.title, isOn: Binding(get: { isOn(tool) }, set: { on in if on != isOn(tool) { toggle(tool) } }))
        .disabled(unavailable[tool] != nil)
    }
  }

  /// The modes the false-colour pickers list (`MonitorTileTool.falseColorChoices`).
  var falseColorChoices: [FalseColorMode] {
    MonitorTileTool.falseColorChoices(allowed: falseColorModes, current: state.falseColor.mode)
  }

  /// Whether a picker may select `mode` on this tile (`.off` always).
  func isFalseColorModeAllowed(_ mode: FalseColorMode) -> Bool {
    mode == .off || (falseColorModes?.contains(mode) ?? true)
  }

  /// The collapsed menu's mode picker: writes an allowed mode through the memory.
  var falseColorSelection: Binding<FalseColorMode> {
    Binding(
      get: { state.falseColor.mode },
      set: { mode in
        guard unavailable[.falseColor] == nil, isFalseColorModeAllowed(mode) else { return }
        var s = state
        memory.select(mode, in: &s)
        state = s
      })
  }

  private var magnifySelection: Binding<MonitorMagnifyChoice> {
    Binding(
      get: { MonitorMagnifyChoice(state.geometry.magnification) },
      set: { choice in
        guard unavailable[.magnify] == nil else { return }
        var s = state
        s.geometry.magnification = choice.applied(to: s.geometry.magnification)
        state = s.normalized()
      })
  }

  @ViewBuilder private func settings(_ tool: MonitorTileTool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(tool.title, systemImage: tool.systemImage).font(.headline)
        Spacer()
        if !name.isEmpty { Text(name).foregroundStyle(.secondary) }
      }
      if let reason = unavailable[tool] {
        Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      ScrollView {
        Group {
          switch tool {
          case .guides: GuideControls(state: $state, status: status)
          case .zebra: ZebraControls(state: $state, status: status)
          case .falseColor:
            FalseColorControls(state: $state, status: status, signal: signal, layout: layout, modes: falseColorModes)
          case .focusPeaking: PeakingControls(state: $state, status: status)
          case .clipIndicators: ClipIndicatorControls(state: $state, status: status)
          case .magnify: GeometryControls(state: $state, status: status)
          case .scopes: scopeSettings
          case .clean, .freeze: EmptyView()
          }
        }
        .disabled(unavailable[tool] != nil)
      }
      .frame(maxHeight: 520)
    }
    .padding(12)
    .frame(width: 320)
    .controlSize(.small)
  }
}

extension MonitorTileToolbar where ScopeSettingsContent == EmptyView {
  /// A toolbar without scope settings (the Scopes button, when `onScopes` is
  /// given, only switches scopes).
  public init(
    state: Binding<MonitorState>, name: String = "", signal: SignalDescription? = nil, status: MonitorStatus? = nil,
    tools: [MonitorTileTool] = MonitorTileTool.standard, unavailable: [MonitorTileTool: String] = [:],
    falseColorModes: [FalseColorMode]? = nil, layout: PixelLayout? = nil,
    placement: MonitorTileToolbarPlacement = .chrome,
    scopesEnabled: Bool = false, onScopes: (@MainActor (Bool) -> Void)? = nil,
    freeze: MonitorFreezeState = .live, onFreeze: (@MainActor () -> Void)? = nil
  ) {
    self.init(
      state: state, name: name, signal: signal, status: status, tools: tools, unavailable: unavailable,
      falseColorModes: falseColorModes, layout: layout, placement: placement, scopesEnabled: scopesEnabled, onScopes: onScopes, freeze: freeze, onFreeze: onFreeze
    ) { EmptyView() }
  }
}

/// The bar's backing: a system material capsule in chrome, the dark picture
/// capsule over video.
struct TileToolbarBackground: ViewModifier {
  let placement: MonitorTileToolbarPlacement

  func body(content: Content) -> some View {
    let padded = content.padding(.horizontal, 4).frame(height: 28)
    switch placement {
    case .chrome:
      padded
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
    case .overPicture:
      // Over video: the same ≥ 4.5:1 dark backing as other picture overlays.
      padded
        .background(Color.black.opacity(0.72), in: Capsule())
        .environment(\.colorScheme, .dark)
    }
  }
}

/// One tool: the icon toggles it; the chevron, when the tool has settings, opens them.
struct TileToolButton: View {
  let tool: MonitorTileTool
  let isOn: Bool
  let title: String
  /// VoiceOver's value ("On", "Off"; Freeze: "Live", "Freeze pending", "Frozen").
  let value: String
  let isSelected: Bool
  let pulses: Bool
  let disabledReason: String?
  let statusReason: String?
  let hasSettings: Bool
  let toggle: () -> Void
  let openSettings: () -> Void

  var help: String {
    if let disabledReason { return disabledReason }
    if tool == .freeze { return title }
    if let statusReason { return "\(tool.title) is on but not drawn: \(statusReason)" }
    return "\(isOn ? "Turn off" : "Turn on") \(tool.title)"
  }

  var body: some View {
    HStack(spacing: 0) {
      Button(action: toggle) {
        Image(systemName: tool.systemImage)
          .font(.callout.weight(.medium))
          .symbolEffect(.pulse, isActive: pulses)
          .frame(width: 24, height: 24)
          .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
          .background(
            isOn ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
          .overlay(alignment: .topTrailing) {
            if statusReason != nil {
              Circle().fill(.orange).frame(width: 5, height: 5).offset(x: -2, y: 2)
            }
          }
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(disabledReason != nil)
      .help(help)
      .accessibilityLabel(title)
      .accessibilityValue(value)
      .accessibilityHint(statusReason ?? disabledReason ?? "")
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      if hasSettings {
        // A system split-button menu can't host a settings form, so the
        // settings half is its own button, wide enough to hit.
        Button(action: openSettings) {
          Image(systemName: "chevron.down")
            .font(.caption.weight(.bold)).imageScale(.small)
            .frame(width: 16, height: 24)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.title) settings")
        .accessibilityLabel("\(tool.title) settings")
      }
    }
    .opacity(disabledReason == nil ? 1 : 0.45)
  }
}
