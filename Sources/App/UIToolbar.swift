import SwiftUI

/// Main window toolbar, on three pieces of glass: switching (cuts, Auto, Hold), then Start
/// when a camera is stopped and the record control, then layout and the inspector. Stop
/// Cameras isn't here while they run: it's ⌘↩, in the Camera menu and in the menu bar.
struct UIToolbarContent: ToolbarContent {
  let context: UIContext

  private var presentation: UISessionPresentation { context.presentation }

  var body: some ToolbarContent {
    let _ = UIRenderProbe.count("UIToolbarContent")
    if !presentation.cutButtons.isEmpty {
      ToolbarItem(placement: .principal) {
        UIToolbarCutGroup(context: context)
      }
    }

    // Order matters: when the window narrows, macOS moves the trailing items into the
    // overflow menu first, so the record control stays visible; layout, collapse and the
    // inspector are also in View. From macOS 26.1 the record control also has the highest
    // priority, so it's the last thing to overflow whatever the cut pills take.
    if #available(macOS 26.1, *) {
      recordGroup.visibilityPriority(.high)
    } else {
      recordGroup
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
      if context.session.expandedFrom != nil {
        Button {
          context.send(.restoreLayout)
        } label: {
          Label("Restore Layout", systemImage: UISymbol.restoreLayout)
            .labelStyle(.titleAndIcon)
        }
        .help("Return to the layout you expanded this picture from")
      }

      // One camera has only the single layout, so the picker appears with a second camera.
      if presentation.layouts.count > 1 {
        Picker("Layout", selection: layoutBinding) {
          ForEach(presentation.layouts, id: \.self) { layout in
            // Each segment names its layout and key, as the View menu does (⌥⌘ and its place there).
            Label(layout.title, systemImage: layout.symbol)
              .help("\(layout.title) (⌥⌘\((UILayout.allCases.firstIndex(of: layout) ?? 0) + 1))")
              .tag(layout)
          }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help("Layout (⌥⌘1–⌥⌘4)")
      }

      Button {
        context.send(.setAllCollapsed(!allCollapsed))
      } label: {
        Label(allCollapsed ? "Expand All Strips" : "Collapse All Strips",
          systemImage: allCollapsed ? UISymbol.expandAll : UISymbol.collapseAll)
      }
      .help(allCollapsed ? "Expand All Strips (⌥⌘S)" : "Collapse All Strips (⌥⌘S)")
      .disabled(presentation.layout == .fourUp || presentation.layout == .programView)
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItem(placement: .primaryAction) {
      Button {
        context.send(.toggleInspector)
      } label: {
        Label("Inspector", systemImage: UISymbol.inspector)
      }
      .help("Show or hide the inspector for the selected camera (⌥⌘I)")
    }
  }

  /// Start, when a camera is stopped, and the record control.
  @ToolbarContentBuilder private var recordGroup: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if let start = presentation.startControl {
        Button { context.send(start.action) } label: {
          Label(start.title, systemImage: UISymbol.start).labelStyle(.titleAndIcon)
        }
        .disabled(!start.enabled)
        .help(start.help)
      }
      UIToolbarRecordControl(context: context)
    }
  }

  private var allCollapsed: Bool {
    let ids = Set(presentation.cameras.map(\.id))
    return !ids.isEmpty && ids.isSubset(of: context.session.collapsed)
  }

  private var layoutBinding: Binding<UILayout> {
    Binding(get: { presentation.layout }, set: { context.send(.setLayout($0)) })
  }
}

/// A toolbar control drawn by hand, so its state survives a window that isn't key: a
/// prominent tint goes gray there, which is all of a meeting. `on` is the white fill with a
/// dark glyph that Auto On and Hold use; `selected` is the on-air cut's quieter fill.
struct UIToolbarPillStyle: ButtonStyle {
  var on = false
  var selected = false
  var outline: Color? = nil
  @Environment(\.isEnabled) private var enabled
  @Environment(\.colorScheme) private var scheme

  /// The on fill: white on a dark toolbar, near black on a light one, the glyph the opposite.
  private var onFill: Color { scheme == .dark ? .white : Color(white: 0.12) }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(on ? .semibold : .medium))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 9).frame(height: 26)
      .foregroundStyle(on ? AnyShapeStyle(scheme == .dark ? Color.black : .white)
        : enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
      .background(background(pressed: configuration.isPressed), in: Capsule())
      .overlay(Capsule().strokeBorder(outline ?? .clear, lineWidth: 1.5))
      .contentShape(Capsule())
  }

  private func background(pressed: Bool) -> AnyShapeStyle {
    if on { return AnyShapeStyle(onFill.opacity(pressed ? 0.75 : 0.9)) }
    if selected || pressed { return AnyShapeStyle(.fill.secondary) }
    return AnyShapeStyle(.clear)
  }
}

