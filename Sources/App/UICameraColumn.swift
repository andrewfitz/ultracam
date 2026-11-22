import AppKit
import MonitorKitCore
import SwiftUI
import UniformTypeIdentifiers

/// One camera: its picture with overlays, then its channel strip.
struct UICameraColumnView: View {
  let camera: UICameraPresentation
  let context: UIContext

  var body: some View {
    let _ = UIRenderProbe.count("UICameraColumnView")
    VStack(alignment: .leading, spacing: 10) {
      UIColumnPictureLayout {
        UICameraPictureView(camera: camera, context: context)
      }
      UIChannelStripView(camera: camera, context: context)
    }
  }
}

/// Sizes the picture from the column's width alone (16:9). Left to `aspectRatio`, a live
/// picture is sized from the native preview's own ideal size whenever the column is
/// proposed no height (inside a scroll view), and comes out narrower than its strip.
struct UIColumnPictureLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 640
    return CGSize(width: width, height: (width * 9 / 16).rounded())
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
  }

  // No guides of its own: the stacks and grid rows that align columns use its edges. The
  // default asks every view on the picture for its guides, in every layout pass (each frame
  // while a side column animates).
  func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

  func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

// MARK: - Picture

/// The picture at 16:9 with its overlays. At rest it shows the camera's number, name and
/// tally, the REC pill, the tools button and every enabled tool. Hovering the picture opens
/// the full tool bar in every state (built on the picture, not on `revealed`, which is live
/// only); live pictures also show their timecode, signal menu and view controls. A click
/// selects the camera and never cuts (cuts come only from explicit cut controls).
struct UICameraPictureView: View {
  let camera: UICameraPresentation
  let context: UIContext
  var compact = false
  @State private var hovering = false
  /// The monitor tool popover open from this picture's bar: it keeps the bar where it is.
  @State private var toolPanel: UIMonitorPanel?
  @State private var zoom = 1.0
  /// Narrow enough that the name row can't hold the full tool bar: it takes its own row.
  @State private var narrow = false
  /// Narrower than the two-column tool popover: the popover takes one column.
  @State private var singleColumnTools = false
  /// Under 480 pt the timecode yields, so the REC pill never truncates.
  @State private var showsTimecode = true
  @FocusState private var focused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var revealed: Bool {
    guard (hovering || focused) && !compact else { return false }
    switch camera.tileState {
    case .live, .updating: return true
    default: return false
    }
  }
  private var snapshot: UICameraSnapshot? { context.snapshot(camera.id) }
  /// Clean View hides the overlays, pills included; the tally ring stays, and hover still
  /// brings the tools and view controls back so Clean View can be turned off again.
  private var isClean: Bool { !compact && UICleanViewState.shared.clean.contains(camera.id) }
  private var toolPlacement: UIMonitorToolButtons.Placement {
    UIMonitorToolButtons.Placement(hovering: hovering, panelOpen: toolPanel != nil, narrow: narrow, clean: isClean)
  }

  private static let cornerRadius: CGFloat = 14

