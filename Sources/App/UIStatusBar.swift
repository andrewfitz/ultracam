import SwiftUI

/// Bottom status bar. Fixed order: output, Program, recording, audio, warning,
/// then resources on the right. Each segment opens a popover with details.
struct UIStatusBarView: View {
  let context: UIContext
  @State private var open: UIStatusSegment.Kind?
  @State private var resourcesOpen = false
  @State private var usage = AppResourceUsage()

  var body: some View {
    // What fits decides the density, so the bar is never empty: full text with the full
    // resource readout when there is room, then a shorter readout, no readout, short
    // segment text, and finally only output, recording and warning. The bar sits in the
    // detail column, so its width depends on the side columns, not just the window.
    ViewThatFits(in: .horizontal) {
      bar(compact: false, readout: .full)
      bar(compact: false, readout: .short)
      bar(compact: false, readout: nil)
      bar(compact: true, readout: .short)
      bar(compact: true, readout: nil)
      bar(compact: true, essentialOnly: true, readout: nil)
    }
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity)
    .frame(height: 30)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Status")
    .task {
      // Sampled here rather than in the readout, which ViewThatFits may swap for another variant.
      var sampler = AppResourceSampler()
      while !Task.isCancelled {
        usage = sampler.sample()
        do { try await Task.sleep(for: .seconds(1)) } catch { break }
      }
    }
  }

  private func bar(compact: Bool, essentialOnly: Bool = false, readout: UIResourceReadout.Density?) -> some View {
    HStack(spacing: 2) {
      segmentsRow(compact: compact, essentialOnly: essentialOnly)
        .layoutPriority(1)
      Spacer(minLength: 8)
      if let readout {
        UIResourceReadout(open: $resourcesOpen, usage: usage, density: readout, context: context)
      }
    }
  }

  private func segmentsRow(compact: Bool, essentialOnly: Bool = false) -> some View {
    HStack(spacing: 2) {
      ForEach(Array(visibleSegments(essentialOnly: essentialOnly).enumerated()), id: \.element.id) { index, segment in
        if index > 0 { Divider().frame(height: 14) }
        segmentButton(segment, compact: compact)
          .layoutPriority(priority(segment.kind))
      }
    }
  }

  /// Under pressure the warning and recording keep their text longest.
  private func priority(_ kind: UIStatusSegment.Kind) -> Double {
    switch kind {
    case .warning: return 3
    case .recording: return 2
    case .output: return 1
    case .program, .audio: return 0
    }
  }

  private func visibleSegments(essentialOnly: Bool) -> [UIStatusSegment] {
    let segments = context.presentation.statusSegments
    guard essentialOnly else { return segments }
    return segments.filter { $0.kind == .output || $0.kind == .recording || $0.kind == .warning }
  }

  private func segmentButton(_ segment: UIStatusSegment, compact: Bool) -> some View {
    Button { open = segment.kind } label: {
      // The tone colors the symbol only; the words stay in a label color so they stay readable.
      HStack(spacing: 5) {
        if segment.kind == .recording && segment.tone == .critical {
          Circle().fill(.red).frame(width: 7, height: 7)
        } else {
          Image(systemName: symbol(segment.kind)).imageScale(.small).foregroundStyle(symbolColor(segment))
        }
        Text(compact ? shortText(segment) : segment.text).lineLimit(1).truncationMode(.tail)
          .foregroundStyle(segment.tone == .neutral ? .secondary : .primary)
      }
      .font(.subheadline)
      .padding(.horizontal, 7).frame(height: 22)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(segment.text)
    .accessibilityLabel(segment.text)
    .accessibilityHint("Shows details")
    .popover(isPresented: Binding(get: { open == segment.kind }, set: { if !$0 { open = nil } }), arrowEdge: .top) {
      UIStatusPopover(kind: segment.kind, segment: segment, context: context)
    }
  }

  private func symbol(_ kind: UIStatusSegment.Kind) -> String {
    switch kind {
    case .output: return "video.badge.checkmark"
    case .program: return "tv"
    case .recording: return "record.circle"
    case .audio: return "waveform"
    case .warning: return "exclamationmark.triangle.fill"
    }
  }

  private func symbolColor(_ segment: UIStatusSegment) -> Color {
    switch segment.tone {
    case .positive: return .green
    case .warning: return .orange
    case .critical where segment.kind == .recording: return .primary
    case .critical, .onAir: return .red
    case .neutral: return .secondary
    }
  }

  /// Shorter text for narrow windows; the full text stays in the tooltip and popover.
  private func shortText(_ segment: UIStatusSegment) -> String {
    switch segment.kind {
    case .output: return shortOutputText
    case .program: return segment.text.components(separatedBy: " · ").first ?? segment.text
    case .recording: return segment.text.components(separatedBy: " · ").prefix(2).joined(separator: " · ")
    case .audio, .warning: return segment.text
    }
  }

  /// The short output text still names what is (not) in use.
  private var shortOutputText: String {
    let session = context.session
    switch session.outputMode {
    case .program:
      return session.programInUse ? "Program in use" : "Program not in use"
    case .separate:
      if session.cameras.count == 1, let camera = session.cameras.first {
        return camera.inUse ? "\(camera.name) in use" : "\(camera.name) not in use"
      }
      let inUse = session.cameras.filter(\.inUse).count
      return inUse > 0 ? "\(inUse) of \(session.cameras.count) in use" : "Cameras not in use"
    }
  }
}

// MARK: - Resources

/// App CPU, combined GPU video busy time and memory. The status bar samples once per second while visible.
struct UIResourceReadout: View {
  enum Density { case full, short }

  @Binding var open: Bool
  let usage: AppResourceUsage
  var density: Density = .full
  let context: UIContext

