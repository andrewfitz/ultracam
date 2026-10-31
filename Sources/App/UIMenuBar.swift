import AppKit
import SwiftUI

// The menu bar item: a native NSStatusItem with an NSMenu. The first item is a
// custom view (a live preview card) shown only while the menu is open; every
// other row is a real NSMenuItem, so keyboard navigation, checkmarks, key
// equivalents and submenus behave natively.
//
// Testable builder (no display needed):
//
//   UIMenuBarController.buildItems(presentation: UISessionPresentation,
//                                  session: UISessionSnapshot,
//                                  target: AnyObject?,
//                                  previewItem: NSMenuItem?,
//                                  showLivePreview: Bool) -> [NSMenuItem]
//
//   UIMenuBarController.commands(for: NSMenuItem) -> [UIMenuCommand]
//
// Each actionable row carries its commands in `representedObject`
// (`UIMenuCommandBox`); `commands(for:)` reads them back for assertions.

/// What a menu row does when chosen.
enum UIMenuCommand: Equatable {
  case action(UIAction)
  /// Automatic waiting state: render the live preview on request (a visible preview counts as demand).
  case showLivePreview
}

final class UIMenuCommandBox: NSObject {
  let commands: [UIMenuCommand]
  init(_ commands: [UIMenuCommand]) { self.commands = commands }
}

@MainActor final class UIMenuBarController: NSObject, NSMenuDelegate {
  let model: AppModel
  let interface: UIInterfaceState
  /// Set by the app so "Open Ultracam" and "Settings…" can open SwiftUI scenes.
  var openWindow: ((String) -> Void)?
  var openSettings: (() -> Void)?

  private let statusItem: NSStatusItem
  private let menu = NSMenu()
  private var previewHost: NSHostingView<AnyView>?
  private var previewItem: NSMenuItem?
  private var showLivePreview = false
  private var previewWidth = UIMenuPreviewContent.minimumWidth
  private var menuOpen = false
  /// Refreshes the open menu's rows each second (see `refreshOpenMenu`).
  private var refreshTimer: Timer?
  private var lastIcon: UIMenuBarIcon?
  private var iconUpdateScheduled = false
  private var lastIconUpdate = Date.distantPast

  init(model: AppModel, interface: UIInterfaceState) {
    self.model = model
    self.interface = interface
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    menu.delegate = self
    menu.autoenablesItems = false
    statusItem.menu = menu
    updateIcon()
    track()
  }

  // MARK: Bridge

  private func bridge() -> UISessionBridge {
    UISessionBridge.live(model: model, interface: interface,
      openWindow: { [weak self] id in self?.open(windowID: id) },
      openSettings: { [weak self] in self?.showSettings() })
  }

