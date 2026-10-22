import MonitorKitCore
import SwiftUI

/// One camera: its picture with overlays, then its channel strip.
struct UICameraColumnView: View {
  let camera: UICameraPresentation
  let context: UIContext

  var body: some View {
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
}

// MARK: - Picture

/// The picture at 16:9 with its overlays. At rest it shows only the camera's
/// identity, tally, recording state and active tools; the tool bar and view
/// controls appear on hover or keyboard focus. A click selects the camera and
/// never cuts (cuts come only from explicit cut controls).
struct UICameraPictureView: View {
  let camera: UICameraPresentation
  let context: UIContext
  var compact = false
  @State private var hovering = false
  @State private var zoom = 1.0
  @FocusState private var focused: Bool

  private var revealed: Bool {
    guard (hovering || focused) && !compact else { return false }
    switch camera.tileState {
    case .live, .updating: return true
    default: return false
    }
  }
  private var snapshot: UICameraSnapshot? { context.snapshot(camera.id) }
  private var isProgramMode: Bool { context.presentation.outputMode == .program }
  /// Clean View hides every overlay on the picture, tally included; hover still
  /// reveals the view controls so Clean View can be turned off again.
  private var isClean: Bool { !compact && UICleanViewState.shared.clean.contains(camera.id) }

