import MonitorKit
import MonitorKitScopes
import SwiftUI

/// The scopes pane and its settings in representative states, for the offscreen
/// renderer (ui-verify) and the self-test, plus the checks of what they show.
/// The scope image is a drawn stand-in: the real one is MonitorKit's GPU image.
@MainActor enum UIScopeScreens {
  struct Screen {
    let name: String
    let view: AnyView
    let size: CGSize
  }

  struct Check {
    let name: String
    let passed: Bool
    let detail: String
  }

  static var pq: SignalDescription {
    var value = SignalDescription.rec709
    value.encoding = .display(.pq)
    value.primaries = .rec2020
    value.matrix = .bt2020
    return value
  }

  static var hlg: SignalDescription {
    var value = pq
    value.encoding = .display(.hlg)
    return value
  }

  static func scopes(_ choice: UIScopeChoice, edit: (inout ScopeSettings) -> Void = { _ in }) -> MonitorScopePreferences {
    var value = MonitorScopePreferences(enabled: true)
    value.settings = choice.applied(to: value.settings)
    edit(&value.settings)
    return value
  }

  static func screens() -> [Screen] {
    var screens: [Screen] = []
    func panel(_ name: String, _ scopes: MonitorScopePreferences, signal: SignalDescription? = .rec709,
      lut: Bool = false, program: Bool = false, expanded: Bool = false, readout: UIScopeReadout? = nil) {
      let description = UIScopeDescription(scopes: scopes, signal: signal, burnInLUT: lut, isProgram: program)
      screens.append(Screen(
        name: "scope-\(name)",
        view: AnyView(
          UIScopePanel(
            description: description, expanded: .constant(expanded), heldReadout: readout,
            timing: "Live · Scope PTS 12.345 · 0.0 s old",
            interpretation: signal.map { _ in "Rec.709 · legal range" } ?? ""
          ) {
            UIScopeStandIn(description: description)
          }.padding(10)),
        size: CGSize(width: 560, height: expanded ? 470 : 330)))
    }
    for choice in UIScopeChoice.allCases {
      panel(choice.rawValue, scopes(choice), lut: true)
    }
    panel("pq-nits", scopes(.luma) { $0.display.waveformScale = .pqNits }, signal: pq, expanded: true)
    panel("hlg-percent", scopes(.rgbParade), signal: hlg)
    panel("code-values", scopes(.ycbcrParade) { $0.display.waveformScale = .codeValues }, expanded: true)
    panel("standard-look", scopes(.rgbParade) { $0 = UIScopeLook.standard.applied(to: $0) })
    panel("vectorscope-zoom", scopes(.vectorscope) {
      $0.vectorscopeZoom = 2
      $0.display.vectorscopeTargets = .percent75
    }, expanded: true)
    panel("histogram-log", scopes(.histogram) {
      $0.histogramMode = .rgbParade
      $0.display.histogramScale = .logarithmic
    })
    panel("program", scopes(.rgbParade), program: true)
    panel("no-signal", scopes(.rgbParade), signal: nil)
    panel("clipping", scopes(.rgbParade),
      readout: UIScopeReadout(
        pixelCount: 1920 * 1080, clippedHigh: SIMD4(0.0004, 0.012, 0.25, 0.031), clippedLow: SIMD4(0, 0, 0.001, 0),
        lumaMinimum: -0.02, lumaMaximum: 1.04, lumaAverage: 0.43))
    let settings: [(String, MonitorScopePreferences, SignalDescription?)] = [
      ("waveform", scopes(.rgbParade), pq), ("vectorscope", scopes(.vectorscope), .rec709),
      ("histogram", scopes(.histogram), .rec709),
    ]
    for (name, preferences, signal) in settings {
      screens.append(Screen(
        name: "scope-settings-\(name)",
        view: AnyView(UIScopeSettingsPreview(scopes: preferences, signal: signal)),
        size: CGSize(width: 344, height: 600)))
    }
    return screens
  }