  private func open(windowID id: String) {
    // Into the Dock first, so the window opens with its menus ("Menu bar when closed").
    if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true }) {
      window.makeKeyAndOrderFront(nil)
    } else if let openWindow = openWindow ?? UIAppEnvironment.openWindow {
      // A closed SwiftUI window is gone; SwiftUI makes it again.
      openWindow(id)
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  private func showSettings() {
    if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    if let openSettings = openSettings ?? UIAppEnvironment.openSettings { openSettings() }
    else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    NSApp.activate(ignoringOtherApps: true)
  }

  // MARK: Icon

  /// Re-arms Observation after every change; updates are coalesced to at most one a second.
  private func track() {
    withObservationTracking {
      _ = bridge().presentation().menuBarIcon
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.scheduleIconUpdate() }
    }
  }

  private func scheduleIconUpdate() {
    guard !iconUpdateScheduled else { return }
    iconUpdateScheduled = true
    let delay = max(0, 1 - Date().timeIntervalSince(lastIconUpdate))
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard let self else { return }
      self.iconUpdateScheduled = false
      self.updateIcon()
      self.track()
    }
  }

  private func updateIcon() {
    lastIconUpdate = Date()
    let icon = bridge().presentation().menuBarIcon
    guard icon != lastIcon, let button = statusItem.button else { return }
    lastIcon = icon
    button.image = Self.image(for: icon)
    button.setAccessibilityLabel(icon.accessibilityLabel)
    button.toolTip = icon.accessibilityLabel
  }

  /// The menu bar's symbol size: the camera glyph is wide and short, so it needs more than
  /// the usual 13–15 pt to look as large as its neighbors.
  private static let iconConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)

  /// A template image: the camera symbol, with the state's badge knocked out of its lower-left
  /// corner. Drawn on demand, so it's sharp at every display scale.
  static func image(for icon: UIMenuBarIcon) -> NSImage? {
    guard let symbol = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: icon.accessibilityLabel)?
      .withSymbolConfiguration(iconConfiguration) else { return nil }
    guard let badgeName = icon.badgeSymbol,
      let badge = NSImage(systemSymbolName: badgeName, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)) else {
      symbol.isTemplate = true
      return symbol
    }
    // The badge sticks out past the camera's lower-left corner by about a third of its size.
    let overhang = NSSize(width: (badge.size.width * 0.3).rounded(.up), height: (badge.size.height * 0.3).rounded(.up))
    let size = NSSize(width: ceil(symbol.size.width + overhang.width), height: ceil(symbol.size.height + overhang.height))
    let image = NSImage(size: size, flipped: false) { bounds in
      symbol.draw(in: NSRect(x: bounds.width - symbol.size.width, y: bounds.height - symbol.size.height,
        width: symbol.size.width, height: symbol.size.height))
      let badgeRect = NSRect(origin: .zero, size: badge.size)
      // A clear ring keeps the badge apart from the camera.
      NSGraphicsContext.current?.compositingOperation = .clear
      NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.5, dy: -1.5)).fill()
      NSGraphicsContext.current?.compositingOperation = .sourceOver
      badge.draw(in: badgeRect)
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = icon.accessibilityLabel
    return image
  }

  // MARK: Menu lifecycle

  func menuNeedsUpdate(_ menu: NSMenu) {
    rebuild()
  }

  func menuWillOpen(_ menu: NSMenu) {
    menuOpen = true
    // NSMenu doesn't rebuild its rows while open, but the preview card does: an automatic
    // cut left the card showing one camera on air and the rows checking another. Common
    // modes, so the timer also fires while the menu tracks the mouse.
    refreshTimer?.invalidate()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshOpenMenu() }
    }
    RunLoop.main.add(timer, forMode: .common)
    refreshTimer = timer
  }

  func menuDidClose(_ menu: NSMenu) {
    menuOpen = false
    refreshTimer?.invalidate()
    refreshTimer = nil
    showLivePreview = false
    // Tear down the preview so nothing renders while the menu is closed.
    previewItem?.view = nil
    previewHost = nil
    previewItem = nil
  }

  private func rebuild() {
    let bridge = bridge()
    let session = bridge.snapshot()
    let presentation = UIPresentationBuilder.session(session)
    let host = NSHostingView(rootView: card(width: UIMenuPreviewContent.minimumWidth))
    host.frame.size = host.fittingSize
    let item = NSMenuItem()
    item.view = host
    previewHost = host
    previewItem = item
    let items = Self.buildItems(presentation: presentation, session: session, target: self, previewItem: item,
      showLivePreview: showLivePreview)
    menu.removeAllItems()
    for item in items { menu.addItem(item) }
    // The menu is as wide as its widest row. Lay the card out again at that width, so the
    // picture fills the menu and stays centered instead of sitting at the left.
    previewWidth = max(UIMenuPreviewContent.minimumWidth, menu.size.width.rounded(.down))
    if previewWidth > host.frame.width {
      host.rootView = card(width: previewWidth)
      host.frame.size = host.fittingSize
    }
  }

  /// Brings the open menu's rows up to date: in place when only their state changed, so the
  /// menu neither jumps nor closes a submenu; rebuilt when rows came or went.
  private func refreshOpenMenu() {
    guard menuOpen, let previewItem else { return }
    let session = bridge().snapshot()
    let fresh = Self.buildItems(presentation: UIPresentationBuilder.session(session), session: session, target: self,
      previewItem: previewItem, showLivePreview: showLivePreview)
    guard !Self.refresh(menu.items, with: fresh) else { return }
    menu.removeAllItems()
    for item in fresh { menu.addItem(item) }
  }

  /// Copies `fresh` rows onto `existing` ones when both have the same shape (the same rows,
  /// separators, headers and submenus, recursively). Returns false, changing nothing, otherwise.
  @discardableResult
  static func refresh(_ existing: [NSMenuItem], with fresh: [NSMenuItem]) -> Bool {
    guard sameShape(existing, fresh) else { return false }
    copy(existing, fresh)
    return true
  }

  private static func sameShape(_ existing: [NSMenuItem], _ fresh: [NSMenuItem]) -> Bool {
    guard existing.count == fresh.count else { return false }
    for (old, new) in zip(existing, fresh) where old !== new {
      guard old.isSeparatorItem == new.isSeparatorItem, old.isSectionHeader == new.isSectionHeader,
        old.view == nil, new.view == nil, (old.submenu == nil) == (new.submenu == nil) else { return false }
      if let oldMenu = old.submenu, let newMenu = new.submenu, !sameShape(oldMenu.items, newMenu.items) { return false }
    }
    return true
  }

  private static func copy(_ existing: [NSMenuItem], _ fresh: [NSMenuItem]) {
    for (old, new) in zip(existing, fresh) where old !== new && !old.isSeparatorItem {
      // Only what changed, so an unchanged row isn't redrawn.
      if old.title != new.title { old.title = new.title }
      if old.attributedTitle != new.attributedTitle { old.attributedTitle = new.attributedTitle }
      if old.subtitle != new.subtitle { old.subtitle = new.subtitle }
      if old.badge?.stringValue != new.badge?.stringValue { old.badge = new.badge }
      if old.state != new.state { old.state = new.state }
      if old.isEnabled != new.isEnabled { old.isEnabled = new.isEnabled }
      if old.toolTip != new.toolTip { old.toolTip = new.toolTip }
      if old.keyEquivalent != new.keyEquivalent { old.keyEquivalent = new.keyEquivalent }
      if old.keyEquivalentModifierMask != new.keyEquivalentModifierMask {
        old.keyEquivalentModifierMask = new.keyEquivalentModifierMask
      }
      if old.image?.name() != new.image?.name() || (old.image == nil) != (new.image == nil) { old.image = new.image }
      old.action = new.action
      old.target = new.target
      old.representedObject = new.representedObject
      if let oldMenu = old.submenu, let newMenu = new.submenu { copy(oldMenu.items, newMenu.items) }
    }
  }

  private func card(width: CGFloat) -> AnyView {
    AnyView(UIMenuPreviewCard(model: model, interface: interface, showLive: showLivePreview, width: width))
  }

  // MARK: Actions

  @objc func menuAction(_ sender: NSMenuItem) {
    for command in Self.commands(for: sender) {
      switch command {
      case .showLivePreview:
        showLivePreview = true
        // Reopen the card as live on the next update; the menu stays as it is.
        previewHost?.rootView = card(width: previewWidth)
      case .action(let action):
        run(action)
      }
    }
  }

  /// The bridge asks for confirmation where needed, in the window in front or as a standard alert.
  private func run(_ action: UIAction) {
    bridge().send(action)
  }

  static func commands(for item: NSMenuItem) -> [UIMenuCommand] {
    (item.representedObject as? UIMenuCommandBox)?.commands ?? []
  }

  // MARK: Builder

  private static func row(_ title: String, _ commands: [UIMenuCommand], key: String = "",
    modifiers: NSEvent.ModifierFlags = [], checked: Bool = false, enabled: Bool = true,
    symbol: String? = nil, tint: NSColor? = nil, subtitle: String? = nil, badge: String? = nil, target: AnyObject?) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: commands.isEmpty ? nil : #selector(UIMenuBarController.menuAction(_:)),
      keyEquivalent: key)
    item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
    item.target = commands.isEmpty ? nil : target
    item.representedObject = commands.isEmpty ? nil : UIMenuCommandBox(commands)
    item.state = checked ? .on : .off
    item.isEnabled = enabled
    if let symbol { item.image = image(symbol, tint: tint) }
    if let subtitle { item.subtitle = subtitle }
    if let badge { item.badge = NSMenuItemBadge(string: badge) }
    return item
  }

  /// A template symbol, or with `tint` a colored one: the tone goes on the image, the words
  /// stay in label color.
  private static func image(_ symbol: String, tint: NSColor?) -> NSImage? {
    guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
    guard let tint else { return image }
    let tinted = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
    tinted?.isTemplate = false
    return tinted
  }

  private static func action(_ action: UIAction) -> [UIMenuCommand] { [.action(action)] }

  /// Damage's solid amber: a dark triangle on an amber square, the menu's stand-in for a fill.
  static let damageImage: NSImage = {
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size, flipped: false) { bounds in
      NSColor.systemOrange.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
      if let glyph = NSImage(systemSymbolName: UISymbol.warning, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
          .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))) {
        glyph.draw(in: NSRect(x: (bounds.width - glyph.size.width) / 2, y: (bounds.height - glyph.size.height) / 2,
          width: glyph.size.width, height: glyph.size.height))
      }
      return true
    }
    image.accessibilityDescription = "Problem"
    return image
  }()

  /// The session with the window hidden: fourteen rows or fewer when healthy, problem rows
  /// not counted. No row depends on the window's selection.
  static func buildItems(presentation: UISessionPresentation, session: UISessionSnapshot,
    target: AnyObject?, previewItem: NSMenuItem?, showLivePreview: Bool = false) -> [NSMenuItem] {
    var items: [NSMenuItem] = []
    if let previewItem { items.append(previewItem) }
    let waiting = !presentation.camerasRunning && session.cameras.contains(where: \.automaticStart)

    // Problems first, each one row that does its one action. A row can't take a fill, so
    // damage to what's on air or rolling is a solid amber image and a semibold title.
    for problem in presentation.problems {
      // Cuts only ever come from a "Cut to …" row (D1), and those are just below.
      var offered = problem.action
      if case .cut? = offered?.action { offered = UIProblemAction(title: "Details", action: .openDiagnostics) }
      let damage = problem.level == .damage
      let item = row(problem.title, offered.map { action($0.action) } ?? [], enabled: offered != nil,
        symbol: UISymbol.warning, tint: .systemOrange, subtitle: problem.detail, badge: offered?.title, target: target)
      if damage {
        item.image = damageImage
        item.attributedTitle = NSAttributedString(string: problem.title,
          attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)])
      }
      items.append(item)
    }
    if waiting && !showLivePreview {
      items.append(row("Show Live Preview", [.showLivePreview], symbol: UISymbol.showPreview, target: target))
    }
    if items.last !== previewItem || previewItem != nil { items.append(.separator()) }

    // Switching. The camera on Program gets no Cut row: there's nothing to cut to.
    if presentation.programAvailable {
      for button in presentation.cutButtons where !button.onAir {
        items.append(row("Cut to \(button.name)", action(.cut(cameraID: button.id)), key: button.number <= 4 ? "\(button.number)" : "",
          modifiers: .control, enabled: button.enabled, symbol: UISymbol.cut,
          badge: button.pending ? UITally.next.label : nil, target: target))
      }
      let auto = row("Automatic Switching", action(.setAutoSwitching(!presentation.autoSwitching)), key: "a",
        modifiers: [.control, .option], checked: presentation.autoSwitching, enabled: presentation.canAutoSwitch,
        symbol: UISymbol.auto, target: target)
      if !presentation.canAutoSwitch { auto.toolTip = "Choose a strategy in the window's Auto menu to switch automatically." }
      items.append(auto)
      items.append(row("Hold Current Shot", action(.setAutoHold(!session.autoHold)), key: "h", modifiers: [.control, .option],
        checked: presentation.canHoldShot && session.autoHold, enabled: presentation.canHoldShot,
        symbol: UISymbol.hold(on: presentation.canHoldShot && session.autoHold), target: target))
      items.append(.separator())
    }

    // Recording, per camera, then the session's.
    for camera in presentation.cameras {
      let taking = camera.recordButtonActive || camera.pauseTitle == "Resume"
      let elapsed = session.cameras.first { $0.id == camera.id }.map { UIFormat.shortElapsed($0.recording.elapsed) }
      items.append(row(taking ? "Stop Recording \(camera.name)" : "Record \(camera.name)", action(.toggleRecording(cameraID: camera.id)),
        enabled: camera.recordButtonEnabled, symbol: taking ? UISymbol.stop : UISymbol.record,
        badge: taking ? elapsed : nil, target: target))
    }
    if presentation.canPauseAll {
      let resume = presentation.pauseAllTitle == "Resume All"
      items.append(row(presentation.pauseAllTitle, action(resume ? .resumeAll : .pauseAll), key: "p", modifiers: [.command, .option],
        symbol: resume ? UISymbol.start : UISymbol.paused, target: target))
    }
    let format = NSMenu(title: "Format")
    format.autoenablesItems = false
    format.addItem(NSMenuItem.sectionHeader(title: "Applies to the next take"))
    for choice in UIPresentationBuilder.formatChoices(session) {
      format.addItem(row(choice.title, action(.setCodec(choice.codec)), checked: choice.selected, enabled: choice.reason == nil,
        badge: choice.reason ?? [choice.rate, choice.left].compactMap { $0 }.joined(separator: "  "), target: target))
    }
    let formatItem = row("Format", [], symbol: UISymbol.format, badge: session.codec.title, target: target)
    formatItem.submenu = format
    items.append(formatItem)
    // All drives share one row: the one that runs out first.
    let worst = session.drives.filter { $0.secondsLeft != nil }.min { ($0.secondsLeft ?? 0) < ($1.secondsLeft ?? 0) }
    let low = worst.map { ($0.secondsLeft ?? .infinity) < UIPresentationBuilder.lowDriveSeconds } ?? false
    items.append(row("Time left", [], enabled: worst != nil, symbol: UISymbol.drive(low: low), tint: low ? .systemOrange : nil,
      badge: worst.map { "\($0.name) \(UIFormat.duration($0.secondsLeft ?? 0))" } ?? "—", target: target))

    if !presentation.cameras.isEmpty {
      items.append(.separator())
      for camera in presentation.cameras {
        items.append(cameraItem(camera, presentation: presentation, session: session, target: target))
      }
    }

    // A separator above it, so a slip off a camera row can't land on it. It keeps its prompt.
    items.append(.separator())
    items.append(row(presentation.camerasControlTitle,
      action(presentation.camerasRunning ? .stopAllCameras : .startAllCameras), key: "\r", modifiers: .command,
      enabled: presentation.canStartAny,
      symbol: presentation.camerasRunning ? UISymbol.stop : UISymbol.start, target: target))

    items.append(.separator())
    items.append(row("Open Ultracam", action(.openMainWindow), key: "0", modifiers: .command, symbol: UISymbol.openWindow, target: target))
    items.append(row("Settings…", action(.openSettings), key: ",", modifiers: .command, symbol: UISymbol.settings, target: target))
    items.append(row("Quit Ultracam", action(.quit), key: "q", modifiers: .command, target: target))
    return items
  }

  /// One camera's own rows. Its subtitle is two parts at most, spaced, with no dot.
  private static func cameraItem(_ camera: UICameraPresentation, presentation: UISessionPresentation,
    session: UISessionSnapshot, target: AnyObject?) -> NSMenuItem {
    let snapshot = session.cameras.first { $0.id == camera.id }
    var status: [String] = []
    if let label = camera.tally.label { status.append(label) }
    switch camera.stripState {
    case .recording, .updating: status.append("REC \(UIFormat.shortElapsed(snapshot?.recording.elapsed ?? 0))")
    case .recordingNoSignal: status.append("REC, no signal")
    case .paused: status.append("Paused \(UIFormat.shortElapsed(snapshot?.recording.elapsed ?? 0))")
    case .failed, .noFolder, .stopped, .waiting: status.append(camera.collapsedWord ?? camera.statusBadge)
    default: if camera.tileState == .live && status.isEmpty { status.append("Live") }
    }
    let item = NSMenuItem(title: camera.name, action: nil, keyEquivalent: "")
    item.subtitle = status.prefix(2).joined(separator: "  ")
    item.image = image(camera.tally.isRed ? UISymbol.cameraOnAir : UISymbol.camera, tint: camera.state == .warning ? .systemOrange : nil)
    let submenu = NSMenu(title: camera.name)
    submenu.autoenablesItems = false
    let taking = camera.recordButtonActive || camera.pauseTitle == "Resume"
    submenu.addItem(row(taking ? "Stop Recording" : "Record", action(.toggleRecording(cameraID: camera.id)),
      enabled: camera.recordButtonEnabled, symbol: taking ? UISymbol.stop : UISymbol.record, target: target))
    if let pause = camera.pauseTitle {
      submenu.addItem(row(pause == "Pause" ? "Pause Recording" : "Resume Recording",
        action(.pauseOrResume(cameraID: camera.id)), symbol: pause == "Pause" ? UISymbol.paused : UISymbol.start, target: target))
    }
    // Always there with two cameras (checked while on Program), so an automatic cut changes
    // the row's state, not the submenu's rows, and the open menu updates in place.
    if presentation.programAvailable {
      let onAir = session.onAirID == camera.id
      submenu.addItem(row("Cut to \(camera.name)", action(.cut(cameraID: camera.id)),
        checked: onAir, enabled: camera.cutEnabled && !onAir, symbol: UISymbol.cut, target: target))
    }
    submenu.addItem(.separator())
    // LUT is the panic control, so it's a direct row: the format meeting apps get doesn't change.
    submenu.addItem(row("LUT", action(.setEffect(cameraID: camera.id, index: 0, !camera.lutIsOn)), checked: camera.lutIsOn,
      enabled: camera.lutEnabled, symbol: UISymbol.lut(on: camera.lutIsOn), subtitle: snapshot?.lutName, target: target))
    let effects = NSMenu(title: "Effects")
    effects.autoenablesItems = false
    for chip in camera.chips.dropFirst() {
      effects.addItem(row("\(chip.id + 1)  \(UIPresentationBuilder.effectLongTitles[chip.id])",
        action(.setEffect(cameraID: camera.id, index: chip.id, !chip.isOn)), checked: chip.isOn,
        enabled: chip.enabled && camera.processing, badge: chip.title, target: target))
    }
    effects.addItem(.separator())
    effects.addItem(row("Effects Off", action(.setProcessing(cameraID: camera.id, !camera.processing)), checked: !camera.processing,
      symbol: UISymbol.effectsOff, target: target))
    let effectsItem = row("Effects", [], symbol: camera.processing ? UISymbol.effects : UISymbol.effectsOff,
      badge: camera.processing ? "\(camera.chips.filter(\.isOn).count) of \(camera.chips.count)" : "Off", target: target)
    effectsItem.submenu = effects
    submenu.addItem(effectsItem)
    submenu.addItem(row("Video Preview", action(.setPreviewEnabled(cameraID: camera.id, !(snapshot?.previewEnabled ?? true))),
      checked: snapshot?.previewEnabled ?? true, symbol: UISymbol.showPreview, target: target))
    submenu.addItem(row("Start with Meeting Apps", action(.setAutomaticStart(cameraID: camera.id, !(snapshot?.automaticStart ?? false))),
      checked: snapshot?.automaticStart ?? false, symbol: UISymbol.startWithApps, target: target))
    submenu.addItem(.separator())
    submenu.addItem(row("Show Inspector", [.action(.showInspector(cameraID: camera.id)), .action(.openMainWindow)],
      symbol: UISymbol.inspector, target: target))
    submenu.addItem(camera.canStop
      ? row("Stop \(camera.name)", action(.stopCamera(cameraID: camera.id)), symbol: UISymbol.stop, target: target)
      : row("Start \(camera.name)", action(.startCamera(cameraID: camera.id)), enabled: camera.canStart,
        symbol: UISymbol.start, target: target))
    item.submenu = submenu
    return item
  }
}