  var body: some View {
    ZStack {
      context.pictures.picture(cameraID: camera.id, compact: compact, zoom: zoom)
        .accessibilityElement()
        .accessibilityLabel(camera.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { context.send(.select(cameraID: camera.id)) }
        .accessibilityAction(named: "Select \(camera.name)") { context.send(.select(cameraID: camera.id)) }
        .modifier(UICutAccessibilityAction(camera: camera, context: context))
      placeholder
      previewErrorNotice
      overlays
    }
    .aspectRatio(16 / 9, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 14))
    .overlay {
      if let color = camera.tally.ringColor, !isClean {
        RoundedRectangle(cornerRadius: compact ? 10 : 14).strokeBorder(color, lineWidth: camera.tally == .onAir ? 4 : 3)
          .allowsHitTesting(false)
      }
    }
    .overlay {
      // Selection only means something next to other pictures; alone, the ring just doubles the tally ring.
      if camera.selected && !compact && context.presentation.layout != .single {
        RoundedRectangle(cornerRadius: 17).strokeBorder(Color.accentColor, lineWidth: 2.5)
          .padding(-4).allowsHitTesting(false)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { context.send(.select(cameraID: camera.id)) }
    .onHover { hovering = $0 }
    .focusable(!compact)
    // The selection ring is the focus ring (D7); the system ring would draw a second one.
    .focusEffectDisabled()
    .focused($focused)
    .onChange(of: focused) { _, isFocused in
      if isFocused && !camera.selected { context.send(.select(cameraID: camera.id)) }
    }
    .contextMenu { pictureMenu }
  }

  // MARK: Placeholders

  @ViewBuilder private var placeholder: some View {
    switch camera.tileState {
    case .live:
      EmptyView()
    case .connecting:
      UIPicturePlaceholder(symbol: "video", title: "Starting…", compact: compact,
        detail: "Waiting for the first frame from \(camera.inputName).", showsProgress: true)
    case .noSignal:
      UIPicturePlaceholder(symbol: "video.slash", title: "No signal", compact: compact,
        detail: "Check the camera's HDMI output: 2160p 29.97 or 59.94, 10-bit 4:2:2, RAW off, display LUT off.")
    case .unsupported(let mode):
      UIPicturePlaceholder(symbol: "exclamationmark.triangle", title: "Unsupported format", compact: compact,
        detail: mode.isEmpty ? "Waiting for 2160p 29.97 or 59.94, 10-bit 4:2:2." : "\(mode) Waiting for 2160p 29.97 or 59.94.")
    case .deviceMissing where snapshot?.inputName == nil:
      UIPicturePlaceholder(symbol: "cable.connector", title: "No input selected", compact: compact,
        detail: "Choose this camera's UltraStudio input in the inspector.") {
        Button("Show Inspector") { context.send(.showInspector(cameraID: camera.id)) }
      }
    case .deviceMissing:
      UIPicturePlaceholder(symbol: "cable.connector.slash", title: "Input disconnected", compact: compact,
        detail: "Reconnect \(camera.inputName) or choose another input.") {
        Button("Refresh Inputs") { context.send(.refreshInputs) }
      }
    case .stopped where camera.automaticStartFailed:
      UIPicturePlaceholder(symbol: "exclamationmark.triangle", title: "Couldn't start \(camera.name)", compact: compact,
        detail: startFailureDetail) {
        Button("Retry", systemImage: "arrow.clockwise") { context.send(.retryAutomaticStart(cameraID: camera.id)) }
      }
    case .stopped:
      UIPicturePlaceholder(symbol: "video", title: "Camera stopped", compact: compact, detail: "Start the camera to see its HDMI input.") {
        // The expanded strip's header has the same button just below.
        if camera.collapsed {
          Button("Start Camera", systemImage: "play.fill") { context.send(.startCamera(cameraID: camera.id)) }
            .disabled(!camera.canStart)
        }
      }
    case .previewHidden:
      UIPicturePlaceholder(symbol: "eye.slash", title: "Preview hidden", compact: compact,
        detail: "Camera output continues. Hidden previews do no rendering work.") {
        Button("Show Preview") { context.send(.setPreviewEnabled(cameraID: camera.id, true)) }
      }
    case .updating:
      Label("Updating output…", systemImage: "arrow.triangle.2.circlepath")
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
    guard let first = status.first else { return nil }
    return first.uppercased() + status.dropFirst()
  }

  /// Preview rendering failed; camera output is unaffected and keeps running.
  @ViewBuilder private var previewErrorNotice: some View {
    if !compact, let error = snapshot?.previewError, !error.isEmpty {
      VStack(spacing: 6) {
        Label("Preview error — camera output continues", systemImage: "exclamationmark.triangle.fill")
          .font(.uiOverlay).foregroundStyle(.orange)
        Text(error).font(.uiMeta).foregroundStyle(.white.opacity(0.7)).lineLimit(2).multilineTextAlignment(.center)
        Button("Retry Preview") { context.send(.retryPreview) }
          .controlSize(.small)
          .help("Restart preview rendering. Camera output keeps running.")
      }
      .padding(10)
      .frame(maxWidth: 360)
      .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
      .environment(\.colorScheme, .dark)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Preview error")
    }
  }

  // MARK: Overlays

  private var overlays: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 6) {
        if isProgramMode && !isClean {
          Text("\(camera.number)")
            .font(.subheadline.weight(.bold).monospacedDigit())
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 24)
            .background(Color.black.opacity(0.72), in: Capsule())
            .foregroundStyle(.white)
            .accessibilityHidden(true)
        }
        if !isClean {
          Text(camera.name)
            .font(.uiOverlay)
            .lineLimit(1).truncationMode(.tail)
            .uiPictureOverlay()
            .help(camera.name)
            // The name keeps its room; a narrow picture folds the tool bar into a menu instead.
            .layoutPriority(1)
          UITallyBadge(tally: camera.tally)
        }
        Spacer(minLength: 4)
        // The tools stay on the picture so they can be found; Clean View hides them until hover.
        if !compact && (!isClean || revealed) {
          UIMonitorToolButtons(camera: camera, context: context)
        }
      }
      Spacer(minLength: 0)
      HStack(alignment: .center, spacing: 6) {
        if revealed {
          Text(camera.timecode).font(.uiOverlay.monospacedDigit()).uiPictureOverlay()
            .accessibilityLabel("Timecode \(camera.timecode)")
          signalMenu
        }
        Spacer(minLength: 4)
        if revealed { viewControls }
        Spacer(minLength: 4)
        if !isClean { recordingPill }
      }
    }
    .padding(compact ? 6 : 10)
    .animation(.easeOut(duration: 0.15), value: revealed)
  }

