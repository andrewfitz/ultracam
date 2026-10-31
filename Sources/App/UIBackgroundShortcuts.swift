import Carbon.HIToolbox
import Foundation
import Observation

/// Shortcuts that reach Ultracam while a meeting app is in front: ⌃⌥⌘1 to ⌃⌥⌘7 cut,
/// ⌃⌥⌘A turns Auto on or off, ⌃⌥⌘H holds the shot, ⌃⌥⌘R records. `RegisterEventHotKey`
/// needs no Accessibility permission, and the meeting app doesn't get the keystroke. Off by
/// default: Settings › General has the one switch. 8 is skipped, which macOS has used for
/// inverting colors.
enum UIBackgroundShortcut: Hashable, Sendable {
  case cut(Int)
  case auto
  case hold
  case record

  static let all: [UIBackgroundShortcut] = (1...7).map { .cut($0) } + [.auto, .hold, .record]

  /// The key with ⌃⌥⌘, as Help and Settings write it.
  var title: String {
    switch self {
    case .cut(let number): return "⌃⌥⌘\(number)"
    case .auto: return "⌃⌥⌘A"
    case .hold: return "⌃⌥⌘H"
    case .record: return "⌃⌥⌘R"
    }
  }

  fileprivate var keyCode: Int {
    switch self {
    case .cut(let number): return [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7][number - 1]
    case .auto: return kVK_ANSI_A
    case .hold: return kVK_ANSI_H
    case .record: return kVK_ANSI_R
    }
  }

  /// What the key does now. Record only ever starts: a stray chord must never end a take, so
  /// it rolls every camera that can and leaves the others alone.
  @MainActor func actions(in presentation: UISessionPresentation) -> [UIAction] {
    switch self {
    case .cut(let number):
      // The camera the strip and toolbar number so, in their order, when it can take a cut.
      guard presentation.programAvailable, presentation.cameras.indices.contains(number - 1) else { return [] }
      let camera = presentation.cameras[number - 1]
      return camera.cutEnabled ? [.cut(cameraID: camera.id)] : []
    case .auto:
      return presentation.canAutoSwitch ? [.setAutoSwitching(!presentation.autoSwitching)] : []
    case .hold:
      guard presentation.canHoldShot else { return [] }
      return [.setAutoHold(!presentation.autoHoldOn)]
    case .record:
      return presentation.cameras.filter { $0.recordButtonEnabled && !$0.recordButtonActive && $0.pauseTitle == nil }
        .map { .toggleRecording(cameraID: $0.id) }
    }
  }
}

/// The switch and the registrations behind it. Settings › General binds `enabled`.
@MainActor @Observable final class UIBackgroundShortcuts {
  static let enabledKey = "ui.backgroundShortcuts"
  private let defaults: UserDefaults
  /// Runs a shortcut's actions; the app hands it the bridge.
  @ObservationIgnored var perform: (@MainActor (UIBackgroundShortcut) -> Void)?
  var enabled: Bool {
    didSet {
      defaults.set(enabled, forKey: Self.enabledKey)
      if enabled != oldValue { enabled ? register() : unregister() }
    }
  }
  /// Chords another app already holds, so the switch can say which didn't register.
  private(set) var unavailable: [UIBackgroundShortcut] = []

  @ObservationIgnored private let carbon: UIHotKeyRegistration
  /// Chords registered now: every one the switch could get while it's on, none while it's off.
  var registeredCount: Int { carbon.hotKeys.count }
  /// The Carbon handler is installed: only while chords are registered.
  var handlerInstalled: Bool { carbon.handler != nil }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    carbon = UIHotKeyRegistration()
    enabled = defaults.bool(forKey: Self.enabledKey)
    carbon.owner = self
  }

  /// Registers the chords when the switch is on. Call once the app has launched.
  func start() { if enabled { register() } }

  private func register() {
    guard carbon.hotKeys.isEmpty else { return }
    carbon.installHandler()
    var missing: [UIBackgroundShortcut] = []
    for (index, shortcut) in UIBackgroundShortcut.all.enumerated() {
      var ref: EventHotKeyRef?
      let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(controlKey | optionKey | cmdKey),
        EventHotKeyID(signature: uiHotKeySignature, id: UInt32(index)), GetApplicationEventTarget(), 0, &ref)
      if status == noErr, let ref { carbon.hotKeys.append(ref) } else { missing.append(shortcut) }
    }
    unavailable = missing
  }

  private func unregister() {
    carbon.removeAll()
    unavailable = []
  }

  fileprivate func pressed(_ index: Int) {
    guard UIBackgroundShortcut.all.indices.contains(index) else { return }
    perform?(UIBackgroundShortcut.all[index])
  }
}

/// Ultracam's chords, so a hot key another part of the process registers isn't taken for one.
private let uiHotKeySignature: OSType = 0x5543_414D  // "UCAM"

/// The Carbon side of the switch. It goes with its owner: the handler and chords are removed
/// then, so nothing calls into a freed object, and the handler reaches the owner only weakly.
private final class UIHotKeyRegistration: @unchecked Sendable {
  weak var owner: UIBackgroundShortcuts?
  var handler: EventHandlerRef?
  var hotKeys: [EventHotKeyRef] = []

  func installHandler() {
    guard handler == nil else { return }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
      guard let event, let userData else { return OSStatus(eventNotHandledErr) }
      var id = EventHotKeyID()
      let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
      guard status == noErr else { return status }
      guard id.signature == uiHotKeySignature else { return OSStatus(eventNotHandledErr) }
      let index = Int(id.id)
      let registration = Unmanaged<UIHotKeyRegistration>.fromOpaque(userData).takeUnretainedValue()
      // Carbon calls on the main thread, from the main event loop.
      MainActor.assumeIsolated { registration.owner?.pressed(index) }
      return noErr
    }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }

  func removeAll() {
    hotKeys.forEach { UnregisterEventHotKey($0) }
    hotKeys = []
    if let handler { RemoveEventHandler(handler) }
    handler = nil
  }

  deinit { removeAll() }
}