// MARK: - Preview card

/// Live card for the menu's first item. Reading the models in `body` keeps it
/// current while the menu is open; it is torn down when the menu closes.
struct UIMenuPreviewCard: View {
  let model: AppModel
  let interface: UIInterfaceState
  let showLive: Bool
  /// The menu's width, so the card fills it edge to edge.
  var width = UIMenuPreviewContent.minimumWidth

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      let session = UISessionBridge.live(model: model, interface: interface).snapshot()
      UIMenuPreviewContent(presentation: UIPresentationBuilder.session(session), session: session,
        pictures: UIAppPictures(model: model), showLive: showLive, width: width)
    }
    // The meter bars read the camera's tap every refresh, not this 1 s snapshot.
    .environment(\.uiAudioMeters, UIAudioMeterSource { [model] in model.audioMeterTap(for: FeedID(rawValue: $0)) })
  }
}

/// The card's content, independent of the live models so it can be rendered from fixtures.
struct UIMenuPreviewContent: View {
  let presentation: UISessionPresentation
  let session: UISessionSnapshot
  let pictures: any UIPictureProviding
  var showLive = false
  var width = Self.minimumWidth

  /// The card's width when the menu's rows are narrower.
  static let minimumWidth: CGFloat = 340

  private var waiting: Bool {
    !presentation.camerasRunning && session.cameras.first { $0.id == session.selectedID }?.automaticStart == true
  }
  private var recordingCameras: [UICameraSnapshot] {
    session.cameras.filter { $0.recording.status == .recording || $0.recording.status == .paused }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Group {
        if showsPlaceholder {
          placeholder
        } else if session.programInUse {
          programPicture
        } else if twoUp {
          HStack(spacing: 6) {
            ForEach(presentation.cameras.prefix(2)) { camera in miniPicture(camera) }
          }
        } else if let shown = presentation.previewCamera {
          cameraPicture(shown)
        }
      }
      if session.programInUse && presentation.camerasRunning {
        // A quarter of the card each, whatever the number of cameras, centered under the picture.
        HStack(spacing: 6) {
          ForEach(presentation.cameras.prefix(4)) { camera in thumbnail(camera).frame(width: thumbnailWidth) }
        }
        .frame(maxWidth: .infinity)
      }
      // Only the two-picture layout has nothing on it that says whether a meeting uses Ultracam.
      if twoUp && !showsPlaceholder {
        Text(presentation.outputSummary)
          .font(.uiMeta)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .padding(.horizontal, 2)
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .frame(width: width)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Ultracam preview")
  }

  private var thumbnailWidth: CGFloat { ((width - 24 - 6 * 3) / 4).rounded(.down) }

  private var showsPlaceholder: Bool { !presentation.camerasRunning && !(waiting && showLive) }
  /// Two small pictures side by side while no meeting uses either camera.
  private var twoUp: Bool { session.cameras.count >= 2 && !presentation.outputInUse }

  private var placeholder: some View {
    UIColumnPictureLayout { RoundedRectangle(cornerRadius: 10).fill(Color.black) }
      .overlay {
        VStack(spacing: 6) {
          Image(systemName: waiting ? UISymbol.waitingCamera : UISymbol.camera).font(.system(size: 26, weight: .light))
          Text(waiting ? "Waiting to start" : presentation.cameras.count == 1 ? "Camera stopped" : "Cameras stopped")
            .font(.callout.weight(.semibold))
          Text(waiting ? "Starts when a meeting app opens Ultracam." : "Start the camera to see its picture.")
            .font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
      }
      .accessibilityElement(children: .combine)
  }

  private var programPicture: some View {
    // Sized from the card's width, so the picture fills it at 16:9 whatever the native preview's own size.
    // Compact, as the camera thumbnails: the window's Program picture brings its monitor tool
    // bar (which covered the tally badge here) and its scopes, and shares Clean View state.
    UIColumnPictureLayout { pictures.picture(cameraID: MonitorFeedHost.programTarget, compact: true) }
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(programTally.ringColor ?? .clear, lineWidth: 3))
      .overlay(alignment: .topLeading) { Label("Ultracam · Program", systemImage: UISymbol.program).font(.uiCompactOverlay).uiPictureOverlay().padding(7) }
      .overlay(alignment: .topTrailing) { UITallyBadge(tally: programTally).padding(7) }
      .overlay(alignment: .bottomLeading) {
        if let onAir = session.cameras.first(where: { $0.id == session.onAirID }) {
          Text(onAir.name).font(.uiCompactOverlay).uiPictureOverlay().padding(7)
        }
      }
      .overlay(alignment: .bottomTrailing) { recPill(for: recordingCameras).padding(7) }
  }

  private var programTally: UITally {
    session.cameras.first { $0.id == session.onAirID }.map { UIPresentationBuilder.tally(for: $0, in: session) } ?? .none
  }

  private func cameraPicture(_ camera: UICameraPresentation) -> some View {
    UIColumnPictureLayout { pictures.picture(cameraID: camera.id, compact: true) }
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(camera.tally.ringColor ?? .clear, lineWidth: 3))
      .overlay(alignment: .topLeading) { Text("Ultracam · \(camera.name)").font(.uiCompactOverlay).uiPictureOverlay().padding(7) }
      .overlay(alignment: .topTrailing) { UITallyBadge(tally: camera.tally).padding(7) }
      .overlay(alignment: .bottomLeading) {
        HStack(spacing: 6) {
          UILiveAudioMeter(cameraID: camera.id, name: camera.name, audio: camera.audio,
            style: .compact)
            .uiPictureOverlay()
        }
        .padding(7)
      }
      .overlay(alignment: .bottomTrailing) {
        recPill(for: session.cameras.filter { $0.id == camera.id && ($0.recording.status == .recording || $0.recording.status == .paused) })
          .padding(7)
      }
  }

