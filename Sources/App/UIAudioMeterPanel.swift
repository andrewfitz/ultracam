import AppKit
import MonitorKitAudio
import MonitorKitUI
import SwiftUI

/// Finds a camera's broadcast audio meters. The app looks up the camera's
/// existing capture (never creating one); fixtures and previews have none and
/// show the plain level meter instead.
@MainActor struct UIAudioMeterSource {
  let tap: @MainActor (_ cameraID: String) -> AudioMeterTap?
  /// Channels Shown from a meter's right-click menu. Here rather than on each meter, so a
  /// meter's inputs stay comparable and a strip's update doesn't redraw it.
  var choose: (@MainActor (_ cameraID: String, UIChannelsShown) -> Void)? = nil
}

private struct UIAudioMeterSourceKey: EnvironmentKey {
  static let defaultValue: UIAudioMeterSource? = nil
}

extension EnvironmentValues {
  var uiAudioMeters: UIAudioMeterSource? {
    get { self[UIAudioMeterSourceKey.self] }
    set { self[UIAudioMeterSourceKey.self] = newValue }
  }
}

/// A camera's embedded audio on MonitorKit's full broadcast panel: true-peak
/// bars with each channel's maximum and the over latch, the EBU R 128 panel
/// in LUFS (M, S, I, LRA, Max TP, PLR) and phase correlation. One standard
/// meter, no meter-type picker. Without a live meter (fixtures, previews) the
/// camera's status peaks stand in on the same scale.
struct UIAudioMeterPanel: View {
  let cameraID: String
  var name: String? = nil
  /// The camera's status levels: whether audio is present, and the fallback readings.
  let levels: UIAudioLevels
  @Environment(\.uiAudioMeters) private var source

  var body: some View {
    Group {
      if let tap = source?.tap(cameraID) {
        // A new capture (camera removed and added again) is a new tap: a new view pairs attach and detach.
        UIAudioMeterTapView(tap: tap, present: levels.present, name: name).id(tap.identity)
      } else {
        LevelMeterView(snapshot: levels.meterSnapshot, style: .full, present: levels.present, name: name,
          channelLabels: UIChannelLabels.labels(levels.meterSnapshot.channelCount))
      }
    }
    .frame(height: 210)
  }
}

/// The meters of one tap. Metering runs only while this view is shown, each
/// showing on the meter `attach` hands it (a new one when metering starts).
private struct UIAudioMeterTapView: View {
  let tap: AudioMeterTap
  let present: Bool
  let name: String?
  @State private var attachment: AudioMeterTap.Attachment?
  @State private var displayedMeter: AudioMeter?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Group {
        if let meter = displayedMeter {
          AudioMeterView(meter: meter, channelLabels: UIChannelLabels.labels(meter.configuration.channelCount),
            present: present, name: name).id(ObjectIdentifier(meter))
        } else { Color.clear }
      }
      Text("Click OVER to reset the peaks; right-click to reset loudness. Loudness is measured while shown or recording, and starts over with each take.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .onAppear {
      if attachment == nil { attachment = AudioMeterTap.Attachment(tap: tap) }
      displayedMeter = attachment?.meter
    }
    .task { @MainActor in
      // A declaration changes the meter object, not its normal display-rate
      // readings. Poll identity without invalidating the body while unchanged.
      while !Task.isCancelled {
        let current = attachment?.meter
        if displayedMeter !== current { displayedMeter = current }
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch { return }
      }
    }
    .onDisappear { displayedMeter = nil; attachment?.close(); attachment = nil }
  }
}

/// A camera's level meter (the expanded strip's, the collapsed strip's, the
/// menu bar card's) on MonitorKit's `LevelMeterView`: true peak on the
/// broadcast scale, drawn at the display rate from the camera's live meter
/// while one exists. The status levels, published a few times a second, say
/// whether audio is present and stand in where there's no meter (fixtures,
/// previews, a camera not capturing).
///
/// `channels` limits the bars to the first channels (Settings › Audio's Channels Shown); nil
/// shows every channel. `menu` adds Channels Shown to the meter's right-click menu.
struct UILiveAudioMeter: View {
  let cameraID: String
  let name: String
  let audio: UIAudioLevels
  var style: LevelMeterStyle = .strip
  var channels: UIChannelsShown? = nil
  var menu = false
  @Environment(\.uiAudioMeters) private var source