  @ViewBuilder private var recordingPill: some View {
    let elapsed = UIFormat.shortElapsed(snapshot?.recording.elapsed ?? 0)
    switch camera.stripState {
    case .recording, .updating:
      HStack(spacing: 5) {
        Circle().fill(.red).frame(width: 8, height: 8)
        Text("REC \(elapsed)").font(.uiOverlay.monospacedDigit())
      }
      .uiPictureOverlay()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Recording \(elapsed)")
    case .paused:
      HStack(spacing: 5) {
        Image(systemName: "pause.fill").imageScale(.small).foregroundStyle(.orange)
        Text("Paused \(elapsed)").monospacedDigit()
      }
      .uiPictureOverlay()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Recording paused at \(elapsed)")
    case .recordingNoSignal:
      HStack(spacing: 5) {
        Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
        Text("REC · no signal")
      }
      .foregroundStyle(.orange)
      .uiPictureOverlay()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Recording, no signal")
    default:
      EmptyView()
    }
  }

  private var signalMenu: some View {
    let stage = context.monitor.preferences(for: camera.id).state.pictureStage
    return Menu {
      Picker("Picture", selection: Binding(
        get: { context.monitor.preferences(for: camera.id).state.pictureStage },
        set: { value in
          var next = context.monitor.preferences(for: camera.id)
          next.state.pictureStage = value
          context.monitor.setPreferences(next, for: camera.id)
        })) {
        Text("Source (camera signal)").tag(SignalStage.source)
        Text("Output (LUT)").tag(SignalStage.output)
        Text("Monitor").tag(SignalStage.monitor)
      }
      .pickerStyle(.inline)
    } label: {
      Text(Self.stageTitle(stage)).font(.uiOverlay)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.visible)
    .fixedSize()
    .uiPictureOverlay()
    .help("Choose what this picture shows")
    .accessibilityLabel("Picture signal")
    .accessibilityValue(Self.stageTitle(stage))
  }

  static func stageTitle(_ stage: SignalStage) -> String {
    switch stage {
    case .source: return "Source"
    case .output: return "Output"
    case .monitor: return "Monitor"
    }
  }

