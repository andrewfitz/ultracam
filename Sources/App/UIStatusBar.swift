import MonitorKitAudio
import SwiftUI

/// Bottom status bar. Fixed order: the worst problem with its action, Virtual Cameras,
/// Program, Recording, Audio, then resources on the right. Each segment opens a popover with
/// details. Segments are typed pieces separated by spacing, never " · ": the triangle, the REC
/// dot and the green virtual camera glyph are the only symbols beside a word.
struct UIStatusBarView: View {
  let context: UIContext
  @State private var open: UIStatusSegment.Kind?
  @State private var resourcesOpen = false
  /// The resource readout's figures: read by the readout alone, so a sample (1 Hz) doesn't
  /// re-evaluate the bar and every density it tries.
  @State private var resources = UIResourceMonitor()

  enum Density { case full, compact, essential }

  var body: some View {
    let _ = UIRenderProbe.count("UIStatusBarView")
    // What fits decides the density, so the bar is never empty: every piece with the
    // readout, then without it, then shorter pieces with and without, and finally only the
    // problem, Program and recording. The bar sits in the detail column, so its width
    // depends on the side columns, not just the window.
    // The recording segment's clock and the drives' free space (in it and in a low-space
    // warning) follow the takes here, not in the bar: one session brought up to date for the
    // bar and every density it measures. A lost signal's clock ticks; free space only needs a
    // look now and then.
    UILiveSession(context: context, refresh: context.session.cameras.contains { $0.signalLostFor != nil } ? 1 : 5,
      probe: "UILiveSession(status)") { _, presentation in
      let segments = presentation.statusSegments
      UIFirstFitting {
        bar(.full, readout: true, segments: segments)
        bar(.full, readout: false, segments: segments)
        bar(.compact, readout: true, segments: segments)
        bar(.compact, readout: false, segments: segments)
        bar(.essential, readout: false, segments: segments)
      }
    }
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity)
    .frame(height: 30)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Status")
    .task {
      // Sampled here rather than in the readout, which UIFirstFitting may swap for another variant.
      var sampler = AppResourceSampler()
      while !Task.isCancelled {
        resources.publish(sampler.sample())
        do { try await Task.sleep(for: .seconds(1)) } catch { break }
      }
    }
  }

  private func bar(_ density: Density, readout: Bool, segments: [UIStatusSegment]) -> some View {
    HStack(spacing: 2) {
      segmentsRow(density, segments: segments)
        .layoutPriority(1)
      Spacer(minLength: 8)
      if readout {
        UIResourceReadout(open: $resourcesOpen, resources: resources, context: context)
      }
    }
  }

  private func segmentsRow(_ density: Density, segments: [UIStatusSegment]) -> some View {
    HStack(spacing: 4) {
      ForEach(visibleSegments(density, segments: segments)) { segment in
        segmentButton(segment, density: density)
          .layoutPriority(priority(segment.kind))
      }
    }
  }

  /// Under pressure the problem and recording keep their pieces longest.
  private func priority(_ kind: UIStatusSegment.Kind) -> Double {
    switch kind {
    case .warning: return 3
    case .recording: return 2
    case .program: return 1
    case .output, .audio: return 0
    }
  }

  private func visibleSegments(_ density: Density, segments: [UIStatusSegment]) -> [UIStatusSegment] {
    guard density == .essential else { return segments }
    return segments.filter { $0.kind == .warning || $0.kind == .recording || $0.kind == .program || $0.kind == .output }
  }

  @ViewBuilder private func segmentButton(_ segment: UIStatusSegment, density: Density) -> some View {
    if let level = segment.level {
      HStack(spacing: 4) {
        plainSegmentButton(segment, density: density)
        // One click with the sidebar closed.
        if let action = segment.action {
          UIProblemButton(action: action, level: level, context: context).padding(.trailing, 3)
        }
      }
      .background(level.fill, in: RoundedRectangle(cornerRadius: 5))
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(level.border, lineWidth: 1))
    } else {
      plainSegmentButton(segment, density: density)
    }
  }

  private func plainSegmentButton(_ segment: UIStatusSegment, density: Density) -> some View {
    let pieces = density == .full ? segment.pieces : density == .compact ? segment.compactPieces : segment.essentialPieces
    return Button { open = segment.kind } label: {
      HStack(spacing: 5) {
        ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
          UIStatusPieceView(piece: piece, level: segment.level, shot: context.session.shot)
        }
      }
      .font(.uiMeta)
      .lineLimit(1)
      .padding(.horizontal, 7).frame(height: 24)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(segment.text)
    .accessibilityLabel(segment.text)
    .accessibilityHint("Shows details")
    .modifier(UIMeasuredPopover(isPresented: Binding(get: { open == segment.kind }, set: { if !$0 { open = nil } }),
      arrowEdge: .top) {
      UIStatusPopover(kind: segment.kind, segment: segment, context: context)
    })
  }
}

