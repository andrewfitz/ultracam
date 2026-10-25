import MonitorKit
import MonitorKitScopes
import SwiftUI

/// One target's scope settings: which scope, the stage it measures, its look,
/// level scale (with the nits scales on PQ and HLG stages), the vectorscope's
/// zoom, targets and skin tone line, the histogram's mode and counts, trace
/// gain, graticule and the clip readout levels. (Scopes follow every video frame.)
///
/// `.stacked` is plain controls without a container, so a host can put them in
/// a `Form` or in MonitorKit's tile toolbar popover. `.columns` lays them out as
/// the monitor tool popovers do: the scope and its signal beside its look and
/// readout. The host's own switch turns scopes on; these settings never do.
/// Every change edits only the field it names, so the classic look
/// (`ScopeSettings.plainWaveform`) survives a change of scope.
struct UIScopeSettingsView: View {
  enum Layout { case stacked, columns }

  @Binding var scopes: MonitorScopePreferences
  var isProgram: Bool
  /// The picture's signal and whether a LUT is on the scope's stage
  /// (`MonitorSurfacePresenter.scopeMeasuresLUT`): they decide which stage
  /// signal the scope measures, and so which scales fit it.
  var signal: SignalDescription?
  var stageLUT: Bool
  var layout: Layout = .stacked

  /// Whether the menus offer every MonitorKit scope and scale. The main
  /// window's scope strip draws and labels every scope (`UIScopeImage`) and
  /// its camera Scopes popover is these same settings, so they do. With false
  /// only the waveforms and the IRE scale would be offered (a setting already
  /// saved is still listed, so it can be changed back).
  static let offersEveryScope = true

  private var description: UIScopeDescription {
    UIScopeDescription(scopes: scopes, signal: signal, stageLUT: stageLUT, isProgram: isProgram)
  }

  private var settings: Binding<ScopeSettings> {
    Binding(
      get: { scopes.settings },
      set: { value in
        let next = value.normalized()
        if next != scopes.settings { scopes.settings = next }
      })
  }

  var body: some View {
    let d = description
    switch layout {
    case .stacked:
      row("Scope") { scopePicker(d) }
      if d.settings.kind == .histogram { row("Channels") { channelsPicker } }
      row("Signal") { signalPicker }
      levelControls(d)
      kindControls(d)
      if d.usesMatrix { row("Matrix") { matrixPicker } }
      traceControls
      caption(d)
    case .columns:
      UIToolColumns {
        UIToolGroup("Scope") {
          row("Scope") { scopePicker(d) }
          if d.settings.kind == .histogram { row("Channels") { channelsPicker } }
          row("Signal") { signalPicker }
          if d.usesMatrix { row("Matrix") { matrixPicker } }
        }
        if d.hasLevelAxis {
          UIToolGroup("Levels") { levelControls(d) }
        }
      } trailing: {
        UIToolGroup("Display") {
          kindControls(d)
          UIScopeSlider(title: "Trace gain", value: settings.display.gain, range: 0.25...4, format: "%.2f×")
          Toggle("Graticule", isOn: settings.display.showsGraticule)
        }
        UIToolGroup("Clip readout") { clipControls }
      } footer: {
        caption(d)
      }
    }
  }

  /// A control as a row: inline as before when stacked, in the label column in columns.
  @ViewBuilder private func row<Control: View>(_ title: String, @ViewBuilder _ control: () -> Control) -> some View {
    switch layout {
    case .stacked: control()
    case .columns: control().fixedSize().uiToolRow(title)
    }
  }

  private func scopePicker(_ d: UIScopeDescription) -> some View {
    Picker("Scope", selection: choice) {
      ForEach(UIScopeChoice.allCases.filter { Self.offersEveryScope || $0.isWaveform || $0 == d.choice }) {
        Text($0.title).tag($0)
      }
    }
    .accessibilityHint(Self.offersEveryScope ? "Waveform, parade, vectorscope or histogram" : "Waveform or parade")
  }

  private var channelsPicker: some View {
    Picker("Channels", selection: settings.histogramMode) {
      Text("Luma").tag(HistogramMode.luma)
      Text("RGB overlay").tag(HistogramMode.rgbOverlay)
      Text("RGB parade").tag(HistogramMode.rgbParade)
    }
  }

  private var signalPicker: some View {
    Picker("Signal", selection: settings.stage) {
      Text("Source").tag(SignalStage.source).disabled(isProgram)
      Text(isProgram ? "Program Output" : "Output (LUT)").tag(SignalStage.output)
      if scopes.settings.stage == .monitor {
        Text("Monitor").tag(SignalStage.monitor)
      }
    }
    .help("The stage the scope measures. Output (LUT) is the source with the burned-in LUT, as published.")
  }

  private var matrixPicker: some View {
    Picker("Matrix", selection: settings.colorimetry) {
      Text("Automatic").tag(ScopeColorimetry.auto)
      Text("BT.601").tag(ScopeColorimetry.bt601)
      Text("BT.709").tag(ScopeColorimetry.bt709)
      Text("BT.2020").tag(ScopeColorimetry.bt2020)
      if scopes.settings.colorimetry == .smpte240m {
        Text("SMPTE 240M").tag(ScopeColorimetry.smpte240m)
      }
    }
    .help("The Y'CbCr weights of the drawn luma and chroma. Automatic uses the camera's matrix for the source and BT.709 after a LUT.")
  }

