import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import MonitorKitUI
import SwiftUI

// The monitor tool popovers' forms, each bound to one camera's preferences.
// Values stay inside MonitorKit's documented ranges (`MonitorState.normalized()`).

/// Guides: frame guides, safe areas, grids, center marks and their look.
struct UIGuideSettingsForm: View {
  @Binding var preferences: MonitorFeedPreferences
  let cameraID: String

  /// The safe areas offered: FX3's 80 and 90, broadcast title and action safe (90, 93), 95.
  static let safeAreas: [Double] = [80, 90, 93, 95]
  /// The frame guide ratios offered (0 is none): MonitorKit's standard ratios.
  static func aspects(current: Double) -> [Double] {
    var choices = [0] + FrameGuide.standardAspects
    if !choices.contains(current) { choices.append(current) }
    return choices
  }

  private var guides: Binding<GuideSettings> { $preferences.state.guides }

  var body: some View {
    let g = preferences.state.guides
    Section {
      Toggle("Guides", isOn: UIMonitorToolBindings.enabling($preferences, \.state.guides.enabled))
      Picker("Frame guide", selection: frameAspect) {
        ForEach(Self.aspects(current: g.frameGuides.first?.aspect ?? 0), id: \.self) { aspect in
          Text(aspect == 0 ? "None" : UIMonitorToolText.aspect(aspect)).tag(aspect)
        }
      }
      if !g.frameGuides.isEmpty {
        Picker("Frame style", selection: firstGuide(\.style, .lines)) {
          ForEach(FrameGuideStyle.allCases, id: \.self) { Text(UIMonitorToolText.frameGuideStyle($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        if g.frameGuides[0].style != .lines {
          UIMonitorSlider("Matte", percent: firstGuide(\.matteOpacity, 0.6))
        }
        Toggle("Grids follow the frame", isOn: guides.followsFrameGuide)
      }
      LabeledContent("Safe area") {
        HStack(spacing: 4) {
          ForEach(safeAreaChoices(g), id: \.self) { percent in
            Toggle(UIMonitorToolText.percent(percent), isOn: safeArea(percent)).toggleStyle(.button)
              .accessibilityLabel("Safe area \(UIMonitorToolText.percent(percent))")
          }
        }
      }
    } header: {
      Text("Frame")
    }
    Section {
      Toggle("Rule of thirds", isOn: guides.thirds)
      Toggle("Square grid", isOn: guides.squareGrid)
      if g.squareGrid {
        Stepper("Grid rows: \(g.squareGridRows)", value: guides.squareGridRows, in: 2...16)
      }
      Toggle("Diagonals", isOn: guides.diagonals)
      Toggle("Center cross", isOn: guides.centerCross)
      Toggle("Center dot", isOn: guides.centerDot)
    } header: {
      Text("Grids and center")
    }
    Section {
      ColorPicker("Color", selection: color, supportsOpacity: false)
      UIMonitorSlider("Opacity", percent: guides.opacity)
      UIMonitorSlider("Contrast", percent: guides.contrast)
      UIMonitorSlider("Line width", value: guides.lineWidth, in: 0.5...4, step: 0.5) { String(format: "%.1f pt", $0) }
      UIMonitorToolCaption("Contrast adds a dark edge so lines stay visible on bright areas. Guides are drawn on the monitor only; output and recordings are unchanged.")
      UIMonitorStatusNote(cameraID: cameraID, tools: [.guides])
    } header: {
      Text("Look")
    }
  }

  /// The first frame guide's ratio, or 0 for none.
  private var frameAspect: Binding<Double> {
    Binding(
      get: { preferences.state.guides.frameGuides.first?.aspect ?? 0 },
      set: { aspect in
        var g = preferences.state.guides
        if aspect == 0 {
          if !g.frameGuides.isEmpty { g.frameGuides.removeFirst() }
        } else if g.frameGuides.isEmpty {
          g.frameGuides = [FrameGuide(aspect: aspect)]
        } else {
          g.frameGuides[0].aspect = aspect
        }
        preferences.state.guides = g
      })
  }

  /// A setting of the first frame guide; safe while the guide is being removed.
  private func firstGuide<T>(_ key: WritableKeyPath<FrameGuide, T>, _ fallback: T) -> Binding<T> {
    Binding(
      get: { preferences.state.guides.frameGuides.first?[keyPath: key] ?? fallback },
      set: { value in
        guard !preferences.state.guides.frameGuides.isEmpty else { return }
        preferences.state.guides.frameGuides[0][keyPath: key] = value
      })
  }

  /// The standard safe areas and any other one in use (from a detached window or an old setting).
  private func safeAreaChoices(_ g: GuideSettings) -> [Double] {
    var choices = Self.safeAreas
    for percent in g.safeAreas where !choices.contains(percent) { choices.append(percent) }
    return choices.sorted()
  }

  private func safeArea(_ percent: Double) -> Binding<Bool> {
    Binding(
      get: { preferences.state.guides.safeAreas.contains(percent) },
      set: { on in
        var areas = preferences.state.guides.safeAreas.filter { $0 != percent }
        // MonitorKit draws at most four.
        if on && areas.count < 4 { areas.append(percent) }
        preferences.state.guides.safeAreas = areas.sorted()
      })
  }

  private var color: Binding<Color> {
    Binding(
      get: { preferences.state.guides.color.color },
      set: { preferences.state.guides.color = ColorRGB($0) })
  }
}

/// Zebra: two sets. Zebra 1 measures the picture shown; Zebra 2 picks its signal.
struct UIZebraSettingsForm: View {
  @Binding var preferences: MonitorFeedPreferences
  let cameraID: String
  let isProgram: Bool

  var body: some View {
    ForEach(0..<MonitorState.maximumZebraSets, id: \.self) { index in
      let zebra = UIMonitorToolBindings.zebra($preferences, index)
      Section {
        Toggle("Zebra \(index + 1)", isOn: UIMonitorToolBindings.zebraEnabled($preferences, index))
        Picker("Mode", selection: zebra.mode) {
          Text("Above threshold").tag(ZebraMode.lowerLimit)
          Text("Band").tag(ZebraMode.band)
        }
        UIMonitorSlider("Threshold", value: zebra.level, in: 0...109, step: 1) { "\(Int($0.rounded())) IRE" }
        // The band's full width; MonitorKit keeps its half-width (`range`).
        UIMonitorSlider("Width", value: Binding(get: { zebra.wrappedValue.range * 2 },
          set: { zebra.wrappedValue.range = $0 / 2 }), in: 0...30, step: 1) { "\(Int($0.rounded())) IRE" }
          .disabled(zebra.wrappedValue.mode != .band)
        UIMonitorSlider("Opacity", percent: zebra.opacity)
        if index == 0 {
          LabeledContent("Signal", value: UIMonitorToolText.stage(preferences.state.pictureStage))
            .help("Zebra 1 measures the picture shown. Change it with the picture's signal menu.")
        } else {
          Picker("Signal", selection: zebra.stage) {
            Text("Source").tag(SignalStage.source).disabled(isProgram)
            Text("Output (LUT)").tag(SignalStage.output)
            if zebra.wrappedValue.stage == .monitor { Text("Monitor").tag(SignalStage.monitor) }
          }
        }
      } header: {
        Text(index == 0 ? "Zebra 1 · picture" : "Zebra 2")
      }
    }
    Section {
      UIMonitorToolCaption("Threshold 0–109 IRE. In Band mode, Width sets the band around the threshold.")
      if preferences.toolsEnabled && preferences.falseColorDeclared {
        UIMonitorToolCaption("Zebra is bypassed while false color is on.")
      }
      UIMonitorStatusNote(cameraID: cameraID, tools: [.zebra1, .zebra2])
    }
  }
}

/// Focus peaking: style, color, sensitivity. Edges are always found on the source.
struct UIFocusSettingsForm: View {
  @Binding var preferences: MonitorFeedPreferences
  let cameraID: String

  var body: some View {
    let focus = $preferences.state.focus
    Section {
      Toggle("Focus peaking", isOn: UIMonitorToolBindings.enabling($preferences, \.state.focus.enabled))
      Picker("Style", selection: focus.style) {
        Text("Colored edges").tag(PeakingStyle.coloredEdges)
        Text("Peak").tag(PeakingStyle.peak)
      }
      .pickerStyle(.segmented)
      Picker("Highlight", selection: focus.color) {
        ForEach(PeakingColor.allCases, id: \.self) { color in
          Label { Text(color.rawValue.capitalized) } icon: {
            Image(systemName: "circle.fill").foregroundStyle(color.rgb.color)
          }
          .tag(color)
        }
      }
      .disabled(preferences.state.focus.style != .coloredEdges)
      UIMonitorSlider("Sensitivity", percent: focus.sensitivity)
      UIMonitorSlider("Noise rejection", percent: focus.noiseRejection)
      UIMonitorSlider("Opacity", percent: focus.opacity)
      UIMonitorToolCaption(preferences.state.focus.style == .peak
        ? "Peak brightens edges, like traditional sharpness peaking. Edges are found on the camera's source picture at full resolution."
        : "Edges are found on the camera's source picture at full resolution.")
      UIMonitorStatusNote(cameraID: cameraID, tools: [.focusPeaking])
    }
  }
}

/// Clip indicators: which channels, the levels and their colors.
struct UIClipIndicatorSettingsForm: View {
  @Binding var preferences: MonitorFeedPreferences
  let cameraID: String
  let isProgram: Bool

  var body: some View {
    let clip = $preferences.state.clipIndicators
    let c = preferences.state.clipIndicators
    Section {
      Toggle("Clip indicators", isOn: UIMonitorToolBindings.enabling($preferences, \.state.clipIndicators.enabled))
      Picker("Signal", selection: clip.stage) {
        Text("Source").tag(SignalStage.source).disabled(isProgram)
        Text("Output (LUT)").tag(SignalStage.output)
        if c.stage == .monitor { Text("Monitor").tag(SignalStage.monitor) }
      }
      LabeledContent("Channels") {
        HStack(spacing: 4) {
          Toggle("R", isOn: clip.red).toggleStyle(.button).accessibilityLabel("Red channel")
          Toggle("G", isOn: clip.green).toggleStyle(.button).accessibilityLabel("Green channel")
          Toggle("B", isOn: clip.blue).toggleStyle(.button).accessibilityLabel("Blue channel")
          Toggle("Y", isOn: clip.luma).toggleStyle(.button).accessibilityLabel("Luma")
        }
      }
    }
    Section {
      Toggle("Over", isOn: clip.showsOver)
      UIMonitorSlider("At or above", value: clip.high, in: 90...109, step: 0.5) { String(format: "%.1f%%", $0) }
        .disabled(!c.showsOver)
      Toggle("Under", isOn: clip.showsUnder)
      UIMonitorSlider("At or below", value: clip.low, in: -7...10, step: 0.5) { String(format: "%.1f%%", $0) }
        .disabled(!c.showsUnder)
    } header: {
      Text("Levels")
    }
    Section {
      Picker("Colors", selection: clip.coloring) {
        Text("Per channel").tag(ClipIndicatorColoring.perChannel)
        Text("Uniform").tag(ClipIndicatorColoring.uniform)
      }
      .pickerStyle(.segmented)
      if c.coloring == .uniform {
        ColorPicker("Over color", selection: color(\.overColor), supportsOpacity: false)
        ColorPicker("Under color", selection: color(\.underColor), supportsOpacity: false)
      }
      UIMonitorSlider("Opacity", percent: clip.opacity)
      UIMonitorToolCaption(c.coloring == .perChannel
        ? "Clipped channels show in their own colors and mix: all three clipped show white. Under-range shows the same mix at half level."
        : "Any clipped channel shows in the over or under color.")
      UIMonitorStatusNote(cameraID: cameraID, tools: [.clipIndicators])
    } header: {
      Text("Look")
    }
  }

  private func color(_ key: WritableKeyPath<ClipIndicatorSettings, ColorRGB>) -> Binding<Color> {
    Binding(
      get: { preferences.state.clipIndicators[keyPath: key].color },
      set: { preferences.state.clipIndicators[keyPath: key] = ColorRGB($0) })
  }
}

/// Scopes: one per camera, under the picture.
struct UIScopeSettingsForm: View {
  @Binding var preferences: MonitorFeedPreferences
  let isProgram: Bool

  var body: some View {
    let settings = $preferences.scopes.settings
    Section {
      Toggle("Scope", isOn: UIMonitorToolBindings.enabling($preferences, \.scopes.enabled))
      Picker("Type", selection: settings.waveformMode) {
        Text("RGB parade").tag(WaveformMode.rgbParade)
        Text("Luma waveform").tag(WaveformMode.luma)
        if preferences.scopes.settings.waveformMode != .rgbParade && preferences.scopes.settings.waveformMode != .luma {
          Text(preferences.scopes.title).tag(preferences.scopes.settings.waveformMode).disabled(true)
        }
      }
      Picker("Signal", selection: settings.stage) {
        Text("Source").tag(SignalStage.source).disabled(isProgram)
        Text("Output (LUT)").tag(SignalStage.output)
        if preferences.scopes.settings.stage == .monitor {
          Text("Monitor").tag(SignalStage.monitor)
        }
      }
      Picker("Refresh", selection: $preferences.scopes.refreshHz) {
        ForEach(MonitorScopePreferences.refreshRates, id: \.self) { Text("\($0) Hz").tag($0) }
      }
      UIMonitorSlider("Trace gain", value: settings.display.gain, in: 0.25...4) { String(format: "%.2f×", $0) }
      Toggle("Graticule", isOn: settings.display.showsGraticule)
      UIMonitorToolCaption("One scope per camera. Every pixel, \(preferences.scopes.ireScale.rangeText) IRE.")
    }
  }
}
