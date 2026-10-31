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
  @State private var zoom = 1.0
  /// Narrow enough that the name row can't hold the full tool bar: it takes its own row.
  @State private var narrow = false
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
  private var switching: Bool { context.presentation.programAvailable }
  /// Clean View hides the overlays, pills included; the tally ring stays, and hover still
  /// brings the tools and view controls back so Clean View can be turned off again.
  private var isClean: Bool { !compact && UICleanViewState.shared.clean.contains(camera.id) }

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
    .contentShape(Rectangle())
    .onTapGesture { context.send(.select(cameraID: camera.id)) }
    .onHover { hovering = $0 }
    .onGeometryChange(for: Bool.self) { $0.size.width < UIMonitorToolButtons.ownRowBelow } action: { narrow = $0 }
    .onGeometryChange(for: Bool.self) { $0.size.width >= 480 } action: { showsTimecode = $0 }
    // Only Full Keyboard Access focuses a picture: a click or window activation doesn't, so it
    // can't silently move the target of ⌘R. Focus reveals the controls and never selects.
    .focusable(!compact, interactions: .activate)
    // The selection ring is the focus ring (D7); the system ring would draw a second one.
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
        tint: .orange)
    case .unsupported(let mode):
      UIPicturePlaceholder(symbol: UISymbol.warning, title: "Unsupported format", compact: compact,
        detail: mode.isEmpty ? "Choose a format supported by this capture device and the current processing route." : "\(mode) Choose a supported source format or check the capture diagnostics.",
        tint: .orange) {
        Button("Show Diagnostics") { context.send(.openDiagnostics) }
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
          Button("Start", systemImage: UISymbol.start) { context.send(.startCamera(cameraID: camera.id)) }
            .disabled(!camera.canStart)
        }
      }
    case .stopped where camera.automaticStartFailed:
      UIPicturePlaceholder(symbol: UISymbol.warning, title: "Couldn't start \(camera.name)", compact: compact,
        detail: startFailureDetail, tint: .orange) {
        Button("Retry", systemImage: UISymbol.retry) { context.send(.retryAutomaticStart(cameraID: camera.id)) }
      }
    case .stopped:
      UIPicturePlaceholder(symbol: UISymbol.camera, title: "Camera stopped", compact: compact, detail: "Start the camera to see its picture.") {
        // The expanded strip's header has the same button just below.
        if camera.collapsed {
          Button("Start Camera", systemImage: UISymbol.start) { context.send(.startCamera(cameraID: camera.id)) }
            .disabled(!camera.canStart)
        }
      }
    case .previewHidden:
      UIPicturePlaceholder(symbol: UISymbol.previewHidden, title: "Preview hidden", compact: compact,
        detail: "Camera output continues. Hidden previews do no rendering work.") {
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
    VStack(spacing: 6) {
      HStack(alignment: .center, spacing: 6) {
        if !isClean {
          identity
        }
        Spacer(minLength: 4)
        if !(narrow && hovering) { tools }
      }
      // Too narrow for the bar beside the name: on hover it takes its own row, right aligned.
      if narrow && hovering {
        HStack {
          Spacer(minLength: 0)
          tools
        }
      }
      Spacer(minLength: 0)
      if !isClean, let store = context.cameraControls {
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
            UILiveCamera(camera: camera, context: context, follows: .capture) { live in
              Text(live.camera.timecode).font(.uiOverlay.monospacedDigit()).uiPictureOverlay()
                .accessibilityLabel("Timecode \(live.camera.timecode)")
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
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
  }

  /// Number, name, tally, and what the picture isn't: Frozen, a stage before the output, a zoom.
  @ViewBuilder private var identity: some View {
    if switching {
      UINumberCapsule(number: camera.number, onPicture: true)
    }
    Text(camera.name)
      .font(.uiOverlay)
      .lineLimit(1).truncationMode(.tail)
      .uiPictureOverlay()
      .help(camera.name)
      // The name keeps its room; the tool bar takes its own row instead.
      .layoutPriority(1)
    UITallyBadge(tally: camera.tally)
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

  /// The tools button and enabled tools at rest; the full bar on hover. Clean View shows
  /// none at rest.
  @ViewBuilder private var tools: some View {
    if !isClean || hovering {
      UIMonitorToolButtons(camera: camera, context: context, expanded: hovering)
    }
  }

  /// The take's clock follows its statistics here, not in the picture. One clock per camera:
  /// the digits show here only while the strip is collapsed. The CPU copy pill yields first,
  /// so REC never truncates.
  private var recordingPill: some View {
    UILiveCamera(camera: camera, context: context, follows: .all) { live in
      HStack(spacing: 6) {
        if live.snapshot?.ingestCPUCopyActive == true {
          HStack(spacing: 4) {
            UIStateGlyph(state: .warning)
            Text("CPU copy")
            Text("\(live.snapshot?.ingestCPUCopyFrames ?? 0)").monospacedDigit()
          }
          .font(.uiOverlay).lineLimit(1).uiPictureOverlay()
          .layoutPriority(-1)
          .help("Ingest is copying frames on the CPU: \(live.snapshot?.ingestCPUCopyFrames ?? 0) so far. Diagnostics has the route.")
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("CPU copy for ingest")
        }
        recordingPill(live.snapshot)
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
        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).imageScale(.small)
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
      overlayButton(UISymbol.freeze, help: "Freeze (⌃⌥F)", label: "Freeze") { context.send(.freeze(cameraID: camera.id)) }
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

  private func overlayButton(_ symbol: String, help: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.callout.weight(.medium))
        .frame(width: 26, height: 24).foregroundStyle(.white).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(label)
  }

  @ViewBuilder private var pictureMenu: some View {
    // A checkmark item, like View › Freeze; the menu is built on open, so it reads the current state.
    Toggle("Freeze", isOn: Binding(get: { UIMonitorBridge.presenter(for: camera.id)?.isFrozen == true },
      set: { _ in context.send(.freeze(cameraID: camera.id)) }))
    Button(isClean ? "Show Overlays" : "Clean View") { context.send(.toggleClean(cameraID: camera.id)) }
    Button("Reset Monitor Tools") { context.send(.resetMonitorTools(cameraID: camera.id)) }
    UICopySettingsMenu(camera: camera, context: context, title: "Copy Monitor Settings To")
    Divider()
    if context.session.expandedFrom != nil {
      Button("Restore Layout") { context.send(.restoreLayout) }
    } else if context.presentation.cameras.count > 1 {
      Button("Expand Picture") { context.send(.expandPicture(cameraID: camera.id)) }
    }
    if context.presentation.cameras.count > 1 {
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

/// A camera that had a picture and lost it: how long ago, the take's countdown, and, with
/// Auto off on Program, a large Cut. Orange everywhere; red stays for frames arriving. A
/// Program View tile says only "Signal lost": the Program picture beside it carries the rest.
struct UILostSignalPlaceholder: View {
  let camera: UICameraPresentation
  var compact = false
  let context: UIContext

  var body: some View {
    UIPicturePlaceholder(symbol: UISymbol.noSignal, title: compact ? "Signal lost" : camera.lostTitle ?? "Signal lost",
      compact: compact, detail: compact ? "" : camera.lostDetail ?? "", tint: .orange) {
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
        if cut.number <= 4 { Text("⌃\(cut.number)").foregroundStyle(.secondary) }
      }
      .frame(maxWidth: .infinity, minHeight: 36)
      .contentShape(Rectangle())
    }
    .buttonStyle(UISlotButtonStyle(strong: true))
    .disabled(!cut.enabled)
    .help(cut.help ?? "Cut Program to \(cut.name) (⌃\(cut.number))")
    .accessibilityLabel("Cut to \(cut.name)")
    .environment(\.colorScheme, .dark)
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

/// A camera's own controls under its picture. Fixed rows, so nothing appears or vanishes and
/// pressing Record never moves the picture: header · record · folder and format (or the
/// problem) · output · meters. Every row starts with a glyph in the same gutter.
struct UIChannelStripView: View {
  let camera: UICameraPresentation
  let context: UIContext
  @Environment(\.colorSchemeContrast) private var contrast

  /// Width of the leading glyph column in every row.
  private static let gutter: CGFloat = 28
  /// One row in every state: the folder, or a problem in its place.
  private static let folderRowHeight: CGFloat = 24
  /// The Cut slot and the LUT toggle never change width.
  static let cutWidth: CGFloat = 64
  static let lutWidth: CGFloat = 72
  /// MonitorKit's compact level meter is 56 pt wide.
  nonisolated private static let compactMeterWidth: CGFloat = 56
  /// Whether the collapsed strip has room for its meter (set only when that changes).
  @State private var compactMeterFits = true
  /// The strip's "2 problems" is open.
  @State private var problemsOpen = false
  /// The Camera Control sheet, from ⋯.
  @State private var controlOpen = false

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
    .sheet(isPresented: $controlOpen) {
      if let store = context.cameraControls {
        UICameraControlSettings(feedID: camera.id, name: camera.name, store: store, viewFactories: context.controlViewFactories)
      }
    }
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
      recordRow
      folderSlot
      Divider()
      outputRow
      HStack(spacing: 8) {
        gutterIcon(UISymbol.audio)
          .help("Embedded audio, true peak")
        UILiveAudioMeter(cameraID: camera.id, name: camera.name, audio: camera.audio)
      }
    }
  }

  /// The folder row, or the camera's worst problem in its place. One height in every
  /// state, so the strip never grows, the pictures never shrink and Cut never moves.
  private var folderSlot: some View {
    Group {
      if let problem = camera.stripProblem { problemRow(problem) } else { folderRow }
    }
    .frame(height: Self.folderRowHeight, alignment: .leading)
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
    .frame(height: Self.folderRowHeight)
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
        UIProblemList(problems: context.presentation.problems.filter { $0.cameraID == camera.id }, context: context)
          .padding(12).frame(width: 340, alignment: .leading)
      }
    } else {
      Text(short ? problem.short : problem.text).font(font).foregroundStyle(short ? .primary : problem.level.text)
        .lineLimit(1).truncationMode(.tail)
        .help(problem.text)
    }
  }

  /// Start, or Retry, takes the header's slot while the camera is stopped. Stop Camera is in ⋯.
  private var header: some View {
    HStack(spacing: 8) {
      chevron
      if let brand = feedBrand {
        UIFeedBrandMark(descriptor: brand)
      }
      Text(camera.name).font(.uiTitle).lineLimit(1).truncationMode(.middle)
        .help("\(camera.name) · \(camera.inputName)")
      UIFeedSettingsMenu(camera: camera, snapshot: snapshot, controlStore: context.cameraControls,
        viewFactories: context.controlViewFactories)
      Spacer(minLength: 4)
      cameraButton
      overflowMenu
    }
    .frame(height: 24)
  }

  private var feedBrand: VendorDescriptor? {
    if let store = context.cameraControls, let assignment = store.assignment(for: camera.id) {
      return store.descriptor(for: assignment.camera.pluginID)
    }
    return snapshot?.inputID.flatMap { context.captureVendors[$0] }
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

  @ViewBuilder private var cameraButton: some View {
    if camera.canStop {
      EmptyView()
    } else if camera.automaticStartFailed {
      // One problem, one action: the same Retry the picture offers.
      Button { context.send(.retryAutomaticStart(cameraID: camera.id)) } label: {
        Label("Retry", systemImage: UISymbol.retry)
      }
      .controlSize(.small)
      .help(retryHelp)
      .accessibilityLabel("Retry \(camera.name)")
    } else {
      Button { context.send(.startCamera(cameraID: camera.id)) } label: {
        Label("Start Camera", systemImage: UISymbol.start)
      }
      .controlSize(.small)
      .disabled(!camera.canStart)
      .help(camera.canStart ? "Start capture from \(camera.inputName)." : "Connect the camera's input first.")
      .accessibilityLabel("Start \(camera.name)")
    }
  }

  /// Trimmed to what a live operator reaches for. Restart Camera sits above Stop: a hang is
  /// the only live reason to open this menu.
  private var overflowMenu: some View {
    Menu {
      Button("Show Inspector") { context.send(.showInspector(cameraID: camera.id)) }
      if context.presentation.programAvailable {
        // ⌃n belongs to the Program menu. The badge only shows it: a keyboard
        // shortcut here would give the menu a second handler for the same key.
        Button("Cut to \(camera.name)") { context.send(.cut(cameraID: camera.id)) }
          .disabled(!camera.cutEnabled)
          .badge(camera.number <= 4 ? Text("⌃\(camera.number)") : nil)
      }
      Divider()
      Button(camera.recordButtonActive || camera.pauseTitle == "Resume" ? "Stop Recording" : "Record") {
        context.send(.toggleRecording(cameraID: camera.id))
      }
      .disabled(!camera.recordButtonEnabled)
      if let pause = camera.pauseTitle {
        Button(pause == "Pause" ? "Pause Recording" : "Resume Recording") { context.send(.pauseOrResume(cameraID: camera.id)) }
      }
      Divider()
      UICopySettingsMenu(camera: camera, context: context, title: "Copy Monitor Settings To")
      if context.cameraControls != nil {
        Button("Camera Control…") { controlOpen = true }
      }
      Divider()
      // The one rename alert lives on the main window; this only asks for it.
      Button("Rename…") { context.send(.beginRename(cameraID: camera.id)) }
        .help("Rename \(camera.name)")
      Button("Diagnostics…") { context.send(.openDiagnostics) }
      Divider()
      if camera.canStop {
        Button("Restart Camera") { context.send(.restartCamera(cameraID: camera.id)) }
          .help("Reopen \(camera.name)'s output. Capture and the take keep running.")
        Button("Stop Camera") { context.send(.stopCamera(cameraID: camera.id)) }
      } else {
        Button("Start Camera") { context.send(.startCamera(cameraID: camera.id)) }.disabled(!camera.canStart)
      }
      Button("Remove Camera…") { context.send(.removeCamera(cameraID: camera.id)) }
        .disabled(!camera.canRemove)
        .help(camera.removeHelp)
    } label: {
      Label("More", systemImage: UISymbol.more).labelStyle(.iconOnly)
        .frame(minWidth: 24, minHeight: 24)
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .menuIndicator(.hidden)
    .fixedSize()
    .frame(minWidth: 24, minHeight: 24)
    .contentShape(Rectangle())
    .help("More for \(camera.name)")
    .accessibilityLabel("More for \(camera.name)")
  }

  /// The camera-original note is on the Ready line, and always in the record button's help.
  private var recordHelp: String {
    var help = camera.recordButtonActive || isRecordingOrPaused ? camera.recordButtonHelp
      : camera.recordButtonHelp + " Records the camera original, without LUT or effects."
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
    case .recordingNoSignal, .noFolder, .failed: UIStateGlyph(state: .warning)
    case .saved: Image(systemName: UISymbol.saved).foregroundStyle(.green).imageScale(.small).accessibilityHidden(true)
    default: EmptyView()
    }
  }

  /// The take's clock and drops follow its statistics in this row alone.
  private var recordRow: some View {
    UILiveCamera(camera: camera, context: context, follows: .take) { live in recordRow(live.camera) }
      .frame(height: 44)
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
        Text(text[..<space]).font(.uiValueStrong).foregroundStyle(warning ? .primary : .primary)
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
        .controlSize(.small)
        .accessibilityLabel("\(pause) \(camera.name)")
      }
    case .saved:
      if let url = snapshot?.recording.savedURL {
        Button("Show in Finder", systemImage: UISymbol.folder) { context.send(.revealInFinder(url)) }.controlSize(.small)
      }
    case .noFolder:
      Button("Choose Folder…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }.controlSize(.small)
    case .failed:
      // One action. Out of space, the next take needs another folder (or room on this
      // drive); otherwise Details shows why, and acknowledges the take.
      if camera.diskFull {
        Button("Choose Folder…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }.controlSize(.small)
      } else {
        Button("Details") { context.send(.acknowledgeStop(cameraID: camera.id)) }.controlSize(.small)
      }
    case .waiting:
      // The strip says a folder is also needed; offer it now rather than after the signal arrives.
      if let recording = snapshot?.recording, recording.folderPath == nil {
        Button("Choose Folder…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }.controlSize(.small)
      }
    case .stopped, .finishing, .ready:
      EmptyView()
    }
  }

  /// Drive, then the folder with its last part primary, then this camera's format, read-only:
  /// one format for every camera, chosen in the sidebar and the Record menus. Time left is
  /// the status bar's and the sidebar's.
  private var folderRow: some View {
    HStack(spacing: 6) {
      if let path = snapshot?.recording.folderPath {
        let drive = UIPresentationBuilder.drive(for: snapshot ?? UICameraSnapshot(id: "", name: ""), in: context.session)
        let low = drive.map { ($0.secondsLeft ?? .infinity) < UIPresentationBuilder.lowDriveSeconds || UIPresentationBuilder.isFull($0) } ?? false
        Image(systemName: UISymbol.drive(low: low)).foregroundStyle(low ? Color.orange : .secondary).imageScale(.small)
          .frame(width: Self.gutter).accessibilityHidden(true)
        if let drive { Text(drive.name).font(.uiValueStrong).lineLimit(1).fixedSize() }
        Image(systemName: UISymbol.folder).foregroundStyle(.secondary).imageScale(.small).accessibilityHidden(true)
        Self.folderText(path).lineLimit(1).truncationMode(.head)
          .help(path)
      } else {
        Text("—").font(.uiRow).foregroundStyle(.secondary).frame(width: Self.gutter)
          .accessibilityLabel("No recording folder")
      }
      Spacer(minLength: 4)
      formatChip
    }
    .font(.uiMeta)
  }

  /// "Takes/Camera 1": the parent dim, the folder itself primary.
  private static func folderText(_ path: String) -> Text {
    let name = (path as NSString).lastPathComponent
    let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    return Text("\(Text("\(parent)/").foregroundStyle(.secondary))\(Text(name).foregroundStyle(.primary))")
  }

  @ViewBuilder private var formatChip: some View {
    if let fallback = camera.formatFallback {
      HStack(spacing: 4) {
        UIStateGlyph(state: .warning)
        Text(fallback).font(.uiBadge).lineLimit(1)
      }
      .fixedSize()
      .help(camera.formatHelp)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Format \(fallback)")
    } else {
      UIBadge(text: camera.formatTitle, symbol: UISymbol.format)
        .fixedSize()
        .help(camera.formatHelp)
        .accessibilityLabel("Format \(camera.formatTitle)")
    }
  }

  /// Cut slot, one output value, the LUT toggle and the Effects menu. The LUT is one click
  /// because it changes pixels, never the format; everything in the menu changes what
  /// meeting apps receive, so it takes two deliberate clicks.
  private var outputRow: some View {
    HStack(spacing: 8) {
      if context.presentation.programAvailable { cutSlot }
      outputValue
      Spacer(minLength: 4)
      lutToggle
      UIEffectsMenu(camera: camera, snapshot: snapshot, context: context)
    }
    .frame(height: 24)
  }

  @ViewBuilder private var outputValue: some View {
    HStack(spacing: 6) {
      Image(systemName: UISymbol.virtualCamera(inUse: camera.outputInUse))
        .foregroundStyle(camera.outputInUse ? Color.green : .secondary).imageScale(.small)
        .accessibilityHidden(true)
      if camera.applying {
        ProgressView().controlSize(.mini)
        Text("Updating output…").foregroundStyle(.secondary)
      } else {
        Text(camera.outputValue).font(.uiValueStrong).fixedSize()
        if camera.outputInUse && camera.tally != .onAir { Text("In use").foregroundStyle(.secondary).fixedSize() }
      }
    }
    .font(.uiRow)
    .lineLimit(1)
    .help("Ultracam · \(camera.name) sends \(camera.outputValue). \(camera.outputLine).")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(camera.applying ? "Updating output" : "Output \(camera.outputValue), \(camera.outputLine)")
  }

  /// A fixed 64 pt slot: Cut, Next while a cut is pending, or the plain gray state of the
  /// camera on Program, so the pill stays the only filled red.
  @ViewBuilder private var cutSlot: some View {
    if context.session.onAirID == camera.id {
      HStack(spacing: 4) {
        Image(systemName: UISymbol.program).imageScale(.small)
        Text(camera.tally == .onAir ? "On air" : "Program")
      }
      .font(.uiRow).foregroundStyle(.secondary)
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
      .help(camera.cutHelp ?? "Cut Program to \(camera.name) (⌃\(camera.number))")
      .accessibilityLabel(pending ? "\(camera.name), cut pending" : "Cut to \(camera.name)")
    }
  }

  /// `LUT On` or `LUT Off`, one click, fixed width. With Sync cameras on it changes every camera.
  private var lutToggle: some View {
    let on = camera.lutIsOn
    return Button { context.send(.setEffect(cameraID: camera.id, index: 0, !on)) } label: {
      Label(on ? "LUT On" : "LUT Off", systemImage: UISymbol.lut(on: on))
        .labelStyle(.titleAndIcon)
        .frame(width: Self.lutWidth, height: 24)
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
    guard camera.lutChip?.enabled == true else { return "Load a .cube LUT in the inspector to use this." }
    var help = camera.lutIsOn ? "Turn the LUT off. Meeting apps keep their format." : "Turn the LUT on. Meeting apps keep their format."
    if context.session.syncCameras { help += " Sync cameras is on, so this changes every camera." }
    return help
  }

  // MARK: Collapsed

  /// Name · state · LUT · ⋯ · meter · Stop: the meter keeps ⋯ away from Stop, so a miss can't
  /// end a take. Four Up has no tile Cut, so its strips carry the Cut slot.
  private var collapsed: some View {
    HStack(spacing: 8) {
      chevron
      Text(camera.name).font(.uiTitle).lineLimit(1).truncationMode(.middle)
      if isClean && camera.tally != .none {
        // Clean View hides the picture's pill, so the tally is said here.
        UIBadge(text: camera.tally.label ?? "", tone: camera.tally.isRed ? .onAir : camera.tally == .next ? .positive : .neutral)
      }
      collapsedState
      Spacer(minLength: 4)
      if context.presentation.layout == .fourUp && context.presentation.programAvailable { cutSlot }
      lutToggle
      overflowMenu
      // One meter, outside ViewThatFits: each candidate would run its own display-rate meter,
      // and a swap between candidates (a column animating) restarted its ballistics. It yields first.
      Color.clear.frame(minWidth: 0, idealWidth: Self.compactMeterWidth, maxWidth: Self.compactMeterWidth, maxHeight: 1)
        .layoutPriority(-1)
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.compactMeterWidth } action: { compactMeterFits = $0 }
        .overlay(alignment: .trailing) {
          if compactMeterFits {
            UILiveAudioMeter(cameraID: camera.id, name: camera.name, audio: camera.audio, style: .compact)
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
          Button(action.title) { context.send(action.action) }.controlSize(.small).fixedSize()
        }
      }
    } else if isClean, isRecordingOrPaused {
      UILiveCamera(camera: camera, context: context, follows: .take) { live in
        HStack(spacing: 4) {
          UIStateGlyph(state: camera.stripState == .paused ? .paused : .recording, size: 7)
          Text(UIFormat.shortElapsed(live.snapshot?.recording.elapsed ?? 0)).font(.uiValueStrong)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording \(UIFormat.shortElapsed(live.snapshot?.recording.elapsed ?? 0))")
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
    }
  }
}

/// Every effect that changes what meeting apps receive: Output size (with Aspect), Color
/// format, Frame rate, the camera's HDMI display, and Effects Off.
struct UIEffectsMenu: View {
  let camera: UICameraPresentation
  let snapshot: UICameraSnapshot?
  let context: UIContext

  var body: some View {
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
      HStack(spacing: 4) {
        Image(systemName: camera.processing ? UISymbol.effects : UISymbol.effectsOff).imageScale(.small)
        Text(camera.processing ? "Effects" : "Effects Off")
        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).imageScale(.small)
      }
      .font(.uiRow.weight(.medium))
      .padding(.horizontal, 8).frame(height: 24)
      .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 7))
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Effects change the format meeting apps receive; the video updates briefly. ⇧⌘B turns them all off.")
    .accessibilityLabel("Effects for \(camera.name)")
    .accessibilityValue(camera.processing ? "On" : "Off")
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
