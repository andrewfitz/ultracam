import AppKit
import MonitorToolsCore
import SwiftUI

/// Diagnostics window: per-camera capture, drops, audio, encoder and
/// monitoring details, Program state, and app resource use. Engineering
/// detail lives here so the everyday window stays calm.
struct UIDiagnosticsView: View {
  let model: AppModel
  @State private var tab = ""
  @State private var copied = false

  private var tabs: [(id: String, title: String)] {
    model.feedDescriptors.map { ($0.id.rawValue, $0.name) }
      + (model.outputMode == .program ? [("program", "Program")] : []) + [("app", "App")]
  }

  var body: some View {
    let selected = tabs.contains { $0.id == tab } ? tab : (tabs.first?.id ?? "app")
    Group {
      switch selected {
      case "app": UIDiagnosticsAppTab()
      case "program": UIDiagnosticsProgramTab(model: model)
      default: UIDiagnosticsCameraTab(model: model, cameraID: FeedID(rawValue: selected))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .frame(minWidth: 760, minHeight: 560)
    // The section picker and Copy live in the window toolbar, like other Mac windows.
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Section", selection: Binding(get: { selected }, set: { tab = $0 })) {
          ForEach(tabs, id: \.id) { Text($0.title).tag($0.id) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      ToolbarItem(placement: .primaryAction) {
        Button(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc") {
          UIDiagnosticsText.copy(model: model)
          copied = true
        }
        .labelStyle(.titleAndIcon)
        .help("Copy a plain-text summary of these diagnostics")
      }
    }
    // "Copied" confirms the copy briefly, then the button reads Copy Diagnostics again.
    .task(id: copied) {
      guard copied else { return }
      try? await Task.sleep(for: .seconds(2))
      copied = false
    }
  }
}

private struct UIDiagnosticsRow: View {
  let title: String
  let value: String
  var warning = false
  init(_ title: String, _ value: String, warning: Bool = false) {
    self.title = title
    self.value = value
    self.warning = warning
  }
  var body: some View {
    LabeledContent(title) {
      // The tone goes on the symbol; small orange text is hard to read in light mode.
      HStack(spacing: 4) {
        if warning {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Warning")
        }
        Text(value).monospacedDigit().textSelection(.enabled)
      }
    }
  }
}

enum UIDiagnosticsFormat {
  static func megabits(_ value: Double) -> String {
    guard value.isFinite, value > 0 else { return "—" }
    return value >= 1000 ? String(format: "%.1f Gb/s", value / 1000) : String(format: "%.2f Mb/s", value)
  }
  static func kilobits(_ value: Double) -> String {
    guard value.isFinite, value > 0 else { return "—" }
    return value >= 1000 ? String(format: "%.2f Mb/s", value / 1000) : String(format: "%.1f kb/s", value)
  }
  static func count(_ value: UInt64) -> String { value.formatted() }
}

// MARK: - Camera

private struct UIDiagnosticsCameraTab: View {
  let model: AppModel
  let cameraID: FeedID

  var body: some View {
    let update = model.cameraUpdate(cameraID)
    let running = model.isCameraRunning(cameraID)
    let state = model.recordingModel.feeds.first { $0.id == cameraID }
    let target = MonitorTargetID(cameraID.rawValue)
    Form {
      if !running {
        // Values from a stopped camera would be stale, so only the last take's encoder details stay.
        Section {
          ContentUnavailableView("Camera Stopped", systemImage: "video.slash",
            description: Text("Live capture, drops, audio and monitoring details appear while this camera runs."))
            .frame(maxWidth: .infinity)
        }
      }
      if running, let update {
        Section("Capture") {
          UIDiagnosticsRow("Input", update.input)
          UIDiagnosticsRow("Output", update.output.isEmpty ? "—" : update.output)
          UIDiagnosticsRow("Delivered", String(format: "%.2f fps", update.outputFPS))
          UIDiagnosticsRow("Processing", String(format: "%.2f ms", update.processingMS))
          UIDiagnosticsRow("Input video bitrate", UIDiagnosticsFormat.megabits(update.videoBitrateMbps))
          UIDiagnosticsRow("Timecode (RP188)", update.timecode ?? "—")
          UIDiagnosticsRow("Video drops", UIDiagnosticsFormat.count(update.videoDrops), warning: update.videoDrops > 0)
        }
        Section {
          UIDiagnosticsRow("Source gaps", UIDiagnosticsFormat.count(update.sourceDrops), warning: update.sourceDrops > 0)
          UIDiagnosticsRow("Capture admission", UIDiagnosticsFormat.count(update.captureDrops), warning: update.captureDrops > 0)
          UIDiagnosticsRow("Output buffers", UIDiagnosticsFormat.count(update.poolDrops), warning: update.poolDrops > 0)
          UIDiagnosticsRow("Camera transport", UIDiagnosticsFormat.count(update.cameraDrops), warning: update.cameraDrops > 0)
          UIDiagnosticsRow("Preview", UIDiagnosticsFormat.count(update.previewDrops), warning: update.previewDrops > 0)
        } header: { Text("Drops by Stage") } footer: {
          Text("Native renderer totals include prior runs. Intentional frame-rate reduction is excluded.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("Embedded Audio") {
          UIDiagnosticsRow("Format", update.audioPresent
            ? "\(update.audioChannels) ch · \(String(format: "%.1f kHz", Double(update.audioSampleRate) / 1000))" : "No embedded audio")
          UIDiagnosticsRow("Audio bitrate", UIDiagnosticsFormat.kilobits(update.audioBitrateKbps))
          UIDiagnosticsRow("Packets · samples", "\(UIDiagnosticsFormat.count(update.audioPackets)) · \(UIDiagnosticsFormat.count(update.audioSamples))")
          UIDiagnosticsRow("Audio drops · gaps", UIDiagnosticsFormat.count(update.audioDrops), warning: update.audioDrops > 0)
          UIAudioMeter(audio: UIAudioLevels(present: update.audioPresent, peakLeft: update.audioPeakLeft,
            peakRight: update.audioPeakRight, rmsLeft: update.audioRMSLeft, rmsRight: update.audioRMSRight))
        }
      }
      Section("Recording · Encoder") {
        if let stats = state?.statistics {
          UIDiagnosticsRow("Status", state?.displayStatus ?? "Idle")
          UIDiagnosticsRow("Elapsed · size", "\(stats.elapsedText) · \(stats.sizeText)")
          UIDiagnosticsRow("Encoder", stats.hardwareEncoder.map { $0 ? "Hardware accelerated" : "Software" } ?? "Waiting for encoder")
          UIDiagnosticsRow("Encode rate · bitrate", String(format: "%.1f fps · ", stats.framesPerSecond) + UIDiagnosticsFormat.megabits(stats.videoMegabitsPerSecond))
          UIDiagnosticsRow("Encode latency", "\(stats.encoderLatencyMS.map { String(format: "%.1f ms", $0) } ?? "—") · peak \(stats.maxEncoderLatencyMS.map { String(format: "%.1f ms", $0) } ?? "—")")
          UIDiagnosticsRow("Writer queue · encoder pending", "\(stats.queueSamples)/\(stats.queueCapacity) samples · \(stats.encoderPendingFrames) frames")
          UIDiagnosticsRow("Dropped video frames", UIDiagnosticsFormat.count(stats.droppedVideoFrames), warning: stats.droppedVideoFrames > 0)
          UIDiagnosticsRow("Audio packets dropped", UIDiagnosticsFormat.count(stats.droppedAudioPackets), warning: stats.droppedAudioPackets > 0)
          UIDiagnosticsRow("Encoder · writer errors", "\(stats.encoderErrors) · \(stats.writerErrors)", warning: stats.encoderErrors + stats.writerErrors > 0)
          UIDiagnosticsRow("File", stats.fileURL?.lastPathComponent ?? "—")
          if let error = stats.lastError { UIDiagnosticsRow("Last error", error, warning: true) }
        } else {
          Text("No take yet.").foregroundStyle(.secondary)
        }
      }
      if running {
        UIDiagnosticsMonitorSection(snapshot: model.monitorCoordinator.diagnostics(for: target))
      }
      if running, let update {
        Section("Messages") {
          UIDiagnosticsRow("Capture", update.message)
          UIDiagnosticsRow("Camera", update.cameraMessage)
          UIDiagnosticsRow("Preview", update.previewError ?? "No preview error", warning: update.previewError != nil)
        }
      }
    }
    .formStyle(.grouped)
  }
}

/// The shared monitor target's rates, quality and budget, one value per row.
private struct UIDiagnosticsMonitorSection: View {
  let snapshot: MonitorDiagnostics

  var body: some View {
    let quality = snapshot.effectiveQuality
    Section("Monitoring") {
      UIDiagnosticsRow("Status", availability)
      UIDiagnosticsRow("Source rate", "\(rate(snapshot.offeredFPS)) fps")
      UIDiagnosticsRow("Picture rate · camera", "\(rate(snapshot.pictureFPS)) fps · \(rate(snapshot.requestedPictureHz)) Hz")
      UIDiagnosticsRow("Scope rate · cap", "\(rate(snapshot.scopeFPS)) fps · \(quality.scopeRefreshHz) Hz")
      UIDiagnosticsRow("Quality", quality.label)
      UIDiagnosticsRow("Picture limit · scope stride", "\(quality.pictureHeightLimit)p · \(quality.scopeSamplingStride)")
      UIDiagnosticsRow("Frames offered · admitted · skipped",
        "\(UIDiagnosticsFormat.count(snapshot.offeredFrames)) · \(UIDiagnosticsFormat.count(snapshot.admittedFrames)) · \(UIDiagnosticsFormat.count(snapshot.skippedFrames))")
      UIDiagnosticsRow("Rejected results", UIDiagnosticsFormat.count(snapshot.rejectedResults), warning: snapshot.rejectedResults > 0)
      UIDiagnosticsRow("Monitor memory", "\(bytes(snapshot.retainedBytes)) retained · \(bytes(snapshot.retiredBytes)) retiring")
      UIDiagnosticsRow("GPU deadline", deadline, warning: snapshot.softDeadlineStatus == .exceeded)
    }
  }

  private func rate(_ value: Double) -> String { String(format: "%.1f", value) }
  private func bytes(_ value: Int) -> String { String(format: "%.1f MiB", Double(value) / 1_048_576) }

  private var deadline: String {
    switch snapshot.softDeadlineStatus {
    case .unavailable: return "Unavailable"
    case .withinDeadline: return "Within limit"
    case .exceeded: return "Exceeded · clean picture only"
    }
  }

  private var availability: String {
    switch snapshot.availability {
    case .noSignal: return "No signal"
    case .starting: return "Starting"
    case .live: return "Live"
    case .paused: return "Paused or hidden"
    case .stale: return "Stale"
    case .unsupported(let reason), .degraded(let reason), .failed(let reason): return reason
    }
  }
}

// MARK: - Program

private struct UIDiagnosticsProgramTab: View {
  let model: AppModel

  private func name(_ id: FeedID?) -> String {
    guard let id else { return "—" }
    return model.feedDescriptors.first { $0.id == id }?.name ?? id.rawValue
  }

  var body: some View {
    let switcher = model.switcherSettings
    Form {
      Section("Output") {
        UIDiagnosticsRow("Camera", "Ultracam · Program")
        UIDiagnosticsRow("Clients", model.programInUse ? "In use" : "Not in use")
        UIDiagnosticsRow("Camera formats", model.programFormatMismatch ? "Differ — each cut updates the output" : "Match",
          warning: model.programFormatMismatch)
      }
      Section("Switching") {
        UIDiagnosticsRow("On air", name(model.switcherSelectedFeedID))
        UIDiagnosticsRow("Pending cut", name(model.switcherPendingFeedID))
        UIDiagnosticsRow("Automatic", switcher.automatic ? (switcher.naturalTalkingHead.manualHold ? "On · holding" : "On") : "Off")
        UIDiagnosticsRow("Strategy", UIStrategy.title(switcher.strategy))
        UIDiagnosticsRow("Switcher", model.switcherStatus)
        UIDiagnosticsRow("Director", model.naturalDirectorStatus)
      }
      Section {
        if model.recentCuts.isEmpty {
          Text("No cuts yet this session.").foregroundStyle(.secondary)
        }
        ForEach(model.recentCuts) { cut in
          LabeledContent(cut.at.formatted(date: .omitted, time: .standard)) {
            Text("\(cut.cameraName) · \(cut.automatic ? "Auto" : "Manual")").foregroundStyle(.secondary)
          }
        }
      } header: { Text("Recent Cuts") } footer: {
        Text("Transcript cues need an external transcript source; the director otherwise listens to one audio stream from the selected camera.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - App

private struct UIDiagnosticsAppTab: View {
  @State private var history: [AppResourceUsage] = []

  var body: some View {
    let latest = history.last
    Form {
      Section {
        UIDiagnosticsMetric(title: "CPU", value: latest?.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—",
          samples: history.map { $0.cpuPercent ?? 0 },
          help: "Total Ultracam process CPU across all threads. 100% is one CPU core; this can exceed 100%. System encoder services run outside this process.")
        UIDiagnosticsMetric(title: "GPU (video)", value: String(format: "%.1f%%", latest?.gpuPercent ?? 0),
          samples: history.map(\.gpuPercent), upperBound: 100,
          help: "Combined busy time of Ultracam's Metal video processing and copy queues over the last second. Overlapping work counts once. Excludes the hardware media encoder and system display compositor.")
        UIDiagnosticsMetric(title: "Memory", value: latest?.memoryBytes.map {
          ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory) } ?? "—",
          samples: history.map { Double($0.memoryBytes ?? 0) },
          help: "Process memory footprint, including bounded frame pools and the shared monitor budget.")
      } header: { Text("Ultracam Total · Last 60 s") } footer: {
        Text("Sampled once per second only while this tab is visible.").font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task {
      var sampler = AppResourceSampler()
      while !Task.isCancelled {
        history.append(sampler.sample())
        if history.count > 60 { history.removeFirst(history.count - 60) }
        do { try await Task.sleep(for: .seconds(1)) } catch { break }
      }
    }
  }
}

private struct UIDiagnosticsMetric: View {
  let title: String
  let value: String
  let samples: [Double]
  var upperBound: Double? = nil
  let help: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.headline)
        Spacer()
        Text(value).font(.title3.monospacedDigit())
      }
      UIDiagnosticsSparkline(samples: samples, upperBound: upperBound)
        .frame(height: 44)
      Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .help(help)
  }
}

private struct UIDiagnosticsSparkline: View {
  let samples: [Double]
  var upperBound: Double?

  var body: some View {
    GeometryReader { proxy in
      let top = max(upperBound ?? (samples.max() ?? 1), 0.0001)
      let step = proxy.size.width / CGFloat(max(59, samples.count - 1))
      Path { path in
        for (index, sample) in samples.enumerated() {
          let point = CGPoint(x: CGFloat(index) * step,
            y: proxy.size.height * (1 - CGFloat(min(1, max(0, sample / top)))))
          if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
      }
      .stroke(Color.accentColor, lineWidth: 1.5)
      .background(RoundedRectangle(cornerRadius: 6).fill(.fill.quaternary))
    }
    .accessibilityHidden(true)
  }
}
