import MonitorKit
import MonitorKitCore
import MonitorKitUI
import SwiftUI

/// Which false-color modes a camera's declared signal can show, as
/// `MonitorFeedPreferences.falseColorDeclared` decides: a log mode needs a
/// declared camera profile it reads; six band and custom need none.
enum UIFalseColorChoices {
  /// The camera log profiles a camera can be declared as.
  static let profiles: [(id: String, title: String)] = [
    ("sony-slog3-sgamut3cine", "Sony S-Gamut3.Cine / S-Log3"),
    ("sony-slog3-sgamut3", "Sony S-Gamut3 / S-Log3"),
    (ARRIFalseColorProfile.logC3EI800.rawValue, ARRIFalseColorProfile.logC3EI800.displayName),
    (ARRIFalseColorProfile.alexa35LogC4EI800.rawValue, ARRIFalseColorProfile.alexa35LogC4EI800.displayName),
  ]

  /// The modes, in menu order.
  static let modes: [FalseColorMode] = [.off, .sonySLog3, .arriStyleSLog3, .arriLogC, .sixBand, .custom]

  /// `MonitorFeedPreferences.falseColorModeIsAvailable`: no log mode on Program.
  static func isAvailable(_ mode: FalseColorMode, profile: String?, isProgram: Bool = false) -> Bool {
    MonitorFeedPreferences.falseColorModeIsAvailable(mode, profile: profile, isProgram: isProgram)
  }

  /// The mode a false-color toggle turns on for `profile`
  /// (`MonitorFeedPreferences.suggestedFalseColorMode`).
  static func suggestedMode(profile: String?, isProgram: Bool = false) -> FalseColorMode {
    MonitorFeedPreferences.suggestedFalseColorMode(profile: profile, isProgram: isProgram)
  }

  /// A new custom band after `bands`: 10 IRE or 1 stop wide, the next color.
  static func nextBand(after bands: [FalseColorBand], unit: FalseColorUnit) -> FalseColorBand {
    let palette = [ColorRGB(r: 0.45, g: 0.2, b: 0.75), ColorRGB(r: 0.1, g: 0.4, b: 1), ColorRGB(r: 0.2, g: 0.75, b: 0.3),
      ColorRGB(r: 1, g: 0.55, b: 0.75), ColorRGB(r: 1, g: 0.85, b: 0.1), ColorRGB(r: 1, g: 0.15, b: 0.1)]
    let width = unit == .ire ? 10.0 : 1.0
    let start = bands.map(\.upper).filter(\.isFinite).max() ?? (unit == .ire ? 0 : -1)
    return FalseColorBand(lower: start, upper: start + width, color: palette[bands.count % palette.count])
  }
}

/// How the camera's signal is read: its log profile, code range and transport.
/// A declaration, not a camera setting: it changes how this monitor reads the
/// picture (false color, display assist), never the camera's output.
struct UISignalDeclarationFields: View {
  @Binding var preferences: MonitorFeedPreferences
  let isProgram: Bool

  var body: some View {
    let profile = preferences.signal.logProfileID
    Picker("Camera log", selection: sourceProfile) {
      Text("Not declared").tag("")
      ForEach(UIFalseColorChoices.profiles, id: \.id) { Text($0.title).tag($0.id) }
      if let profile, !UIFalseColorChoices.profiles.contains(where: { $0.id == profile }) {
        Text("Unsupported saved profile").tag(profile).disabled(true)
      }
    }
    .uiToolRow("Camera log")
    .disabled(isProgram)
    Picker("Input code range", selection: $preferences.signal.range) {
      Text("Format native").tag(Optional<CodeRange>.none)
      Text("Legal (64…940 at 10-bit)").tag(Optional(CodeRange.legal))
      Text("Full (0…1023 at 10-bit)").tag(Optional(CodeRange.full))
    }
    .uiToolRow("Input code range")
    .disabled(isProgram)
    Picker("Log transport", selection: $preferences.signal.transport) {
      Text("Native 10-bit codes").tag(LogTransport.native)
      Text("Full codes rescaled to legal").tag(LogTransport.fullRescaledToLegal)
    }
    .uiToolRow("Log transport")
    .disabled(profile == nil || isProgram)
    UIMonitorToolCaption(isProgram
      ? "Program is not a camera signal, so it has no camera log to declare."
      : "Match the camera's actual output. These settings don't change the camera output.")
  }