  var body: some View {
    let _ = UIRenderProbe.count("UICameraPictureView")
    let radius = compact ? 10 : Self.cornerRadius
    ZStack {
      context.pictures.picture(cameraID: camera.id, compact: compact, zoom: zoom)
        .accessibilityElement()
        .modifier(UILiveCameraAccessibilityLabel(camera: camera, context: context))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(camera.selected ? .isSelected : [])
        .accessibilityAction { context.send(.select(cameraID: camera.id)) }
        .accessibilityAction(named: "Select \(camera.name)") { context.send(.select(cameraID: camera.id)) }
        .modifier(UICutAccessibilityAction(camera: camera, context: context))
      placeholder
      overlays
    }
    .aspectRatio(16 / 9, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: radius))
    .overlay {
      // The tally ring stays in Clean View: it doesn't cover the picture.
      if let color = camera.tally.ringColor {
        RoundedRectangle(cornerRadius: radius).strokeBorder(color, lineWidth: camera.tally.isRed || camera.tally == .noPicture ? 4 : 3)
          .allowsHitTesting(false)
      }
    }
    .overlay {
      // Selection only means something next to other pictures; alone, the ring just doubles the tally ring.
      // Always in the hierarchy and shown by opacity, without animation: selecting never inserts a
      // view or animates anything, and an overlay never changes the picture's layout. It sits in
      // the margin around the pictures (UIPictureSpacing), so it's never clipped. Beside a tally
      // ring it thins to 1 pt: selection is the least urgent fact on that edge.
      let outset = UIPictureSpacing.ringOutset
      RoundedRectangle(cornerRadius: radius + outset)
        .strokeBorder(UIPictureSpacing.selectionRing, lineWidth: camera.tally.ringColor == nil ? 2 : 1)
        .padding(-outset)
        .opacity(camera.selected && !compact && context.presentation.layout != .single ? 1 : 0)
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .overlay {
      // Keyboard focus, which no longer selects (D7), has its own ring: dashed, just outside the
      // selection ring's, so the two read apart and both can show. Drawn here because the
      // system's focus ring is off (it would hug the picture, over the tally ring).
      let outset = UIPictureSpacing.focusRingOutset
      RoundedRectangle(cornerRadius: radius + outset)
        .strokeBorder(UIPictureSpacing.selectionRing, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        .padding(-outset)
        .opacity(focused && !compact ? 1 : 0)
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .contentShape(Rectangle())
    .onTapGesture { context.send(.select(cameraID: camera.id)) }
    .onHover { hovering = $0 }
    .onGeometryChange(for: Bool.self) { $0.size.width < UIMonitorToolButtons.ownRowBelow } action: { narrow = $0 }
    .onGeometryChange(for: Bool.self) { $0.size.width >= 480 } action: { showsTimecode = $0 }
    .onGeometryChange(for: Bool.self) { $0.size.width < UIMonitorToolButtons.singleColumnPanelsBelow } action: { singleColumnTools = $0 }
    // Only Full Keyboard Access focuses a picture: a click or window activation doesn't, so it
    // can't silently move the target of ⌘R. Focus reveals the controls and never selects.
    .focusable(!compact, interactions: .activate)
    // The picture draws its own focus ring, apart from selection (above): the system's would sit
    // on the tally ring.
    .focusEffectDisabled()
    .focused($focused)
    .onKeyPress(.space) { context.send(.select(cameraID: camera.id)); return .handled }
    .onKeyPress(.return) { context.send(.select(cameraID: camera.id)); return .handled }
    .contextMenu { pictureMenu }
  }

  // MARK: Placeholders

  /// One large glyph says the cause. Problems are orange; a stopped or hidden picture,
  /// where nothing is wrong, stays gray.
  @ViewBuilder private var placeholder: some View {
    switch camera.tileState {
    case .live:
      EmptyView()
    case .connecting:
      UIPicturePlaceholder(symbol: UISymbol.camera, title: "Starting…", compact: compact,
        detail: "Waiting for the first frame from \(camera.inputName).", showsProgress: true)
    case .signalLost:
      // No update arrives during a loss: its clock and countdown tick here, from when it began.
      UILiveCamera(camera: camera, context: context, follows: [], refresh: 1) { live in
        UILostSignalPlaceholder(camera: live.camera, compact: compact, context: context)
      }
    case .noSignal:
      UIPicturePlaceholder(symbol: UISymbol.noSignal, title: "No signal", compact: compact,
        detail: "Check that the source is sending video and that its input connection is selected on the capture device.",
        tint: camera.statusTone == .warning ? .orange : nil)
    case .unsupported(let mode):
      UIPicturePlaceholder(symbol: UISymbol.warning, title: "Unsupported format", compact: compact,
        detail: mode.isEmpty ? "Choose a format supported by this capture device and the current processing route." : "\(mode) Choose a supported source format or check the capture diagnostics.",
        tint: .orange) {
        Button("Open Diagnostics") { context.send(.openDiagnosticsSection(.camera(camera.id))) }
      }
    case .deviceMissing where snapshot?.inputName == nil:
      UIPicturePlaceholder(symbol: UISymbol.input, title: "No input", compact: compact,
        detail: "Choose this camera's input device in the inspector.", tint: .orange) {
        Button("Show Inspector") { context.send(.showInspector(cameraID: camera.id)) }
      }
    case .deviceMissing:
      UIPicturePlaceholder(symbol: UISymbol.inputDisconnected, title: "Input disconnected", compact: compact,
        detail: "Reconnect \(camera.inputName) or choose another input.", tint: .orange) {
        Button("Refresh Inputs") { context.send(.refreshInputs) }
      }
    case .stopped where snapshot?.unexpectedStop?.reason != nil:
      // Over an expanded strip the reason is enough: Start and the take are on the strip.
      let stop = snapshot?.unexpectedStop
      UIPicturePlaceholder(symbol: UISymbol.warning, title: "\(camera.name) stopped", compact: compact,
        detail: camera.collapsed ? [stop?.reason.map(UICameraPictureView.sentence),
          snapshot.flatMap(UIPresentationBuilder.takeSavedLine)].compactMap { $0 }.joined(separator: ". ")
          : stop?.reason.map(UICameraPictureView.sentence) ?? "",
        tint: .orange) {
        if camera.collapsed {
          Button("Start Capture", systemImage: UISymbol.camera) { context.send(.startCamera(cameraID: camera.id)) }
            .disabled(!camera.canStart)
        }
      }
    case .stopped where camera.automaticStartFailed:
      UIPicturePlaceholder(symbol: UISymbol.warning, title: "Couldn't start \(camera.name)", compact: compact,
        detail: startFailureDetail, tint: .orange) {
        Button("Retry", systemImage: UISymbol.retry) { context.send(.retryAutomaticStart(cameraID: camera.id)) }
      }
    case .stopped:
      UIPicturePlaceholder(symbol: UISymbol.camera, title: "Capture stopped", compact: compact,
        detail: "Start Capture to receive video from this input.") {
        // The expanded strip has a capture control just below.
        if camera.collapsed {
          Button("Start Capture", systemImage: UISymbol.camera) { context.send(.startCamera(cameraID: camera.id)) }
            .disabled(!camera.canStart)
        }
      }
    case .previewHidden:
      UIPicturePlaceholder(symbol: UISymbol.previewHidden, title: "Preview hidden", compact: compact,
        detail: "Preview controls what appears here. Recording and video output can continue.") {
        Button("Show Preview") { context.send(.setPreviewEnabled(cameraID: camera.id, true)) }
      }
    case .updating:
      Label("Updating output…", systemImage: UISymbol.updating)
        .uiPictureOverlay()
        .accessibilityLabel("Updating output")
    }
  }

  /// The reason only: the title already says "Couldn't start".
  private var startFailureDetail: String {
    Self.startFailureReason(snapshot?.automaticStatus ?? snapshot?.message ?? "") ?? "Retry to try again."
  }

  /// A start failure's reason as a sentence, without a leading "Couldn't start: ".
  static func startFailureReason(_ status: String) -> String? {
    var status = status
    for prefix in ["Couldn't start: ", "Couldn’t start: "] where status.hasPrefix(prefix) {
      status = String(status.dropFirst(prefix.count))
    }
    guard !status.isEmpty else { return nil }
    return sentence(status)
  }

  /// The first letter in capitals.
  static func sentence(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.uppercased() + text.dropFirst()
  }

  // MARK: Overlays

  private var overlays: some View {
    let placement = toolPlacement
    return VStack(spacing: 6) {
      HStack(alignment: .center, spacing: 6) {
        if !isClean {
          identity
        }
        Spacer(minLength: 4)
        if !placement.ownRow { tools(placement) }
      }
      // Too narrow for the bar beside the name: on hover it takes its own row, right aligned.
      if placement.ownRow {
        HStack {
          Spacer(minLength: 0)
          tools(placement)
        }
      }
      Spacer(minLength: 0)
      if !isClean && !compact {
        sourceLine.padding(.bottom, 4)
      } else if !isClean, let store = context.cameraControls {
        HStack {
          UICameraSettingsOverlay(feedID: camera.id, store: store)
          Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
      }
      HStack(alignment: .center, spacing: 6) {
        if revealed {
          if showsTimecode {
            // The timecode alone follows the camera's updates (4 Hz), not the picture.
            UILiveCamera(snapshotFor: camera, context: context, follows: .capture) { snapshot in
              let timecode = snapshot.map { $0.timecode ?? "—" } ?? camera.timecode
              Text(timecode).font(.uiOverlay.monospacedDigit()).uiPictureOverlay()
                .accessibilityLabel("Timecode \(timecode)")
            }
            .layoutPriority(-1)
          }
          signalMenu
        }
        Spacer(minLength: 4)
        if revealed { viewControls }
        Spacer(minLength: 4)
        if !isClean { recordingPill }
      }
    }
    .padding(compact ? 6 : 10)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering || focused || toolPanel != nil)
  }

  /// What's coming in, along the picture's bottom: the signal's format, the body's exposure
  /// (its own overlay), its battery, and its control link when that is down, with Reconnect.
  /// Standing facts about the source, so they sit together here and stay off the strip.
  /// Clean View hides them with the other overlays; the inspector has them all.
  private var sourceLine: some View {
    HStack(spacing: 6) {
      if camera.tileState.showsPicture, camera.statusTone == .positive {
        Text(camera.statusBadge).font(.uiOverlay.monospacedDigit()).lineLimit(1).uiPictureOverlay()
          .help("The signal \(camera.inputName) is receiving.")
          .accessibilityLabel("Signal \(camera.statusBadge)")
      }
      if let store = context.cameraControls { UICameraSettingsOverlay(feedID: camera.id, store: store) }
      if let cameraBody = snapshot?.body { bodyStatus(cameraBody) }
      Spacer(minLength: 0)
    }
  }

  /// The paired body's battery while its control link is up; while it's down, that fact and
  /// Reconnect, in the overlay's own gray: the picture comes over HDMI and isn't affected.
  @ViewBuilder private func bodyStatus(_ cameraBody: UICameraBody) -> some View {
    if cameraBody.connected {
      if let battery = cameraBody.battery {
        UIBatteryGlyph(battery: battery).font(.uiOverlay).uiPictureOverlay()
      }
    } else {
      HStack(spacing: 6) {
        Image(systemName: UISymbol.wifi(connected: false)).imageScale(.small).accessibilityHidden(true)
        Text(cameraBody.retrying ? "\(cameraBody.name) reconnecting…" : "\(cameraBody.name) control not connected")
          .lineLimit(1).truncationMode(.middle)
        if !cameraBody.retrying {
          Button("Reconnect") { context.send(.reconnectCameraBody(cameraID: camera.id)) }
            .buttonStyle(.plain)
            .font(.uiOverlay.weight(.semibold))
            .padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
            .accessibilityLabel("Reconnect \(cameraBody.name)")
        }
      }
      .uiPictureOverlay()
      .help("\(camera.name)'s camera control. The picture isn't affected.")
    }
  }

  /// Number, name, tally, and what the picture isn't: Frozen, a stage before the output, a zoom.
  @ViewBuilder private var identity: some View {
    UICameraName(camera: camera, context: context, onPicture: true)
      // The name keeps its room; the tool bar takes its own row instead.
      .layoutPriority(1)
    // A Program View tile keeps its ring only: the Program picture beside it has the pill.
    if !compact { UITallyBadge(tally: camera.tally) }
    if !compact && UICleanViewState.shared.frozen.contains(camera.id) {
      Label("Frozen", systemImage: UISymbol.freeze).font(.uiOverlay).uiPictureOverlay()
        .help("This picture is held. Freeze again (⌃⌥F) to show live video.")
        .accessibilityLabel("Picture frozen")
    }
    stageNotice
    if zoom != 1 {
      Text("\(Int(zoom * 100))%").font(.uiOverlay.monospacedDigit()).uiPictureOverlay()
        .help("This view is magnified. Choose Fit to see the whole picture.")
        .accessibilityLabel("Zoomed to \(Int(zoom * 100)) percent")
    }
  }

  /// The tools button and enabled tools at rest; the full bar on hover and while one of its
  /// popovers is open. Clean View shows none at rest.
  @ViewBuilder private func tools(_ placement: UIMonitorToolButtons.Placement) -> some View {
    if placement.shown {
      UIMonitorToolButtons(camera: camera, context: context, openPanel: $toolPanel, expanded: placement.expanded,
        singleColumnPanels: singleColumnTools)
    }
  }

  /// The take's clock follows its statistics here, not in the picture. One clock per camera:
  /// the digits show here only while the strip is collapsed. The CPU copy pill yields first,
  /// so REC never truncates.
  private var recordingPill: some View {
    UILiveCamera(snapshotFor: camera, context: context, follows: .all) { snapshot in
      HStack(spacing: 6) {
        if snapshot?.ingestCPUCopyActive == true {
          HStack(spacing: 4) {
            UIStateGlyph(state: .warning)
            Text("CPU copy")
            Text("\(snapshot?.ingestCPUCopyFrames ?? 0)").monospacedDigit()
          }
          .font(.uiOverlay).lineLimit(1).uiPictureOverlay()
          .layoutPriority(-1)
          .help("Ingest is copying frames on the CPU: \(snapshot?.ingestCPUCopyFrames ?? 0) so far. Diagnostics has the route.")
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("CPU copy for ingest")
        }
        recordingPill(snapshot)
      }
    }
  }

  @ViewBuilder private func recordingPill(_ snapshot: UICameraSnapshot?) -> some View {
    let elapsed = camera.collapsed ? UIFormat.shortElapsed(snapshot?.recording.elapsed ?? 0) : nil
    switch camera.stripState {
    case .recording, .updating: UIPictureStatePill(style: .recording, elapsed: elapsed)
    case .paused: UIPictureStatePill(style: .paused, elapsed: elapsed)
    // Plain REC: the picture says what happened, and the strip what to do.
    case .recordingNoSignal: UIPictureStatePill(style: .recording, elapsed: elapsed)
    default: EmptyView()
    }
  }

  private var signalMenu: some View {
    let stage = context.monitor.preferences(for: camera.id).state.pictureStage
    // What the camera sends ("1080p 29.97"): the picture runs at its frame rate.
    let output = context.session.cameras.first { $0.id == camera.id }?.outputFormat
    return Menu {
      Picker("Picture", selection: Binding(
        get: { context.monitor.preferences(for: camera.id).state.pictureStage },
        set: { value in
          var next = context.monitor.preferences(for: camera.id)
          next.setPictureStage(value)
          context.monitor.setPreferences(next, for: camera.id)
        })) {
        Text("Source (camera signal)").tag(SignalStage.source)
        Text(output.map { "Output (LUT, sent as \($0))" } ?? "Output (LUT)").tag(SignalStage.output)
        Text("Monitor").tag(SignalStage.monitor)
      }
      .pickerStyle(.inline)
    } label: {
      HStack(spacing: 4) {
        Text(Self.stageName(stage)).foregroundStyle(.white.opacity(0.7))
        if stage == .output, let output { Text(output).monospacedDigit() }
        Image(systemName: UISymbol.menuIndicator).font(.caption2.weight(.bold)).imageScale(.small)
      }
      .foregroundStyle(.white)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .uiPictureMenuBacking()
    .help(output.map { "Choose what this picture shows. The camera sends \($0), and the picture runs at its frame rate." }
      ?? "Choose what this picture shows")
    .accessibilityLabel("Picture signal")
    .accessibilityValue(Self.stageTitle(stage, output: output))
  }

  /// What the picture shows when it isn't the Output stage, always on the picture (not only
  /// on hover), so a picture without the camera's LUT explains itself: "Source" strong,
  /// "before LUT" dim. The stage menu below changes it.
  @ViewBuilder private var stageNotice: some View {
    let stage = context.monitor.preferences(for: camera.id).state.pictureStage
    if let notice = Self.stageNotice(stage) {
      HStack(spacing: 4) {
        Image(systemName: UISymbol.pictureSettings).symbolRenderingMode(.monochrome).imageScale(.small)
        Text(Self.stageName(stage))
        if stage == .source { Text("before LUT").foregroundStyle(.white.opacity(0.7)).fontWeight(.regular) }
      }
      .font(.uiOverlay)
      .lineLimit(1).truncationMode(.tail)
      .uiPictureOverlay()
      .help(Self.stageNoticeHelp(stage))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Picture shows \(notice)")
    }
  }

  /// The picture's stage when it isn't Output (the default, the camera's output), nil at Output.
  static func stageNotice(_ stage: SignalStage) -> String? {
    switch stage {
    case .output: return nil
    case .source: return "Source before LUT"
    case .monitor: return "Monitor"
    }
  }

  static func stageName(_ stage: SignalStage) -> String {
    switch stage {
    case .source: return "Source"
    case .output: return "Output"
    case .monitor: return "Monitor"
    }
  }

  static func stageNoticeHelp(_ stage: SignalStage) -> String {
    switch stage {
    case .output: return ""
    case .source: return "This picture shows the camera signal before its LUT. Choose Output to see what the camera outputs."
    case .monitor: return "This picture shows the Monitor stage: the output with this camera's monitor-only LUT."
    }
  }

  /// The stage menu's spoken value; on the Output stage, with what the camera sends.
  static func stageTitle(_ stage: SignalStage, output: String? = nil) -> String {
    switch stage {
    case .source: return "Source"
    case .output: return output.map { "Output \($0)" } ?? "Output"
    case .monitor: return "Monitor"
    }
  }

  private var viewControls: some View {
    HStack(spacing: 2) {
      // Read from the observed mirror, as the View menu does, so the button follows the picture.
      let frozen = UICleanViewState.shared.frozen.contains(camera.id)
      overlayButton(UISymbol.freeze, help: frozen ? "Unfreeze (⌃⌥F)" : "Freeze (⌃⌥F)", label: frozen ? "Unfreeze" : "Freeze", on: frozen) {
        context.send(.freeze(cameraID: camera.id))
      }
      overlayButton(UISymbol.cleanView(on: isClean), help: isClean ? "Show Overlays (⌃⌥C)" : "Clean View (⌃⌥C)",
        label: isClean ? "Show Overlays" : "Clean View") { context.send(.toggleClean(cameraID: camera.id)) }
      Menu {
        Picker("Zoom", selection: $zoom) {
          Text("Fit").tag(1.0)
          Text("150%").tag(1.5)
          Text("200%").tag(2.0)
          Text("400%").tag(4.0)
        }
        .pickerStyle(.inline)
      } label: {
        UIPictureMenuLabel(title: zoom == 1 ? "Fit" : "\(Int(zoom * 100))%").font(.uiOverlay)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .padding(.horizontal, 6)
      .frame(minWidth: 36, minHeight: 24)
      .help("Zoom (center crop, this view only)")
      .accessibilityLabel("Zoom")
      overlayButton(UISymbol.detach, help: "Detach to Window", label: "Detach to Window") {
        context.send(.detachMonitor(cameraID: camera.id))
      }
    }
    .uiPictureControls()
  }

  private func overlayButton(_ symbol: String, help: String, label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.callout.weight(.medium))
        .frame(width: 26, height: 24).foregroundStyle(.white).contentShape(Rectangle())
        .background(on ? Color.white.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(label)
  }

  @ViewBuilder private var pictureMenu: some View {
    // A checkmark item, like View › Freeze; the menu is built on open, so it reads the current state.
    // A compact tile registers no presenter, so it has nothing to freeze or clean.
    // As in the View menu: only while the picture shows video.
    if !compact {
      Toggle("Freeze", isOn: Binding(get: { UIMonitorBridge.presenter(for: camera.id)?.isFrozen == true },
        set: { _ in context.send(.freeze(cameraID: camera.id)) }))
        .disabled(!camera.tileState.showsPicture)
      Button(isClean ? "Show Overlays" : "Clean View") { context.send(.toggleClean(cameraID: camera.id)) }
        .disabled(!camera.tileState.showsPicture)
    }
    Button("Reset Monitor Tools") { context.send(.resetMonitorTools(cameraID: camera.id)) }
    UICopySettingsMenu(camera: camera, context: context, title: "Copy Monitor Settings To")
    Divider()
    // The View menu's conditions: Single has nothing to expand or swap, and Program View no swap.
    let layout = context.presentation.layout
    if context.session.expandedFrom != nil {
      Button("Restore Layout") { context.send(.restoreLayout) }
    } else if context.presentation.cameras.count > 1 && layout != .single {
      Button("Expand Picture") { context.send(.expandPicture(cameraID: camera.id)) }
    }
    if context.presentation.cameras.count > 1 && layout != .single && layout != .programView {
      Button("Swap Pictures") { context.send(.swapPictures) }
    }
    Divider()
    Button("Detach to Window") { context.send(.detachMonitor(cameraID: camera.id)) }
    if camera.tileState == .previewHidden {
      Button("Show Preview") { context.send(.setPreviewEnabled(cameraID: camera.id, true)) }
    } else {
      Button("Hide Preview") { context.send(.setPreviewEnabled(cameraID: camera.id, false)) }
    }
    Button("Show Inspector") { context.send(.showInspector(cameraID: camera.id)) }
  }
}

/// The picture and strip both offer the same display selector in Single layout.
private struct UICameraName: View {
  let camera: UICameraPresentation
  let context: UIContext
  var onPicture = false

  var body: some View {
    if context.presentation.layout == .single, context.presentation.cameras.count > 1 {
      Menu {
        Picker("Displayed Camera", selection: Binding(get: { camera.id }, set: { context.send(.select(cameraID: $0)) })) {
          ForEach(context.presentation.cameras) { choice in
            let numberedName = "Camera \(choice.number)"
            Text(choice.name == numberedName ? numberedName : "\(choice.number) · \(choice.name)").tag(choice.id)
          }
        }
        .pickerStyle(.inline)
      } label: {
        label(choosable: true)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .help("Choose the camera shown in Single view.")
      .accessibilityLabel("Displayed Camera")
      .accessibilityValue(camera.name)
    } else {
      label(choosable: false)
        .help(onPicture ? camera.name : "\(camera.name), from \(camera.inputName)")
    }
  }

  @ViewBuilder private func label(choosable: Bool) -> some View {
    if onPicture {
      HStack(spacing: 6) {
        if context.presentation.programAvailable { UINumberCapsule(number: camera.number, onPicture: true) }
        name(choosable: choosable)
          .uiPictureMenuBacking().foregroundStyle(.white)
      }
      .contentShape(Rectangle())
    } else {
      name(choosable: choosable)
        .font(.uiTitle)
        .contentShape(Rectangle())
    }
  }

  private func name(choosable: Bool) -> some View {
    HStack(spacing: 5) {
      Text(camera.name).lineLimit(1).truncationMode(onPicture ? .tail : .middle)
      if choosable {
        Image(systemName: UISymbol.menuIndicator).font(.caption2.weight(.semibold))
          .accessibilityHidden(true)
      }
    }
  }
}

/// "Copy Settings To" with every other camera, plus Program with two or more cameras.
private struct UICopySettingsMenu: View {
  let camera: UICameraPresentation
  let context: UIContext
  let title: String
  var body: some View {
    let others = context.presentation.cameras.filter { $0.id != camera.id }
    let program = context.presentation.programAvailable
    if !others.isEmpty || program {
      Menu(title) {
        ForEach(others) { other in
          Button(other.name) { context.send(.copyMonitorSettings(from: camera.id, to: other.id)) }
        }
        if program {
          if !others.isEmpty { Divider() }
          Button("Program") { context.send(.copyMonitorSettings(from: camera.id, to: "program")) }
        }
      }
    }
  }
}

/// A camera's monitor-only LUT: a .cube file its pictures show on the Monitor
/// stage, over the burn-in LUT. Never burned in: Program and the camera output
/// keep the burn-in LUT only, and recording keeps the camera original. Saved in
/// the camera's monitor preferences as a read-only bookmark, like the burn-in LUT.
struct UIMonitorLUTMenu: View {
  let cameraID: String
  let cameraName: String
  let monitor: any UIMonitorSettingsProviding

  var body: some View {
    let preferences = monitor.preferences(for: cameraID)
    let choice = preferences.monitorLUT
    Menu("Monitor LUT") {
      if let choice {
        Text(choice.fileName.isEmpty ? "Monitor LUT chosen" : choice.fileName)
        // A file that is missing or does not parse shows nothing on the picture: say so here.
        if case .failed = monitor.monitorLUTState(for: cameraID),
          let failure = MonitorFeedHost.describe(monitor.monitorLUTState(for: cameraID)) {
          Text(failure)
        }
      }
      Button(choice == nil ? "Load Monitor LUT…" : "Replace Monitor LUT…") {
        Self.choose(cameraID: cameraID, cameraName: cameraName, monitor: monitor)
      }
      Toggle("Show Monitor LUT", isOn: Binding(
        get: { choice != nil && monitor.preferences(for: cameraID).monitorLUTEnabled },
        set: { Self.setShown($0, cameraID: cameraID, monitor: monitor) }))
        .disabled(choice == nil)
      Button("Remove Monitor LUT") { Self.remove(cameraID: cameraID, monitor: monitor) }
        .disabled(choice == nil)
    }
    .help("A LUT for this camera's monitor pictures only (the Monitor picture). It is never burned in.")
  }

  /// Asks for a .cube file, reads it (so a file that does not parse is refused
  /// before it is saved) and makes its read-only bookmark.
  static func choose(cameraID: String, cameraName: String, monitor: any UIMonitorSettingsProviding) {
    let panel = NSOpenPanel()
    panel.title = "Choose a monitor LUT for \(cameraName)"
    panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { @MainActor in
      do {
        chosen(try await MonitorFeedHost.monitorLUTLoader.load(url: url), cameraID: cameraID, monitor: monitor)
      } catch {
        let alert = NSAlert()
        alert.messageText = "Monitor LUT was not changed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
      }
    }
  }

  /// Saves a chosen file as the camera's monitor LUT, shows it, and switches the
  /// camera's pictures to the Monitor stage, the one that shows it. Every choice
  /// is a new pick, so choosing the same file again (edited, or on a volume that
  /// was not mounted) makes the feed host read it again.
  static func chosen(_ file: LoadedLUT, cameraID: String, monitor: any UIMonitorSettingsProviding) {
    var next = monitor.preferences(for: cameraID)
    next.monitorLUT = MonitorLUTChoice(bookmark: file.bookmark, fileName: file.fileName, pick: UUID())
    next.monitorLUTEnabled = true
    next.setPictureStage(.monitor)
    monitor.setPreferences(next, for: cameraID)
  }

  static func setShown(_ shown: Bool, cameraID: String, monitor: any UIMonitorSettingsProviding) {
    var next = monitor.preferences(for: cameraID)
    guard next.monitorLUT != nil else { return }
    next.monitorLUTEnabled = shown
    monitor.setPreferences(next, for: cameraID)
  }

  /// Forgets the file. A Monitor picture then shows what Output (LUT) shows.
  static func remove(cameraID: String, monitor: any UIMonitorSettingsProviding) {
    var next = monitor.preferences(for: cameraID)
    guard next.monitorLUT != nil else { return }
    next.monitorLUT = nil
    next.monitorLUTEnabled = true
    monitor.setPreferences(next, for: cameraID)
  }
}

/// Adds the named "Cut to Camera N" accessibility action only when a cut is possible.
private struct UICutAccessibilityAction: ViewModifier {
  let camera: UICameraPresentation
  let context: UIContext
  func body(content: Content) -> some View {
    if camera.showsCut && camera.cutEnabled {
      content.accessibilityAction(named: "Cut to \(camera.name)") { context.send(.cut(cameraID: camera.id)) }
    } else {
      content
    }
  }
}

/// Shows when the signal went away, the take's countdown, and a Cut when Program is manual.
/// A compact Program View tile leaves those details to the Program picture beside it.
struct UILostSignalPlaceholder: View {
  let camera: UICameraPresentation
  var compact = false
  let context: UIContext

  var body: some View {
    UIPicturePlaceholder(symbol: UISymbol.noSignal, title: compact ? "Signal lost" : camera.lostTitle ?? "Signal lost",
      compact: compact, detail: compact ? "" : camera.lostDetail ?? "",
      tint: camera.statusTone == .warning ? .orange : nil) {
      if !compact, let cut = camera.lostCut {
        UIWideCutButton(cut: cut, context: context, title: "Cut to \(cut.name)").frame(width: 220)
      }
    }
  }
}

/// The large Cut: 36 pt tall, the same stronger gray as LUT On, with the key. No white fill:
/// white already means "this is on".
struct UIWideCutButton: View {
  let cut: UICutButton
  let context: UIContext
  var title = "Cut"

  var body: some View {
    Button { context.send(.cut(cameraID: cut.id)) } label: {
      HStack(spacing: 6) {
        Image(systemName: UISymbol.cut)
        Text(title).fontWeight(.bold)
      }
      .frame(maxWidth: .infinity, minHeight: 36)
      .contentShape(Rectangle())
    }
    .buttonStyle(UISlotButtonStyle(strong: true))
    .disabled(!cut.enabled)
    // Only ⌃1–⌃4 are bound.
    .help(cut.help ?? (cut.number <= 4 ? "Cut Program to \(cut.name) (⌃\(cut.number))" : "Cut Program to \(cut.name)"))
    .accessibilityLabel("Cut to \(cut.name)")
  }
}

struct UIPicturePlaceholder<Actions: View>: View {
  let symbol: String
  let title: String
  let detail: String
  /// Small pictures (Program sources) keep the small sizes.
  var compact = false
  var showsProgress = false
  /// The glyph's color, when the placeholder is a problem.
  var tint: Color? = nil
  @ViewBuilder var actions: () -> Actions

  init(symbol: String, title: String, compact: Bool = false, detail: String, showsProgress: Bool = false,
    tint: Color? = nil, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
    self.symbol = symbol
    self.title = title
    self.compact = compact
    self.detail = detail
    self.showsProgress = showsProgress
    self.tint = tint
    self.actions = actions
  }

  var body: some View {
    ZStack {
      Color(white: 0.06)
      VStack(spacing: compact ? 6 : 8) {
        if showsProgress { ProgressView().controlSize(compact ? .small : .regular) }
        else {
          Image(systemName: symbol).font(.system(size: compact ? 26 : 32, weight: .light))
            .foregroundStyle(tint ?? .white.opacity(0.6))
        }
        Text(title).font(compact ? .callout.weight(.semibold) : .uiPlaceholderTitle).monospacedDigit()
          .foregroundStyle(.white.opacity(0.9))
        if !detail.isEmpty {
          Text(detail).font(compact ? .uiMeta : .uiRow).foregroundStyle(.white.opacity(0.6))
            .multilineTextAlignment(.center).frame(maxWidth: compact ? 380 : 440).fixedSize(horizontal: false, vertical: true)
        }
        actions().controlSize(.small).padding(.top, compact ? 2 : 4)
      }
      .padding(.horizontal, 24)
    }
    .environment(\.colorScheme, .dark)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}

/// A fixed-width control in a strip row: Cut and LUT. Drawn by hand so its state holds in a
/// window that isn't key, and so toggling never changes its width.
struct UISlotButtonStyle: ButtonStyle {
  /// LUT On and Cut: the stronger gray.
  var strong = false
  var outline: Color? = nil
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.uiRow.weight(strong ? .semibold : .medium))
      .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
      .background(fill(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(outline ?? .clear, lineWidth: 1.5))
  }

  private func fill(pressed: Bool) -> AnyShapeStyle {
    if !enabled { return AnyShapeStyle(.fill.quaternary) }
    if pressed { return AnyShapeStyle(.fill) }
    return strong ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.tertiary)
  }
}

// MARK: - Channel strip

/// A camera's own controls under its picture. Four fixed rows, so nothing appears or vanishes
/// and pressing Record never moves the picture: the name with its output controls (Cut, LUT,
/// Effects) and the gear · record · the drive's time left (or the problem) · meters. Only
/// what changes during a show is here; what's set once is in the inspector the gear opens.
struct UIChannelStripView: View {
  let camera: UICameraPresentation
  let context: UIContext
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var colorScheme

  /// Width of the leading glyph column in every row.
  private static let gutter: CGFloat = 28
  /// One row in every state: the drive and its time left, or a problem in its place.
  private static let slotHeight: CGFloat = 24
  /// The Cut slot and the LUT toggle never change width at one density.
  nonisolated static let cutWidth: CGFloat = 64
  static let lutWidth: CGFloat = 72
  /// The LUT toggle and the Effects menu as glyphs alone, in a narrow strip.
  static let glyphWidth: CGFloat = 30
  /// MonitorKit's compact level meter is 56 pt wide.
  nonisolated private static let compactMeterWidth: CGFloat = 56
  /// Whether the collapsed strip has room for its meter (set only when that changes).
  @State private var compactMeterFits = true
  /// The strip's "2 problems" is open.
  @State private var problemsOpen = false
  /// How much the header's controls spell out, from the strip's width alone (set only when
  /// that changes), so every strip of one width looks the same whatever its camera's name.
  @State private var density = HeaderDensity.full

  /// What gives way as the strip narrows: the Effects menu's word first, then the LUT
  /// toggle's and the collapse chevron (Collapse All Strips stays in the toolbar and the View
  /// menu). Cut keeps its word, and the name truncates last.
  enum HeaderDensity: Sendable { case full, effectsGlyph, glyphs }

  /// Widths the header needs with a Cut slot, each leaving a name like "Camera 2" whole:
  /// the gutter, the name, then the controls.
  nonisolated static func headerDensity(width: CGFloat, hasCut: Bool) -> HeaderDensity {
    let cut: CGFloat = hasCut ? 0 : cutWidth + 8
    if width + cut >= 432 { return .full }
    return width + cut >= 348 ? .effectsGlyph : .glyphs
  }

  private var snapshot: UICameraSnapshot? { context.snapshot(camera.id) }
  private var isRecordingOrPaused: Bool { camera.pauseTitle != nil }
  private var isClean: Bool { UICleanViewState.shared.clean.contains(camera.id) }

  /// Retry's help names the reason, which a collapsed strip doesn't show.
  private var retryHelp: String {
    "Couldn't start \(camera.name). "
      + (UICameraPictureView.startFailureReason(snapshot?.automaticStatus ?? "") ?? "Try starting the camera again.")
  }

  var body: some View {
    let _ = UIRenderProbe.count("UIChannelStripView")
    Group {
      if camera.collapsed { collapsed } else { expanded }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, camera.collapsed ? 6 : 10)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
    // The picture's ring is the one selection indicator (D7), so the strip has no accent border.
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: contrast == .increased ? 1.5 : 1))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(camera.name) controls")
  }

  /// A leading row glyph in the shared gutter. Decoration: the row's words say it.
  private func gutterIcon(_ symbol: String, color: Color = .secondary) -> some View {
    Image(systemName: symbol).font(.uiRow).foregroundStyle(color).frame(width: Self.gutter)
      .accessibilityHidden(true)
  }

  // MARK: Expanded

  private var expanded: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      Divider()
      captureRow
      recordRow
      slot
      Divider()
      HStack(spacing: 8) {
        gutterIcon(UISymbol.audio)
          .help((context.snapshot(camera.id)?.captureAudio.title ?? "Audio") + ", true peak")
        UILiveAudioMeter(cameraID: camera.id, name: camera.name, audio: camera.audio, channels: camera.channelsShown, menu: true)
      }
    }
  }

