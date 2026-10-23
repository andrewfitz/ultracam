#if UI_VERIFY
import MonitorKitCore
import SwiftUI

/// The monitor tool popovers' rules, checked offscreen (ui-verify): which
/// false-color modes a declaration offers and what its toggle turns on, the
/// clip-indicator and zebra master-switch rules, the declaration's mode remap,
/// the temperature slider's return to D65, the Picture button's "adjusted"
/// state and the signal each popover's header names.
@MainActor enum UIMonitorToolVerify {
  static let sony = "sony-slog3-sgamut3cine"
  static let sonyWide = "sony-slog3-sgamut3"
  static let arri = ARRIFalseColorProfile.logC3EI800.rawValue

  static func run(verifier: Verifier) {
    falseColorChoices(verifier)
    toggles(verifier)
    zebraBinding(verifier)
    declaration(verifier)
    picture(verifier)
    subtitles(verifier)
  }

  /// A binding's storage; the checks run on the main actor only.
  private final class Box: @unchecked Sendable {
    var value: MonitorFeedPreferences
    init(_ value: MonitorFeedPreferences) { self.value = value }
    var binding: Binding<MonitorFeedPreferences> { Binding(get: { self.value }, set: { self.value = $0 }) }
  }

  static func falseColorChoices(_ verifier: Verifier) {
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) { verifier.check(name, ok, detail()) }
    check("false color: Off is always available", UIFalseColorChoices.isAvailable(.off, profile: nil), "")
    for mode in [FalseColorMode.sixBand, .custom] {
      check("false color: \(mode) needs no declaration", UIFalseColorChoices.isAvailable(mode, profile: nil), "")
    }
    for mode in UIFalseColorChoices.modes where mode.needsLogSource {
      check("false color: \(mode) needs a declared log", !UIFalseColorChoices.isAvailable(mode, profile: nil), "")
    }
    check("false color: Sony on S-Log3", UIFalseColorChoices.isAvailable(.sonySLog3, profile: sony), "")
    check("false color: EL Zone on S-Log3", UIFalseColorChoices.isAvailable(.elZone, profile: sonyWide), "")
    check("false color: ARRI LogC on LogC3", UIFalseColorChoices.isAvailable(.arriLogC, profile: arri), "")
    check("false color: no Sony table on LogC3", !UIFalseColorChoices.isAvailable(.sonySLog3, profile: arri), "")
    check("false color: no ARRI table on S-Log3", !UIFalseColorChoices.isAvailable(.arriLogC, profile: sony), "")
    let suggested: [(String?, FalseColorMode)] = [(nil, .sixBand), (sony, .sonySLog3), (sonyWide, .sonySLog3),
      (arri, .arriLogC), (ARRIFalseColorProfile.alexa35LogC4EI800.rawValue, .arriLogC), ("unknown-profile", .sixBand)]
    for (profile, mode) in suggested {
      let value = UIFalseColorChoices.suggestedMode(profile: profile)
      check("false color: suggested for \(profile ?? "nil")", value == mode, "\(value), expected \(mode)")
      check("false color: suggested for \(profile ?? "nil") is available",
        UIFalseColorChoices.isAvailable(value, profile: profile), "\(value)")
    }
  }

  static func toggles(_ verifier: Verifier) {
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) { verifier.check(name, ok, detail()) }
    // The false-color toggle: the suggested mode for the declaration, with the
    // master switch following; nothing declared turns on six band.
    for (profile, mode) in [(String?.none, FalseColorMode.sixBand), (sony, .sonySLog3), (arri, .arriLogC)] {
      var start = MonitorFeedPreferences()
      start.signal.logProfileID = profile
      let on = UIMonitorBridge.toggled(.falseColor, in: start)
      check("toggle false color on (\(profile ?? "nil"))", on.state.falseColor.mode == mode && on.toolsEnabled,
        "\(on.state.falseColor.mode), tools \(on.toolsEnabled)")
      let off = UIMonitorBridge.toggled(.falseColor, in: on)
      check("toggle false color off (\(profile ?? "nil"))", off.state.falseColor.mode == .off && !off.toolsEnabled,
        "\(off.state.falseColor.mode), tools \(off.toolsEnabled)")
    }
    let declared = UIMonitorBridge.toggled(.falseColor, in: MonitorFeedPreferences(), defaultSourceProfile: sony)
    check("toggle false color declares the LUT's source profile",
      declared.signal.logProfileID == sony && declared.state.falseColor.mode == .sonySLog3,
      "\(declared.signal.logProfileID ?? "nil"), \(declared.state.falseColor.mode)")

    // Clip indicators: on and off with the master switch, never resurrecting
    // tools left on underneath it.
    var hidden = MonitorFeedPreferences()
    hidden.state.guides.enabled = true
    hidden.state.clipIndicators.enabled = true
    check("clip indicators are off while the tools are hidden", !UIMonitorBridge.clipIndicatorsOn(hidden), "")
    let clipOn = UIMonitorBridge.toggledClipIndicators(in: hidden)
    check("clip indicators on from hidden tools",
      clipOn.toolsEnabled && clipOn.state.clipIndicators.enabled && !clipOn.state.guides.enabled,
      "tools \(clipOn.toolsEnabled), clip \(clipOn.state.clipIndicators.enabled), guides \(clipOn.state.guides.enabled)")
    let clipOff = UIMonitorBridge.toggledClipIndicators(in: clipOn)
    check("clip indicators off turns the master switch off",
      !clipOff.toolsEnabled && !clipOff.state.clipIndicators.enabled, "tools \(clipOff.toolsEnabled)")
    var shown = MonitorFeedPreferences()
    shown.toolsEnabled = true
    shown.state.guides.enabled = true
    let withGuides = UIMonitorBridge.toggledClipIndicators(in: UIMonitorBridge.toggledClipIndicators(in: shown))
    check("clip indicators off keeps the other tools", withGuides.toolsEnabled && withGuides.state.guides.enabled
      && !withGuides.state.clipIndicators.enabled, "tools \(withGuides.toolsEnabled)")
  }

  static func zebraBinding(_ verifier: Verifier) {
    var short = MonitorFeedPreferences()
    short.toolsEnabled = true
    short.state.zebras = [ZebraSet(enabled: true, mode: .lowerLimit, level: 90)]
    let box = Box(short)
    let second = UIMonitorToolBindings.zebra(box.binding, 1)
    verifier.check("zebra 2 reads the default set on a one-set state",
      second.wrappedValue == MonitorFeedPreferences.defaultState.zebras[1] && box.value.state.zebras.count == 1,
      "\(box.value.state.zebras.count) sets")
    var changed = second.wrappedValue
    changed.level = 55
    second.wrappedValue = changed
    verifier.check("zebra 2 write pads the sets", box.value.state.zebras.count == 2
      && box.value.state.zebras[1].level == 55 && box.value.state.zebras[0].level == 90,
      "\(box.value.state.zebras.map(\.level))")
    let hidden = Box(MonitorFeedPreferences(state: { var s = MonitorFeedPreferences.defaultState; s.zebras = []; return s }()))
    hidden.value.state.guides.enabled = true
    UIMonitorToolBindings.zebraEnabled(hidden.binding, 1).wrappedValue = true
    verifier.check("zebra 2 on from hidden tools pads and shows only it",
      hidden.value.toolsEnabled && hidden.value.state.zebras.count == 2 && hidden.value.state.zebras[1].enabled
        && !hidden.value.state.zebras[0].enabled && !hidden.value.state.guides.enabled,
      "\(hidden.value.state.zebras.map(\.enabled)), guides \(hidden.value.state.guides.enabled)")
  }

  static func declaration(_ verifier: Verifier) {
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) { verifier.check(name, ok, detail()) }
    func with(_ mode: FalseColorMode, _ profile: String?) -> MonitorFeedPreferences {
      var value = MonitorFeedPreferences()
      value.toolsEnabled = true
      value.signal.logProfileID = profile
      value.state.falseColor.mode = mode
      return value
    }
    let toARRI = UISignalDeclarationFields.declaring(arri, in: with(.sonySLog3, sony))
    check("declaring LogC switches Sony false color to ARRI's", toARRI.state.falseColor.mode == .arriLogC
      && toARRI.signal.logProfileID == arri, "\(toARRI.state.falseColor.mode)")
    let toSony = UISignalDeclarationFields.declaring(sony, in: with(.arriLogC, arri))
    check("declaring S-Log3 switches ARRI false color to Sony's", toSony.state.falseColor.mode == .sonySLog3,
      "\(toSony.state.falseColor.mode)")
    let kept = UISignalDeclarationFields.declaring(sonyWide, in: with(.elZone, sony))
    check("declaring another S-Log3 keeps EL Zone", kept.state.falseColor.mode == .elZone, "\(kept.state.falseColor.mode)")
    let cleared = UISignalDeclarationFields.declaring(nil, in: with(.sonySLog3, sony))
    check("clearing the declaration leaves a log mode to explain itself",
      cleared.state.falseColor.mode == .sonySLog3 && cleared.signal.logProfileID == nil, "\(cleared.state.falseColor.mode)")
    let six = UISignalDeclarationFields.declaring(arri, in: with(.sixBand, nil))
    check("declaring a log keeps six band", six.state.falseColor.mode == .sixBand, "\(six.state.falseColor.mode)")
  }

  static func picture(_ verifier: Verifier) {
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) { verifier.check(name, ok, detail()) }
    let d65 = WhitePointTrim.d65Temperature
    for value in [6500.0, 6504, 6528.9, 6479.1] {
      check("temperature \(value) snaps to D65", UIPictureSettingsForm.snappedTemperature(value) == d65, "")
    }
    for value in [6550.0, 6450, 4000, 10_000] {
      check("temperature \(value) is kept", UIPictureSettingsForm.snappedTemperature(value) == value, "")
    }
    // The slider's grid (4000 + 50n) and the accessibility steps (D65 ± 50n)
    // both return to no trim.
    var display = DisplayAdjustments()
    display.temperature = UIPictureSettingsForm.snappedTemperature(4000 + 50 * 50)
    check("temperature back on the slider grid is no trim", display.isIdentity, "\(display.temperature)")
    display.temperature = UIPictureSettingsForm.snappedTemperature(d65 + 50 - 50)
    check("temperature back by accessibility steps is no trim", display.isIdentity, "\(display.temperature)")

    var state = MonitorFeedPreferences.defaultState
    check("the published picture is not adjusted", !UIPictureSettingsForm.isAdjusted(state), "")
    for stage in [SignalStage.source, .monitor] {
      state.pictureStage = stage
      check("picture on \(stage) is adjusted", UIPictureSettingsForm.isAdjusted(state), "")
    }
    state = MonitorFeedPreferences.defaultState
    state.display.temperature = 6500
    check("a 6500 K trim is adjusted", UIPictureSettingsForm.isAdjusted(state), "")
    state.display.temperature = UIPictureSettingsForm.snappedTemperature(6500)
    check("a snapped temperature is not adjusted", !UIPictureSettingsForm.isAdjusted(state), "")
  }

  static func subtitles(_ verifier: Verifier) {
    func subtitle(_ panel: UIMonitorPanel, _ preferences: MonitorFeedPreferences, program: Bool = false) -> String {
      UIMonitorToolSettingsView.subtitle(panel, cameraName: "Camera 1", isProgram: program, preferences: preferences)
    }
    func expect(_ name: String, _ panel: UIMonitorPanel, _ preferences: MonitorFeedPreferences, _ expected: String,
      program: Bool = false) {
      let value = subtitle(panel, preferences, program: program)
      verifier.check("header: \(name)", value == expected, "\(value), expected \(expected)")
    }
    var value = MonitorFeedPreferences()
    value.signal.logProfileID = sony
    value.state.falseColor.mode = .sonySLog3
    expect("log false color reads the source", .tool(.falseColor), value, "Camera 1 · analysis on Source")
    value.state.falseColor.mode = .sixBand
    expect("six band reads its stage", .tool(.falseColor), value, "Camera 1 · analysis on Output (LUT)")
    value.state.falseColor.stage = .source
    value.state.falseColor.mode = .custom
    expect("custom bands read their stage", .tool(.falseColor), value, "Camera 1 · analysis on Source")
    var off = MonitorFeedPreferences()
    expect("off, undeclared: the six-band toggle's stage", .tool(.falseColor), off, "Camera 1 · analysis on Output (LUT)")
    off.signal.logProfileID = arri
    expect("off, declared log: the source", .tool(.falseColor), off, "Camera 1 · analysis on Source")
    expect("false color on Program", .tool(.falseColor), off, "Camera 1 · Program Output", program: true)

    var clip = MonitorFeedPreferences()
    clip.setPictureStage(.source)
    expect("clip reads its own stage", .clipIndicators, clip, "Camera 1 · Output (LUT)")
    expect("picture names the picture stage", .picture, clip, "Camera 1 · Source")
    expect("guides name the picture stage", .tool(.guides), clip, "Camera 1 · Source")
    expect("focus reads its stage", .tool(.focus), clip, "Camera 1 · analysis on Source")
    clip.state.focus.stage = .output
    expect("focus on output", .tool(.focus), clip, "Camera 1 · analysis on Output (LUT)")
    expect("scopes", .tool(.scopes), clip, "Camera 1 · below the picture")
    expect("scopes on Program", .tool(.scopes), clip, "Camera 1 · below the picture", program: true)

    var zebra = MonitorFeedPreferences()
    expect("zebra off names the picture", .tool(.zebra), zebra, "Camera 1 · Output (LUT)")
    zebra.state.zebras[1].enabled = true
    zebra.state.zebras[1].stage = .source
    expect("zebra 2 alone names its stage", .tool(.zebra), zebra, "Camera 1 · Source")
    zebra.state.zebras[0].enabled = true
    expect("both zebras name both stages", .tool(.zebra), zebra, "Camera 1 · Output (LUT) + Source")
    zebra.state.zebras[1].stage = .output
    expect("both zebras on one stage name it once", .tool(.zebra), zebra, "Camera 1 · Output (LUT)")
    expect("zebra on Program", .tool(.zebra), zebra, "Camera 1 · Program Output", program: true)
  }
}
#endif