/// A popover on a control that `UIFirstFitting` also lays out hidden, to measure it: only the
/// copy on screen presents it, not every measured copy bound to the same state.
struct UIMeasuredPopover<Popover: View>: ViewModifier {
  @Binding var isPresented: Bool
  var arrowEdge: Edge = .top
  @ViewBuilder var popover: () -> Popover
  @Environment(\.uiMeasuring) private var measuring

  func body(content: Content) -> some View {
    if measuring {
      content
    } else {
      content.popover(isPresented: $isPresented, arrowEdge: arrowEdge, content: popover)
    }
  }
}

/// One typed piece of the bar.
private struct UIStatusPieceView: View {
  let piece: UIStatusPiece
  let level: UIProblemLevel?
  let shot: UIShotTiming

  var body: some View {
    switch piece {
    case .strong(let text): Text(text).font(.uiValueStrong).foregroundStyle(level?.text ?? .primary)
    case .dim(let text): Text(text).foregroundStyle(level?.secondaryText ?? .secondary)
    case .value(let parts): UIValue(parts: parts)
    case .virtualCamera(let inUse):
      Image(systemName: UISymbol.virtualCamera(inUse: inUse)).foregroundStyle(inUse ? Color.green : .secondary)
        .accessibilityHidden(true)
    case .recordingDot: UIStateGlyph(state: .recording, size: 7)
    case .pausedGlyph: UIStateGlyph(state: .paused)
    case .warningGlyph:
      Image(systemName: UISymbol.warning).imageScale(.small).foregroundStyle(level?.glyph ?? .orange).accessibilityHidden(true)
    case .shot(let bar, let countsAuto): UIShotClock(shot: shot, bar: bar, countsAuto: countsAuto)
    }
  }
}

/// The current shot, ticking on its own: its length, a mini bar against the maximum, and
/// "Auto in 4 s" while Auto waits out the minimum after a manual cut. Past the soft maximum
/// a yellow timer appears, and the number stays the reading.
struct UIShotClock: View {
  let shot: UIShotTiming
  var bar = true
  var countsAuto = false
  @State private var ticker = UISecondTicker.shared

  var body: some View {
    let seconds = shot.anchor.map { max(0, ticker.now.timeIntervalSince($0)) }
    HStack(spacing: 5) {
      if let seconds {
        let long = seconds >= shot.softMaximum
        if long {
          Image(systemName: UISymbol.shotTime).foregroundStyle(.yellow).imageScale(.small).accessibilityHidden(true)
        }
        UIValue(parts: Self.parts(seconds))
        if bar { UILevelBar(fraction: seconds / max(shot.maximum, 1), tint: long ? .yellow : .secondary) }
        if countsAuto, seconds < shot.minimum {
          Text("Auto in").foregroundStyle(.secondary)
          UIValue(parts: [UIValuePart(number: "\(Int((shot.minimum - seconds).rounded(.up)))", unit: "s")])
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(seconds.map { "Shot \(Int($0)) seconds" } ?? "No shot")
    .onAppear { ticker.retain() }
    .onDisappear { ticker.release() }
  }

  /// "8 s", "1:12" past a minute.
  static func parts(_ seconds: TimeInterval) -> [UIValuePart] {
    seconds < 60 ? [UIValuePart(number: "\(Int(seconds))", unit: "s")] : [UIValuePart(number: UIFormat.shortElapsed(seconds))]
  }
}

// MARK: - Resources

/// App CPU and combined GPU video busy time. The status bar samples once per second while
/// visible; memory and the qualifiers are in the popover.
struct UIResourceReadout: View {
  @Binding var open: Bool
  let resources: UIResourceMonitor
  let context: UIContext

  var body: some View {
    let _ = UIRenderProbe.count("UIResourceReadout")
    Button { open = true } label: {
      HStack(spacing: 4) {
        Text("CPU").foregroundStyle(.secondary)
        Text(cpuShort).font(.uiValueStrong)
        Text("GPU").foregroundStyle(.secondary).padding(.leading, 6)
        Text(String(format: "%.0f%%", usage.gpuPercent)).font(.uiValueStrong)
      }
      .font(.uiMeta)
      .lineLimit(1)
      .padding(.horizontal, 7).frame(height: 24)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Total Ultracam process CPU across all threads (100% is one core). GPU is the combined busy time of Ultracam's Metal video processing and copy queues; it excludes the hardware media encoder and the system display compositor.")
    .accessibilityLabel("Ultracam resources")
    .accessibilityValue("CPU \(cpu), GPU \(String(format: "%.1f%%", usage.gpuPercent)), memory \(memory)")
    .modifier(UIMeasuredPopover(isPresented: $open, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Ultracam total").font(.uiTitle)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
          GridRow { Text("CPU"); Text(cpu).monospacedDigit().gridColumnAlignment(.trailing) }
          GridRow { Text("GPU (video)"); Text(String(format: "%.1f%%", usage.gpuPercent)).monospacedDigit() }
          GridRow { Text("Memory"); Text(memory).monospacedDigit() }
        }
        .font(.uiRow)
        Text("CPU counts all Ultracam threads; 100% is one core, so it can exceed 100%. System encoder services run outside this process.")
          .font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text("GPU (video) unions completed Metal processing and copy intervals, so overlapping work counts once. It excludes the hardware media encoder and the display compositor, and is not a whole-machine reading.")
          .font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("Open Diagnostics", systemImage: UISymbol.diagnostics) { open = false; context.send(.openDiagnostics) }
        }
      }
      .padding(12)
      .frame(width: 320)
    })
  }

  private var usage: AppResourceUsage { resources.usage }
  private var cpu: String { usage.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—" }
  private var cpuShort: String { usage.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—" }
  private var memory: String {
    usage.memoryBytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory) } ?? "—"
  }
}

// MARK: - Popovers

/// A popover's title: symbol, title, one subtitle, as the tool popovers draw it.
struct UIPopoverHeader: View {
  let symbol: String
  let title: String
  var subtitle: String? = nil
  var tint: Color = .secondary

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 24).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.uiTitle).accessibilityAddTraits(.isHeader)
        if let subtitle { Text(subtitle).font(.uiMeta).foregroundStyle(.secondary) }
      }
    }
  }
}

