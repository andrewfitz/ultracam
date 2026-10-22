import MonitorToolsCore
import SwiftUI

public struct MonitorToolsToolbar: View {
  @Binding var configuration: MonitorConfiguration
  public var compact: Bool
  public var supportsSourceAnalysis: Bool
  @State private var tool: String?
  public init(
    configuration: Binding<MonitorConfiguration>, compact: Bool = false,
    supportsSourceAnalysis: Bool = true
  ) {
    _configuration = configuration
    self.compact = compact
    self.supportsSourceAnalysis = supportsSourceAnalysis
  }
  private let toolNames = ["Guides", "Zebra", "False Color", "Focus", "Scopes"]
  public var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        Toggle("Monitor tools", isOn: $configuration.toolsEnabled).toggleStyle(.switch).controlSize(
          .mini)
        ForEach(toolNames, id: \.self) { name in Button(name) { tool = name } }
      }
      HStack(spacing: 8) {
        Toggle("Tools", isOn: $configuration.toolsEnabled).toggleStyle(.switch).controlSize(.mini)
        Menu("Settings") { ForEach(toolNames, id: \.self) { name in Button(name) { tool = name } } }
          .menuStyle(.borderlessButton).fixedSize()
        Spacer(minLength: 0)
      }
    }
    .font(.caption)
    .popover(isPresented: Binding(get: { tool != nil }, set: { if !$0 { tool = nil } })) {
      settings(tool ?? "Guides").padding().frame(width: 280)
    }
  }
  @ViewBuilder private func settings(_ name: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(name).font(.headline)
      switch name {
      case "Guides":
        Toggle("Guides", isOn: $configuration.guides.enabled)
        Toggle("Thirds", isOn: $configuration.guides.thirds)
        Toggle("Center cross", isOn: $configuration.guides.centerCross)
        Toggle("Safe area", isOn: $configuration.guides.safeArea)
        slider("Opacity", value: $configuration.guides.opacity, range: 0...1)
        slider("Contrast", value: $configuration.guides.contrast, range: 0...1)
      case "Zebra":
        Toggle("Zebra", isOn: $configuration.zebra.enabled)
        Picker("Mode", selection: $configuration.zebra.mode) {
          Text("Above threshold").tag(MonitorZebraMode.aboveThreshold)
          Text("Band").tag(MonitorZebraMode.band)
        }
        slider("Threshold IRE", value: $configuration.zebra.thresholdIRE, range: 0...109)
        slider("Width IRE", value: $configuration.zebra.widthIRE, range: 0...30)
        slider("Opacity", value: $configuration.zebra.opacity, range: 0...1)
        if configuration.falseColor.mode != .off {
          Text("Zebra is bypassed while false color is selected.").font(.caption)
        }
      case "False Color":
        if !supportsSourceAnalysis {
          Text(
            "False Color unavailable for Program: matching source Log provenance across cuts is required."
          ).font(.caption)
        }
        Picker("Mode", selection: falseColorModeSelection) {
          Text("Off").tag(MonitorFalseColorMode.off)
          Text("Sony S-Log3").tag(MonitorFalseColorMode.sonySLog3).disabled(
            !isSonyFalseColorAvailable)
          Text("EL Zone").tag(MonitorFalseColorMode.elZone).disabled(!isELZoneAvailable)
          if configuration.falseColor.mode == .arri {
            Text("Unsupported saved mode").tag(MonitorFalseColorMode.arri).disabled(true)
          }
        }
        Text(falseColorAnalysisLabel).font(.caption)
        Picker(
          "Camera / Log",
          selection: sourceProfileSelection
        ) {
          if configuration.sourceProfileID != "" {
            Text("Unknown").tag("")
          }
          Text("Sony S-Gamut3.Cine / S-Log3").tag("sony-slog3-sgamut3cine")
          Text("Sony S-Gamut3 / S-Log3").tag("sony-slog3-sgamut3")
          if let source = unsupportedSavedSourceProfileID {
            Text("Unsupported saved input").tag(source).disabled(true)
          }
        }.disabled(!supportsSourceAnalysis)
        Picker("Input code range", selection: $configuration.sourceCodeRange) {
          Text("Format native / unspecified").tag(Optional<MonitorCodeRange>.none)
          Text("Legal range (64…940 at 10-bit)").tag(Optional(MonitorCodeRange.legal))
          Text("Full range (0…1023 at 10-bit)").tag(Optional(MonitorCodeRange.full))
        }.disabled(!supportsSourceAnalysis)
        Picker("Log transport mapping", selection: $configuration.sourceLogMapping) {
          Text("Declared native 10-bit codes").tag(MonitorSourceLogMapping.native10Bit)
          Text("Full codes rescaled to legal").tag(MonitorSourceLogMapping.fullRescaledToLegal10Bit)
        }.disabled(!supportsSourceAnalysis)
        Text(
          "Match the actual camera output. These declarations do not change the camera output."
        ).font(.caption).foregroundStyle(.secondary)
        if unsupportedSavedSourceProfileID != nil || configuration.falseColor.mode == .arri {
          Text("Select a Sony input to use current false-color modes.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if configuration.falseColor.mode == .elZone {
          Stepper(
            value: $configuration.falseColor.referenceOffsetStops, in: -10...10, step: 0.25
          ) {
            Text(
              "Monitor exposure offset: \(configuration.falseColor.referenceOffsetStops, specifier: "%+.2f") stops"
            )
          }.disabled(!isELZoneAvailable)
            .help("Adds stops to measured source exposure. Camera EI is independent.")
        }
        Text(
          configuration.falseColor.mode == .elZone
            ? isELZoneAvailable
              ? "Public-chart mapping · Sony M&C match not tested"
              : "EL Zone requires a supported Sony S-Log3 source."
            : isSonySource
              ? "Sony source IRE thresholds are independent of EI and do not guarantee sensor clipping."
              : "Choose a supported Sony S-Log3 source profile."
        ).font(.caption).foregroundStyle(.secondary)
      case "Focus":
        Toggle("Focus peaking", isOn: $configuration.focus.enabled).disabled(
          !supportsSourceAnalysis)
        Picker("Highlight", selection: $configuration.focus.color) {
          ForEach(MonitorPeakingColor.allCases, id: \.self) {
            Text($0.rawValue.capitalized).tag($0)
          }
        }
        slider("Sensitivity", value: $configuration.focus.sensitivity, range: 0...1)
        slider("Noise rejection", value: $configuration.focus.noiseRejection, range: 0...1)
        slider("Opacity", value: $configuration.focus.opacity, range: 0...1)
        Text(
          supportsSourceAnalysis
            ? "Focus: Source"
            : "Focus unavailable for Program: matching source resolution and provenance are required."
        ).font(.caption)
      default:
        Toggle("Scopes", isOn: $configuration.scopes.enabled)
        Picker("Scope", selection: $configuration.scopes.mode) {
          Text("RGB parade").tag(MonitorScopeMode.rgbParade)
          Text("Luma waveform").tag(MonitorScopeMode.lumaWaveform)
        }
        Picker("Signal", selection: $configuration.scopeStage) { stageOptions }
        Picker("Refresh", selection: $configuration.scopes.refreshHz) {
          ForEach([10, 15, 30], id: \.self) { Text("\($0) Hz").tag($0) }
        }
        slider("Trace gain", value: $configuration.scopes.gain, range: 0.25...4)
        Toggle("Graticule", isOn: $configuration.scopes.graticule)
      }
    }.controlSize(.small)
  }
  var falseColorAnalysisLabel: String {
    guard configuration.falseColor.mode != .off else { return "Analysis: Off" }
    guard supportsSourceAnalysis else {
      return "Analysis unavailable: Program Output has no paired source Log"
    }
    switch configuration.falseColor.mode {
    case .off: return "Analysis: Off"
    case .elZone: return "Analysis: Source stops · 18% gray = 0 before offset"
    case .sonySLog3: return "Analysis: Source IRE · Sony S-Log3"
    case .arri: return "Analysis: Unsupported saved mode"
    }
  }
  private var isSonySource: Bool {
    SonySLog3FalseColor.supports(sourceProfileID: configuration.sourceProfileID)
  }
  var unsupportedSavedSourceProfileID: String? {
    guard let source = configuration.sourceProfileID,
      !SonySLog3FalseColor.supports(sourceProfileID: source)
    else { return nil }
    return source
  }
  var isSonyFalseColorAvailable: Bool {
    supportsSourceAnalysis && isSonySource
  }
  var isELZoneAvailable: Bool {
    supportsSourceAnalysis && ELZoneProfile.supports(sourceProfileID: configuration.sourceProfileID)
  }
  var falseColorModeSelection: Binding<MonitorFalseColorMode> {
    Binding(
      get: { configuration.falseColor.mode },
      set: { mode in
        var next = configuration
        next.falseColor.mode = mode
        if mode == .sonySLog3,
          SonySLog3FalseColor.supports(sourceProfileID: next.sourceProfileID)
        {
          next.falseColor.profileID = SonySLog3FalseColor.profileID
          next.falseColor.specificationVersion = SonySLog3FalseColor.specificationVersion
        } else if mode == .elZone,
          ELZoneProfile.supports(sourceProfileID: next.sourceProfileID)
        {
          next.falseColor.profileID = ELZoneProfile.profileID
          next.falseColor.specificationVersion = ELZoneProfile.specificationVersion
        }
        configuration = next
      })
  }
  var sourceProfileSelection: Binding<String> {
    Binding(
      get: { configuration.sourceProfileID ?? "" },
      set: { value in
        var next = configuration
        next.sourceProfileID = value.isEmpty ? nil : value
        if SonySLog3FalseColor.supports(sourceProfileID: value) {
          if next.falseColor.mode == .elZone {
            next.falseColor.profileID = ELZoneProfile.profileID
            next.falseColor.specificationVersion = ELZoneProfile.specificationVersion
          } else {
            next.falseColor.profileID = SonySLog3FalseColor.profileID
            next.falseColor.specificationVersion = SonySLog3FalseColor.specificationVersion
          }
          if next.falseColor.mode == .arri { next.falseColor.mode = .sonySLog3 }
        } else if let profile = ARRIFalseColorProfile(rawValue: value) {
          next.falseColor.profileID = profile.rawValue
          next.falseColor.specificationVersion = ARRIFalseColorProfile.specificationVersion
          next.falseColor.exposureIndex = profile.exposureIndex
        } else {
          next.falseColor.profileID = nil
          next.falseColor.specificationVersion = nil
        }
        configuration = next
      })
  }
  private var stageOptions: some View {
    Group {
      Text("Source").tag(MonitorStage.source).disabled(!supportsSourceAnalysis)
      Text("Processed Output").tag(MonitorStage.processedOutput)
    }
  }
  private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>)
    -> some View
  {
    VStack(alignment: .leading) {
      Text(label)
      Slider(value: value, in: range).accessibilityLabel(label)
    }
  }
}