/// One ⇆ glyph so the group reads as Cut and not as tabs, the cut buttons, then Auto with its
/// options and Hold in a fixed slot, so nothing moves under the pointer.
struct UIToolbarCutGroup: View {
  let context: UIContext

  private var presentation: UISessionPresentation { context.presentation }
  private var session: UISessionSnapshot { context.session }

  var body: some View {
    // Six pills at most, the rest in More; digits only when the names wouldn't fit.
    let cuts = UIPresentationBuilder.toolbarCuts(presentation.cutButtons)
    let numberOnly = UIPresentationBuilder.toolbarCutsNumberOnly(cuts.shown, hasMore: !cuts.more.isEmpty,
      narrowWindow: session.narrowWindow)
    HStack(spacing: 4) {
      Image(systemName: UISymbol.cut).foregroundStyle(.secondary).padding(.horizontal, 4)
        .help("Cut: each button puts its camera on Program")
        .accessibilityHidden(true)
      ForEach(cuts.shown) { button in
        cutButton(button, numberOnly: numberOnly)
      }
      if !cuts.more.isEmpty { moreCuts(cuts.more) }
      Divider().frame(height: 18).padding(.horizontal, 2)
      auto
      autoOptions
      hold
    }
    // A toolbar draws labels icon-only; these keep their words, which carry the state.
    .labelStyle(.titleAndIcon)
  }

  @ViewBuilder private func cutButton(_ button: UICutButton, numberOnly: Bool) -> some View {
    Button { context.send(.cut(cameraID: button.id)) } label: {
      UICutButtonLabel(button: button, numberOnly: numberOnly, showsNext: !numberOnly)
    }
    .buttonStyle(UIToolbarPillStyle(selected: button.onAir, outline: button.pending ? .green : nil))
    .disabled(!button.enabled)
    .help(button.onAir ? "\(button.name) is \(Self.programWords(button))"
      : button.help ?? (button.pending ? "Cut to \(button.name) is pending" : (button.number <= 4 ? "Cut to \(button.name) (⌃\(button.number))" : "Cut to \(button.name)")))
    .accessibilityLabel(button.onAir ? "\(button.name), \(Self.programWords(button))" : button.pending ? "\(button.name), cut pending" : "Cut to \(button.name)")
  }

  /// The cameras past the pills, in one menu at a fixed place. When the camera on Program or
  /// a pending cut is among them, the More pill shows it, so that state never hides in a menu.
  private func moreCuts(_ more: [UICutButton]) -> some View {
    let shown = more.first(where: \.onAir) ?? more.first(where: \.pending)
    let pending = more.contains(where: \.pending)
    let label: String
    if let shown, shown.onAir {
      label = "More cameras, \(shown.name) \(Self.programWords(shown))" + (pending ? ", a cut pending" : "")
    } else if let shown {
      label = "More cameras, cut to \(shown.name) pending"
    } else {
      label = "More cameras"
    }
    return Menu {
      // Only ⌃1–⌃4 are keys (the Program menu's), so these past the pills name none.
      ForEach(more) { button in
        Toggle("Cut to \(button.name)", isOn: Binding(get: { button.onAir }, set: { _ in context.send(.cut(cameraID: button.id)) }))
          .badge(button.pending ? Text(UITally.next.label ?? "Next") : nil)
          .disabled(!button.enabled)
          .help(button.help ?? "Cut to \(button.name)")
      }
    } label: {
      HStack(spacing: 4) {
        if let shown {
          UICutButtonLabel(button: shown, numberOnly: true)
        } else {
          Text("More")
        }
        Image(systemName: UISymbol.menuIndicator).font(.caption.weight(.bold))
      }
    }
    .menuStyle(.button)
    .buttonStyle(UIToolbarPillStyle(selected: shown?.onAir == true, outline: pending ? .green : nil))
    .menuIndicator(.hidden)
    .fixedSize()
    .help("More cameras: \(more.map(\.name).joined(separator: ", "))")
    .accessibilityLabel(label)
  }

  /// What the dot says about the camera on Program.
  static func programWords(_ button: UICutButton) -> String {
    switch button.tally {
    case .onAir: return "on air"
    case .noPicture: return "on Program with no picture"
    default: return "on Program"
    }
  }