  /// What the pane and settings promise, checked on their models.
  static func checks() -> [Check] {
    var checks: [Check] = []
    func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
      checks.append(Check(name: "scopes: " + name, passed: passed, detail: passed ? "" : detail()))
    }
    let classic = MonitorScopePreferences().settings
    check("the default is the classic RGB parade, −10…110 IRE",
      UIScopeChoice(classic) == .rgbParade && UIScopeLook(classic) == .classic
        && classic.waveformColumns == ScopeSettings.ultracamLegacyImageWidth
        && classic.waveformLevels == ScopeSettings.ultracamLegacyImageHeight)
    for choice in UIScopeChoice.allCases {
      let changed = choice.applied(to: classic)
      var expected = classic
      expected.kind = changed.kind
      expected.waveformMode = changed.waveformMode
      check("choosing \(choice.title) keeps every other setting", changed == expected && UIScopeChoice(changed) == choice,
        "\(changed)")
    }
    let standard = UIScopeLook.standard.applied(to: classic)
    check("the standard look changes only the range and colours",
      standard.levelRange == .standard && standard.display.palette == .standard
        && standard.waveformColumns == classic.waveformColumns && UIScopeLook(standard) == .standard
        && UIScopeLook.classic.applied(to: standard) == classic)

    let pqScope = UIScopeDescription(scopes: scopes(.luma), signal: pq, burnInLUT: false, isProgram: false)
    check("a PQ stage offers the PQ nits scale and suggests it",
      pqScope.offers(.pqNits) && !pqScope.offers(.hlgNits) && pqScope.suggestedHDRScale == .pqNits
        && pqScope.scaleNote != nil)
    let hlgScope = UIScopeDescription(scopes: scopes(.luma), signal: hlg, burnInLUT: false, isProgram: false)
    check("an HLG stage offers the HLG nits scale", hlgScope.offers(.hlgNits) && !hlgScope.offers(.pqNits))
    let afterLUT = UIScopeDescription(scopes: scopes(.luma), signal: pq, burnInLUT: true, isProgram: false)
    check("after the burn-in LUT the stage is Rec.709: no nits scale",
      afterLUT.hdrTransfer == nil && !afterLUT.offers(.pqNits) && afterLUT.context.matrix == .bt709)
    let sourceStage = UIScopeDescription(
      scopes: scopes(.luma) { $0.stage = .source }, signal: pq, burnInLUT: true, isProgram: false)
    check("the source stage of a LUT camera measures the camera signal",
      sourceStage.hdrTransfer == .pq && sourceStage.context.matrix == .bt2020)
    let sdr = UIScopeDescription(scopes: scopes(.luma), signal: .rec709, burnInLUT: false, isProgram: false)
    check("an SDR stage has no nits scale or note", !sdr.offers(.pqNits) && sdr.scaleNote == nil)
    let mismatch = UIScopeDescription(
      scopes: scopes(.luma) { $0.display.waveformScale = .pqNits }, signal: .rec709, burnInLUT: false,
      isProgram: false)
    check("a nits scale on an SDR stage says so", mismatch.scaleNote?.contains("not PQ") == true,
      mismatch.scaleNote ?? "no note")