  var body: some View {
    if let tap = source?.tap(cameraID) {
      // A new capture is a new tap: a new view pairs attach and detach. Only
      // `present` goes in, so the 4 Hz status peaks don't re-evaluate it.
      UILiveAudioMeterTapView(tap: tap, cameraID: cameraID, name: name, present: audio.present, style: style,
        channels: channels, menu: menu)
        .id(tap.identity)
    } else {
      let snapshot = audio.meterSnapshot
      let count = channels?.count(detected: AudioMeterTap.channelsWithSignal(snapshot), available: snapshot.channelCount)
      let shown = count.map { UIAudioMeterSubset.snapshot(snapshot, channels: $0) } ?? snapshot
      LevelMeterView(snapshot: shown, style: style, present: audio.present, name: name,
        channelLabels: UIChannelLabels.labels(shown.channelCount, of: snapshot.channelCount))
    }
  }
}

/// Meters one tap while shown; the tap meters off the capture thread only while a view attaches.
private struct UILiveAudioMeterTapView: View {
  let tap: AudioMeterTap
  let cameraID: String
  let name: String
  let present: Bool
  let style: LevelMeterStyle
  let channels: UIChannelsShown?
  let menu: Bool
  @Environment(\.uiAudioMeters) private var source
  @State private var attachment: AudioMeterTap.Attachment?
  /// Every channel the capture meters.
  @State private var fullMeter: AudioMeter?
  /// What the bars show: the full meter, or the tap's meter of the first channels.
  @State private var displayedMeter: AudioMeter?
  /// A hidden channel that went over, so the strip still lights OVER and names it.
  @State private var hiddenOver: Int?
  private static let silence = AudioMeterTap.snapshot(statusPeaks: [0, 0])

  var body: some View {
    Group {
      if let meter = displayedMeter {
        LevelMeterView(meter: meter, style: style, present: present, name: name,
          channelLabels: UIChannelLabels.labels(meter.configuration.channelCount, of: fullMeter?.configuration.channelCount))
          .id(ObjectIdentifier(meter))
          .overlay(alignment: .bottomTrailing) {
            if let hiddenOver, style == .strip {
              UIHiddenOverLatch(channel: hiddenOver) { resetPeaks() }
            }
          }
          .overlay {
            if menu, let choose = source?.choose, let channels {
              UIMeterContextMenu(shown: channels, resetPeaks: { resetPeaks() }, choose: { [cameraID] in choose(cameraID, $0) })
            }
          }
      } else {
        // Before the first appearance: two silent channels, the live meter's layout.
        LevelMeterView(snapshot: Self.silence, style: style, present: present, name: name)
      }
    }
    .onAppear {
      if attachment == nil { attachment = AudioMeterTap.Attachment(tap: tap) }
      refresh()
    }
    .task(id: channels) { @MainActor in
      // A declaration changes the meter object, not its normal display-rate readings, and
      // As Detected grows while signal arrives. Poll without invalidating the body while unchanged.
      while !Task.isCancelled {
        refresh()
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch { return }
      }
    }
    .onDisappear { displayedMeter = nil; fullMeter = nil; attachment?.close(); attachment = nil }
  }

  /// Follows the session's meter and the channel count, and looks for an over the bars hide.
  private func refresh() {
    let full = attachment?.meter
    if fullMeter !== full { fullMeter = full }
    var shown = full
    var hidden: Int?
    if let full, let channels {
      let count = channels.count(detected: tap.detectedChannels, available: full.configuration.channelCount)
      if let subset = tap.displayMeter(channels: count) {
        shown = subset
        hidden = AudioMeterTap.hiddenOver(full.snapshot(), from: count)
      }
    }
    if displayedMeter !== shown { displayedMeter = shown }
    if hiddenOver != hidden { hiddenOver = hidden }
  }

  private func resetPeaks() {
    fullMeter?.resetPeaks()
    if displayedMeter !== fullMeter { displayedMeter?.resetPeaks() }
  }
}

