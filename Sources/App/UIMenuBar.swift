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
//                                  inputs: [UIInput],
//                                  stats: String?,
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
  private var sampler = AppResourceSampler()
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
    _ = sampler.sample()
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
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true }) {
      window.makeKeyAndOrderFront(nil)
    } else if let openWindow {
      openWindow(id)
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  private func showSettings() {
    if let openSettings { openSettings() }
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
  }

  func menuDidClose(_ menu: NSMenu) {
    menuOpen = false
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
    let items = Self.buildItems(presentation: presentation, session: session,
      inputs: model.devices.map { UIInput(id: $0.id, name: $0.name) },
      stats: statsLine(session: session), target: self, previewItem: item, showLivePreview: showLivePreview)
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

  private func card(width: CGFloat) -> AnyView {
    AnyView(UIMenuPreviewCard(model: model, interface: interface, showLive: showLivePreview, width: width))
  }

  private func statsLine(session: UISessionSnapshot) -> String {
    let usage = sampler.sample()
    var parts: [String] = []
    parts.append(usage.cpuPercent.map { String(format: "CPU %.0f%%", $0) } ?? "CPU —")
    parts.append(String(format: "GPU %.0f%%", usage.gpuPercent))
    if let memory = usage.memoryBytes {
      parts.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: memory), countStyle: .memory))
    }
    if let drive = session.drives.first, let left = drive.secondsLeft {
      parts.append("\(drive.name) \(UIFormat.duration(left)) left")
    } else if let drive = session.drives.first, UIPresentationBuilder.isFull(drive) {
      parts.append("\(drive.name) full")
    }
    return parts.joined(separator: " · ")
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
    symbol: String? = nil, subtitle: String? = nil, target: AnyObject?) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: commands.isEmpty ? nil : #selector(UIMenuBarController.menuAction(_:)),
      keyEquivalent: key)
    item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
    item.target = commands.isEmpty ? nil : target
    item.representedObject = commands.isEmpty ? nil : UIMenuCommandBox(commands)
    item.state = checked ? .on : .off
    item.isEnabled = enabled
    if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    if let subtitle { item.subtitle = subtitle }
    return item
  }

  private static func action(_ action: UIAction) -> [UIMenuCommand] { [.action(action)] }

  static func buildItems(presentation: UISessionPresentation, session: UISessionSnapshot, inputs: [UIInput],
    stats: String?, target: AnyObject?, previewItem: NSMenuItem?, showLivePreview: Bool = false) -> [NSMenuItem] {
    var items: [NSMenuItem] = []
    if let previewItem { items.append(previewItem) }
    let selected = presentation.selected
    let selectedSnapshot = session.cameras.first { $0.id == session.selectedID }
    let waiting = !presentation.camerasRunning && selectedSnapshot?.automaticStart == true

    // Problems first, in orange, one action each where there is one.
    if let warning = UIPresentationBuilder.warning(session) {
      let banner = NSMenuItem(title: warning, action: nil, keyEquivalent: "")
      banner.attributedTitle = NSAttributedString(string: warning,
        attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.menuFont(ofSize: 0)])
      banner.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
      banner.isEnabled = false
      items.append(banner)
    }
    // A failed automatic start gets one explicit Retry (there is no background retry loop).
    let failedCameras = session.cameras.filter(\.automaticStartFailed)
    for camera in failedCameras {
      let title = failedCameras.count > 1 ? "Retry \(camera.name)" : "Retry Camera Start"
      items.append(row(title, action(.retryAutomaticStart(cameraID: camera.id)), symbol: "arrow.clockwise", target: target))
    }
    if waiting && !showLivePreview {
      items.append(row("Show Live Preview", [.showLivePreview], symbol: "eye", target: target))
    }
    if !items.isEmpty && items.last !== previewItem || previewItem != nil { items.append(.separator()) }

    // Cameras: start/stop, and whether the selected camera starts with meeting apps.
    items.append(row(presentation.camerasControlTitle,
      action(presentation.camerasRunning ? .stopAllCameras : .startAllCameras), key: "\r", modifiers: .command,
      enabled: presentation.canStartAny,
      symbol: presentation.camerasRunning ? "stop.fill" : "play.fill", target: target))
    if let selected, let snapshot = selectedSnapshot {
      items.append(row("Start with Camera Apps", action(.setAutomaticStart(cameraID: selected.id, !snapshot.automaticStart)),
        checked: snapshot.automaticStart, symbol: "wand.and.rays",
        subtitle: presentation.cameras.count > 1 ? selected.name : nil, target: target))
    }

    // Recording. ⌘R records the selected camera, as in the Record menu; ⌥⌘R is for all of them.
    items.append(.separator())
    switch presentation.recordControl {
    case .record(let all, let enabled):
      items.append(row(all ? "Record All" : "Record", action(all ? .recordAll : .toggleRecordingSelected), key: "r",
        modifiers: all ? [.command, .option] : .command, enabled: enabled, symbol: "record.circle", target: target))
    case .stop(let elapsed):
      items.append(row("Stop Recording", action(.stopAllRecordings), key: "r", modifiers: .command,
        symbol: "stop.circle", subtitle: elapsed, target: target))
    case .stopAll(let count, let elapsed):
      items.append(row("Stop All Recordings (\(count))", action(.stopAllRecordings), key: "r",
        modifiers: [.command, .option], symbol: "stop.circle", subtitle: elapsed, target: target))
    }

    // Program: cut rows (thumbnails never cut), automatic switching, hold.
    if presentation.outputMode == .program {
      items.append(.separator())
      for button in presentation.cutButtons {
        let title = "Cut to \(button.name)"
        let subtitle = button.onAir ? UITally.onAir.label : button.pending ? UITally.next.label : nil
        items.append(row(title, action(.cut(cameraID: button.id)), key: button.number <= 4 ? "\(button.number)" : "",
          modifiers: .control, checked: button.onAir, enabled: button.enabled && !button.onAir,
          symbol: "tv", subtitle: subtitle, target: target))
      }
      let auto = row("Automatic Switching", action(.setAutoSwitching(!presentation.autoSwitching)), key: "a",
        modifiers: [.control, .option], checked: presentation.autoSwitching, enabled: presentation.canAutoSwitch,
        symbol: "wand.and.stars", target: target)
      if !presentation.canAutoSwitch { auto.toolTip = "Choose a switching strategy in Program › Strategy first." }
      items.append(auto)
      items.append(row("Hold Current Shot", action(.setAutoHold(!session.autoHold)), checked: session.autoHold,
        enabled: presentation.canHoldShot, target: target))
    }

    // Cameras: processing and preview for the selected camera, then one submenu per camera.
    if !presentation.cameras.isEmpty {
      items.append(.separator())
      if presentation.cameras.count > 1 { items.append(NSMenuItem.sectionHeader(title: "Cameras")) }
      if let selected {
        items.append(row("Processing", action(.setProcessing(cameraID: selected.id, !selected.processing)), key: "b",
          modifiers: [.command, .shift], checked: selected.processing, symbol: "square.stack.3d.up",
          subtitle: presentation.cameras.count > 1 ? selected.name : nil, target: target))
        if let snapshot = selectedSnapshot {
          items.append(row("Video Preview", action(.setPreviewEnabled(cameraID: selected.id, !snapshot.previewEnabled)),
            key: "p", modifiers: [.command, .shift], checked: snapshot.previewEnabled, symbol: "eye", target: target))
        }
      }
      for camera in presentation.cameras {
        items.append(cameraItem(camera, presentation: presentation, session: session, inputs: inputs, target: target))
      }
    }

    // App, with Quit last.
    items.append(.separator())
    let reveal = row("Show Recordings in Finder", action(.revealRecordings), enabled: presentation.canRevealRecordings,
      symbol: "folder", target: target)
    if !presentation.canRevealRecordings { reveal.toolTip = "Choose a recording folder first." }
    items.append(reveal)
    items.append(row("Open Ultracam", action(.openMainWindow), key: "0", modifiers: .command, symbol: "macwindow", target: target))
    items.append(row("Settings…", action(.openSettings), key: ",", modifiers: .command, symbol: "gearshape", target: target))
    items.append(.separator())
    if let stats {
      // A footnote, not a command: small secondary text.
      let item = NSMenuItem(title: stats, action: nil, keyEquivalent: "")
      item.attributedTitle = NSAttributedString(string: stats, attributes: [
        .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
      item.isEnabled = false
      items.append(item)
    }
    items.append(row("Quit Ultracam", action(.quit), key: "q", modifiers: .command, target: target))
    return items
  }

  private static func cameraItem(_ camera: UICameraPresentation, presentation: UISessionPresentation,
    session: UISessionSnapshot, inputs: [UIInput], target: AnyObject?) -> NSMenuItem {
    var status: [String] = []
    if let label = camera.tally.label { status.append(label) }
    switch camera.stripState {
    case .recording, .updating: status.append("REC \(UIFormat.shortElapsed(session.cameras.first { $0.id == camera.id }?.recording.elapsed ?? 0))")
    case .recordingNoSignal: status.append("Recording, no signal")
    case .paused: status.append("Paused")
    case .failed: status.append(camera.recordTitle)
    case .noFolder: status.append("No folder")
    // "Stopped", "Couldn't start" or "Input missing", as on the camera's own badge.
    case .stopped, .waiting: status.append(camera.statusBadge)
    default: if camera.tileState == .live { status.append("Live") }
    }
    let item = NSMenuItem(title: camera.name, action: nil, keyEquivalent: "")
    item.subtitle = status.joined(separator: " · ")
    item.image = NSImage(systemSymbolName: camera.tally == .onAir ? "video.fill" : "video", accessibilityDescription: nil)
    let submenu = NSMenu(title: camera.name)
    submenu.autoenablesItems = false
    let isTaking = camera.recordButtonActive || camera.pauseTitle == "Resume"
    submenu.addItem(row(isTaking ? "Stop Recording" : "Record", action(.toggleRecording(cameraID: camera.id)),
      enabled: camera.recordButtonEnabled, symbol: isTaking ? "stop.circle" : "record.circle", target: target))
    if let pause = camera.pauseTitle {
      submenu.addItem(row(pause == "Pause" ? "Pause Recording" : "Resume Recording",
        action(.pauseOrResume(cameraID: camera.id)), symbol: pause == "Pause" ? "pause" : "play", target: target))
    }
    if presentation.outputMode == .program && camera.showsCut {
      submenu.addItem(row("Cut to \(camera.name)", action(.cut(cameraID: camera.id)), key: "",
        modifiers: .control, enabled: camera.cutEnabled, symbol: "tv", target: target))
    }
    submenu.addItem(.separator())
    submenu.addItem(row("Processing", action(.setProcessing(cameraID: camera.id, !camera.processing)),
      checked: camera.processing, target: target))
    let effects = NSMenu(title: "Effects")
    effects.autoenablesItems = false
    for chip in camera.chips {
      effects.addItem(row("\(chip.id + 1) · \(UIPresentationBuilder.effectLongTitles[chip.id])",
        action(.setEffect(cameraID: camera.id, index: chip.id, !chip.isOn)), checked: chip.isOn,
        enabled: chip.enabled, target: target))
    }
    let effectsItem = NSMenuItem(title: "Effects", action: nil, keyEquivalent: "")
    effectsItem.subtitle = "\(camera.chips.filter(\.isOn).count) of \(camera.chips.count)"
    effectsItem.submenu = effects
    submenu.addItem(effectsItem)
    submenu.addItem(row("Load LUT…", action(.chooseLUT(cameraID: camera.id)), symbol: "cube", target: target))
    let inputMenu = NSMenu(title: "Input")
    inputMenu.autoenablesItems = false
    let cameraSnapshot = session.cameras.first { $0.id == camera.id }
    let running = cameraSnapshot?.running == true
    let inputID = cameraSnapshot?.inputID
    // By ID, as in the inspector: an input another camera has is disabled and says which.
    inputMenu.addItem(row("None", action(.setInput(cameraID: camera.id, deviceID: "")),
      checked: inputID == nil, enabled: !running, target: target))
    inputMenu.addItem(.separator())
    let options = UIInputLabels.options(inputs.map { ($0.id, $0.name) }, cameras: session.cameras, for: camera.id)
    for option in options {
      inputMenu.addItem(row(option.label, action(.setInput(cameraID: camera.id, deviceID: option.id)),
        checked: option.id == inputID, enabled: !running && (option.usedBy == nil || option.id == inputID),
        subtitle: option.usedBy.map { "Used by \($0)" }, target: target))
    }
    if let inputID, !options.contains(where: { $0.id == inputID }) {
      inputMenu.addItem(row(camera.inputName, [], checked: true, enabled: false, subtitle: "Disconnected", target: target))
    } else if inputs.isEmpty {
      let none = NSMenuItem(title: "No inputs detected", action: nil, keyEquivalent: "")
      none.isEnabled = false
      inputMenu.addItem(none)
    }
    inputMenu.addItem(.separator())
    inputMenu.addItem(row("Refresh Inputs", action(.refreshInputs), target: target))
    let inputItem = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
    inputItem.subtitle = camera.inputName
    inputItem.submenu = inputMenu
    if running { inputItem.toolTip = "Stop the camera to change its input." }
    submenu.addItem(inputItem)
    submenu.addItem(.separator())
    submenu.addItem(row("Show Inspector", [.action(.showInspector(cameraID: camera.id)), .action(.openMainWindow)],
      symbol: "sidebar.right", target: target))
    submenu.addItem(camera.canStop
      ? row("Stop \(camera.name)", action(.stopCamera(cameraID: camera.id)), symbol: "stop.fill", target: target)
      : row("Start \(camera.name)", action(.startCamera(cameraID: camera.id)), enabled: camera.canStart,
        symbol: "play.fill", target: target))
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
        } else if presentation.outputMode == .program {
          programPicture
        } else if twoUp {
          HStack(spacing: 6) {
            ForEach(presentation.cameras.prefix(2)) { camera in miniPicture(camera) }
          }
        } else if let shown = presentation.previewCamera {
          cameraPicture(shown)
        }
      }
      if presentation.outputMode == .program && presentation.camerasRunning {
        // A quarter of the card each, whatever the number of cameras, centered under the picture.
        HStack(spacing: 6) {
          ForEach(presentation.cameras.prefix(4)) { camera in thumbnail(camera).frame(width: thumbnailWidth) }
        }
        .frame(maxWidth: .infinity)
      }
      // Only the two-picture layout has nothing on it that says whether a meeting uses Ultracam.
      if twoUp && !showsPlaceholder {
        Text(presentation.outputSummary)
          .font(.subheadline)
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
  private var twoUp: Bool { presentation.outputMode == .separate && session.cameras.count >= 2 && !presentation.outputInUse }

  private var placeholder: some View {
    UIColumnPictureLayout { RoundedRectangle(cornerRadius: 10).fill(Color.black) }
      .overlay {
        VStack(spacing: 6) {
          Image(systemName: "video").font(.system(size: 26, weight: .light))
          Text(waiting ? "Waiting to start" : presentation.cameras.count == 1 ? "Camera stopped" : "Cameras stopped")
            .font(.callout.weight(.semibold))
          Text(waiting ? "Starts when a meeting app opens Ultracam." : "Start the camera to see its HDMI input.")
            .font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
      }
      .accessibilityElement(children: .combine)
  }

  private var programPicture: some View {
    // Sized from the card's width, so the picture fills it at 16:9 whatever the native preview's own size.
    UIColumnPictureLayout { pictures.programPicture() }
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(alignment: .topLeading) { Label("Ultracam · Program", systemImage: "tv").font(.caption.weight(.semibold)).uiPictureOverlay().padding(7) }
      .overlay(alignment: .topTrailing) { UITallyBadge(tally: session.programInUse ? .onAir : .program).padding(7) }
      .overlay(alignment: .bottomLeading) {
        Text(session.cameras.first { $0.id == session.onAirID }?.timecode ?? "—").font(.caption.monospacedDigit().weight(.semibold))
          .uiPictureOverlay().padding(7)
      }
      .overlay(alignment: .bottomTrailing) { recPill(for: recordingCameras).padding(7) }
  }

  private func cameraPicture(_ camera: UICameraPresentation) -> some View {
    UIColumnPictureLayout { pictures.picture(cameraID: camera.id, compact: true) }
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(camera.tally.ringColor ?? .clear, lineWidth: 3))
      .overlay(alignment: .topLeading) { Text("Ultracam · \(camera.name)").font(.caption.weight(.semibold)).uiPictureOverlay().padding(7) }
      .overlay(alignment: .topTrailing) { UITallyBadge(tally: camera.tally).padding(7) }
      .overlay(alignment: .bottomLeading) {
        HStack(spacing: 6) {
          Text(camera.timecode).font(.caption.monospacedDigit().weight(.semibold)).uiPictureOverlay()
          UILiveAudioMeter(cameraID: camera.id, name: camera.name, timecode: camera.timecode, audio: camera.audio,
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
      .overlay(alignment: .bottomLeading) { Text(camera.name).font(.caption2.weight(.semibold)).uiPictureOverlay().padding(5) }
      .overlay(alignment: .topLeading) {
        recPill(for: session.cameras.filter { $0.id == camera.id && ($0.recording.status == .recording || $0.recording.status == .paused) })
          .padding(5)
      }
  }

  /// Program thumbnails show tally only; cutting happens from the menu rows.
  private func thumbnail(_ camera: UICameraPresentation) -> some View {
    UIColumnPictureLayout { pictures.picture(cameraID: camera.id, compact: true) }
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(camera.tally.ringColor ?? .clear, lineWidth: 2.5))
      .overlay(alignment: .bottomLeading) {
        Text(camera.tally == .onAir ? "\(camera.number) · on air" : camera.tally == .next ? "\(camera.number) · next" : "\(camera.number)")
          .font(.caption2.weight(.semibold)).uiPictureOverlay().padding(4)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(camera.accessibilityLabel)
  }

  @ViewBuilder private func recPill(for cameras: [UICameraSnapshot]) -> some View {
    if !cameras.isEmpty {
      let paused = cameras.allSatisfy { $0.recording.status == .paused }
      let elapsed = UIFormat.shortElapsed(cameras.map(\.recording.elapsed).max() ?? 0)
      HStack(spacing: 5) {
        if paused { Image(systemName: "pause.fill").foregroundStyle(.orange) }
        else { Circle().fill(.red).frame(width: 7, height: 7) }
        Text(paused ? "Paused \(elapsed)" : (cameras.count > 1 ? "REC \(cameras.count) · \(elapsed)" : "REC \(elapsed)"))
          .font(.caption.monospacedDigit().weight(.semibold))
      }
      .uiPictureOverlay()
      .accessibilityElement(children: .combine)
    }
  }
}