    let docked = UIScopeDescription(scopes: scopes(.rgbParade), signal: .rec709, burnInLUT: false, isProgram: false)
      .visibleLabels(width: 560, height: 120).filter { $0.role == .tick }.map(\.text)
    check("a docked waveform labels 0, 50 and 100 IRE without overlaps", docked == ["0", "50", "100"],
      docked.joined(separator: ", "))
    let expanded = UIScopeDescription(scopes: scopes(.luma), signal: .rec709, burnInLUT: false, isProgram: false)
      .visibleLabels(width: 560, height: 240).filter { $0.role == .tick }.map(\.text)
    check("an expanded waveform keeps the −10 and 110 ends", expanded.contains("-10") && expanded.contains("110"),
      expanded.joined(separator: ", "))
    let parade = UIScopeDescription(scopes: scopes(.rgbParade), signal: .rec709, burnInLUT: false, isProgram: false)
    check("the RGB parade names its channels",
      parade.labels.filter { $0.role == .channel }.map(\.text) == ["R", "G", "B"])
    let ycbcr = UIScopeDescription(
      scopes: scopes(.ycbcrParade) { $0.display.waveformScale = .codeValues }, signal: .rec709, burnInLUT: false,
      isProgram: false)
    check("the YCbCr parade labels its chroma codes",
      ycbcr.visibleLabels(width: 560, height: 240).contains { $0.role == .tick && $0.text == "512" })
    let vector = UIScopeDescription(
      scopes: scopes(.vectorscope) { $0.display.vectorscopeTargets = .percent75 }, signal: .rec709, burnInLUT: false,
      isProgram: false)
    check("the vectorscope labels its six 75% targets", vector.labels.filter { $0.role == .target }.count == 6)
    let noGraticule = UIScopeDescription(
      scopes: scopes(.vectorscope) { $0.display.showsGraticule = false }, signal: .rec709, burnInLUT: false,
      isProgram: false)
    check("targets are labelled only with the graticule", !noGraticule.labels.contains { $0.role == .target })
    check("a vectorscope keeps the image's shape",
      UIScopeDescription.imageAspectRatio == 3 && vector.settings.kind == .vectorscope)
    check("Program's scope says Program Output",
      UIScopeDescription(scopes: scopes(.rgbParade), signal: .rec709, burnInLUT: false, isProgram: true).title
        == "RGB parade · Program Output")

    let lines = UIScopeReadout.lines(
      UIScopeReadout(
        pixelCount: 100, clippedHigh: SIMD4(0, 0.0001, 0.012, 0.003), clippedLow: .zero, lumaMinimum: -0.02,
        lumaMaximum: 1.03, lumaAverage: 0.41), settings: classic)
    check("the clip readout shows R, G, B and luma, with <0.1% for a few pixels",
      lines.high == "Over 100%  R 0.0%  G <0.1%  B 1.2%  Y 0.3%" && lines.luma == "Luma  min -2%  avg 41%  max 103%",
      "\(lines)")
    let empty = UIScopeReadout.lines(nil, settings: classic)
    check("before a measurement the readout shows dashes", empty.high == "Over 100%  —" && empty.low == "Under 0%  —")
    check("an empty measurement is no measurement", UIScopeReadout(nil) == nil)
    return checks
  }
}

/// The scope settings at popover width with their own state.
private struct UIScopeSettingsPreview: View {
  @State var scopes: MonitorScopePreferences
  let signal: SignalDescription?
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      UIScopeSettingsView(scopes: $scopes, isProgram: false, signal: signal, burnInLUT: false)
    }
    .padding(12).frame(width: 320, alignment: .topLeading).controlSize(.small)
    .frame(maxHeight: .infinity, alignment: .top)
  }
}

/// A drawn stand-in for the GPU scope image: a trace in the look's colours.
private struct UIScopeStandIn: View {
  let description: UIScopeDescription
  var body: some View {
    Canvas { context, size in
      let kind = description.settings.kind
      if kind == .vectorscope {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        for i in 0..<240 {
          let angle = Double(i) / 240 * 2 * .pi
          let r = side * (0.12 + 0.1 * sin(angle * 3))
          let point = CGPoint(x: center.x + cos(angle) * r, y: center.y - sin(angle) * r)
          context.fill(Path(CGRect(x: point.x, y: point.y, width: 2, height: 2)), with: .color(.green.opacity(0.8)))
        }
        return
      }
      let colors: [Color] =
        description.settings.channelCount == 3 ? [.red, .green, .blue] : [.white]
      for (channel, color) in colors.enumerated() {
        for i in 0..<300 {
          let t = Double(i) / 300
          let wave = 0.5 + 0.35 * sin(t * 12 + Double(channel))
          let point =
            kind == .histogram
            ? CGPoint(x: wave * size.width, y: size.height * (1 - t * 0.6))
            : CGPoint(x: t * size.width, y: size.height * (1 - wave))
          context.fill(Path(CGRect(x: point.x, y: point.y, width: 2, height: 2)), with: .color(color.opacity(0.7)))
        }
      }
    }
    .background(Color.black)
  }
}