public struct MonitorGuideOverlay: View {
  public var settings: MonitorGuideSettings
  public init(settings: MonitorGuideSettings) { self.settings = settings }
  public var body: some View {
    GeometryReader { geometry in
      Path { path in
        let w = geometry.size.width
        let h = geometry.size.height
        if settings.thirds {
          for n in [1.0 / 3, 2.0 / 3] {
            path.move(to: CGPoint(x: w * n, y: 0))
            path.addLine(to: CGPoint(x: w * n, y: h))
            path.move(to: CGPoint(x: 0, y: h * n))
            path.addLine(to: CGPoint(x: w, y: h * n))
          }
        }
        if settings.centerCross {
          path.move(to: CGPoint(x: w / 2 - 12, y: h / 2))
          path.addLine(to: CGPoint(x: w / 2 + 12, y: h / 2))
          path.move(to: CGPoint(x: w / 2, y: h / 2 - 12))
          path.addLine(to: CGPoint(x: w / 2, y: h / 2 + 12))
        }
        if settings.safeArea {
          path.addRect(CGRect(x: w * 0.05, y: h * 0.05, width: w * 0.9, height: h * 0.9))
        }
      }.stroke(.white.opacity(settings.opacity), lineWidth: 1).shadow(
        color: .black.opacity(settings.contrast), radius: 1)
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
}