  private func miniPicture(_ camera: UICameraPresentation) -> some View {
    UIColumnPictureLayout { pictures.picture(cameraID: camera.id, compact: true) }
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(alignment: .topLeading) { Text(camera.name).font(.uiCompactOverlay).uiPictureOverlay().padding(5) }
      .overlay(alignment: .bottomTrailing) {
        recPill(for: session.cameras.filter { $0.id == camera.id && ($0.recording.status == .recording || $0.recording.status == .paused) })
          .padding(5)
      }
  }

  /// Program thumbnails show tally only; cutting happens from the menu rows.
  private func thumbnail(_ camera: UICameraPresentation) -> some View {
    UIColumnPictureLayout { pictures.picture(cameraID: camera.id, compact: true) }
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(camera.tally.ringColor ?? .clear, lineWidth: 2.5))
      // The number only: the ring and the row's subtitle carry the state.
      .overlay(alignment: .bottomLeading) {
        Text("\(camera.number)").font(.uiCompactOverlay.monospacedDigit()).uiPictureOverlay().padding(4)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(camera.accessibilityLabel)
  }

  @ViewBuilder private func recPill(for cameras: [UICameraSnapshot]) -> some View {
    if !cameras.isEmpty {
      let paused = cameras.allSatisfy { $0.recording.status == .paused }
      UIPictureStatePill(style: paused ? .paused : .recording, count: cameras.count,
        elapsed: UIFormat.shortElapsed(cameras.map(\.recording.elapsed).max() ?? 0), compact: true)
    }
  }
}