struct UIStatusPopover: View {
  let kind: UIStatusSegment.Kind
  let segment: UIStatusSegment
  let context: UIContext

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch kind {
      case .output: output
      case .program: program
      case .recording: recording
      case .audio: audio
      case .warning:
        UILiveSession(context: context, refresh: 1, probe: "UILiveSession(problems)") { _, presentation in
          UIProblemList(problems: presentation.problems, context: context)
        }
      }
    }
    .padding(12)
    // More than two channels keeps every maximum readable at 450 pt.
    .frame(width: kind == .audio && context.session.cameras.contains { $0.audioChannels > 2 } ? 450 : 340, alignment: .leading)
  }

  private var output: some View {
    let rows = context.presentation.virtualCameras
    let using = rows.filter(\.inUse).count
    return Group {
      UIPopoverHeader(symbol: UISymbol.virtualCamera(inUse: using > 0), title: "Virtual Cameras",
        subtitle: using == 0 ? "None in use" : "\(using) of \(rows.count) in use", tint: using > 0 ? .green : .secondary)
      ForEach(rows) { row in
        HStack(spacing: 6) {
          UIVirtualCameraRow(row: row)
          if let format = row.format { UIBadge(text: format).fixedSize() }
        }
      }
      if using == 0 {
        Label { Text(UISessionSidebarViewContent.microphoneReminder) } icon: { Image(systemName: UISymbol.microphoneReminder) }
          .font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var program: some View {
    let session = context.session
    let onAir = session.cameras.first { $0.id == session.onAirID }?.name ?? "No camera"
    let auto = context.presentation.autoSwitching
    let holding = context.presentation.canHoldShot && session.autoHold
    return Group {
      UIPopoverHeader(symbol: UISymbol.program, title: "Program", subtitle: session.strategyTitle)
      HStack(spacing: 8) {
        Text(onAir).font(.uiRowEmphasis)
        UIShotClock(shot: session.shot, bar: true,
          countsAuto: auto && !holding && session.recentCuts.first?.automatic == false)
        if holding {
          Label("Hold", systemImage: UISymbol.hold(on: true)).font(.uiMeta)
        } else {
          Text(auto ? "Auto" : "Manual").font(.uiMeta).foregroundStyle(.secondary)
        }
      }
      if holding { UIPastSoftMaximumNote(shot: session.shot) }
      if session.programFormatMismatch {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text("Formats converted").font(.uiRowEmphasis)
            Text("Program cameras use different formats. The GPU converts each to the Program camera's format, so cuts don't interrupt the output.")
              .font(.uiMeta).foregroundStyle(.secondary)
          }
        } icon: {
          Image(systemName: UISymbol.updating)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      if !session.recentCuts.isEmpty {
        Divider()
        Text("Recent cuts").font(.uiMeta.weight(.semibold)).foregroundStyle(.secondary)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
          ForEach(session.recentCuts.prefix(5)) { cut in
            GridRow {
              Text(cut.at.formatted(date: .omitted, time: .standard)).font(.uiValue).foregroundStyle(.secondary)
              Text(cut.cameraName).font(.uiRow)
              Group {
                if cut.automatic { UIBadge(text: "Auto", symbol: UISymbol.auto) }
                else { Text("Manual").font(.uiMeta).foregroundStyle(.secondary) }
              }
              .gridColumnAlignment(.trailing)
            }
          }
        }
      }
      Label("Program isn't recorded. Each take keeps its camera original, plus this cut list.", systemImage: UISymbol.information)
        .font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The takes' clocks, sizes and the drives follow their statistics while the popover is open.
  private var recording: some View {
    UILiveSession(context: context, refresh: 2) { session, presentation in recording(session, presentation) }
  }

  private func recording(_ session: UISessionSnapshot, _ presentation: UISessionPresentation) -> some View {
    let takes = presentation.cameras.filter { $0.sizeLine != nil }
    let paused = takes.filter { $0.stripState == .paused }.count
    let subtitle = takes.isEmpty ? "Not recording"
      : [takes.count - paused > 0 ? "\(takes.count - paused) rolling" : nil, paused > 0 ? "\(paused) paused" : nil]
        .compactMap { $0 }.joined(separator: ", ")
    return Group {
      UIPopoverHeader(symbol: UISymbol.record, title: "Recording", subtitle: takes.isEmpty ? subtitle
        : takes.count == 1 && paused == 0 ? "1 take rolling" : subtitle)
      if !takes.isEmpty {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
          GridRow {
            Text("Camera"); Text("Clock"); Text("Size"); Text("Rate"); Text("Drop"); Text("Left")
          }
          .font(.uiBadge).foregroundStyle(.secondary)
          ForEach(takes) { camera in
            let snapshot = session.cameras.first { $0.id == camera.id }
            GridRow {
              HStack(spacing: 4) {
                UIStateGlyph(state: camera.stripState == .paused ? .paused
                  : camera.dropsWarning ? .warning : .recording, size: 7)
                Text(camera.name).font(.uiRowEmphasis).lineLimit(1)
              }
              Text(camera.stripState == .paused ? "Paused" : camera.recordDetail).font(.uiValueStrong)
              Text(camera.sizeLine ?? "—").font(.uiValue)
              Text(snapshot.map { UIFormat.bitrate($0.recording.megabitsPerSecond) } ?? "—").font(.uiValue).fixedSize()
              Text("\(snapshot?.recording.droppedFrames ?? 0)").font(.uiValue).gridColumnAlignment(.trailing)
              Text(camera.timeLeftLine?.replacingOccurrences(of: " left", with: "") ?? "—").font(.uiValue)
            }
            if let audio = snapshot?.recording.audio {
              GridRow {
                UIIconValue(symbol: UISymbol.audio, label: Self.audioLine(audio), help: audio.note, accessibilityLabel: audio.note)
                  .font(.uiMeta)
                  .gridCellColumns(6)
              }
            }
          }
        }
      }
      let notes = takes.compactMap { camera -> String? in camera.recordingNote.map { "\(camera.name): \($0)" } }
        + presentation.cameras.compactMap { camera in
          session.cameras.first { $0.id == camera.id }?.recording.compatibilityNote.map { "\(camera.name): \($0)" }
        }
      ForEach(notes, id: \.self) { note in
        Label { Text(note) } icon: { UIStateGlyph(state: .warning) }
          .font(.uiMeta).fixedSize(horizontal: false, vertical: true)
      }
      ForEach(presentation.cameras.filter { $0.formatFallback != nil }) { camera in
        VStack(alignment: .leading, spacing: 2) {
          Label { Text(camera.formatFallback ?? "").font(.uiRowEmphasis) } icon: { UIStateGlyph(state: .warning) }
          Text(camera.formatHelp).font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Divider()
      HStack(spacing: 8) {
        UIBadge(text: session.codec.title, symbol: UISymbol.format).fixedSize()
        Text("Camera original").font(.uiMeta).foregroundStyle(.secondary)
        Label(session.timecodeTitle, systemImage: UISymbol.timecode).font(.uiMeta).foregroundStyle(.secondary)
      }
      if takes.isEmpty, let camera = session.cameras.first {
        HStack {
          Text("Estimated, per camera").font(.uiMeta).foregroundStyle(.secondary)
          Spacer()
          Text("~\(UIFormat.bitrate(UIPresentationBuilder.estimateMegabits(session.codec.resolved(for: camera.sourceFormat), camera)))")
            .font(.uiValueStrong)
        }
      }
      ForEach(session.drives) { UIDriveRow(drive: $0, cameras: UIPresentationBuilder.cameras(on: $0, in: session)) }
      HStack {
        Button("Show in Finder", systemImage: UISymbol.folder) { context.send(.revealRecordings) }
          .disabled(!context.presentation.canRevealRecordings)
          .help(context.presentation.canRevealRecordings ? "Open the recording folder in Finder." : "Choose a recording folder first.")
        Spacer()
        if !takes.isEmpty {
          Button("Stop All Recordings") { context.send(.stopAllRecordings) }
            .help("Stop every recording (⌥⌘R)")
        }
      }
    }
  }

  /// "−23.4 LUFS  −2.1 dBTP  No overs", spaced.
  static func audioLine(_ audio: AudioTakeSummary) -> String {
    let loudness = audio.integrated.isFinite ? "\(MeterText.level(audio.integrated)) LUFS" : "No loudness"
    let peak = audio.maximumTruePeak.isFinite ? "\(MeterText.level(audio.maximumTruePeak)) dBTP" : "Silent"
    let overs = audio.overs == 0 ? "No overs" : audio.overs == 1 ? "1 over" : "\(audio.overs) overs"
    return "\(loudness)   \(peak)   \(overs)"
  }

  /// What the source declares: "48 kHz", "8 ch".
  nonisolated static func audioFormat(_ camera: UICameraSnapshot?) -> (rate: String, channels: String)? {
    guard let camera, camera.audioChannels > 0, camera.audioSampleRate > 0 else { return nil }
    let rate = Double(camera.audioSampleRate) / 1000
    return ("\(rate == rate.rounded() ? String(Int(rate)) : String(format: "%.1f", rate)) kHz", "\(camera.audioChannels) ch")
  }

  private var audio: some View {
    let live = context.presentation.cameras.filter { context.snapshot($0.id)?.running == true }
    let withAudio = live.filter(\.audio.present).count
    return Group {
      UIPopoverHeader(symbol: UISymbol.audio, title: "Embedded audio",
        subtitle: live.isEmpty ? "No camera is running" : "\(withAudio) of \(live.count) cameras")
      ForEach(live) { camera in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            if !camera.audio.present { UIStateGlyph(state: .warning) }
            Text(camera.name).font(.uiRowEmphasis)
            if !camera.audio.present { Text("No embedded audio").font(.uiMeta).foregroundStyle(.secondary) }
            Spacer()
            if let format = Self.audioFormat(context.snapshot(camera.id)) {
              UIBadge(text: format.rate).fixedSize()
              UIBadge(text: format.channels).fixedSize()
            }
          }
          UIAudioMeterPanel(cameraID: camera.id, name: camera.name, levels: camera.audio)
        }
      }
      Text("Not sent through the Ultracam cameras.")
        .font(.uiMeta).foregroundStyle(.secondary)
    }
  }
}

/// Under Hold, once the shot passes the soft maximum: it appears as the shot clock above it
/// ticks, on the same shared ticker (which that clock keeps running while it's shown).
private struct UIPastSoftMaximumNote: View {
  let shot: UIShotTiming
  @State private var ticker = UISecondTicker.shared

  var body: some View {
    if let started = shot.anchor, ticker.now.timeIntervalSince(started) >= shot.softMaximum {
      Label("Past the soft maximum. Hold stays on until you turn it off.", systemImage: UISymbol.information)
        .font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// One clock for every shot timer on screen: a TimelineView in each of the status bar's
/// measuring copies kept the window's graph updating on every display frame. It runs only
/// while a shot timer is shown.
@MainActor @Observable final class UISecondTicker {
  static let shared = UISecondTicker()
  private(set) var now = Date()
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var users = 0

  func retain() {
    users += 1
    guard timer == nil else { return }
    now = Date()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.now = Date() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func release() {
    users = max(0, users - 1)
    guard users == 0 else { return }
    timer?.invalidate()
    timer = nil
  }
}

/// The status bar's latest resource figures, observed by the readouts alone.
@MainActor @Observable final class UIResourceMonitor {
  private(set) var usage = AppResourceUsage()
  func publish(_ usage: AppResourceUsage) { if usage != self.usage { self.usage = usage } }
}