  /// "Auto On" or "Auto Off" at one width. With Manual chosen, Auto asks how to switch first.
  @ViewBuilder private var auto: some View {
    let on = presentation.autoSwitching
    let label = Label {
      ZStack(alignment: .leading) {
        Text("Auto Off").hidden()
        Text(on ? "Auto On" : "Auto Off")
      }
    } icon: { Image(systemName: UISymbol.auto) }
    if presentation.canAutoSwitch {
      Button { context.send(.setAutoSwitching(!on)) } label: { label }
        .buttonStyle(UIToolbarPillStyle(on: on))
        .help(on ? "Turn off automatic switching (⌃⌥A)" : "Switch automatically with \(session.strategyTitle) (⌃⌥A)")
        .accessibilityLabel("Automatic switching")
        .accessibilityValue(on ? "On" : "Off")
    } else {
      Menu {
        Section("Switch automatically") {
          ForEach(UIStrategy.offered.filter { $0 != .manual }, id: \.self) { strategy in
            Button(UIStrategy.title(strategy)) {
              context.send(.setStrategy(strategy))
              context.send(.setAutoSwitching(true))
            }
          }
        }
      } label: { label }
        .menuStyle(.button)
        .buttonStyle(UIToolbarPillStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch automatically: choose a strategy and Auto turns on.")
        .accessibilityLabel("Automatic switching")
        .accessibilityValue("Off")
    }
  }

  /// Strategy, Anchor and Emphasis. Anchor and Emphasis stay live with Auto off: they're set
  /// before a show.
  private var autoOptions: some View {
    Menu {
      Picker("Strategy", selection: Binding(get: { session.strategy }, set: { context.send(.setStrategy($0)) })) {
        ForEach(UIStrategy.offered, id: \.self) { Text(UIStrategy.title($0)).tag($0) }
      }
      .pickerStyle(.inline)
      if session.strategy == .naturalTalkingHead {
        Divider()
        UICameraPickerMenu(title: "Anchor", selection: session.anchorID, cameras: presentation.cameras) {
          context.send(.setAnchor(cameraID: $0))
        }
        UICameraPickerMenu(title: "Emphasis", selection: session.emphasisID, cameras: presentation.cameras) {
          context.send(.setEmphasis(cameraID: $0))
        }
      }
    } label: {
      Image(systemName: UISymbol.menuIndicator).font(.caption.weight(.bold)).frame(width: 16, height: 26).contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Strategy, Anchor and Emphasis")
    .accessibilityLabel("Auto options")
  }

  private var hold: some View {
    let on = presentation.canHoldShot && session.autoHold
    return Button { context.send(.setAutoHold(!session.autoHold)) } label: {
      Label("Hold", systemImage: UISymbol.hold(on: on))
    }
    .buttonStyle(UIToolbarPillStyle(on: on))
    .disabled(!presentation.canHoldShot)
    .help(presentation.canHoldShot ? (on ? "Let Auto cut again (⌃⌥H)" : "Hold Current Shot: Auto stays on and makes no cuts (⌃⌥H)")
      : "Hold works while Auto is on.")
    .accessibilityLabel("Hold Current Shot")
    .accessibilityValue(on ? "On" : "Off")
  }
}

/// A camera choice with Automatic first, as a submenu showing the choice.
struct UICameraPickerMenu: View {
  let title: String
  let selection: String?
  let cameras: [UICameraPresentation]
  let choose: (String?) -> Void

  var body: some View {
    Picker(title, selection: Binding(get: { selection }, set: { choose($0) })) {
      Text("Automatic").tag(String?.none)
      ForEach(cameras) { Text($0.name).tag(String?.some($0.id)) }
    }
    .pickerStyle(.menu)
  }
}

/// A cut button's number and name, with a tally dot: on Program, red only while frames reach
/// a meeting (J 13), orange while it waits on a picture, gray otherwise; green while a cut is
/// pending, a green triangle where the word Next isn't shown. With Differentiate Without Color
/// each state has its own shape. The dot is drawn, so it holds its color in a window that isn't key.
struct UICutButtonLabel: View {
  let button: UICutButton
  var numberOnly = false
  var showsNext = false

  /// The dot's color, nil for none.
  static func dot(_ button: UICutButton) -> Color? {
    if button.onAir {
      switch button.tally {
      case .onAir: return .red
      case .noPicture: return .orange
      default: return .secondary
      }
    }
    return button.pending ? .green : nil
  }

  /// The widest a name draws before it truncates, so a long name can't push Record off the toolbar.
  static let nameWidth: CGFloat = 120

  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

  var body: some View {
    HStack(spacing: 5) {
      if button.pending && !button.onAir && (!showsNext || differentiateWithoutColor) {
        // Without the word Next, a shape of its own: the pending cut never rests on green alone.
        Image(systemName: UISymbol.nextCut).font(.system(size: 8, weight: .bold)).foregroundStyle(.green)
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)
      } else if differentiateWithoutColor && button.onAir && button.tally == .noPicture {
        Image(systemName: UISymbol.warning).font(.system(size: 8, weight: .bold)).foregroundStyle(.orange)
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)
      } else if differentiateWithoutColor && button.onAir && button.tally != .onAir {
        // On Program with nobody watching: a ring, where on air is a filled dot.
        Circle().strokeBorder(.secondary, lineWidth: 1.5)
          .frame(width: 7, height: 7)
          .accessibilityHidden(true)
      } else if let dot = Self.dot(button) {
        Circle().fill(dot)
          .frame(width: 7, height: 7)
          .accessibilityHidden(true)
      }
      Text("\(button.number)").monospacedDigit().fontWeight(.bold)
      if !numberOnly {
        UIMaxWidthLayout(maxWidth: Self.nameWidth) {
          Text(button.name).fontWeight(button.onAir ? .semibold : .regular).truncationMode(.tail)
        }
      }
      if showsNext && button.pending { Text("Next").font(.uiMeta).foregroundStyle(.secondary) }
    }
  }
}

