import AppKit
import MonitorKitAudio
import SwiftUI

/// The level meters on a live tap. Every fixture render shows the status-peak
/// fallback, so these render the live `LevelMeterView(meter:)` and
/// `AudioMeterView` paths with an over latched, check VoiceOver reads the
/// meter, and check each view attaches once and detaches when it goes away
/// (the collapsed strip's `ViewThatFits` included).
@MainActor enum AudioMeterViewsVerify {
  static func run(verifier: Verifier, recording: UISessionSnapshot, saved: UISessionSnapshot,
    render: (String, AnyView, CGSize) -> Void) {
    let tap = AudioMeterTap()
    // Held for the whole run, so the views share one session fed before they appear.
    tap.attach()
    AudioMeterTapVerify.feed(tap, AudioMeterTapVerify.sine(dBFS: -0.3, phase: 0), times: 12)
    AudioMeterTapVerify.feed(tap, AudioMeterTapVerify.sine(dBFS: -14, phase: 0), times: 8)
    verifier.check("live meter: the fed over latched", tap.meter?.snapshot().isOver() == true)
    let source = UIAudioMeterSource { _ in tap }

    func live(_ view: some View) -> AnyView { AnyView(view.environment(\.uiAudioMeters, source)) }
    let context = UIContext.fixture(recording)
    guard let camera = context.presentation.cameras.first else {
      return verifier.check("live meter: recording fixture has a camera", false)
    }
    var collapsedSession = recording
    collapsedSession.collapsed = [camera.id]
    guard let collapsedCamera = UIContext.fixture(collapsedSession).presentation.cameras.first else { return }

    render("strip-live-meter", live(UIChannelStripView(camera: camera, context: context)), CGSize(width: 560, height: 230))
    // The narrowest the strip gets beside a picture: the readouts and OVER must not clip.
    render("strip-live-meter-narrow", live(UIChannelStripView(camera: camera, context: context)),
      CGSize(width: 400, height: 250))
    render("strip-live-meter-collapsed",
      live(UIChannelStripView(camera: collapsedCamera, context: UIContext.fixture(collapsedSession))),
      CGSize(width: 560, height: 52))
    let presentation = UIPresentationBuilder.session(recording)
    render("menubar-preview-live-meter", live(UIMenuPreviewContent(presentation: presentation, session: recording,
      pictures: UIFixturePictures(), showLive: true).fixedSize(horizontal: false, vertical: true)),
      CGSize(width: UIMenuPreviewContent.minimumWidth, height: 330))
    let audio = UIStatusSegment(kind: .audio, text: "Audio", tone: .neutral)
    render("popover-audio-live", live(UIStatusPopover(kind: .audio, segment: audio, context: context)),
      CGSize(width: 340, height: 360))
    render("popover-audio", AnyView(UIStatusPopover(kind: .audio, segment: audio, context: context)),
      CGSize(width: 340, height: 360))
    let take = UIStatusSegment(kind: .recording, text: "Recording", tone: .critical)
    render("popover-recording", AnyView(UIStatusPopover(kind: .recording, segment: take, context: context)),
      CGSize(width: 340, height: 220))
    if let savedCamera = UIContext.fixture(saved).presentation.cameras.first {
      verifier.check("take audio: a saved take with an over warns",
        savedCamera.recordingNote?.contains("1 over") == true, savedCamera.recordingNote ?? "no note")
    }
    verifier.check("take audio: a clean take shows no warning", camera.recordingNote == nil &&
      camera.takeAudioHelp?.hasPrefix("This take so far: Audio −23.4 LUFS") == true, camera.takeAudioHelp ?? "no help")
    verifier.check("live meter: closed views detached", tap.viewerCount == 1, "\(tap.viewerCount) viewers")

    // Open views: each meter attaches once; VoiceOver reads the camera's meter with its numbers.
    for (name, view, size) in [
      ("expanded", live(UIChannelStripView(camera: camera, context: context)), CGSize(width: 560, height: 230)),
      ("collapsed", live(UIChannelStripView(camera: collapsedCamera, context: UIContext.fixture(collapsedSession))),
        CGSize(width: 560, height: 52)),
    ] {
      let hosted = HostedView(view, size: size, dark: false)
      hosted.settle(0.3)
      verifier.check("live meter: the \(name) strip attaches once", tap.viewerCount == 2, "\(tap.viewerCount) viewers")
      // The harness reads SwiftUI's labels but not its AX values (a plain
      // `.accessibilityValue` reads nil here too), so the numbers are checked
      // through the compact meter's tooltip, which carries the same summary.
      let meter = Accessibility.nodes(in: hosted.host).first { $0.label == "Camera 1 audio" }
      verifier.check("live meter: VoiceOver finds the \(name) strip's meter", meter != nil, "no \"Camera 1 audio\" element",
        viewDependent: true)
      if name == "collapsed" {
        let help = meter.flatMap { $0.object.value(forKey: "accessibilityHelp") as? String } ?? ""
        verifier.check("live meter: the compact meter's tooltip reads the maxima and the over",
          help.hasPrefix("Camera 1: left max ") && help.contains("dBTP") && help.hasSuffix("over"), help, viewDependent: true)
      }
      hosted.close()
      MainLoop.run(seconds: 0.05)
      verifier.check("live meter: the \(name) strip detaches when closed", tap.viewerCount == 1, "\(tap.viewerCount) viewers")
    }
    tap.detach()
    verifier.check("live meter: nothing meters once every view is gone", !tap.isMetering)
  }
}
