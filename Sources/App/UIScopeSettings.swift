import MonitorKit
import MonitorKitScopes
import SwiftUI

/// One target's scope settings: which scope, the stage it measures, its look,
/// level scale (with the nits scales on PQ and HLG stages), the vectorscope's
/// zoom, targets and skin tone line, the histogram's mode and counts, the
/// refresh rate, trace gain, graticule and the clip readout levels.
///
/// Plain controls without a container, so a host can put them in a `Form` or in
/// MonitorKit's tile toolbar popover. The host's own switch turns scopes on;
/// these settings never do. Every change edits only the field it names, so the
/// classic look (`ScopeSettings.ultracamLegacy`) survives a change of scope.
struct UIScopeSettingsView: View {
  @Binding var scopes: MonitorScopePreferences
  var isProgram: Bool
  /// The picture's signal and whether the target has a burn-in LUT: they decide
  /// which stage signal the scope measures, and so which scales fit it.
  var signal: SignalDescription?
  var burnInLUT: Bool

  private var description: UIScopeDescription {
    UIScopeDescription(scopes: scopes, signal: signal, burnInLUT: burnInLUT, isProgram: isProgram)
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
    Picker("Scope", selection: choice) {
      ForEach(UIScopeChoice.allCases) { Text($0.title).tag($0) }
    }
    .accessibilityHint("Waveform, parade, vectorscope or histogram")
    if d.settings.kind == .histogram {
      Picker("Channels", selection: settings.histogramMode) {
        Text("Luma").tag(HistogramMode.luma)
        Text("RGB overlay").tag(HistogramMode.rgbOverlay)
        Text("RGB parade").tag(HistogramMode.rgbParade)
      }
    }
    Picker("Signal", selection: settings.stage) {
      Text("Source").tag(SignalStage.source).disabled(isProgram)
      Text(isProgram ? "Program Output" : "Output (LUT)").tag(SignalStage.output)
      if scopes.settings.stage == .monitor {
        Text("Monitor").tag(SignalStage.monitor)
      }
    }
    .help("The stage the scope measures. Output (LUT) is the source with the burned-in LUT, as published.")
    if d.hasLevelAxis {
      Picker("Look", selection: look) {
        ForEach(UIScopeLook.allCases) { Text($0.title).tag(Optional($0)) }
        if UIScopeLook(scopes.settings) == nil {
          Text("Custom").tag(Optional<UIScopeLook>.none).disabled(true)
        }
      }
      .help("Classic is the earlier Ultracam scope: −10…110 IRE with its trace colours.")
      Picker("Scale", selection: settings.display.waveformScale) {
        ForEach(WaveformScale.allCases, id: \.self) { scale in
          Text(UIScopeDescription.scaleTitle(scale)).tag(scale)
            .disabled(!d.offers(scale) && scopes.settings.display.waveformScale != scale)
        }
      }
      .help("Nits scales read light levels on PQ and HLG signals.")
      if let note = d.scaleNote {
        HStack(alignment: .firstTextBaseline) {
          Text(note).font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          if let suggested = d.suggestedHDRScale, scopes.settings.display.waveformScale != suggested {
            Spacer(minLength: 4)
            Button("Use \(UIScopeDescription.scaleTitle(suggested))") {
              settings.wrappedValue.display.waveformScale = suggested
            }
          }
        }
      }
    }
    switch d.settings.kind {
    case .vectorscope:
      Picker("Zoom", selection: settings.vectorscopeZoom) {
        ForEach(ScopeSettings.vectorscopeZooms, id: \.self) { Text("\($0)×").tag($0) }
      }
      Picker("Targets", selection: settings.display.vectorscopeTargets) {
        Text("None").tag(VectorscopeTargets.none)
        Text("75%").tag(VectorscopeTargets.percent75)
        Text("100%").tag(VectorscopeTargets.percent100)
        Text("75% and 100%").tag(VectorscopeTargets.both)
      }
      Toggle("Skin tone line", isOn: settings.display.showsSkinToneLine)
      Picker("Matrix", selection: settings.colorimetry) {
        Text("Automatic").tag(ScopeColorimetry.auto)
        Text("BT.601").tag(ScopeColorimetry.bt601)
        Text("BT.709").tag(ScopeColorimetry.bt709)
        Text("BT.2020").tag(ScopeColorimetry.bt2020)
        if scopes.settings.colorimetry == .smpte240m {
          Text("SMPTE 240M").tag(ScopeColorimetry.smpte240m)
        }
      }
      .help("Automatic uses the camera's matrix for the source and BT.709 after a LUT.")
    case .histogram:
      Picker("Counts", selection: settings.display.histogramScale) {
        Text("Linear").tag(HistogramScale.linear)
        Text("Logarithmic").tag(HistogramScale.logarithmic)
      }
    case .waveform:
      EmptyView()
    }
    Picker("Refresh", selection: $scopes.refreshHz) {
      ForEach(MonitorScopePreferences.refreshRates, id: \.self) { Text("\($0) Hz").tag($0) }
    }
    UIScopeSlider(title: "Trace gain", value: settings.display.gain, range: 0.25...4, format: "%.2f×")
    Toggle("Graticule", isOn: settings.display.showsGraticule)
    UIScopeSlider(title: "Clip above", value: settings.clipHighPercent, range: 90...109, format: "%.0f%%", step: 1)
      .help("The clip readout counts pixels at or above this level, per R, G, B and luma.")
    UIScopeSlider(title: "Clip below", value: settings.clipLowPercent, range: -7...10, format: "%.0f%%", step: 1)
      .help("The clip readout counts pixels at or below this level, per R, G, B and luma.")
    Text("One scope per camera. \(d.caption).")
      .font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