  private var viewControls: some View {
    HStack(spacing: 2) {
      overlayButton("snowflake", help: "Freeze (⌃⌥F)", label: "Freeze") { context.send(.freeze(cameraID: camera.id)) }
      overlayButton(isClean ? "rectangle.inset.filled" : "rectangle.dashed", help: isClean ? "Show Overlays (⌃⌥C)" : "Clean View (⌃⌥C)",
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
        Text(zoom == 1 ? "Fit" : "\(Int(zoom * 100))%").font(.uiOverlay)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .padding(.horizontal, 6)
      .frame(minWidth: 36, minHeight: 24)
      .help("Zoom (center crop, this view only)")
      .accessibilityLabel("Zoom")
      overlayButton("arrow.up.forward.square", help: "Detach to Window", label: "Detach to Window") {
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
    UICopySettingsMenu(camera: camera, context: context, title: "Copy Settings To")
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

/// "Copy Settings To" with every other camera, plus Program in Program mode.
private struct UICopySettingsMenu: View {
  let camera: UICameraPresentation
  let context: UIContext
  let title: String
  var body: some View {
    let others = context.presentation.cameras.filter { $0.id != camera.id }
    let program = context.presentation.outputMode == .program
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

private struct UIPicturePlaceholder<Actions: View>: View {
  let symbol: String
  let title: String
  let detail: String
  /// Small pictures (Program sources) keep the small sizes.
  var compact = false
  var showsProgress = false
  @ViewBuilder var actions: () -> Actions

  init(symbol: String, title: String, compact: Bool = false, detail: String, showsProgress: Bool = false,
    @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
    self.symbol = symbol
    self.title = title
    self.compact = compact
    self.detail = detail
    self.showsProgress = showsProgress
    self.actions = actions
  }

  var body: some View {
    ZStack {
      Color(white: 0.06)
      VStack(spacing: compact ? 6 : 8) {
        if showsProgress { ProgressView().controlSize(compact ? .small : .regular) }
        else {
          Image(systemName: symbol).font(.system(size: compact ? 26 : 32, weight: .light)).foregroundStyle(.white.opacity(0.6))
        }
        Text(title).font(compact ? .callout.weight(.semibold) : .uiPlaceholderTitle).foregroundStyle(.white.opacity(0.9))
        Text(detail).font(compact ? .caption : .uiRow).foregroundStyle(.white.opacity(0.6))
          .multilineTextAlignment(.center).frame(maxWidth: compact ? 380 : 440).fixedSize(horizontal: false, vertical: true)
        actions().controlSize(.small).padding(.top, compact ? 2 : 4)
      }
      .padding(.horizontal, 24)
    }
    .environment(\.colorScheme, .dark)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}

// MARK: - Channel strip

/// A camera's own controls under its picture: recording, output, effects and audio.
/// Every row starts with a glyph in the same gutter, so the text lines up in one column.
struct UIChannelStripView: View {
  let camera: UICameraPresentation
  let context: UIContext
  @Environment(\.colorSchemeContrast) private var contrast

  /// Width of the leading glyph column in every row.
  private static let gutter: CGFloat = 28

  private var snapshot: UICameraSnapshot? { context.snapshot(camera.id) }
  private var isRecordingOrPaused: Bool { camera.pauseTitle != nil }

  /// Retry's help names the reason, which a collapsed strip doesn't show.
  private var retryHelp: String {
    "Couldn't start \(camera.name). "
      + (UICameraPictureView.startFailureReason(snapshot?.automaticStatus ?? "") ?? "Try starting the camera again.")
  }

  var body: some View {
    Group {
      if camera.collapsed { collapsed } else { expanded }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, camera.collapsed ? 6 : 10)
    .background(background, in: RoundedRectangle(cornerRadius: 12))
    // The picture's ring is the one selection indicator (D7), so the strip has no accent border.
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: contrast == .increased ? 1.5 : 1))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(camera.name) controls")
  }

  /// Orange for problems, including a failed take; red stays for on air and recording (D8).
  private var stateTone: UITone? {
    switch camera.stripState {
    case .recordingNoSignal, .noFolder, .failed: return .warning
    default: return nil
    }
  }

  private var background: AnyShapeStyle {
    if let tone = stateTone { return AnyShapeStyle(tone.color.opacity(0.08)) }
    return AnyShapeStyle(.fill.quaternary)
  }

  private var border: AnyShapeStyle {
    if let tone = stateTone { return AnyShapeStyle(tone.color.opacity(0.5)) }
    return AnyShapeStyle(.separator)
  }

  /// A leading row glyph in the shared gutter.
  private func gutterIcon(_ symbol: String, color: Color = .secondary) -> some View {
    Image(systemName: symbol).font(.uiRow).foregroundStyle(color).frame(width: Self.gutter)
  }

  // MARK: Expanded

  private var expanded: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      Divider()
      recordRow
      folderRow
      alertRows
      Divider()
      outputRow
      HStack(spacing: 8) {
        gutterIcon("waveform").help("Embedded audio").accessibilityHidden(true)
        UIAudioMeter(audio: camera.audio)
      }
    }
  }

  /// Problems that need one action: a failed automatic start, an unavailable LUT.
  @ViewBuilder private var alertRows: some View {
    // A stopped camera's picture and header already offer Retry.
    if camera.automaticStartFailed && camera.tileState != .stopped {
      HStack(spacing: 8) {
        gutterIcon("exclamationmark.triangle.fill", color: .orange)
        Text("Couldn't start \(camera.name)").font(.uiRowEmphasis)
        Text(snapshot?.automaticStatus ?? "").font(.uiRow).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 4)
        Button("Retry") { context.send(.retryAutomaticStart(cameraID: camera.id)) }.controlSize(.small)
          .help("Try starting the camera again.")
      }
      .accessibilityElement(children: .contain)
    }
    if let error = camera.lutError {
      HStack(spacing: 8) {
        gutterIcon("exclamationmark.triangle.fill", color: .orange)
        Text("LUT unavailable").font(.uiRowEmphasis)
        Text(error).font(.uiRow).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(error)
        Spacer(minLength: 4)
        Button("Locate…") { context.send(.chooseLUT(cameraID: camera.id)) }.controlSize(.small)
          .help("Choose the .cube file again. Capture keeps working without it.")
      }
      .accessibilityElement(children: .contain)
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      chevron
      Text(camera.name).font(.uiTitle).lineLimit(1).truncationMode(.middle)
        .help("\(camera.name) · \(camera.inputName)")
      UIBadge(text: camera.statusBadge, tone: camera.statusTone)
      tallyBadge
      Spacer(minLength: 4)
      ViewThatFits(in: .horizontal) {
        cameraButton(compact: false)
        cameraButton(compact: true)
      }
      overflowMenu
    }
  }

  private var chevron: some View {
    Button { context.send(.toggleCollapsed(cameraID: camera.id)) } label: {
      Image(systemName: camera.collapsed ? "chevron.right" : "chevron.down")
        .font(.subheadline.weight(.semibold))
        .frame(width: Self.gutter, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(camera.collapsed ? "Expand" : "Collapse")
    .accessibilityLabel(camera.collapsed ? "Expand \(camera.name)" : "Collapse \(camera.name)")
  }

  @ViewBuilder private var tallyBadge: some View {
    if let label = camera.tally.label {
      switch camera.tally {
      case .onAir: UIBadge(text: label, tone: .critical)
      case .next: UIBadge(text: label, tone: .positive)
      default: UIBadge(text: label, tone: .neutral)
      }
    }
  }

  @ViewBuilder private func cameraButton(compact: Bool) -> some View {
    if camera.canStop {
      Button { context.send(.stopCamera(cameraID: camera.id)) } label: {
        if compact { Image(systemName: "stop.fill") } else { Label("Stop Camera", systemImage: "stop.fill") }
      }
      .controlSize(.small)
      .help(camera.stopNeedsConfirmation ? "Stops capture and output. Asks first because it would end a recording or on-air video."
        : "Stops this camera's capture and output.")
      .accessibilityLabel("Stop \(camera.name)")
    } else if camera.automaticStartFailed {
      // One problem, one action: the same Retry the picture offers.
      Button { context.send(.retryAutomaticStart(cameraID: camera.id)) } label: {
        if compact { Image(systemName: "arrow.clockwise") } else { Label("Retry", systemImage: "arrow.clockwise") }
      }
      .controlSize(.small)
      .help(retryHelp)
      .accessibilityLabel("Retry \(camera.name)")
    } else {
      Button { context.send(.startCamera(cameraID: camera.id)) } label: {
        if compact { Image(systemName: "play.fill") } else { Label("Start Camera", systemImage: "play.fill") }
      }
      .controlSize(.small)
      .disabled(!camera.canStart)
      .help(camera.canStart ? "Start capture from \(camera.inputName)." : "Connect the camera's input first.")
      .accessibilityLabel("Start \(camera.name)")
    }
  }

  private var overflowMenu: some View {
    let canEdit = context.session.canEditTopology
    let lastCamera = context.presentation.cameras.count < 2
    return Menu {
      Button("Show Inspector") { context.send(.showInspector(cameraID: camera.id)) }
      if context.presentation.outputMode == .program {
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
      Button("Load LUT…") { context.send(.chooseLUT(cameraID: camera.id)) }
      Button("Choose Recording Folder…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }
      if snapshot?.recording.folderIsCustom == true {
        Button("Use Default Folder") { context.send(.useDefaultFolder(cameraID: camera.id)) }
      }
      UICopySettingsMenu(camera: camera, context: context, title: "Copy Monitor Settings To")
      Divider()
      // The one rename alert lives on the main window; this only asks for it.
      Button("Rename…") { context.send(.beginRename(cameraID: camera.id)) }
        .disabled(!canEdit)
        .help(canEdit ? "Rename \(camera.name)" : "Stop all cameras to rename a camera.")
      Button("Diagnostics…") { context.send(.openDiagnostics) }
      Divider()
      if camera.canStop {
        Button("Stop Camera") { context.send(.stopCamera(cameraID: camera.id)) }
      } else {
        Button("Start Camera") { context.send(.startCamera(cameraID: camera.id)) }.disabled(!camera.canStart)
      }
      Button("Remove Camera…") { context.send(.removeCamera(cameraID: camera.id)) }
        .disabled(!canEdit || lastCamera)
        .help(!canEdit ? "Stop all cameras to remove a camera." : lastCamera ? "The only camera can't be removed." : "Remove \(camera.name)")
    } label: {
      Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        .frame(minWidth: 24, minHeight: 24)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .frame(minWidth: 24, minHeight: 24)
    .contentShape(Rectangle())
    .help("More for \(camera.name)")
    .accessibilityLabel("More for \(camera.name)")
  }

  /// The footnote ("Camera original · no LUT or effects") can drop out of a
  /// narrow strip, so the record button's help always says it too.
  private var recordHelp: String {
    camera.recordButtonActive || isRecordingOrPaused ? camera.recordButtonHelp
      : camera.recordButtonHelp + " Records the camera original, without LUT or effects."
  }

  private var recordButton: some View {
    UIRecordButton(active: camera.recordButtonActive || camera.pauseTitle == "Resume", enabled: camera.recordButtonEnabled,
      help: recordHelp) {
      context.send(.toggleRecording(cameraID: camera.id))
    }
  }

  /// Small status words stay in a label color; the state's color goes on a symbol.
  private var recordSymbol: (name: String, color: Color)? {
    switch camera.stripState {
    case .paused: return ("pause.fill", .orange)
    case .recordingNoSignal, .noFolder, .failed: return ("exclamationmark.triangle.fill", .orange)
    case .saved: return ("checkmark.circle.fill", .green)
    default: return nil
    }
  }

  private var recordRow: some View {
    HStack(spacing: 8) {
      Group {
        if camera.stripState == .finishing { ProgressView().controlSize(.small) } else { recordButton }
      }
      .frame(width: Self.gutter, height: 28)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          if let symbol = recordSymbol {
            Image(systemName: symbol.name).foregroundStyle(symbol.color).imageScale(.small)
          }
          // Red only for a live take, where the title is bold next to the red stop button.
          Text(camera.recordTitle)
            .foregroundStyle(camera.recordTone == .critical ? Color.red : Color.primary)
        }
        .font(.uiRowEmphasis)
        if isRecordingOrPaused {
          Text(camera.recordDetail).font(.uiClock)
            .foregroundStyle(camera.stripState == .paused ? .secondary : .primary)
        } else {
          Text(camera.recordDetail).font(.uiRow).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(camera.stripState == .saved ? .primary : .secondary)
        }
      }
      .layoutPriority(1)
      if let size = camera.sizeLine {
        VStack(alignment: .leading, spacing: 2) {
          Text(size).font(.uiValue)
          if let drops = camera.dropsLine {
            HStack(spacing: 4) {
              Image(systemName: camera.dropsWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(camera.dropsWarning ? .orange : .green).imageScale(.small)
              Text(drops).foregroundStyle(.secondary)
            }
            .font(.uiValue)
          }
        }
      }
      Spacer(minLength: 4)
      recordActions
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var recordActions: some View {
    switch camera.stripState {
    case .recording, .recordingNoSignal, .updating, .paused:
      if let pause = camera.pauseTitle {
        Button(pause, systemImage: pause == "Pause" ? "pause.fill" : "play.fill") {
          context.send(.pauseOrResume(cameraID: camera.id))
        }
        .controlSize(.small)
      }
    case .saved:
      if let url = snapshot?.recording.savedURL {
        Button("Show in Finder", systemImage: "folder") { context.send(.revealInFinder(url)) }.controlSize(.small)
      }
    case .noFolder:
      Button("Choose Folder…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }.controlSize(.small)
    case .failed:
      HStack(spacing: 6) {
        // Out of space: the next take needs another folder (or room on this drive).
        if camera.diskFull {
          Button("Choose Folder…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }
        }
        Button("Show in Finder", systemImage: "folder") {
          if let url = snapshot?.recording.savedURL { context.send(.revealInFinder(url)) } else { context.send(.revealRecordings) }
        }
        Button("Details") { context.send(.openDiagnostics) }
      }
      .controlSize(.small)
    case .stopped:
      EmptyView()
    case .finishing:
      Text("Saving…").font(.uiRow).foregroundStyle(.secondary)
    case .waiting:
      // The strip says a folder is also needed; offer it now rather than after the signal arrives.
      if let recording = snapshot?.recording, recording.folderPath == nil {
        Button("Choose Folder…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }.controlSize(.small)
      }
    case .ready:
      EmptyView()
    }
  }

  private var folderRow: some View {
    ViewThatFits(in: .horizontal) {
      folderContent(footnote: true)
      folderContent(footnote: false)
    }
  }

  private func folderContent(footnote: Bool) -> some View {
    HStack(spacing: 8) {
      gutterIcon("folder")
      HStack(spacing: 4) {
        Text(camera.folderLine).font(.uiRow).lineLimit(1).truncationMode(.middle)
          .help(snapshot?.recording.folderPath ?? camera.folderLine)
        if let left = camera.timeLeftLine {
          Text("· \(left)").font(.uiValue).foregroundStyle(.secondary).fixedSize()
        }
      }
      if snapshot?.recording.folderIsCustom == true {
        UIBadge(text: "Own folder").fixedSize()
      }
      Spacer(minLength: 4)
      if footnote {
        Text("Camera original · no LUT or effects").font(.uiMeta).foregroundStyle(.secondary).fixedSize()
      }
    }
  }

  private var outputRow: some View {
    ViewThatFits(in: .horizontal) {
      outputContent(full: true)
      outputContent(full: false)
      // Narrow cells: icon-only output state and an unlabeled Processing switch, so the
      // strip never grows wider than its picture.
      outputContent(full: false, minimal: true)
    }
  }

  private func outputContent(full: Bool, minimal: Bool = false) -> some View {
    HStack(spacing: 8) {
      outputLabel(full: full, minimal: minimal)
      Spacer(minLength: 4)
      if camera.applying {
        HStack(spacing: 4) {
          ProgressView().controlSize(.mini)
          if full { Text("Updating output…").font(.uiRow).foregroundStyle(.secondary) }
        }
        .fixedSize()
        .accessibilityLabel("Updating output")
      }
      effectChips
      if minimal { processingToggle.labelsHidden() } else { processingToggle }
    }
  }

  private var processingToggle: some View {
    Toggle(isOn: Binding(get: { camera.processing }, set: { context.send(.setProcessing(cameraID: camera.id, $0)) })) {
      Text("Processing").font(.uiMeta).foregroundStyle(.secondary)
    }
    .toggleStyle(.switch)
    .controlSize(.mini)
    .fixedSize()
    .help("Processing. Off = complete bypass: the original resolution, color, pixels and frame rate. Effect choices stay saved. ⇧⌘B")
  }

  /// Effects only apply with Processing on, so the chips are disabled (not just dimmed) without it.
  private var effectChips: some View {
    HStack(spacing: 4) {
      ForEach(camera.chips) { chip in
        UIChipToggle(chip: chip) { context.send(.setEffect(cameraID: camera.id, index: chip.id, $0)) }
      }
    }
    .disabled(!camera.processing)
    .fixedSize()
  }

  @ViewBuilder private func outputLabel(full: Bool, minimal: Bool = false) -> some View {
    if camera.showsCut {
      // Wider than the gutter; the cut button leads the row in Program mode.
      Button {
        context.send(.cut(cameraID: camera.id))
      } label: {
        Label("Cut", systemImage: "arrow.left.arrow.right")
      }
      .controlSize(.small)
      .disabled(!camera.cutEnabled)
      .help(camera.cutEnabled ? "Cut Program to \(camera.name) (⌃\(camera.number))" : "\(camera.name) needs a live signal before it can go on air.")
      .accessibilityLabel("Cut to \(camera.name)")
    } else {
      HStack(spacing: 8) {
        gutterIcon(context.presentation.outputMode == .program ? "dot.radiowaves.left.and.right" : "video.badge.checkmark",
          color: camera.outputInUse ? .green : .secondary)
        if !minimal {
          // Natural width, so the row falls back to shorter wording instead of truncating.
          Text(full ? camera.outputLine : compactOutputLine)
            .font(.uiRow).lineLimit(1).fixedSize()
            .foregroundStyle(camera.outputInUse ? .primary : .secondary)
        }
      }
      .help(camera.outputLine)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(camera.outputLine)
    }
  }

  /// Short output wording for narrow strips. Program mode never says "In use".
  private var compactOutputLine: String {
    if context.presentation.outputMode == .program {
      return camera.tally == .onAir ? "On air" : "In Program"
    }
    return camera.outputInUse ? "In use" : "Not in use"
  }

  // MARK: Collapsed

  private var collapsed: some View {
    HStack(spacing: 8) {
      chevron
      Text(camera.name).font(.uiTitle).lineLimit(1).truncationMode(.middle)
      tallyBadge
      collapsedState
      if camera.automaticStartFailed {
        Button("Retry") { context.send(.retryAutomaticStart(cameraID: camera.id)) }.controlSize(.small)
          .help(retryHelp)
      }
      if camera.lutError != nil {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.uiRow)
          .help(camera.lutError ?? "")
          .accessibilityLabel("LUT unavailable")
      }
      Spacer(minLength: 4)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 6) {
          effectChips
          UIAudioMeter(audio: camera.audio, compact: true)
        }
        UIAudioMeter(audio: camera.audio, compact: true)
        EmptyView()
      }
      if camera.stripState == .finishing {
        ProgressView().controlSize(.mini).frame(width: 24, height: 24)
      } else {
        UIRecordButton(active: camera.recordButtonActive || camera.pauseTitle == "Resume", enabled: camera.recordButtonEnabled,
          help: recordHelp, size: 24) {
          context.send(.toggleRecording(cameraID: camera.id))
        }
      }
      overflowMenu
    }
  }

  /// One collapsed status: words in a label color, the state's color on the symbol.
  private func collapsedLabel(_ text: String, symbol: String? = nil, color: Color = .secondary, value: Bool = false) -> some View {
    HStack(spacing: 4) {
      if let symbol { Image(systemName: symbol).foregroundStyle(color).imageScale(.small) }
      Text(text).foregroundStyle(.secondary).lineLimit(1)
    }
    .font(value ? .uiValue : .uiRow)
  }

  @ViewBuilder private var collapsedState: some View {
    let elapsed = UIFormat.shortElapsed(snapshot?.recording.elapsed ?? 0)
    switch camera.stripState {
    case .recording, .updating:
      HStack(spacing: 4) {
        Circle().fill(.red).frame(width: 7, height: 7)
        Text(elapsed).font(.uiValue)
      }
      .accessibilityElement(children: .ignore).accessibilityLabel("Recording \(elapsed)")
    case .recordingNoSignal:
      collapsedLabel("\(elapsed) · no signal", symbol: "exclamationmark.triangle.fill", color: .orange, value: true)
        .accessibilityElement(children: .combine)
    case .paused:
      collapsedLabel(elapsed, symbol: "pause.fill", color: .orange, value: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Paused at \(elapsed)")
    case .saved: collapsedLabel("Saved", symbol: "checkmark.circle.fill", color: .green)
    case .finishing: collapsedLabel("Finishing…")
    case .stopped: collapsedLabel("Stopped")
    case .waiting:
      collapsedLabel(camera.statusBadge, symbol: camera.statusTone == .warning ? "exclamationmark.triangle.fill" : nil, color: .orange)
    case .noFolder: collapsedLabel("No folder", symbol: "exclamationmark.triangle.fill", color: .orange)
    case .failed:
      collapsedLabel(camera.recordTitle, symbol: "exclamationmark.triangle.fill", color: .orange)
        .accessibilityElement(children: .combine)
    case .ready: collapsedLabel("Ready")
    }
  }
}