  /// The drive and its time left, or the camera's worst problem in its place. One height in
  /// every state, so the strip never grows, the pictures never shrink and Cut never moves.
  private var slot: some View {
    Group {
      if let problem = camera.stripProblem { problemRow(problem) } else { driveRow }
    }
    .frame(height: Self.slotHeight, alignment: .leading)
  }

  private func problemRow(_ problem: UIStripProblem) -> some View {
    HStack(spacing: 8) {
      gutterIcon(UISymbol.warning, color: problem.level.glyph)
      problemWords(problem, font: .uiRowEmphasis)
      Spacer(minLength: 4)
      if problem.count == 1, let action = problem.action {
        UIProblemButton(action: action, level: problem.level, context: context).padding(.trailing, 3)
      }
    }
    .frame(height: Self.slotHeight)
    .background(problem.level.fill, in: RoundedRectangle(cornerRadius: 5))
    .accessibilityElement(children: .contain)
  }

  /// What's wrong, or with more than one thing wrong, how many: then the words open the list.
  @ViewBuilder private func problemWords(_ problem: UIStripProblem, font: Font, short: Bool = false) -> some View {
    if problem.count > 1 {
      Button { problemsOpen = true } label: {
        HStack(spacing: 3) {
          Text("\(problem.count) problems")
          Image(systemName: UISymbol.expandStrip).imageScale(.small)
        }
      }
      .buttonStyle(.plain).font(font).foregroundStyle(short ? .primary : problem.level.text)
      .help("Show \(camera.name)'s problems")
      .popover(isPresented: $problemsOpen, arrowEdge: .bottom) {
        // Its countdowns ("Take ends in 40 s") and clocks tick while it's open.
        UILiveSession(context: context, refresh: 1, probe: "UILiveSession(strip problems)") { (session: UISessionSnapshot) in
          UIProblemList(problems: UIPresentationBuilder.problems(session).filter { $0.cameraID == camera.id }, context: context)
        }
        .padding(12).frame(width: 340, alignment: .leading)
      }
    } else {
      Text(short ? problem.short : problem.text).font(font).foregroundStyle(short ? .primary : problem.level.text)
        .lineLimit(1).truncationMode(.tail)
        .help(problem.text)
    }
  }