  var body: some View {
    Button { open = true } label: {
      Text(density == .full ? fullText : shortText)
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 7).frame(height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Total Ultracam process CPU across all threads (100% is one core). GPU (video) is the combined busy time of Ultracam's Metal video processing and copy queues; it excludes the hardware media encoder and the system display compositor.")
    .accessibilityLabel("Ultracam resources")
    .accessibilityValue(fullText)
    .popover(isPresented: $open, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Ultracam total").font(.headline)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
          GridRow { Text("CPU"); Text(cpu).monospacedDigit() }
          GridRow { Text("GPU (video)"); Text(String(format: "%.1f%%", usage.gpuPercent)).monospacedDigit() }
          GridRow { Text("Memory"); Text(memory).monospacedDigit() }
        }
        Text("CPU counts all Ultracam threads; 100% is one core, so it can exceed 100%. System encoder services run outside this process.")
          .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text("GPU (video) unions completed Metal processing and copy intervals, so overlapping work counts once. It excludes the hardware media encoder and the display compositor, and is not a whole-machine reading.")
          .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("Open Diagnostics") { open = false; context.send(.openDiagnostics) }
        }
      }
      .padding(14)
      .frame(width: 320)
    }
  }

  private var cpu: String { usage.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—" }
  private var memory: String {
    usage.memoryBytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory) } ?? "—"
  }
  private var fullText: String { "CPU \(cpu) · GPU (video) \(String(format: "%.1f%%", usage.gpuPercent)) · Memory \(memory)" }
  private var shortText: String { "CPU \(cpu) · GPU \(String(format: "%.0f%%", usage.gpuPercent))" }
}

// MARK: - Popovers

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
        Label { Text(segment.text) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(width: 340, alignment: .leading)
  }

  private var output: some View {
    Group {
      Text("Output").font(.headline)
      switch context.session.outputMode {
      case .program:
        row(title: "Ultracam · Program", detail: context.session.programInUse ? "In use" : "Not in use",
          positive: context.session.programInUse,
          format: context.session.cameras.first { $0.id == context.session.onAirID }?.outputFormat)
      case .separate:
        ForEach(context.session.cameras) { camera in
          row(title: "Ultracam · \(camera.name)", detail: camera.inUse ? "In use" : "Not in use", positive: camera.inUse,
            format: camera.outputFormat)
        }
      }
      Text("Video only — select your microphone in your meeting app.")
        .font(.subheadline).foregroundStyle(.secondary)
    }
  }

  private func row(title: String, detail: String, positive: Bool, format: String?) -> some View {
    HStack {
      Image(systemName: "video.badge.checkmark").foregroundStyle(positive ? Color.green : .secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).lineLimit(1).truncationMode(.middle)
        Text([detail, format].compactMap { $0 }.joined(separator: " · ")).font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var program: some View {
    Group {
      Text("Program").font(.headline)
      Text(segment.text)
      if context.session.programFormatMismatch {
        Label {
          Text("Program cameras use different formats. The GPU converts each to the Program camera's format, so cuts don't interrupt the output.")
        } icon: {
          Image(systemName: "arrow.triangle.2.circlepath")
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
      }
      if !context.session.recentCuts.isEmpty {
        Divider()
        Text("Recent cuts").font(.subheadline.weight(.semibold))
        ForEach(context.session.recentCuts.prefix(5)) { cut in
          HStack {
            Text(cut.at.formatted(date: .omitted, time: .standard)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            Text(cut.cameraName)
            Spacer()
            UIBadge(text: cut.automatic ? "Auto" : "Manual")
          }
        }
      }
    }
  }

  private var recording: some View {
    Group {
      Text("Recording").font(.headline)
      let takes = context.presentation.cameras.filter { $0.sizeLine != nil }
      if takes.isEmpty {
        Text("Not recording").foregroundStyle(.secondary)
      }
      ForEach(takes) { camera in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Circle().fill(camera.recordTone == .critical ? Color.red : camera.recordTone.color).frame(width: 7, height: 7)
            Text(camera.name).fontWeight(.medium)
            Text("\(camera.recordTitle) · \(camera.recordDetail)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
          }
          HStack(spacing: 4) {
            if camera.dropsWarning {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).imageScale(.small)
            }
            Text([camera.sizeLine, camera.dropsLine, camera.timeLeftLine].compactMap { $0 }.joined(separator: " · "))
              .foregroundStyle(.secondary)
          }
          .font(.subheadline.monospacedDigit())
          // The take's audio: a warning line when it needs a look, the summary otherwise.
          if let note = camera.recordingNote {
            Label { Text(note).foregroundStyle(.secondary) } icon: {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).imageScale(.small)
            }
            .font(.subheadline.monospacedDigit())
            .fixedSize(horizontal: false, vertical: true)
          } else if let audio = camera.takeAudioHelp {
            Text(audio).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .accessibilityElement(children: .combine)
      }
      ForEach(context.session.drives) { UIDriveRow(drive: $0) }
      HStack {
        Button("Show in Finder") { context.send(.revealRecordings) }
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

  private var audio: some View {
    Group {
      Text("Embedded audio").font(.headline)
      let live = context.presentation.cameras.filter { context.snapshot($0.id)?.running == true }
      if live.isEmpty { Text("No camera is running.").foregroundStyle(.secondary) }
      ForEach(live) { camera in
        VStack(alignment: .leading, spacing: 4) {
          Text(camera.name).font(.callout.weight(.medium))
          UIAudioMeterPanel(cameraID: camera.id, name: camera.name, levels: camera.audio)
        }
      }
      Text("48 kHz stereo from each input. Not sent through the Ultracam cameras.")
        .font(.subheadline).foregroundStyle(.secondary)
    }
  }
}