/// OVER for a channel the strip doesn't show, drawn over the meter's own latch so an over
/// is never hidden. Help names the channel; clicking resets the peaks, as the latch does.
struct UIHiddenOverLatch: View {
  let channel: Int
  let reset: () -> Void

  var body: some View {
    Button(action: reset) {
      Text("OVER")
        .font(.system(size: 9, weight: .heavy))
        .tracking(0.5)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 3).fill(MeterPalette.standard.latch))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("An over on channel \(channel + 1), which this strip doesn't show: a sample clipped or the true peak reached −1 dBTP. Click to reset the peaks.")
    .accessibilityLabel("Over on channel \(channel + 1)")
  }
}

/// A strip meter's subset for fixed readings: the first `channels` of a snapshot.
enum UIAudioMeterSubset {
  static func snapshot(_ snapshot: AudioMeterSnapshot, channels: Int) -> AudioMeterSnapshot {
    guard channels < snapshot.channelCount else { return snapshot }
    var subset = snapshot
    subset.channelCount = channels
    subset.programmeChannelMask &= UInt16(truncatingIfNeeded: (1 << channels) - 1)
    return subset
  }
}

/// The meter's right-click menu with Channels Shown beside Reset Peaks. MonitorKit's meter
/// owns its context menu and takes no items from its host, so this sits over the meter and
/// answers only a right click (or a Control-click); every other event goes through to it.
struct UIMeterContextMenu: NSViewRepresentable {
  let shown: UIChannelsShown
  let resetPeaks: @MainActor () -> Void
  let choose: @MainActor (UIChannelsShown) -> Void

  func makeNSView(context: Context) -> MenuView { MenuView() }

  func updateNSView(_ view: MenuView, context: Context) {
    view.build = { [shown, resetPeaks, choose] in UIMeterContextMenu.menu(shown: shown, resetPeaks: resetPeaks, choose: choose) }
  }

  /// Reset Peaks, then Channels Shown's choices, the current one checked.
  @MainActor static func menu(shown: UIChannelsShown, resetPeaks: @escaping @MainActor () -> Void,
    choose: @escaping @MainActor (UIChannelsShown) -> Void) -> NSMenu {
    let menu = NSMenu()
    menu.addItem(UIClosureMenuItem(title: "Reset Peaks", handler: resetPeaks))
    menu.addItem(.separator())
    let header = NSMenuItem(title: "Channels Shown", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    for choice in UIChannelsShown.allCases {
      let item = UIClosureMenuItem(title: choice.title) { choose(choice) }
      item.state = choice == shown ? .on : .off
      item.indentationLevel = 1
      menu.addItem(item)
    }
    return menu
  }

  final class MenuView: NSView {
    var build: (@MainActor () -> NSMenu)?

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard let event = NSApp.currentEvent else { return nil }
      let secondary = event.type == .rightMouseDown || event.type == .rightMouseUp
        || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
      return secondary ? super.hitTest(point) : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { build?() }
  }
}

/// An `NSMenuItem` that runs a closure.
@MainActor final class UIClosureMenuItem: NSMenuItem {
  private let handler: @MainActor () -> Void

  init(title: String, handler: @escaping @MainActor () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  @objc private func run() { handler() }
}

/// Embedded audio is unlabeled, so anything but a stereo pair is numbered. MonitorKit's
/// default gives 6 and 8 channels surround names, which would be a guess here.
enum UIChannelLabels {
  static func labels(_ count: Int) -> [String]? {
    count == 2 ? nil : (0..<count).map { String($0 + 1) }
  }

  /// The first `count` of a source's `total` channels: numbered unless the source is a pair.
  static func labels(_ count: Int, of total: Int?) -> [String]? {
    guard let total, total != count else { return labels(count) }
    return (0..<count).map { String($0 + 1) }
  }
}

extension UIAudioLevels {
  /// The status peaks as meter readings, for a camera without a live meter.
  var meterSnapshot: AudioMeterSnapshot { AudioMeterTap.snapshot(statusPeaks: channelPeaks ?? [peakLeft, peakRight]) }
}
