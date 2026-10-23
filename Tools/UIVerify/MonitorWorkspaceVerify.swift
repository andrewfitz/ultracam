import MonitorKitCore

/// The detached monitor tile's captions and its local scope visibility
/// (MonitorToolsUITests:53 and the view half of :877), through the rules the
/// tile itself uses (`MonitorDetachedRules`).
@MainActor enum MonitorWorkspaceVerify {
  static func run(verifier: Verifier) {
    func expect(_ name: String, _ value: String, _ expected: String) {
      verifier.check("detached tile: \(name)", value == expected, "\(value), expected \(expected)")
    }
    var preferences = MonitorFeedPreferences()
    preferences.toolsEnabled = true
    expect("the default picture caption", MonitorDetachedRules.pictureCaption(isProgram: false, preferences: preferences),
      "Picture: Output (LUT)")
    for (stage, title) in [(SignalStage.source, "Source"), (.output, "Output (LUT)"), (.monitor, "Monitor")] {
      var value = preferences
      value.setPictureStage(stage)
      expect("the caption names the \(title) stage",
        MonitorDetachedRules.pictureCaption(isProgram: false, preferences: value), "Picture: \(title)")
    }
    expect("Program's caption", MonitorDetachedRules.pictureCaption(isProgram: true, preferences: preferences),
      "Picture: Program Output")
    var falseColor = preferences
    falseColor.signal.logProfileID = "sony-slog3-sgamut3cine"
    falseColor.state.falseColor.mode = .sonySLog3
    expect("false colour analyses the source",
      MonitorDetachedRules.pictureCaption(isProgram: false, preferences: falseColor),
      "False color: Source analysis · selected picture signal: Output (LUT)")
    falseColor.setPictureStage(.source)
    expect("false colour names the selected picture signal",
      MonitorDetachedRules.pictureCaption(isProgram: false, preferences: falseColor),
      "False color: Source analysis · selected picture signal: Source")
    expect("false colour on Program keeps the picture caption",
      MonitorDetachedRules.pictureCaption(isProgram: true, preferences: falseColor), "Picture: Program Output")
    var hidden = falseColor
    hidden.toolsEnabled = false
    expect("tools off: no false colour caption",
      MonitorDetachedRules.pictureCaption(isProgram: false, preferences: hidden), "Picture: Source")

    var scopes = preferences
    scopes.scopes.enabled = true
    func registers(_ value: MonitorFeedPreferences, local: Bool = true, frozen: Bool = false, preview: Bool = true)
      -> Bool {
      MonitorDetachedRules.registersScope(preferences: value, locallyVisible: local, frozen: frozen,
        previewEnabled: preview)
    }
    verifier.check("detached tile: scopes on register the scope", registers(scopes))
    verifier.check("detached tile: hiding scopes in this view registers none", !registers(scopes, local: false))
    verifier.check("detached tile: hiding them locally keeps the feed's scopes on",
      scopes.scopesShown && !registers(scopes, local: false))
    verifier.check("detached tile: a held picture registers no scope", !registers(scopes, frozen: true))
    verifier.check("detached tile: a hidden preview registers no scope", !registers(scopes, preview: false))
    verifier.check("detached tile: scopes off register none", !registers(preferences))
    var off = scopes
    off.toolsEnabled = false
    verifier.check("detached tile: the master switch off registers no scope", !registers(off))
  }
}