  /// Declaring another camera log keeps false color on: a log mode the new
  /// profile can't show switches to the one it can.
  private var sourceProfile: Binding<String> {
    Binding(
      get: { preferences.signal.logProfileID ?? "" },
      set: { value in preferences = Self.declaring(value.isEmpty ? nil : value, in: preferences) })
  }

  /// `preferences` with `profile` declared
  /// (`MonitorFeedPreferences.declaringCameraLog`, which scripts/test.sh covers).
  static func declaring(_ profile: String?, in preferences: MonitorFeedPreferences) -> MonitorFeedPreferences {
    preferences.declaringCameraLog(profile)
  }
}

/// False color: every MonitorKit mode the camera's declared signal can show,
/// the declaration itself, and the legend of the active table.
struct UIFalseColorSettingsForm: View {
  @Binding var preferences: MonitorFeedPreferences
  let cameraID: String
  let isProgram: Bool

  var body: some View {
    let profile = preferences.signal.logProfileID
    let mode = preferences.state.falseColor.mode
    let fc = $preferences.state.falseColor
    UIToolColumns {
      UIToolGroup("Mode") {
        Picker("Mode", selection: UIMonitorToolBindings.falseColorMode($preferences)) {
          ForEach(UIFalseColorChoices.modes, id: \.self) { choice in
            Text(UIMonitorToolText.falseColor(choice)).tag(choice)
              .disabled(!UIFalseColorChoices.isAvailable(choice, profile: profile, isProgram: isProgram))
          }
        }
        .fixedSize()
        .uiToolRow("Mode")
        if mode == .sixBand || mode == .custom {
          Picker("Signal", selection: fc.stage) {
            Text("Source").tag(SignalStage.source)
            Text("Output (LUT)").tag(SignalStage.output)
            if preferences.state.falseColor.stage == .monitor { Text("Monitor").tag(SignalStage.monitor) }
          }
          .fixedSize()
          .uiToolRow("Signal")
        }
        if mode == .custom {
          Picker("Unit", selection: fc.customUnit) {
            Text("IRE").tag(FalseColorUnit.ire)
            Text("Stops").tag(FalseColorUnit.stops)
          }
          .pickerStyle(.segmented)
          .fixedSize()
          .uiToolRow("Unit")
        }
        if mode == .custom && preferences.state.falseColor.customUnit == .stops {
          Stepper(value: fc.referenceOffsetStops, in: -6...6, step: 0.25) {
            Text("Exposure offset \(preferences.state.falseColor.referenceOffsetStops, specifier: "%+.2f") stops")
              .font(.callout)
          }
          .help("Adds stops to measured source exposure. Camera EI is independent.")
          .uiToolInline()
        }
        UIMonitorToolCaption(isProgram && mode.needsLogSource
          ? "Program is not a camera signal, so log false color is off. Six band and custom bands work on Program."
          : Self.caption(mode, profile: profile))
        UIMonitorStatusNote(cameraID: cameraID, tools: [.falseColor])
      }
      UIToolGroup("Camera signal") {
        UISignalDeclarationFields(preferences: $preferences, isProgram: isProgram)
      }
    } trailing: {
      if mode == .custom {
        UIFalseColorBandEditor(settings: fc)
      }
      UIFalseColorLegendSection(cameraID: cameraID, settings: preferences.state.falseColor,
        declaration: preferences.signal)
    }
  }