  /// The name, then what the camera sends: Cut, the LUT, Effects, and the gear that opens the
  /// inspector. The controls keep their places whatever the state; in a narrow strip their
  /// words give way (see HeaderDensity) before the name does.
  private var header: some View {
    let hasCut = context.presentation.programAvailable
    return HStack(spacing: 8) {
      if density != .glyphs { chevron }
      UICameraName(camera: camera, context: context)
      Spacer(minLength: 4)
      if hasCut { cutSlot }
      lutToggle
      UIEffectsMenu(camera: camera, snapshot: snapshot, context: context, glyphOnly: density != .full)
      inspectorButton
    }
    .frame(height: 24)
    .onGeometryChange(for: HeaderDensity.self) { Self.headerDensity(width: $0.size.width, hasCut: hasCut) } action: { density = $0 }
  }

  /// The one way from a strip into its camera's settings: the inspector, on this camera.
  private var inspectorButton: some View {
    Button { context.send(.showInspector(cameraID: camera.id)) } label: {
      Image(systemName: UISymbol.settings).font(.uiRow)
        .frame(minWidth: 24, minHeight: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help("Show \(camera.name) in the inspector")
    .accessibilityLabel("Settings for \(camera.name)")
  }

  private var chevron: some View {
    Button { context.send(.toggleCollapsed(cameraID: camera.id)) } label: {
      Image(systemName: camera.collapsed ? UISymbol.expandStrip : UISymbol.collapseStrip)
        .font(.subheadline.weight(.semibold))
        .frame(width: Self.gutter, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(camera.collapsed ? "Expand" : "Collapse")
    .accessibilityLabel(camera.collapsed ? "Expand \(camera.name)" : "Collapse \(camera.name)")
  }

  private var captureRow: some View {
    let preview = snapshot?.previewEnabled ?? true
    return HStack(spacing: 8) {
      gutterIcon(UISymbol.camera)
      cameraButton
      Spacer(minLength: 4)
      Button(preview ? "Hide Preview" : "Show Preview", systemImage: preview ? UISymbol.previewHidden : UISymbol.showPreview) {
        context.send(.setPreviewEnabled(cameraID: camera.id, !preview))
      }
      .controlSize(.small)
      .fixedSize()
      .help(previewHelp)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Capture and preview for \(camera.name)")
  }

  private var previewHelp: String {
    let scope = context.session.syncCameras ? "Show or hide previews for synced cameras." : "Show or hide this camera's on-screen picture."
    let automatic = snapshot?.automaticStart == true ? " A visible preview can request capture in automatic mode." : ""
    return scope + " Recording and video sent to meeting apps continue." + automatic
  }

  @ViewBuilder private var cameraButton: some View {
    if camera.canStop {
      Button("Stop Capture", systemImage: UISymbol.noSignal) { context.send(.stopCamera(cameraID: camera.id)) }
        .controlSize(.small)
        .fixedSize()
        .help("Stop receiving video from \(camera.inputName). This ends this camera's output and recording.")
        .accessibilityLabel("Stop Capture for \(camera.name)")
    } else if camera.automaticStartFailed {
      // One problem, one action: the same Retry the picture offers.
      Button { context.send(.retryAutomaticStart(cameraID: camera.id)) } label: {
        Label("Retry", systemImage: UISymbol.retry)
      }
      .controlSize(.small)
      // Whole in a narrow strip: the words beside it give way, not the action.
      .fixedSize()
      .help(retryHelp)
      .accessibilityLabel("Retry \(camera.name)")
    } else {
      Button { context.send(.startCamera(cameraID: camera.id)) } label: {
        Label("Start Capture", systemImage: UISymbol.camera)
      }
      .controlSize(.small)
      .fixedSize()
      .disabled(!camera.canStart)
      .help(camera.canStart ? "Start receiving video from \(camera.inputName). Use Record to save a take." : "Connect the camera's input first.")
      .accessibilityLabel("Start Capture for \(camera.name)")
    }
  }

  /// The camera-original note is on the Ready line, and always in the record button's help.
  private var recordHelp: String {
    let burnsInLUT = context.snapshot(camera.id).map { UIPresentationBuilder.recordsLUT($0, in: context.session) } ?? false
    var help = camera.recordButtonActive || isRecordingOrPaused ? camera.recordButtonHelp
      : camera.recordButtonHelp + (burnsInLUT ? " Records the camera original with its LUT burned in."
        : " Records the camera original, without LUT or effects.")
    if let fallback = camera.formatFallback { help += " \(fallback): \(camera.formatHelp)" }
    return help
  }

  private func recordButton(size: CGFloat = 28, neutralStop: Bool = false) -> some View {
    UIRecordButton(active: camera.recordButtonActive || camera.pauseTitle == "Resume", enabled: camera.recordButtonEnabled,
      help: recordHelp, size: size, neutralStop: neutralStop, name: camera.name) {
      context.send(.toggleRecording(cameraID: camera.id))
    }
  }

  /// The state's glyph before its word. The word stays in a label color.
  @ViewBuilder private func recordGlyph(_ camera: UICameraPresentation) -> some View {
    switch camera.stripState {
    case .recording, .updating: UIStateGlyph(state: .recording, size: 7)
    case .paused: UIStateGlyph(state: .paused)
    case .recordingNoSignal, .noFolder: UIStateGlyph(state: .warning)
    // On the amber row the triangle is dark, like its words.
    case .failed: Image(systemName: UISymbol.warning).imageScale(.small).foregroundStyle(.primary).accessibilityHidden(true)
    case .saved: Image(systemName: UISymbol.saved).foregroundStyle(.green).imageScale(.small).accessibilityHidden(true)
    default: EmptyView()
    }
  }

  /// The take's clock and drops follow its statistics in this row alone.
  private var recordRow: some View {
    UILiveCamera(camera: camera, context: context, follows: .take) { live in recordRow(live.camera) }
      .frame(height: 44)
      // A take that ended early is damage to what was rolling: solid amber, dark text, edge to edge.
      .padding(.horizontal, camera.stripState == .failed ? 12 : 0)
      .background(camera.stripState == .failed ? Color.orange : .clear)
      .environment(\.colorScheme, camera.stripState == .failed ? .light : colorScheme)
      .padding(.horizontal, camera.stripState == .failed ? -12 : 0)
  }

  private func recordRow(_ camera: UICameraPresentation) -> some View {
    HStack(spacing: 8) {
      Group {
        if camera.stripState == .finishing { ProgressView().controlSize(.small) } else { recordButton() }
      }
      .frame(width: Self.gutter, height: 28)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          recordGlyph(camera)
          Text(camera.recordTitle).monospacedDigit()
        }
        .font(.uiRowEmphasis)
        if isRecordingOrPaused {
          Text(camera.recordDetail).font(.uiClock)
            .foregroundStyle(camera.stripState == .paused ? .secondary : .primary)
            .help(camera.takeAudioHelp ?? "")
        } else {
          Text(camera.recordDetail).font(.uiMeta).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(.secondary)
            .help(camera.takeAudioHelp.map { "\(camera.recordDetail)\n\($0)" } ?? camera.recordDetail)
        }
      }
      .layoutPriority(1)
      if let drops = camera.dropsLine {
        dropsLine(drops, warning: camera.dropsWarning).padding(.leading, 6)
      } else if camera.stripState == .saved, let note = camera.recordingNote {
        noteLine(note)
      }
      Spacer(minLength: 4)
      recordActions
    }
    .accessibilityElement(children: .contain)
  }

  /// "✓ 0 dropped", the count strong. While the signal is lost: "Losing frames" with the
  /// triangle, so a green tick never sits beside the countdown.
  private func dropsLine(_ text: String, warning: Bool) -> some View {
    HStack(spacing: 4) {
      Image(systemName: warning ? UISymbol.warning : UISymbol.saved)
        .foregroundStyle(warning ? .orange : .green).imageScale(.small)
        .accessibilityHidden(true)
      if let space = text.firstIndex(of: " "), text.first?.isNumber == true {
        Text(text[..<space]).font(.uiValueStrong).foregroundStyle(.primary)
        Text(text[text.index(after: space)...]).font(.uiMeta).foregroundStyle(warning ? .primary : .secondary)
      } else {
        Text(text).font(.uiRow).foregroundStyle(.primary)
      }
      if let note = camera.recordingNote { noteLine(note) }
    }
    .lineLimit(1)
    .accessibilityElement(children: .combine)
  }

  /// A take's note that needs a look, with the orange warning symbol.
  private func noteLine(_ note: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: UISymbol.warning).foregroundStyle(.orange).imageScale(.small)
      Text(note).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
    }
    .font(.uiMeta)
    .help(note)
  }

  @ViewBuilder private var recordActions: some View {
    switch camera.stripState {
    case .recording, .recordingNoSignal, .updating, .paused:
      if let pause = camera.pauseTitle {
        Button(pause, systemImage: pause == "Pause" ? UISymbol.paused : UISymbol.start) {
          context.send(.pauseOrResume(cameraID: camera.id))
        }
        .controlSize(.small).fixedSize()
        .accessibilityLabel("\(pause) \(camera.name)")
      }
    case .saved:
      if let url = snapshot?.recording.savedURL {
        Button("Show in Finder", systemImage: UISymbol.folder) { context.send(.revealInFinder(url)) }.controlSize(.small).fixedSize()
      }
    case .noFolder:
      Button("Choose Folder…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }.controlSize(.small).fixedSize()
    case .failed:
      // One action. Out of space, the next take needs another folder (or room on this
      // drive); otherwise Details shows why. Looking never clears the row: × does (and ⋯).
      if camera.diskFull {
        Button("Choose Folder…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }.controlSize(.small).fixedSize()
      } else {
        Button("Details") { context.send(.openDiagnosticsSection(.camera(camera.id))) }.controlSize(.small).fixedSize()
        Button { context.send(.acknowledgeStop(cameraID: camera.id)) } label: {
          Image(systemName: UISymbol.close).font(.uiMeta.weight(.semibold))
            .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Dismiss. The strip goes back to the take's result.")
        .accessibilityLabel("Dismiss \(camera.name)'s ended take")
      }
    case .waiting:
      // The strip says a folder is also needed; offer it now rather than after the signal arrives.
      if let recording = snapshot?.recording, recording.folderPath == nil {
        Button("Choose Folder…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }.controlSize(.small).fixedSize()
      }
    case .stopped, .finishing, .ready:
      EmptyView()
    }
  }

  /// The drive this camera records to and the time left on it: the one recording fact that
  /// differs from camera to camera during a show. The folder's path is in the inspector and
  /// the format in Record's popover; only a camera that can't use that format says so here.
  /// The time follows the take, re-read every few seconds, in this row alone.
  private var driveRow: some View {
    UILiveCamera(snapshotFor: camera, context: context, follows: .take, refresh: 5) { live in
      let snapshot = live ?? self.snapshot
      HStack(spacing: 6) {
        if let path = snapshot?.recording.folderPath {
          let drive = snapshot.flatMap { UIPresentationBuilder.drive(for: $0, in: context.session) }
          let low = drive.map { UIPresentationBuilder.isLow($0) || UIPresentationBuilder.isFull($0) } ?? false
          Image(systemName: UISymbol.drive(low: low)).foregroundStyle(low ? Color.orange : .secondary).imageScale(.small)
            .frame(width: Self.gutter).accessibilityHidden(true)
          Text(drive?.name ?? UIFormat.folderName(path)).font(.uiValueStrong).lineLimit(1).truncationMode(.middle)
          if let seconds = snapshot?.recording.secondsLeft {
            UIValue(parts: UIFormat.durationParts(seconds))
            Text("left").foregroundStyle(.secondary).fixedSize()
          }
        } else {
          Image(systemName: UISymbol.folder).foregroundStyle(.secondary).imageScale(.small)
            .frame(width: Self.gutter).accessibilityHidden(true)
          Text("No folder chosen").foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 4)
        formatFallbackChip
      }
      .font(.uiMeta)
      .help(snapshot?.recording.folderPath ?? "Choose a recording folder in the inspector or Record's popover.")
      .accessibilityElement(children: .combine)
    }
  }

  /// "ProRes 4444 → ProRes 422 HQ", only when this camera's source can't record the session's format.
  @ViewBuilder private var formatFallbackChip: some View {
    if let fallback = camera.formatFallback {
      HStack(spacing: 4) {
        UIStateGlyph(state: .warning)
        Text(fallback).font(.uiBadge).lineLimit(1)
      }
      .fixedSize()
      .help(camera.formatHelp)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Format \(fallback)")
    }
  }

  // The output controls sit in the header: the Cut slot, the LUT toggle and the Effects
  // menu. The LUT is one click because it changes pixels, never the format; everything in
  // the menu changes what meeting apps receive, so it takes two deliberate clicks. What the
  // camera sends ("1080p 29.97") is the menu's first row and the inspector's Effects section.

  /// A fixed 64 pt slot: Cut, Next while a cut is pending, or the plain gray state of the
  /// camera on Program, so the pill stays the only filled red.
  @ViewBuilder private var cutSlot: some View {
    if context.session.onAirID == camera.id {
      HStack(spacing: 4) {
        Image(systemName: UISymbol.program).imageScale(.small)
        Text(camera.tally == .onAir ? "On air" : "Program")
      }
      .font(.uiRow).foregroundStyle(.secondary)
      .lineLimit(1).minimumScaleFactor(0.85)
      .frame(width: Self.cutWidth, alignment: .leading)
      .accessibilityElement(children: .combine)
    } else {
      let pending = context.session.pendingCutID == camera.id
      Button { context.send(.cut(cameraID: camera.id)) } label: {
        HStack(spacing: 4) {
          if pending { Circle().fill(.green).frame(width: 6, height: 6) }
          else { Image(systemName: UISymbol.cut).imageScale(.small) }
          Text(pending ? "Next" : "Cut")
        }
        .frame(width: Self.cutWidth, height: 24)
        .contentShape(Rectangle())
      }
      .buttonStyle(UISlotButtonStyle(outline: pending ? .green : nil))
      .disabled(!camera.cutEnabled)
      .help(camera.cutHelp ?? (camera.number <= 4 ? "Cut Program to \(camera.name) (⌃\(camera.number))" : "Cut Program to \(camera.name)"))
      .accessibilityLabel(pending ? "\(camera.name), cut pending" : "Cut to \(camera.name)")
    }
  }

  /// `LUT On` or `LUT Off`, one click, fixed width. With Sync cameras on it changes every camera.
  /// With no LUT loaded (and none loading) it's `Load LUT…`, which asks for one, in the same slot.
  @ViewBuilder private var lutToggle: some View {
    let on = camera.lutIsOn
    // An expanded strip's narrowest density draws the glyph alone; a collapsed strip keeps the words.
    let glyph = !camera.collapsed && density == .glyphs
    if camera.lutChip?.enabled != true && snapshot?.lutLoading != true {
      Button { context.send(.chooseLUT(cameraID: camera.id)) } label: {
        Group {
          if glyph { Image(systemName: UISymbol.lut(on: false)) } else { Text("Load LUT…").lineLimit(1).minimumScaleFactor(0.85) }
        }
        .frame(width: glyph ? Self.glyphWidth : Self.lutWidth, height: 24)
        .contentShape(Rectangle())
      }
      .buttonStyle(UISlotButtonStyle())
      .help("Choose a .cube LUT for \(camera.name).")
      .accessibilityLabel("Load LUT for \(camera.name)")
    } else {
      lutOnOff(on, glyph: glyph)
    }
  }

  private func lutOnOff(_ on: Bool, glyph: Bool) -> some View {
    Button { context.send(.setEffect(cameraID: camera.id, index: 0, !on)) } label: {
      Group {
        if glyph {
          Image(systemName: UISymbol.lut(on: on))
        } else {
          Label(on ? "LUT On" : "LUT Off", systemImage: UISymbol.lut(on: on)).labelStyle(.titleAndIcon)
        }
      }
      .frame(width: glyph ? Self.glyphWidth : Self.lutWidth, height: 24)
      .contentShape(Rectangle())
    }
    .buttonStyle(UISlotButtonStyle(strong: on))
    .disabled(!camera.lutEnabled)
    .help(lutHelp)
    .accessibilityLabel("LUT for \(camera.name)")
    .accessibilityValue(on ? "On" : "Off")
  }

  private var lutHelp: String {
    if !camera.processing { return "Effects are off: the camera original goes out unchanged." }
    // Without a LUT the slot is Load LUT…, unless one is still loading.
    guard camera.lutChip?.enabled == true else { return "\(camera.name)'s LUT is loading." }
    var help = camera.lutIsOn ? "Turn the LUT off. Meeting apps keep their format." : "Turn the LUT on. Meeting apps keep their format."
    if context.session.syncCameras { help += " Sync cameras is on, so this changes every camera." }
    return help
  }

  // MARK: Collapsed

  /// Name · state · LUT · gear · meter · Stop: the meter keeps the gear away from Stop, so a
  /// miss can't end a take. Four Up has no tile Cut, so its strips carry the Cut slot. Short of room the
  /// name keeps its own, and the rest yield in turn: the meter, the LUT slot (the inspector loads one),
  /// then the problem's button (expanded, the strip's problem row keeps it).
  private var collapsed: some View {
    HStack(spacing: 8) {
      // Four Up and Program View keep every strip collapsed: no chevron that would do nothing.
      if context.presentation.cameras.count > 1,
        context.presentation.layout == .fourUp || context.presentation.layout == .programView {
        Color.clear.frame(width: Self.gutter, height: 24)
      } else {
        chevron
      }
      UICameraName(camera: camera, context: context)
        .frame(minWidth: 48, alignment: .leading)
        .layoutPriority(1)
      if isClean && camera.tally != .none {
        // Clean View hides the picture's pill, so the tally is said here.
        UIBadge(text: camera.tally.label ?? "", tone: camera.tally.isRed ? .onAir : camera.tally == .next ? .positive : .neutral)
      }
      collapsedState
      Spacer(minLength: 4)
      if context.presentation.layout == .fourUp && context.presentation.programAvailable { cutSlot }
      // Whole or not at all, after the meter.
      ViewThatFits(in: .horizontal) {
        lutToggle
        Color.clear.frame(width: 0, height: 0)
      }
      .layoutPriority(-1)
      inspectorButton
      // One meter, outside ViewThatFits: each candidate would run its own display-rate meter,
      // and a swap between candidates (a column animating) restarted its ballistics. It yields first.
      Color.clear.frame(minWidth: 0, idealWidth: Self.compactMeterWidth, maxWidth: Self.compactMeterWidth, maxHeight: 1)
        .layoutPriority(-2)
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.compactMeterWidth } action: { compactMeterFits = $0 }
        .overlay(alignment: .trailing) {
          if compactMeterFits {
            // Collapsed strips always show channels 1–2.
            UILiveAudioMeter(cameraID: camera.id, name: camera.name, audio: camera.audio, style: .compact, channels: .two)
          }
        }
      if camera.stripState == .finishing {
        ProgressView().controlSize(.mini).frame(width: 24, height: 24)
      } else {
        // Rolling: a neutral square, always. The REC pill already says it's rolling.
        recordButton(size: 24, neutralStop: true)
      }
    }
    .frame(height: 28)
  }

  /// A problem takes the state slot with its short name and action; otherwise the state word.
  /// Rolling says nothing here, since the REC pill does, unless Clean View hides the pill.
  @ViewBuilder private var collapsedState: some View {
    if let problem = camera.stripProblem {
      HStack(spacing: 4) {
        UIStateGlyph(state: .warning)
        problemWords(problem, font: .uiRow, short: true)
        if problem.count == 1, let action = problem.action {
          // The expanded row's button, in label colors: there's no amber behind it here. Whole or
          // not at all, after the meter and the LUT slot.
          ViewThatFits(in: .horizontal) {
            UIProblemButton(action: action, level: .notice, context: context)
            Color.clear.frame(width: 0, height: 0)
          }
          .layoutPriority(-1)
        }
      }
    } else if isClean, isRecordingOrPaused {
      UILiveCamera(snapshotFor: camera, context: context, follows: .take) { snapshot in
        HStack(spacing: 4) {
          UIStateGlyph(state: camera.stripState == .paused ? .paused : .recording, size: 7)
          Text(UIFormat.shortElapsed(snapshot?.recording.elapsed ?? 0)).font(.uiValueStrong)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording \(UIFormat.shortElapsed(snapshot?.recording.elapsed ?? 0))")
      }
    } else if let word = camera.collapsedWord {
      HStack(spacing: 4) {
        if camera.collapsedWarns { UIStateGlyph(state: .warning) }
        else if camera.stripState == .paused { UIStateGlyph(state: .paused) }
        else if camera.stripState == .saved {
          Image(systemName: UISymbol.saved).foregroundStyle(.green).imageScale(.small).accessibilityHidden(true)
        }
        Text(word).foregroundStyle(camera.collapsedWarns ? .primary : .secondary).lineLimit(1)
      }
      .font(.uiRow)
      .accessibilityElement(children: .combine)
      .help(camera.formatFallback.map { "\($0). \(camera.formatHelp)" } ?? word)
      // A take that ended early keeps Details collapsed too: it says why. Looking doesn't put the
      // take away: × does, as on the expanded strip.
      if camera.stripState == .failed, !camera.diskFull {
        Button("Details") { context.send(.openDiagnosticsSection(.camera(camera.id))) }
          .controlSize(.small).fixedSize()
          .accessibilityLabel("Details for \(camera.name)")
        Button { context.send(.acknowledgeStop(cameraID: camera.id)) } label: {
          Image(systemName: UISymbol.close).font(.uiMeta.weight(.semibold))
            .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Dismiss. The strip goes back to the take's result.")
        .accessibilityLabel("Dismiss \(camera.name)'s ended take")
      }
    }
  }
}

/// Every effect that changes what meeting apps receive: Output size (with Aspect), Color
/// format, Frame rate, the camera's HDMI display, and Effects Off.
struct UIEffectsMenu: View {
  let camera: UICameraPresentation
  let snapshot: UICameraSnapshot?
  let context: UIContext
  /// A narrow strip draws the menu as its symbol alone; its words stay its spoken name.
  var glyphOnly = false

  var body: some View {
    let styled = menu
      .font(.uiRow.weight(.medium))
      .padding(.horizontal, glyphOnly ? 4 : 8).frame(height: 24)
      .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 7))
      .help((glyphOnly ? "\(effectsWord). " : "") + "Effects change the format meeting apps receive; the video updates briefly. ⇧⌘B turns them all off.")
    // With its words the menu names itself. As a glyph it would be named after its symbol.
    if glyphOnly { styled.accessibilityLabel(effectsWord) } else { styled }
  }

  private var effectsWord: String { camera.processing ? "Effects" : "Effects Off" }

  private var menu: some View {
    Menu {
      if let source = snapshot.flatMap(Self.sourceFormat) {
        Text("\(source) → \(camera.outputValue)")
      }
      Menu {
        effectPicker(index: 1, current: snapshot?.resizeTarget ?? .hd1080, all: ResizeTarget.allCases, title: \.title) {
          .setResizeTarget(cameraID: camera.id, $0)
        }
        Divider()
        Section("Aspect") {
          Picker("Aspect", selection: Binding(get: { snapshot?.scalingMode ?? .fit },
            set: { context.send(.setScalingMode(cameraID: camera.id, $0)) })) {
            Text("Fit").tag(ProgramScalingMode.fit)
            Text("Crop").tag(ProgramScalingMode.crop)
          }
          .pickerStyle(.inline).labelsHidden()
        }
        if let snapshot, snapshot.showsAllowUpscale {
          Toggle("Allow upscaling", isOn: Binding(get: { snapshot.allowUpscale },
            set: { context.send(.setAllowUpscale(cameraID: camera.id, $0)) }))
        }
      } label: { Text("Output size") }
      .badge(effectBadge(1))
      Menu {
        effectPicker(index: 2, current: snapshot?.colorTarget ?? .yuv4208, all: ColorTarget.allCases, title: \.title) {
          .setColorTarget(cameraID: camera.id, $0)
        }
      } label: { Text("Color format") }
      .badge(effectBadge(2))
      Menu {
        effectPicker(index: 3, current: snapshot?.frameRateTarget ?? .fps2997, all: FrameRateTarget.allCases, title: \.title) {
          .setFrameRateTarget(cameraID: camera.id, $0)
        }
      } label: { Text("Frame-rate cap") }
      .badge(effectBadge(3))
      if let store = context.cameraControls {
        UICameraDisplayToggle(feedID: camera.id, store: store)
      }
      Divider()
      // ⇧⌘B is the Camera menu's, for the selected camera: one handler per key.
      Toggle("Effects Off", isOn: Binding(get: { !camera.processing }, set: { context.send(.setProcessing(cameraID: camera.id, !$0)) }))
      if !camera.processing { Text("Camera original goes out unchanged.") }
    } label: {
      // One Text with the symbol inside it: a borderless menu names its button after a
      // separate image view ("hdr" for this one), and the words are the name.
      // The gap after the symbol is kerning, not a space, so the name has no stray leading
      // character. Any modifier on this label makes the menu host a view, which loops layout.
      // One Text either way, so the glyph-only form is the same kind of label.
      glyphOnly ? Text(Image(systemName: camera.processing ? UISymbol.effects : UISymbol.effectsOff))
        : Text("\(Text(Image(systemName: camera.processing ? UISymbol.effects : UISymbol.effectsOff)).kerning(5))\(effectsWord)")
    }
    // Borderless keeps the items reachable by VoiceOver and the keyboard.
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private static func sourceFormat(_ snapshot: UICameraSnapshot) -> String? {
    if case .live(let format) = snapshot.signal { return format }
    return nil
  }

  /// A menu row can't both toggle and open, so Off is the submenu's first choice.
  private func effectPicker<Target: Hashable>(index: Int, current: Target, all: [Target], title: KeyPath<Target, String>,
    action: @escaping (Target) -> UIAction) -> some View {
    let on = camera.chips.indices.contains(index) && camera.chips[index].isOn
    return Picker("Value", selection: Binding<Target?>(get: { on ? current : nil }, set: { value in
      if let value { context.send(action(value)) } else { context.send(.setEffect(cameraID: camera.id, index: index, false)) }
    })) {
      Text("Off").tag(Target?.none)
      Divider()
      ForEach(all, id: \.self) { Text($0[keyPath: title]).tag(Target?.some($0)) }
    }
    .pickerStyle(.inline).labelsHidden()
    .disabled(!camera.processing)
  }

  /// The value when the effect is on, "Off" otherwise: the row's state without a checkmark,
  /// which a submenu row can't show.
  private func effectBadge(_ index: Int) -> Text {
    let chip = camera.chips.indices.contains(index) ? camera.chips[index] : nil
    return Text(chip?.isOn == true ? chip?.title ?? "" : "Off")
  }
}

/// The camera's own display on its HDMI output, when its control plugin can switch it. It's
/// carried by the signal, so it lives with the effects that change what goes out.
private struct UICameraDisplayToggle: View {
  let feedID: String
  let store: CameraControlStore

  var body: some View {
    let state = store.state(for: feedID)
    if state.connected, let property = state.properties.first(where: { $0.role == .cameraDisplay }),
      property.writable, case .boolean(let enabled) = property.value {
      Toggle(property.localizedLabel(), isOn: Binding(get: { enabled }, set: { value in
        Task { await store.set(property, value: .boolean(value), feedID: feedID) }
      }))
      .disabled(state.busy)
      .help(property.localizedUnavailableReason() ?? property.localizedLabel())
    }
  }
}
