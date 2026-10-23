import MonitorKit
import MonitorKitCore
import MonitorKitUI
import SwiftUI

/// The picture itself: which signal it shows, the display transform, geometry
/// and display adjustments. All of it changes this camera's monitor pictures
/// only; tools keep measuring their own signal, and output and recordings are
/// unchanged.
struct UIPictureSettingsForm: View {
  @Binding var preferences: MonitorFeedPreferences
  let cameraID: String
  let isProgram: Bool

  /// The PQ mastering peaks offered for HDR transforms, in cd/m².
  static let pqPeaks: [Double] = [300, 500, 800, 1000, 2000, 4000]

  /// Whether anything here differs from the picture as published.
  static func isAdjusted(_ state: MonitorState) -> Bool {
    state.displayTransform.mode != .none || state.geometry.desqueeze != 1 || state.geometry.flip != .none
      || !state.display.isIdentity
  }

  var body: some View {
    let state = $preferences.state
    Section {
      Picker("Signal", selection: UIMonitorToolBindings.pictureStage($preferences)) {
        Text("Source (camera signal)").tag(SignalStage.source).disabled(isProgram)
        Text("Output (LUT)").tag(SignalStage.output)
        Text("Monitor").tag(SignalStage.monitor)
      }
      UIMonitorToolCaption(isProgram
        ? "On Program the picture is Program Output; Source is unavailable."
        : "Output (LUT) is the camera's source with the burn-in LUT, as published. Zebra 1 measures the picture shown.")
      UIMonitorStatusNote(cameraID: cameraID, tools: [.picture, .burnInLUT, .monitorLUT], explainsCodeValues: true)
    } header: {
      Text("Picture")
    }
    Section {
      Picker("Transform", selection: state.displayTransform.mode) {
        ForEach(DisplayTransform.allCases, id: \.self) { Text(UIMonitorToolText.displayTransform($0)).tag($0) }
      }
      let mode = preferences.state.displayTransform.mode
      if mode == .hdrToSDR || mode == .hdrPassthrough {
        Picker("PQ mastering peak", selection: state.displayTransform.pqSourcePeak) {
          ForEach(Self.pqPeaks, id: \.self) { Text("\(Int($0)) cd/m²").tag($0) }
          let peak = preferences.state.displayTransform.pqSourcePeak
          if !Self.pqPeaks.contains(peak) { Text("\(Int(peak)) cd/m²").tag(peak) }
        }
      }
      UIMonitorToolCaption(Self.transformCaption(mode))
      UIMonitorStatusNote(cameraID: cameraID, tools: [.displayTransform])
      if mode == .logToRec709 && !isProgram {
        UISignalDeclarationFields(preferences: $preferences, isProgram: isProgram)
      }
    } header: {
      Text("Display transform")
    }
    Section {
      Picker("De-squeeze", selection: state.geometry.desqueeze) {
        ForEach(desqueezeChoices, id: \.self) { Text(UIMonitorToolText.desqueeze($0)).tag($0) }
      }
      Picker("Flip", selection: state.geometry.flip) {
        ForEach(FlipMode.allCases, id: \.self) { Text(UIMonitorToolText.flip($0)).tag($0) }
      }
      UIMonitorToolCaption("Zoom is in the picture's zoom menu, for this view only.")
      UIMonitorStatusNote(cameraID: cameraID, tools: [.desqueeze, .flip])
    } header: {
      Text("Geometry")
    }
    Section {
      let display = state.display
      UIMonitorSlider("Brightness", value: display.brightness, in: -1...1, step: 0.01) { String(format: "%+.0f%%", $0 * 100) }
      UIMonitorSlider("Contrast", value: display.contrast, in: 0...2, step: 0.01) { String(format: "%.2f×", $0) }
      UIMonitorSlider("Saturation", value: display.saturation, in: 0...2, step: 0.01) { String(format: "%.2f×", $0) }
      Picker("Color", selection: display.monochrome) {
        ForEach(MonochromeMode.allCases, id: \.self) { Text(UIMonitorToolText.monochrome($0)).tag($0) }
      }
      .pickerStyle(.segmented)
      UIMonitorSlider("Temperature", value: display.temperature, in: WhitePointTrim.temperatureRange, step: 50) {
        String(format: "%.0f K", $0)
      }
      UIMonitorSlider("Tint", value: display.tint, in: WhitePointTrim.tintRange, step: 0.001) { String(format: "%+.3f", $0) }
      Button("Reset Display") { preferences.state.display = DisplayAdjustments() }
        .disabled(preferences.state.display.isIdentity)
      UIMonitorToolCaption("Display adjustments change this monitor's picture only, never tools, legends or output.")
      UIMonitorStatusNote(cameraID: cameraID, tools: [.displayAdjustments])
    } header: {
      Text("Display")
    }
  }

  private var desqueezeChoices: [Double] {
    var choices = ViewGeometry.standardDesqueezeFactors
    let current = preferences.state.geometry.desqueeze
    if !choices.contains(current) { choices.append(current) }
    return choices
  }

  static func transformCaption(_ mode: DisplayTransform) -> String {
    switch mode {
    case .none: return "The picture's own encoding. Log pictures show as code values."
    case .logToRec709:
      return "Display assist: a log source shown as Rec.709, like a camera's gamma display assist. Needs a declared camera log, and no LUT on the picture."
    case .hdrToSDR: return "PQ or HLG shown as Rec.709 SDR. Needs no LUT on the picture."
    case .hdrPassthrough: return "PQ or HLG stays HDR on an HDR display, highlights rolled off to what it can show."
    }
  }
}