  static func caption(_ mode: FalseColorMode, profile: String?) -> String {
    let available = UIFalseColorChoices.isAvailable(mode, profile: profile)
    switch mode {
    case .off:
      return "Choose a mode. Log modes need the camera log declared below; six band and custom bands work on any picture."
    case .sonySLog3:
      return available
        ? "Sony source IRE thresholds are independent of EI and don't guarantee sensor clipping."
        : "Declare the Sony S-Log3 profile that matches the camera."
    case .arriStyleSLog3:
      return available
        ? "ARRI LogC3 EI 800 reference bands, from S-Log3 scene light. An adaptation, not ARRI's own table."
        : "ARRI-style bands need a Sony S-Gamut3 or S-Gamut3.Cine / S-Log3 source."
    case .arriLogC:
      return available
        ? "ARRI's published 10-bit code-value table for EI 800, on the declared LogC source."
        : "Declare the ARRI LogC3 or LogC4 profile that matches the camera."
    case .sixBand:
      return "Six bands on the chosen signal's display IRE. No log source needed."
    case .custom:
      return "Your bands: lower edge included, upper edge excluded. Other levels show in gray."
    }
  }
}

/// The custom bands: range and color of each, at most sixteen.
private struct UIFalseColorBandEditor: View {
  @Binding var settings: FalseColorSettings

  var body: some View {
    let unit = settings.customUnit == .ire ? "IRE" : "stops"
    UIToolGroup("Bands") {
      ForEach(Array(settings.customBands.indices), id: \.self) { index in
        HStack(spacing: 6) {
          ColorPicker("Band \(index + 1) color", selection: color(index), supportsOpacity: false).labelsHidden()
          TextField("From", value: edge(index, \.lower), format: .number.precision(.fractionLength(0...2)))
            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 56)
            .accessibilityLabel("Band \(index + 1) from, \(unit)")
          Text("to").foregroundStyle(.secondary)
          TextField("To", value: edge(index, \.upper), format: .number.precision(.fractionLength(0...2)))
            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 56)
            .accessibilityLabel("Band \(index + 1) to, \(unit)")
          Text(unit).font(.uiMeta).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button {
            if index < settings.customBands.count { settings.customBands.remove(at: index) }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .help("Remove band \(index + 1)")
          .accessibilityLabel("Remove band \(index + 1)")
        }
      }
      Button("Add Band") {
        settings.customBands.append(UIFalseColorChoices.nextBand(after: settings.customBands, unit: settings.customUnit))
      }
      .disabled(settings.customBands.count >= FalseColorSettings.maximumCustomBands)
      if settings.customBands.isEmpty {
        UIMonitorToolCaption("No bands yet: false color shows nothing until you add one.")
      }
    }
  }

  /// Safe while a band is being removed: SwiftUI may still read a leaving row.
  private func edge(_ index: Int, _ key: WritableKeyPath<FalseColorBand, Double>) -> Binding<Double> {
    Binding(
      get: { index < settings.customBands.count ? settings.customBands[index][keyPath: key] : 0 },
      set: { value in
        guard index < settings.customBands.count, !value.isNaN else { return }
        settings.customBands[index][keyPath: key] = value
      })
  }

  private func color(_ index: Int) -> Binding<Color> {
    Binding(
      get: { index < settings.customBands.count ? settings.customBands[index].color.color : .gray },
      set: { value in
        guard index < settings.customBands.count else { return }
        settings.customBands[index].color = ColorRGB(value)
      })
  }
}

/// MonitorKit's legend of the active table, for the camera's signal: the picture
/// on screen when one is open, with this camera's declaration applied.
struct UIFalseColorLegendSection: View {
  let cameraID: String
  let settings: FalseColorSettings
  let declaration: MonitorSignalDeclaration

  var body: some View {
    if let presenter = UIMonitorBridge.presenter(for: cameraID) {
      Observed(presenter: presenter, settings: settings, declaration: declaration)
    } else {
      Self.legend(settings: settings, signal: declaration.applied(to: SignalDescription()), unavailable: nil)
    }
  }