  /// The look, the level scale and its note, for scopes with a level axis.
  @ViewBuilder private func levelControls(_ d: UIScopeDescription) -> some View {
    if d.hasLevelAxis {
      row("Look") {
        Picker("Look", selection: look) {
          ForEach(UIScopeLook.allCases) { Text($0.title).tag(Optional($0)) }
          if UIScopeLook(scopes.settings) == nil {
            Text("Custom").tag(Optional<UIScopeLook>.none).disabled(true)
          }
        }
        .help("Classic is the earlier Ultracam scope: −10…110 IRE with its trace colours.")
      }
      if scales.count > 1 {
        row("Scale") {
          Picker("Scale", selection: settings.display.waveformScale) {
            ForEach(scales, id: \.self) { scale in
              Text(UIScopeDescription.scaleTitle(scale)).tag(scale)
                .disabled(!d.offers(scale) && scopes.settings.display.waveformScale != scale)
            }
          }
          .help("Nits scales read light levels on PQ and HLG signals.")
        }
      }
      if let note = d.scaleNote, Self.offersEveryScope || scopes.settings.display.waveformScale != .percent {
        HStack(alignment: .firstTextBaseline) {
          Text(note).font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          if let suggested = d.suggestedHDRScale, scopes.settings.display.waveformScale != suggested,
            scales.contains(suggested)
          {
            Spacer(minLength: 4)
            Button("Use \(UIScopeDescription.scaleTitle(suggested))") {
              settings.wrappedValue.display.waveformScale = suggested
            }
          }
        }
      }
    }
  }

  /// The vectorscope's zoom, targets and skin tone line; the histogram's counts.
  @ViewBuilder private func kindControls(_ d: UIScopeDescription) -> some View {
    switch d.settings.kind {
    case .vectorscope:
      row("Zoom") {
        Picker("Zoom", selection: settings.vectorscopeZoom) {
          ForEach(ScopeSettings.vectorscopeZooms, id: \.self) { Text("\($0)×").tag($0) }
        }
      }
      row("Targets") {
        Picker("Targets", selection: settings.display.vectorscopeTargets) {
          Text("None").tag(VectorscopeTargets.none)
          Text("75%").tag(VectorscopeTargets.percent75)
          Text("100%").tag(VectorscopeTargets.percent100)
          Text("75% and 100%").tag(VectorscopeTargets.both)
        }
      }
      Toggle("Skin tone line", isOn: settings.display.showsSkinToneLine)
    case .histogram:
      row("Counts") {
        Picker("Counts", selection: settings.display.histogramScale) {
          Text("Linear").tag(HistogramScale.linear)
          Text("Logarithmic").tag(HistogramScale.logarithmic)
        }
      }
    case .waveform:
      EmptyView()
    }
  }

  /// Trace gain, graticule and the clip readout's levels, as stacked.
  @ViewBuilder private var traceControls: some View {
    UIScopeSlider(title: "Trace gain", value: settings.display.gain, range: 0.25...4, format: "%.2f×")
    Toggle("Graticule", isOn: settings.display.showsGraticule)
    clipControls
  }

  @ViewBuilder private var clipControls: some View {
    UIScopeSlider(title: "Clip above", value: settings.clipHighPercent, range: 90...109, format: "%.0f%%", step: 1)
      .help("The clip readout counts pixels at or above this level, per R, G, B and luma.")
    UIScopeSlider(title: "Clip below", value: settings.clipLowPercent, range: -7...10, format: "%.0f%%", step: 1)
      .help("The clip readout counts pixels at or below this level, per R, G, B and luma.")
  }

  private func caption(_ d: UIScopeDescription) -> some View {
    Text("One scope per camera. \(d.caption).")
      .font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }

  /// The scales in the menu: every one, or IRE % and the saved one.
  private var scales: [WaveformScale] {
    WaveformScale.allCases.filter {
      Self.offersEveryScope || $0 == .percent || $0 == scopes.settings.display.waveformScale
    }
  }

  private var choice: Binding<UIScopeChoice> {
    Binding(
      get: { UIScopeChoice(scopes.settings) },
      set: { settings.wrappedValue = $0.applied(to: scopes.settings) })
  }

  private var look: Binding<UIScopeLook?> {
    Binding(
      get: { UIScopeLook(scopes.settings) },
      set: { look in
        guard let look else { return }
        settings.wrappedValue = look.applied(to: scopes.settings)
      })
  }
}

/// A labelled slider with its value, in the monitor settings' style.
private struct UIScopeSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let format: String
  var step: Double?

  init(title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, step: Double? = nil) {
    self.title = title
    _value = value
    self.range = range
    self.format = format
    self.step = step
  }

  var body: some View {
    LabeledContent {
      HStack {
        if let step {
          Slider(value: clamped, in: range, step: step).frame(minWidth: 110)
        } else {
          Slider(value: clamped, in: range).frame(minWidth: 110)
        }
        Text(String(format: format, value))
          .font(.uiMeta.monospacedDigit()).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
      }
    } label: {
      Text(title)
    }
    .accessibilityElement(children: .combine)
  }

  /// A saved value outside the slider's range shows at its end and stays as saved until moved.
  private var clamped: Binding<Double> {
    Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: { value = $0 })
  }
}