/// Its one subview at no more than `maxWidth`, even where the proposal is unbounded (a
/// toolbar pill is laid out at its ideal size), so a long label truncates there.
private struct UIMaxWidthLayout: Layout {
  let maxWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = min(proposal.width ?? maxWidth, maxWidth)
    return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for subview in subviews {
      subview.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
  }
}

/// "Record All", "Record 1 of 2", "Stop Recording" or "Stop 2 Recordings", at one width
/// whatever the clock does, plus its menu: Format, Record Camera 2, Pause All. A red dot, not
/// a red fill, while rolling. The words stay: this ends something.
struct UIToolbarRecordControl: View {
  let context: UIContext

  var body: some View {
    let _ = UIRenderProbe.count("UIToolbarRecordControl")
    let presentation = context.presentation
    let control = presentation.recordControl
    HStack(spacing: 0) {
      Button { context.send(action(control)) } label: {
        HStack(spacing: 6) {
          if case .record = control {
            Image(systemName: UISymbol.record)
          } else {
            UIStateGlyph(state: .recording)
          }
          Text(control.title)
        }
      }
      .buttonStyle(UIToolbarPillStyle())
      .disabled(!enabled(control))
      .help(help(control))
      .accessibilityLabel(control.title)
      Menu {
        Menu {
          UIFormatChoices(session: context.session, send: context.send)
        } label: {
          Label("Format", systemImage: UISymbol.format)
        }
        .badge(Text(context.session.codec.title))
        if presentation.cameras.count > 1 {
          ForEach(presentation.cameras.filter { $0.recordButtonEnabled && !$0.recordButtonActive && $0.pauseTitle == nil }) { camera in
            Button("Record \(camera.name)") { context.send(.toggleRecording(cameraID: camera.id)) }
          }
        }
        Button(presentation.pauseAllTitle) { context.send(presentation.pauseAllTitle == "Resume All" ? .resumeAll : .pauseAll) }
          .disabled(!presentation.canPauseAll)
      } label: {
        Image(systemName: UISymbol.menuIndicator).font(.caption.weight(.bold)).frame(width: 18, height: 26).contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Format, Record a camera, Pause All")
      .accessibilityLabel("Record options")
    }
  }

  private func action(_ control: UIRecordControl) -> UIAction {
    switch control {
    case .record(let all, _, _, _): return all ? .recordAll : .toggleRecordingSelected
    case .stop: return .toggleRecordingSelected
    // Keeps Stop All when one of several records: toggling the selected camera could start a second take.
    case .stopAll: return .stopAllRecordings
    }
  }

  private func enabled(_ control: UIRecordControl) -> Bool {
    if case .record(_, let enabled, _, _) = control { return enabled }
    return true
  }

  private func help(_ control: UIRecordControl) -> String {
    let format = context.session.codec.title
    switch control {
    case .record(let all, let enabled, _, _):
      if !enabled { return "Recording becomes available when a camera has a signal and a folder." }
      return all ? "Record every camera that can roll, in \(format) (⌥⌘R)" : "Record in \(format) (⌘R)"
    case .stop: return "Stop Recording (⌘R)"
    case .stopAll: return "Stop every recording (⌥⌘R)"
    }
  }
}
