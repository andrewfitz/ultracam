import MonitorKit
import MonitorKitCore
import SwiftUI

// Each control edits the bound `MonitorState` through `normalizing`, so Core's
// `normalized()` is the only place a value is clamped. Pass the surface's
// `MonitorStatus` to show why a tool that is on is not drawn.

/// The two zebra sets: lower limit or band, level in IRE, opacity, signal stage.
public struct ZebraControls: View {
  @Binding var state: MonitorState
  let status: MonitorStatus?

  public init(state: Binding<MonitorState>, status: MonitorStatus? = nil) {
    _state = state
    self.status = status
  }

  /// Zebra set `i`, safe on a state with fewer sets (a host's own or an older
  /// model): reads a default set, and a write pads the list first.
  static func zebra(_ state: Binding<MonitorState>, _ i: Int) -> Binding<ZebraSet> {
    Binding(
      get: { i < state.wrappedValue.zebras.count ? state.wrappedValue.zebras[i] : ZebraSet() },
      set: { z in
        var s = state.wrappedValue
        while s.zebras.count <= i { s.zebras.append(ZebraSet()) }
        s.zebras[i] = z
        state.wrappedValue = s
      })
  }

  public var body: some View {
    MonitorControlSection("Zebra") {
      ForEach(0..<MonitorState.maximumZebraSets, id: \.self) { i in
        let zebra = Self.zebra($state.normalizing, i)
        let current = zebra.wrappedValue
        Toggle("Zebra \(i + 1)", isOn: zebra.enabled)
        if current.enabled {
          Picker("Mode", selection: zebra.mode) {
            ForEach(ZebraMode.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          // 0…109 IRE spans both devices' menus (the FX3 runs to 109, super-white).
          ValueSlider("Level", value: zebra.level, in: 0...109, step: 1, format: MonitorFormat.ire)
          if current.mode == .band {
            ValueSlider("Range", value: zebra.range, in: 1...10, step: 1) { String(format: "±%.0f IRE", $0) }
          }
          ValueSlider("Opacity", value: zebra.opacity, in: 0...1, step: 0.05, format: MonitorFormat.percent)
          StagePicker(selection: zebra.stage)
          UnavailableNote(reason: status?.reason(for: i == 0 ? .zebra1 : .zebra2))
        }
      }
    }
  }
}

/// False-colour mode, its stage and offset, and the legend of the active table.
public struct FalseColorControls: View {
  @Binding var state: MonitorState
  let status: MonitorStatus?
  let signal: SignalDescription?
  let layout: PixelLayout?
  let modes: [FalseColorMode]?

  /// `signal` picks the ARRI table the legend shows (LogC3 or LogC4), and with
  /// `layout` its range by the pass's rule
  /// (`FalseColorTable.usesFullRangeARRI(signal:layout:)`: a float container is
  /// full range). `modes` narrows the modes offered (`.off` always is, and the
  /// current mode stays listed); nil offers all.
  public init(
    state: Binding<MonitorState>, status: MonitorStatus? = nil, signal: SignalDescription? = nil,
    layout: PixelLayout? = nil, modes: [FalseColorMode]? = nil
  ) {
    _state = state
    self.status = status
    self.signal = signal
    self.layout = layout
    self.modes = modes
  }

  /// The legend shown: the bands the pass classifies with for this signal and layout.
  var legend: FalseColorLegend? { FalseColorLegend(settings: state.falseColor, signal: signal, layout: layout) }

  /// The mode picker: an allowed mode is written, others are ignored.
  var modeSelection: Binding<FalseColorMode> {
    let mode = $state.normalizing.falseColor.mode
    let modes = modes
    return Binding(
      get: { mode.wrappedValue },
      set: { m in if m == .off || (modes?.contains(m) ?? true) { mode.wrappedValue = m } })
  }

  public var body: some View {
    let fc = $state.normalizing.falseColor
    MonitorControlSection("False colour") {
      Picker("Mode", selection: modeSelection) {
        ForEach(MonitorTileTool.falseColorChoices(allowed: modes, current: state.falseColor.mode), id: \.self) { m in
          Text(m.title).tag(m).disabled(!(m == .off || (modes?.contains(m) ?? true)))
        }
      }
      let mode = state.falseColor.mode
      if mode == .sixBand || mode == .custom {
        StagePicker(selection: fc.stage)
      }
      if mode == .custom {
        Picker("Unit", selection: fc.customUnit) {
          ForEach(FalseColorUnit.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
      }
      if mode == .elZone || (mode == .custom && state.falseColor.customUnit == .stops) {
        ValueSlider("Offset", value: fc.referenceOffsetStops, in: -6...6, step: 0.1, format: MonitorFormat.stops)
      }
      UnavailableNote(reason: status?.reason(for: .falseColor))
      if let legend {
        FalseColorLegendView(legend: legend)
      }
    }
  }
}

/// Focus peaking: style, colour, level and the stage the edges are found in.
public struct PeakingControls: View {
  @Binding var state: MonitorState
  let status: MonitorStatus?

  public init(state: Binding<MonitorState>, status: MonitorStatus? = nil) {
    _state = state
    self.status = status
  }

  /// Low, Mid and High, as both devices name the levels.
  static let levels: [(String, Double)] = [("Low", 0.25), ("Mid", 0.5), ("High", 0.75)]

  public var body: some View {
    let focus = $state.normalizing.focus
    MonitorControlSection("Peaking") {
      Toggle("Focus peaking", isOn: focus.enabled)
      if state.focus.enabled {
        Picker("Style", selection: focus.style) {
          ForEach(PeakingStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if state.focus.style == .coloredEdges {
          Picker("Colour", selection: focus.color) {
            ForEach(PeakingColor.allCases, id: \.self) { c in
              Label { Text(c.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(c.rgb.color) }.tag(c)
            }
          }
        }
        Picker("Level", selection: focus.sensitivity) {
          ForEach(Self.levels, id: \.1) { Text($0.0).tag($0.1) }
          if !Self.levels.contains(where: { $0.1 == state.focus.sensitivity }) {
            Text("Custom").tag(state.focus.sensitivity)
          }
        }
        .pickerStyle(.segmented)
        ValueSlider("Sensitivity", value: focus.sensitivity, in: 0...1, step: 0.01, format: MonitorFormat.percent)
        ValueSlider("Noise rejection", value: focus.noiseRejection, in: 0...0.2, step: 0.005, format: MonitorFormat.percent)
        ValueSlider("Opacity", value: focus.opacity, in: 0...1, step: 0.05, format: MonitorFormat.percent)
        StagePicker(selection: focus.stage)
        UnavailableNote(reason: status?.reason(for: .focusPeaking))
      }
    }
  }
}

/// Frame guides, safe areas, grids and their look.
public struct GuideControls: View {
  @Binding var state: MonitorState
  let status: MonitorStatus?

  public init(state: Binding<MonitorState>, status: MonitorStatus? = nil) {
    _state = state
    self.status = status
  }

  /// The safe areas the menu offers (FX3: 80 and 90; broadcast action and title safe: 93 and 90).
  static let safeAreas: [Double] = [80, 90, 93, 95]
  /// What Core keeps (`MonitorState.normalized()`).
  static let aspectRange = 0.1...10.0
  static let safeAreaRange = 10.0...100.0

  @State private var customSafeArea = 85.0

  /// The ratios the frame picker lists: none, the standard ones, and the
  /// current one when it is custom, so a host's or a saved look's ratio shows.
  static func aspectChoices(current: Double) -> [Double] {
    var choices = [0] + FrameGuide.standardAspects
    if !choices.contains(current) { choices.append(current) }
    return choices
  }

  /// The safe areas listed as toggles: the standard ones and any custom one in use.
  static func safeAreaChoices(_ guides: GuideSettings) -> [Double] {
    var choices = safeAreas
    for p in guides.safeAreas where !choices.contains(p) { choices.append(p) }
    return choices.sorted()
  }

  /// A typed ratio: written when Core would keep it, else ignored.
  static func customAspectBinding(_ guides: Binding<GuideSettings>) -> Binding<Double> {
    let aspect = aspectBinding(guides)
    return Binding(
      get: { aspect.wrappedValue == 0 ? 16.0 / 9 : aspect.wrappedValue },
      set: { a in if aspectRange.contains(a) { aspect.wrappedValue = a } })
  }

  /// Adds a custom safe area when Core would keep it (in range, at most four).
  static func addSafeArea(_ percent: Double, to guides: Binding<GuideSettings>) {
    guard safeAreaRange.contains(percent), guides.wrappedValue.safeAreas.count < 4 else { return }
    safeAreaBinding(guides, percent).wrappedValue = true
  }

  /// The first frame guide's aspect, or 0 for none.
  static func aspectBinding(_ guides: Binding<GuideSettings>) -> Binding<Double> {
    Binding(
      get: { guides.wrappedValue.frameGuides.first?.aspect ?? 0 },
      set: { a in
        var g = guides.wrappedValue
        if a == 0 {
          if !g.frameGuides.isEmpty { g.frameGuides.removeFirst() }
        } else if g.frameGuides.isEmpty {
          g.frameGuides = [FrameGuide(aspect: a)]
        } else {
          g.frameGuides[0].aspect = a
        }
        guides.wrappedValue = g
      })
  }

  /// A setting of the first frame guide. Safe while the guide is removed: SwiftUI
  /// may still read a binding of a control that is leaving.
  static func firstGuide<T>(_ guides: Binding<GuideSettings>, _ key: WritableKeyPath<FrameGuide, T>, _ fallback: T)
    -> Binding<T>
  {
    Binding(
      get: { guides.wrappedValue.frameGuides.first?[keyPath: key] ?? fallback },
      set: { v in
        guard !guides.wrappedValue.frameGuides.isEmpty else { return }
        var g = guides.wrappedValue
        g.frameGuides[0][keyPath: key] = v
        guides.wrappedValue = g
      })
  }

  /// Whether `percent` is one of the safe areas shown.
  static func safeAreaBinding(_ guides: Binding<GuideSettings>, _ percent: Double) -> Binding<Bool> {
    Binding(
      get: { guides.wrappedValue.safeAreas.contains(percent) },
      set: { on in
        var g = guides.wrappedValue
        g.safeAreas.removeAll { $0 == percent }
        if on { g.safeAreas.append(percent) }
        g.safeAreas.sort()
        guides.wrappedValue = g
      })
  }

  public var body: some View {
    let guides = $state.normalizing.guides
    let g = state.guides
    MonitorControlSection("Guides") {
      Toggle("Guides", isOn: guides.enabled)
      if g.enabled {
        let aspect = g.frameGuides.first?.aspect ?? 0
        Picker("Frame", selection: Self.aspectBinding(guides)) {
          ForEach(Self.aspectChoices(current: aspect), id: \.self) { a in
            Text(a == 0 ? "None" : MonitorFormat.aspect(a) + (FrameGuide.standardAspects.contains(a) ? "" : " (custom)"))
              .tag(a)
          }
        }
        LabeledContent("Custom ratio") {
          TextField(
            "Ratio", value: Self.customAspectBinding(guides), format: .number.precision(.fractionLength(0...3))
          )
          .multilineTextAlignment(.trailing)
          .frame(maxWidth: 70)
          .accessibilityLabel("Custom frame ratio, width over height")
          Text(":1").foregroundStyle(.secondary)
        }
        if !g.frameGuides.isEmpty {
          Picker("Style", selection: Self.firstGuide(guides, \.style, .lines)) {
            ForEach(FrameGuideStyle.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          if g.frameGuides[0].style != .lines {
            ValueSlider(
              "Matte", value: Self.firstGuide(guides, \.matteOpacity, 0.6), in: 0...1, step: 0.05,
              format: MonitorFormat.percent)
          }
          Toggle("Grids follow the frame", isOn: guides.followsFrameGuide)
        }
        LabeledContent("Safe area") {
          HStack {
            ForEach(Self.safeAreaChoices(g), id: \.self) { p in
              Toggle("\(MonitorFormat.number(p, digits: 1))%", isOn: Self.safeAreaBinding(guides, p)).toggleStyle(.button)
                .accessibilityLabel("Safe area \(MonitorFormat.number(p, digits: 1)) percent")
            }
          }
        }
        LabeledContent("Custom safe area") {
          TextField("Percent", value: $customSafeArea, format: .number.precision(.fractionLength(0...1)))
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 60)
            .accessibilityLabel("Custom safe area percent")
          Button("Add") { Self.addSafeArea(customSafeArea, to: guides) }
            .disabled(!Self.safeAreaRange.contains(customSafeArea) || g.safeAreas.count >= 4 || g.safeAreas.contains(customSafeArea))
        }
        Toggle("Thirds", isOn: guides.thirds)
        Toggle("Square grid", isOn: guides.squareGrid)
        if g.squareGrid {
          Stepper("Rows: \(g.squareGridRows)", value: guides.squareGridRows, in: 2...16)
        }
        Toggle("Diagonals", isOn: guides.diagonals)
        Toggle("Centre cross", isOn: guides.centerCross)
        Toggle("Centre dot", isOn: guides.centerDot)
        ColorPicker("Colour", selection: colorBinding(guides.color), supportsOpacity: false)
        ValueSlider("Opacity", value: guides.opacity, in: 0...1, step: 0.05, format: MonitorFormat.percent)
        ValueSlider("Outline", value: guides.contrast, in: 0...1, step: 0.05, format: MonitorFormat.percent)
        ValueSlider("Line width", value: guides.lineWidth, in: 0.5...4, step: 0.5, format: MonitorFormat.points)
        UnavailableNote(reason: status?.reason(for: .guides))
      }
    }
  }
}

/// De-squeeze, flip and magnification.
public struct GeometryControls: View {
  @Binding var state: MonitorState
  let status: MonitorStatus?

  public init(state: Binding<MonitorState>, status: MonitorStatus? = nil) {
    _state = state
    self.status = status
  }

  /// What Core keeps (`MonitorState.normalized()`).
  static let desqueezeRange = 1.0...4.0

  /// The factors the picker lists: the standard ones and the current one when custom.
  static func desqueezeChoices(current: Double) -> [Double] {
    var choices = ViewGeometry.standardDesqueezeFactors
    if !choices.contains(current) { choices.append(current) }
    return choices
  }

  /// A typed factor: written when Core would keep it, else ignored.
  static func customDesqueezeBinding(_ geometry: Binding<ViewGeometry>) -> Binding<Double> {
    Binding(
      get: { geometry.wrappedValue.desqueeze },
      set: { f in if desqueezeRange.contains(f) { geometry.wrappedValue.desqueeze = f } })
  }

  public var body: some View {
    let geometry = $state.normalizing.geometry
    let m = state.geometry.magnification
    MonitorControlSection("Geometry") {
      Picker("De-squeeze", selection: geometry.desqueeze) {
        ForEach(Self.desqueezeChoices(current: state.geometry.desqueeze), id: \.self) { f in
          Text(
            MonitorFormat.desqueeze(f) + (ViewGeometry.standardDesqueezeFactors.contains(f) ? "" : " (custom)")
          ).tag(f)
        }
      }
      LabeledContent("Custom de-squeeze") {
        TextField(
          "Factor", value: Self.customDesqueezeBinding(geometry), format: .number.precision(.fractionLength(0...3))
        )
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 70)
        .accessibilityLabel("Custom de-squeeze factor, 1 to 4")
        Text("×").foregroundStyle(.secondary)
      }
      Picker("Flip", selection: geometry.flip) {
        ForEach(FlipMode.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      ValueSlider("Zoom", value: geometry.magnification.zoom, in: 1...16, step: 0.1, format: MonitorFormat.zoom)
        .disabled(m.pixelExact)
      Toggle("Pixel exact (1:1)", isOn: geometry.magnification.pixelExact)
      Toggle("Navigator", isOn: geometry.magnification.showsNavigator)
      HStack {
        ForEach([2.0, 4.0, 8.0], id: \.self) { z in
          Button("\(Int(z))×") {
            state.geometry.magnification.zoom = z
            state.geometry.magnification.pixelExact = false
            state = state.normalized()
          }
        }
        Button("Fit") { state.geometry.magnification = MonitorMagnifier.reset(m) }
      }
      UnavailableNote(reason: status?.reason(for: .magnification))
    }
  }
}

/// Brightness, contrast, saturation, monochrome and the white-point trim. They
/// change this surface's picture only, never output, tools or legends.
public struct DisplayAdjustmentControls: View {
  @Binding var state: MonitorState

  public init(state: Binding<MonitorState>) { _state = state }

  public var body: some View {
    let display = $state.normalizing.display
    MonitorControlSection("Display") {
      ValueSlider("Brightness", value: display.brightness, in: -1...1, step: 0.01, format: MonitorFormat.signedPercent)
      ValueSlider("Contrast", value: display.contrast, in: 0...2, step: 0.01, format: MonitorFormat.gain)
      ValueSlider("Saturation", value: display.saturation, in: 0...2, step: 0.01, format: MonitorFormat.gain)
      Picker("Monochrome", selection: display.monochrome) {
        ForEach(MonochromeMode.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      ValueSlider(
        "Temperature", value: Self.temperatureBinding(display.temperature, step: Self.temperatureStep),
        in: WhitePointTrim.temperatureRange, step: Self.temperatureStep, format: MonitorFormat.kelvin)
      ValueSlider("Tint", value: display.tint, in: WhitePointTrim.tintRange, step: 0.001, format: MonitorFormat.duv)
      Button("Reset") { state.display = DisplayAdjustments() }
        .disabled(state.display.isIdentity)
    }
  }

  static let temperatureStep = 50.0

  /// The slider's grid misses D65 (6504 K): a value within half a step of it is
  /// stored as D65 exactly, so dragging back to the middle removes the trim.
  static func temperatureBinding(_ temperature: Binding<Double>, step: Double) -> Binding<Double> {
    Binding(
      get: { temperature.wrappedValue },
      set: { temperature.wrappedValue = WhitePointTrim.snappedToD65($0, within: step / 2) })
  }
}

/// Where the source's LUT applies and how it is sampled, and whether this surface
/// shows the monitor-only LUT. The host owns the LUT itself: rebuild the
/// `MonitorLUT` when `interpolation` changes and `MonitorSource.setLUT(_:routing:)` it.
public struct LUTRoutingControls: View {
  @Binding var state: MonitorState
  @Binding var routing: LUTRouting
  @Binding var interpolation: LUTInterpolation
  let lutName: String?

  public init(
    state: Binding<MonitorState>, routing: Binding<LUTRouting>, interpolation: Binding<LUTInterpolation>,
    lutName: String? = nil
  ) {
    _state = state
    _routing = routing
    _interpolation = interpolation
    self.lutName = lutName
  }

  public var body: some View {
    MonitorControlSection("LUT") {
      if let lutName {
        LabeledContent("LUT", value: lutName)
      }
      Picker("Apply to", selection: $routing) {
        ForEach(LUTRouting.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      Text(routing == .burnIn ? "Also changes the output feed." : "This monitor only; output is untouched.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Picker("Interpolation", selection: $interpolation) {
        ForEach(LUTInterpolation.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      Toggle("Show monitor LUT here", isOn: $state.normalizing.monitorLUT)
    }
  }
}

/// The display transform (log or HDR to SDR, HDR passthrough) and, when given,
/// the surface's output encoding.
public struct OutputColorControls: View {
  @Binding var state: MonitorState
  let outputColor: Binding<MonitorOutputColor>?
  let status: MonitorStatus?

  public init(
    state: Binding<MonitorState>, outputColor: Binding<MonitorOutputColor>? = nil, status: MonitorStatus? = nil
  ) {
    _state = state
    self.outputColor = outputColor
    self.status = status
  }

  /// The PQ mastering peaks the Video Assist's signal override offers.
  static let pqPeaks: [Double] = [300, 500, 800, 1000, 2000, 4000]

  static func encodingBinding(_ output: Binding<MonitorOutputColor>) -> Binding<OutputEncodingChoice> {
    Binding(
      get: { OutputEncodingChoice(output.wrappedValue.encoding) },
      set: {
        var o = output.wrappedValue
        o.encoding = $0.encoding
        output.wrappedValue = o.normalized()
      })
  }

  public var body: some View {
    let transform = $state.normalizing.displayTransform
    MonitorControlSection("Output colour") {
      Picker("Transform", selection: transform.mode) {
        ForEach(DisplayTransform.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      let mode = state.displayTransform.mode
      if mode == .hdrToSDR || mode == .hdrPassthrough {
        Picker("PQ mastering peak", selection: transform.pqSourcePeak) {
          ForEach(Self.pqPeaks, id: \.self) { Text(MonitorFormat.nits($0)).tag($0) }
          if !Self.pqPeaks.contains(state.displayTransform.pqSourcePeak) {
            Text(MonitorFormat.nits(state.displayTransform.pqSourcePeak)).tag(state.displayTransform.pqSourcePeak)
          }
        }
      }
      UnavailableNote(reason: status?.reason(for: .displayTransform))
      if let outputColor {
        Picker("Encoding", selection: Self.encodingBinding(outputColor)) {
          ForEach(OutputEncodingChoice.allCases) { Text($0.title).tag($0) }
        }
        if outputColor.wrappedValue.encoding != .signalNative {
          Picker("Primaries", selection: outputColor.primaries) {
            ForEach(ColorPrimaries.allCases, id: \.self) { Text($0.title).tag($0) }
          }
        }
        if outputColor.wrappedValue.encoding.isHDR || outputColor.wrappedValue.encoding == .signalNative {
          ValueSlider(
            "Graphics white", value: outputColor.referenceWhite, in: 100...400, step: 1, format: MonitorFormat.nits)
        }
      }
    }
  }
}

/// Per-channel clip indicators: channels, thresholds and colours.
public struct ClipIndicatorControls: View {
  @Binding var state: MonitorState
  let status: MonitorStatus?

  public init(state: Binding<MonitorState>, status: MonitorStatus? = nil) {
    _state = state
    self.status = status
  }

  public var body: some View {
    let clip = $state.normalizing.clipIndicators
    let c = state.clipIndicators
    MonitorControlSection("Clip") {
      Toggle("Clip indicators", isOn: clip.enabled)
      if c.enabled {
        StagePicker(selection: clip.stage)
        HStack {
          Toggle("R", isOn: clip.red).toggleStyle(.button).accessibilityLabel("Red channel")
          Toggle("G", isOn: clip.green).toggleStyle(.button).accessibilityLabel("Green channel")
          Toggle("B", isOn: clip.blue).toggleStyle(.button).accessibilityLabel("Blue channel")
          Toggle("Y", isOn: clip.luma).toggleStyle(.button).accessibilityLabel("Luma")
        }
        Toggle("Over", isOn: clip.showsOver)
        if c.showsOver {
          ValueSlider("At or above", value: clip.high, in: 90...109, step: 0.5) { String(format: "%.1f%%", $0) }
        }
        Toggle("Under", isOn: clip.showsUnder)
        if c.showsUnder {
          ValueSlider("At or below", value: clip.low, in: -7...10, step: 0.5) { String(format: "%.1f%%", $0) }
        }
        Picker("Colours", selection: clip.coloring) {
          ForEach(ClipIndicatorColoring.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if c.coloring == .uniform {
          ColorPicker("Over colour", selection: colorBinding(clip.overColor), supportsOpacity: false)
          ColorPicker("Under colour", selection: colorBinding(clip.underColor), supportsOpacity: false)
        }
        ValueSlider("Opacity", value: clip.opacity, in: 0...1, step: 0.05, format: MonitorFormat.percent)
        UnavailableNote(reason: status?.reason(for: .clipIndicators))
      }
    }
  }
}

/// One switch that hides every overlay; LUTs, display adjustments and geometry stay.
public struct CleanSwitch: View {
  @Binding var state: MonitorState

  public init(state: Binding<MonitorState>) { _state = state }

  public var body: some View {
    Toggle(isOn: $state.normalizing.clean) {
      Label("Clean", systemImage: state.clean ? "eye.slash" : "eye")
    }
    .toggleStyle(.button)
    .help("Hide every overlay. LUTs, display adjustments and geometry stay.")
    .accessibilityHint("Hides every overlay; LUTs, display adjustments and geometry stay.")
  }
}

/// The signal stage a tool measures.
struct StagePicker: View {
  @Binding var selection: SignalStage

  var body: some View {
    Picker("Signal", selection: $selection) {
      ForEach(SignalStage.allCases, id: \.self) { Text($0.title).tag($0) }
    }
    .pickerStyle(.segmented)
  }
}
