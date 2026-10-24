import MonitorKitCore
import MonitorKitScopes
import SwiftUI

/// Every monitor tool popover and the tool bar in representative states, for the
/// offscreen renderer (ui-verify) and the self-test. Each screen has its own
/// fixture settings, so the forms show their controls as a person would see them.
@MainActor enum UIMonitorToolScreens {
  struct Screen {
    let name: String
    let view: AnyView
    let size: CGSize
  }

  /// A camera declared as Sony S-Gamut3.Cine / S-Log3 with the tools on.
  static func cameraPreferences() -> MonitorFeedPreferences {
    var value = MonitorFeedPreferences()
    value.toolsEnabled = true
    value.signal.logProfileID = "sony-slog3-sgamut3cine"
    value.state.guides.enabled = true
    value.state.guides.frameGuides = [FrameGuide(aspect: 2.39, style: .linesAndMatte)]
    value.state.guides.safeAreas = [90, 93]
    value.state.guides.centerDot = true
    value.state.zebras[0].enabled = true
    value.state.zebras[1].enabled = true
    value.state.zebras[1].mode = .band
    value.state.zebras[1].level = 55
    value.state.zebras[1].stage = .source
    value.state.focus.enabled = true
    value.state.focus.style = .peak
    value.state.clipIndicators.enabled = true
    value.state.clipIndicators.coloring = .uniform
    value.state.displayTransform.mode = .logToRec709
    value.state.geometry.desqueeze = 1.33
    value.state.display.saturation = 0.8
    value.scopes.enabled = true
    return value
  }

  /// The false-color variants: each mode with the declaration it reads.
  static func falseColorVariants() -> [(name: String, preferences: MonitorFeedPreferences)] {
    func with(_ mode: FalseColorMode, profile: String?, _ change: (inout MonitorFeedPreferences) -> Void = { _ in })
      -> MonitorFeedPreferences {
      var value = cameraPreferences()
      value.signal.logProfileID = profile
      value.state.falseColor.mode = mode
      change(&value)
      return value
    }
    return [
      ("sony", with(.sonySLog3, profile: "sony-slog3-sgamut3cine")),
      ("arri", with(.arriLogC, profile: ARRIFalseColorProfile.logC3EI800.rawValue)),
      ("sixband", with(.sixBand, profile: nil)),
      ("custom", with(.custom, profile: nil) {
        $0.state.falseColor.customBands = [
          FalseColorBand(lower: -.infinity, upper: 5, color: ColorRGB(r: 0.45, g: 0.2, b: 0.75)),
          FalseColorBand(lower: 40, upper: 50, color: ColorRGB(r: 0.2, g: 0.75, b: 0.3)),
          FalseColorBand(lower: 95, upper: .infinity, color: ColorRGB(r: 1, g: 0.15, b: 0.1)),
        ]
      }),
      // Stops show the exposure-offset stepper; IRE bands (above) do not.
      ("customstops", with(.custom, profile: nil) {
        $0.state.falseColor.customUnit = .stops
        $0.state.falseColor.referenceOffsetStops = 0.5
        $0.state.falseColor.customBands = [
          FalseColorBand(lower: -.infinity, upper: -4, color: ColorRGB(r: 0.45, g: 0.2, b: 0.75)),
          FalseColorBand(lower: -0.5, upper: 0.5, color: ColorRGB(r: 0.2, g: 0.75, b: 0.3)),
          FalseColorBand(lower: 4, upper: .infinity, color: ColorRGB(r: 1, g: 0.15, b: 0.1)),
        ]
      }),
      ("undeclared", with(.sonySLog3, profile: nil)),
    ]
  }

  static func screens(_ session: UISessionSnapshot = UIFixtures.programMeeting()) -> [Screen] {
    var screens: [Screen] = []
    let cameraID = session.cameras.first?.id ?? "camera-1"
    let name = session.cameras.first?.name ?? "Camera 1"
    func panel(_ label: String, _ panel: UIMonitorPanel, _ preferences: MonitorFeedPreferences,
      target: String, title: String, program: Bool) {
      let provider = UIFixtureMonitorSettings(session: session)
      provider.setPreferences(preferences, for: target)
      screens.append(Screen(name: "monitor-tool-\(label)",
        view: AnyView(UIMonitorToolSettingsView(panel: panel, cameraID: target, cameraName: title, isProgram: program,
          provider: provider)),
        size: CGSize(width: 340 + 28, height: 680)))
    }
    let camera = cameraPreferences()
    panel("guides", .tool(.guides), camera, target: cameraID, title: name, program: false)
    panel("zebra", .tool(.zebra), camera, target: cameraID, title: name, program: false)
    for variant in falseColorVariants() {
      panel("false-color-\(variant.name)", .tool(.falseColor), variant.preferences, target: cameraID, title: name,
        program: false)
    }
    panel("focus", .tool(.focus), camera, target: cameraID, title: name, program: false)
    panel("scopes", .tool(.scopes), camera, target: cameraID, title: name, program: false)
    panel("clip", .clipIndicators, camera, target: cameraID, title: name, program: false)
    panel("picture", .picture, camera, target: cameraID, title: name, program: false)
    var program = MonitorFeedPreferences()
    program.toolsEnabled = true
    program.state.zebras[0].enabled = true
    program.state.clipIndicators.enabled = true
    panel("program-zebra", .tool(.zebra), program, target: "program", title: "Program", program: true)
    panel("program-false-color", .tool(.falseColor), program, target: "program", title: "Program", program: true)
    panel("program-focus", .tool(.focus), program, target: "program", title: "Program", program: true)
    panel("program-clip", .clipIndicators, program, target: "program", title: "Program", program: true)
    panel("program-picture", .picture, program, target: "program", title: "Program", program: true)

    // The bar itself, with clip indicators on and the picture adjusted.
    let provider = UIFixtureMonitorSettings(session: session)
    provider.setPreferences(camera, for: cameraID)
    let tools = UIMonitorTool.allCases.filter { UIMonitorBridge.activeTools(camera).contains($0) }
    screens.append(Screen(name: "monitor-tool-bar",
      view: AnyView(UIMonitorToolButtons(targetID: cameraID, name: name, activeTools: tools, isProgram: false,
        toggle: { _ in }, monitor: provider).padding(8).background(Color.black)),
      size: CGSize(width: 360, height: 48)))
    return screens
  }
}