  @ViewBuilder static func legend(settings: FalseColorSettings, signal: SignalDescription,
    unavailable: MonitorUnavailableReason?) -> some View {
    if let legend = FalseColorLegend(settings: settings, signal: signal) {
      UIToolGroup("Legend") {
        UIFalseColorLegendGrid(legend: legend, unavailable: unavailable)
      } accessory: {
        Text(legend.unit.symbol).font(.uiMeta).foregroundStyle(.secondary)
      }
    } else {
      // No table to show: off, an ARRI table without a LogC signal, or no custom bands.
      UIToolGroup("Legend") {
        UIMonitorToolCaption(settings.mode == .off
          ? "Choose a mode to see its bands here."
          : "No bands to show for this mode and signal.")
      }
    }
  }

  private struct Observed: View {
    @ObservedObject var presenter: MonitorSurfacePresenter
    let settings: FalseColorSettings
    let declaration: MonitorSignalDeclaration
    var body: some View {
      UIFalseColorLegendSection.legend(settings: settings,
        signal: declaration.applied(to: presenter.shownSignal ?? SignalDescription()),
        unavailable: presenter.shownStatus.reason(for: .falseColor))
    }
  }
}

/// MonitorKit's captioned legend, laid out compactly: the headline and the
/// reference's captions, the bands brightest first as a swatch grid (two
/// columns when they fit without truncating), then the footnotes. Label colors and
/// outlined swatches read in light and dark.
struct UIFalseColorLegendGrid: View {
  let legend: FalseColorLegend
  /// The surface status's reason for `.falseColor`; it replaces the swatches.
  let unavailable: MonitorUnavailableReason?

  /// Why nothing is drawn: the surface's reason, else the legend's own check.
  var unavailableText: String? { unavailable.map { "Unavailable: \($0.description)" } ?? legend.unavailableNote }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(legend.headline).font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
      if let reason = unavailableText {
        Label(reason, systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      } else {
        ForEach(Array(legend.captions.enumerated()), id: \.offset) { _, line in
          Text(line).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        swatches
        ForEach(Array(legend.footnotes.enumerated()), id: \.offset) { _, line in
          Text(line).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("False color legend, \(legend.headline)")
  }

  /// Two columns when every name and range fits in them, else one.
  @ViewBuilder private var swatches: some View {
    if legend.entries.count > 3 {
      ViewThatFits(in: .horizontal) {
        grid(columns: 2)
        grid(columns: 1)
      }
    } else {
      grid(columns: 1)
    }
  }

  /// Brightest first, down the first column and then the next. Each band is a
  /// swatch, name and range in grid columns sized to their widest cell, so
  /// nothing truncates: when two columns are too wide, one is used.
  private func grid(columns: Int) -> some View {
    let entries = legend.displayOrder
    let rows = (entries.count + columns - 1) / columns
    return Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
      ForEach(0..<rows, id: \.self) { row in
        GridRow {
          ForEach(0..<columns, id: \.self) { column in
            let index = column * rows + row
            if index < entries.count {
              swatch(entries[index]).padding(.leading, column > 0 ? 12 : 0)
              Text(entries[index].name).lineLimit(1).accessibilityHidden(true)
              Text(entries[index].range).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                .gridColumnAlignment(.trailing)
                .accessibilityHidden(true)
            }
          }
        }
      }
    }
    .font(.caption)
    .fixedSize()
    .padding(.vertical, 2)
  }

  /// A band's color, outlined so white and black bands show in either appearance.
  /// It carries the band's name and range for VoiceOver.
  private func swatch(_ entry: FalseColorLegend.Entry) -> some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(entry.color.color)
      .frame(width: 12, height: 10)
      .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
      .accessibilityElement()
      .accessibilityLabel("\(entry.name), \(entry.range) \(legend.unit.symbol)")
  }
}
