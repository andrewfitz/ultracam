import AppKit
import CoreMedia
import CoreVideo
import Metal
import MonitorKit
import MonitorKitScopes
import MonitorKitUI
import QuartzCore
import SwiftUI
import XCTest

// W4 (integration map §8.2): MonitorToolsUITests' presenter, freeze, visibility,
// layer colour, out-of-order, scope locality, layout and zoom cases, moved onto the
// app's glue: MonitorSurfacePresenter, MonitorCoordinator and MonitorFeedHost.
// Each case names the MonitorToolsUITests line it replaces. Window and display-link
// cases keep the old rule: a check that needs the link to fire is skipped (or its
// drawn half left out) when the test window never reaches the screen.

/// Keeps the newest delivery a host offers (to forge stamps from a real one).
private final class PortedDeliveryRecorder: MonitorFeedConsumer, @unchecked Sendable {
  private let lock = NSLock()
  private var last: MonitorFeedHost.Delivery?
  func accept(_ delivery: MonitorFeedHost.Delivery) { lock.withLock { last = delivery } }
  var delivery: MonitorFeedHost.Delivery? { lock.withLock { last } }
}

/// Counts the GPU intervals a monitor GPU context reports.
private final class PortedGPUTimingProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var intervals = 0
  var count: Int { lock.withLock { intervals } }
  func record(start: Double, end: Double) { lock.withLock { if end > start { intervals += 1 } } }
}

/// Captures a SwiftUI view's backing NSView, to measure where it landed.
@MainActor private struct PortedLayoutProbe: NSViewRepresentable {
  let capture: (NSView) -> Void
  init(_ capture: @escaping (NSView) -> Void) { self.capture = capture }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    capture(view)
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) { capture(nsView) }
}

extension MonitorCoordinatorChecks {
  private var portedAlpha: MonitorTargetID { MonitorTargetID("alpha") }
  private var portedBeta: MonitorTargetID { MonitorTargetID("beta") }

  /// A coordinator on the shared GPU with two camera targets.
  private func portedCoordinator(feeds: [String] = ["alpha", "beta"]) -> MonitorCoordinator {
    let value = MonitorCoordinator()
    value.updateTargets(
      feeds: feeds.map { FeedDescriptor(id: FeedID(rawValue: $0), name: $0.capitalized) }, programAvailable: false)
    return value
  }

  /// A visible surface of `target`, registered as the interface registers one.
  private func portedSurface(_ value: MonitorCoordinator, _ target: MonitorTargetID)
    -> (presenter: MonitorSurfacePresenter, host: MonitorFeedHost, id: UUID)
  {
    let id = UUID()
    let presenter = value.surface(id: id, target: target)
    value.registerSurface(id: id, target: target, isVisible: true, scopeVisible: false)
    return (presenter, value.captureSink(for: target), id)
  }

  /// A presenter fed by its own host, with no coordinator and no GPU: nothing it
  /// does here builds a GPU core, so it never reports a monitor error.
  private func portedDetachedPresenter() -> (MonitorSurfacePresenter, MonitorFeedHost) {
    let gpu = MonitorGPUContext(device: { nil })
    let host = MonitorFeedHost(target: portedAlpha.rawValue, gpu: gpu)
    let presenter = MonitorSurfacePresenter(target: portedAlpha, host: host, gpu: gpu)
    host.setConsumers([presenter])
    return (presenter, host)
  }

  /// Offers frame `sequence` with a source time of `sequence` seconds.
  private func portedOffer(_ host: MonitorFeedHost, _ sequence: UInt64, generation: UInt64 = 1, _ buffer: CVPixelBuffer) {
    host.offer(
      buffer, pts: CMTime(value: CMTimeValue(sequence), timescale: 1), captureGeneration: generation,
      sequence: sequence)
  }

  private var portedHasGPU: Bool { (try? MonitorCoordinator.sharedGPU.core()) != nil }

  /// Runs the main run loop until `condition` holds or `seconds` pass.
  @discardableResult
  private func portedWait(_ seconds: Double = 3, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    return condition()
  }

  /// A titled test window around `view`, ordered on screen (whether the window
  /// server shows it is up to the session).
  private func portedWindow(_ view: NSView, size: NSSize, style: NSWindow.StyleMask = [.titled]) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Synthetic monitor surface fixture"
    window.contentView = view
    window.orderFrontRegardless()
    return window
  }

  // MARK: Freeze and hold

  /// MonitorToolsUITests:15. A picture view starts as 10-bit Rec.709 SDR, and a
  /// newer frame never replaces a held picture.
  func testFrozenHoldKeepsItsStampWithAPictureView() throws {
    let value = portedCoordinator()
    let (presenter, host, _) = portedSurface(value, portedAlpha)
    let picture = try XCTUnwrap(presenter.makeView() as? MonitorPictureNSView)
    XCTAssertEqual(picture.metalLayer.pixelFormat, .bgr10a2Unorm)
    XCTAssertEqual(picture.metalLayer.colorspace?.name, CGColorSpace.itur_709)
    XCTAssertFalse(picture.metalLayer.wantsExtendedDynamicRangeContent)
    let buffer = try monitorPixelBuffer()
    portedOffer(host, 1, buffer)
    let held = try XCTUnwrap(presenter.currentStamp)
    presenter.setClean(false)
    presenter.toggleFreeze()
    XCTAssertTrue(presenter.isFrozen)
    portedOffer(host, 2, buffer)
    XCTAssertTrue(presenter.isFrozen, "A newer frame never replaces a held picture")
    XCTAssertEqual(presenter.currentStamp, held)
    picture.tearDown()
  }

  /// MonitorToolsUITests:32. Occluded and hidden surfaces say so; a freeze made
  /// while visible stays frozen (and says Frozen) when the surface is occluded.
  func testOcclusionAndHiddenStatusPreserveASuccessfulFreeze() throws {
    let value = portedCoordinator()
    let (presenter, host, _) = portedSurface(value, portedAlpha)
    let buffer = try monitorPixelBuffer()
    portedOffer(host, 1, buffer)
    presenter.setClean(false)
    presenter.reportVisibility(presented: true, drawable: false)
    XCTAssertEqual(presenter.status, "Occluded")
    presenter.reportVisibility(presented: false, drawable: false)
    XCTAssertEqual(presenter.status, "Paused / hidden")
    presenter.reportVisibility(presented: true, drawable: true)
    portedOffer(host, 2, buffer)
    presenter.setClean(false)
    presenter.toggleFreeze()
    let frozen = try XCTUnwrap(presenter.currentStamp)
    XCTAssertEqual(frozen.sequence, 2)
    presenter.reportVisibility(presented: true, drawable: false)
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertEqual(presenter.status, "Frozen")
    XCTAssertEqual(presenter.currentStamp, frozen)
  }

  /// MonitorToolsUITests:254. Freeze and Clean View on one surface keep its held
  /// tools and signal; another surface of the same feed takes the new frame, tools
  /// and signal. After unfreezing, the hold stays until the next live frame.
  func testFreezeAndCleanKeepTheHeldToolsAndLeaveTheOtherSurfaceLive() throws {
    guard portedHasGPU else { throw XCTSkip("No Metal 4 device") }
    let value = portedCoordinator()
    var tools = value.preferences(for: portedAlpha)
    tools.toolsEnabled = true
    tools.state.guides.enabled = true
    tools.signal = MonitorSignalDeclaration(logProfileID: "sony-slog3-sgamut3cine")
    value.setPreferences(tools, for: portedAlpha)
    let (first, host, firstID) = portedSurface(value, portedAlpha)
    let (second, _, _) = portedSurface(value, portedAlpha)
    let native = first.makeView()
    native.frame = NSRect(x: 0, y: 0, width: 160, height: 90)
    let buffer = try monitorPixelBuffer(width: 64, height: 36)
    portedOffer(host, 1, buffer)
    first.toggleFreeze()
    value.registerSurface(id: firstID, target: portedAlpha, isVisible: true, scopeVisible: false)
    first.setClean(true)
    var next = tools
    next.state.guides.thirds = false
    next.signal = MonitorSignalDeclaration()
    value.setPreferences(next, for: portedAlpha)
    portedOffer(host, 2, buffer)
    // An explicit refresh: switching Clean View never replaces a held picture's tools.
    first.setClean(false)
    second.setClean(false)
    XCTAssertTrue(first.isFrozen)
    XCTAssertFalse(second.isFrozen)
    XCTAssertEqual(first.shownPreferences, tools)
    XCTAssertEqual(first.shownSignal?.encoding.log?.curve, .sLog3, "The hold keeps the S-Log3 reading it was frozen with")
    XCTAssertEqual(second.shownPreferences, next)
    XCTAssertNil(second.shownSignal?.encoding.log, "The other surface reads the new frame as the feed now declares it")
    XCTAssertTrue(first.detail.contains("1.000"), first.detail)
    XCTAssertTrue(second.detail.contains("2.000"), second.detail)
    first.setClean(true)
    XCTAssertTrue(first.isFrozen)
    XCTAssertEqual(first.shownPreferences, tools)
    first.toggleFreeze()
    value.registerSurface(id: firstID, target: portedAlpha, isVisible: true, scopeVisible: false)
    XCTAssertFalse(first.isFrozen)
    // The surface took no frames while frozen: the hold stays until the next one.
    XCTAssertEqual(first.shownPreferences, tools)
    portedOffer(host, 3, buffer)
    first.setClean(false)
    XCTAssertEqual(first.shownPreferences, next)
    XCTAssertEqual(first.currentStamp?.sequence, 3)
    (native as? MonitorPictureNSView)?.tearDown()
  }

  /// MonitorToolsUITests:297. A stopped or missing feed never unfreezes a hold;
  /// once unfrozen, the surface reports why it has no picture.
  func testStaleAvailabilityAndMissingSignalDoNotUnfreezeAHold() throws {
    let value = portedCoordinator()
    let (presenter, host, _) = portedSurface(value, portedAlpha)
    portedOffer(host, 1, try monitorPixelBuffer())
    presenter.setClean(false)
    presenter.toggleFreeze()
    value.sourceStateChanged(target: portedAlpha, running: false, message: "")
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertEqual(presenter.status, "Frozen")
    presenter.toggleFreeze()
    XCTAssertEqual(presenter.status, "Feed stopped")
    value.updateTargets(feeds: [FeedDescriptor(id: FeedID(rawValue: "beta"), name: "Beta")], programAvailable: false)
    XCTAssertEqual(presenter.status, "Missing feed")
    XCTAssertFalse(presenter.isFrozen)
  }

  /// MonitorToolsUITests:347. A pending freeze says so, takes the next frame with
  /// the tools current then, and a cancelled request freezes nothing.
  func testPendingFreezeUsesTheNextAdmittedPictureAndCanCancel() throws {
    let value = portedCoordinator()
    let (presenter, host, _) = portedSurface(value, portedAlpha)
    let buffer = try monitorPixelBuffer()
    portedOffer(host, 1, buffer)
    presenter.requestFreezeOnNextFrame()
    XCTAssertTrue(presenter.isFreezePending)
    XCTAssertFalse(presenter.isFrozen)
    XCTAssertEqual(presenter.status, "Waiting to freeze next picture")
    var next = value.preferences(for: portedAlpha)
    next.toolsEnabled = true
    next.state.guides.enabled = true
    next.state.guides.centerCross = true
    value.setPreferences(next, for: portedAlpha)
    portedOffer(host, 2, buffer)
    presenter.setClean(true)
    XCTAssertFalse(presenter.isFreezePending)
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertEqual(presenter.shownPreferences, next)
    XCTAssertTrue(presenter.detail.contains("2.000"), presenter.detail)
    presenter.toggleFreeze()
    presenter.requestFreezeOnNextFrame()
    presenter.cancelPendingFreeze()
    portedOffer(host, 3, buffer)
    presenter.setClean(false)
    XCTAssertFalse(presenter.isFreezePending)
    XCTAssertFalse(presenter.isFrozen)
    XCTAssertEqual(presenter.currentStamp?.sequence, 3)
  }

  /// MonitorToolsUITests:712. A frozen surface keeps no new frame, and its hold
  /// becomes a GPU copy at once (no window, no display link), so it pins no capture
  /// buffer. A surface that stops being drawable drops its waiting frame, and frames
  /// replaced while hidden are not counted as superseded.
  func testFreezeAndHiddenSurfacesHoldNoCaptureBuffer() throws {
    guard portedHasGPU else { throw XCTSkip("No Metal 4 device") }
    let gpu = MonitorCoordinator.sharedGPU
    let host = MonitorFeedHost(target: portedAlpha.rawValue, gpu: gpu)
    let presenter = MonitorSurfacePresenter(target: portedAlpha, host: host, gpu: gpu)
    host.setConsumers([presenter])
    let buffer = try monitorPixelBuffer(width: 64, height: 36)
    portedOffer(host, 1, buffer)
    presenter.toggleFreeze()
    XCTAssertTrue(presenter.isFrozen)
    portedOffer(host, 2, buffer)
    XCTAssertEqual(presenter.statistics.acceptedFrames, 1, "A frozen surface keeps no new frame")
    XCTAssertEqual(presenter.currentStamp?.sequence, 1)
    XCTAssertTrue(portedWait { !presenter.holdsProducerFrame }, "The GPU copy replaced the capture buffer")
    XCTAssertEqual(presenter.statistics.failures, 0)
    presenter.toggleFreeze()
    presenter.reportVisibility(presented: true, drawable: true)
    portedOffer(host, 3, buffer)
    XCTAssertTrue(presenter.holdsProducerFrame)
    // Hidden: the waiting frame is dropped; frames replaced while the display link
    // is paused are not counted as superseded.
    presenter.reportVisibility(presented: false, drawable: false)
    XCTAssertFalse(presenter.holdsProducerFrame)
    XCTAssertEqual(presenter.status, "Paused / hidden")
    portedOffer(host, 4, buffer)
    portedOffer(host, 5, buffer)
    XCTAssertEqual(presenter.statistics.supersededFrames, 0)
    // Freezing while hidden still swaps the capture buffer for a GPU copy.
    presenter.toggleFreeze()
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertTrue(portedWait { !presenter.holdsProducerFrame }, "A hidden freeze is copied on the GPU too")
    XCTAssertEqual(presenter.currentStamp?.sequence, 5)
    presenter.toggleFreeze()
    presenter.reportVisibility(presented: true, drawable: true)
    portedOffer(host, 6, buffer)
    XCTAssertEqual(presenter.currentStamp?.sequence, 6)
    XCTAssertEqual(presenter.statistics.failures, 0)
  }

  /// MonitorToolsUITests:802. Cancel wins over a pending freeze a frame already
  /// satisfied but the interface has not shown yet; another surface is untouched,
  /// and cancelling never ends a freeze that is already shown.
  func testCancelWinsOverAnAdmittedButUnpublishedPendingFreeze() throws {
    guard portedHasGPU else { throw XCTSkip("No Metal 4 device") }
    let value = portedCoordinator()
    let (presenter, host, _) = portedSurface(value, portedAlpha)
    let (other, otherHost, _) = portedSurface(value, portedBeta)
    presenter.requestFreezeOnNextFrame()
    portedOffer(host, 4, try monitorPixelBuffer())
    portedOffer(otherHost, 5, try monitorPixelBuffer())
    // No main-queue publication ran between the frame and the cancel.
    XCTAssertTrue(presenter.isFreezePending)
    XCTAssertTrue(presenter.holdsFreeze, "The frame already satisfied the request")
    presenter.cancelPendingFreeze()
    presenter.setClean(true)
    other.setClean(false)
    XCTAssertFalse(presenter.isFreezePending)
    XCTAssertFalse(presenter.isFrozen)
    XCTAssertEqual(presenter.currentStamp?.sequence, 4)
    XCTAssertTrue(presenter.detail.contains("4.000"), presenter.detail)
    XCTAssertFalse(other.isFrozen)
    XCTAssertEqual(other.currentStamp?.sequence, 5)
    presenter.toggleFreeze()
    XCTAssertTrue(presenter.isFrozen)
    presenter.cancelPendingFreeze()  // Keeps a freeze that is already shown.
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertEqual(presenter.currentStamp?.sequence, 4)
  }

  /// MonitorToolsUITests:852. Frames that can no longer reach a surface (preview
  /// hidden, a stopped capture generation) neither bring a picture back nor satisfy
  /// a pending freeze; the next current frame does.
  func testInvalidatedFramesCannotResurrectOrSatisfyAPendingFreeze() throws {
    let value = portedCoordinator()
    let (presenter, host, _) = portedSurface(value, portedAlpha)
    let buffer = try monitorPixelBuffer()
    portedOffer(host, 1, buffer)
    value.setPreviewEnabled(false, for: portedAlpha)
    portedOffer(host, 2, buffer)
    XCTAssertNil(presenter.currentStamp)
    XCTAssertEqual(presenter.status, "Preview hidden")
    presenter.requestFreezeOnNextFrame()
    portedOffer(host, 3, buffer)
    XCTAssertTrue(presenter.isFreezePending)
    XCTAssertFalse(presenter.holdsFreeze)
    XCTAssertNil(presenter.currentStamp)
    host.invalidate(rejectingCaptureGeneration: 1)
    value.setPreviewEnabled(true, for: portedAlpha)
    XCTAssertTrue(host.hasConsumers)
    portedOffer(host, 4, buffer)
    XCTAssertTrue(presenter.isFreezePending, "A stopped generation's frame is not the next picture")
    XCTAssertFalse(presenter.holdsFreeze)
    XCTAssertNil(presenter.currentStamp)
    portedOffer(host, 1, generation: 2, buffer)
    presenter.setClean(false)
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertFalse(presenter.isFreezePending)
    XCTAssertEqual(presenter.currentStamp?.sequence, 1)
  }

  // MARK: Out of order

  /// MonitorToolsUITests:828. An older sequence, an older revision, another
  /// target's frame and a retired generation never replace the newest frame, and
  /// an equal stamp is a valid repeat. (MonitorTools' processing revision has no
  /// counterpart: the Output stage is the source plus the LUT in the shader.)
  func testOutOfOrderCompletionCannotRollBackOrChangeTheSurfaceTarget() throws {
    let recorder = PortedDeliveryRecorder()
    let source = MonitorFeedHost(target: portedAlpha.rawValue, gpu: nil)
    source.setConsumers([recorder])
    portedOffer(source, 1, try monitorPixelBuffer())
    let base = try XCTUnwrap(recorder.delivery)
    func delivery(_ sequence: UInt64, revision: UInt64, generation: UInt64? = nil, target: String? = nil)
      -> MonitorFeedHost.Delivery
    {
      var stamp = base.stamp
      stamp.sequence = sequence
      stamp.sourcePTS = Double(sequence)
      stamp.revision = revision
      stamp.hostTime = ProcessInfo.processInfo.systemUptime
      if let generation { stamp.generation = generation }
      if let target { stamp.target = target }
      return MonitorFeedHost.Delivery(
        stamp: stamp, pixelBuffer: base.pixelBuffer, layout: base.layout, signal: base.signal, geometry: base.geometry,
        frameID: base.frameID &+ sequence, isProcessed: base.isProcessed)
    }
    let (presenter, _) = portedDetachedPresenter()
    let newest = delivery(8, revision: 3)
    presenter.accept(newest)
    presenter.accept(delivery(7, revision: 3))
    presenter.accept(delivery(9, revision: 2))
    presenter.accept(delivery(9, revision: 3, target: "other"))
    XCTAssertEqual(presenter.currentStamp, newest.stamp)
    presenter.accept(newest)  // An equal stamp is a valid repeat.
    XCTAssertEqual(presenter.statistics.acceptedFrames, 2)
    presenter.setUnavailable("Feed stopped")
    presenter.accept(delivery(7, revision: 3))
    XCTAssertNil(presenter.currentStamp)
    let restarted = delivery(1, revision: 1, generation: base.stamp.generation + 1)
    presenter.accept(restarted)
    presenter.accept(newest)  // The retired generation cannot return after a restart.
    presenter.setClean(false)
    XCTAssertEqual(presenter.currentStamp, restarted.stamp)
    XCTAssertEqual(presenter.status, "Live")
  }

  // MARK: Visibility and the display link

  /// MonitorToolsUITests:312. Visibility reports reach the owner once per change
  /// and never touch the freeze intent.
  func testVisibilityTransitionsAreIndependentFromFreezeIntent() {
    let (presenter, _) = portedDetachedPresenter()
    var changes: [(Bool, Bool)] = []
    presenter.onVisibilityChange = { changes.append(($0, $1)) }
    presenter.reportVisibility(presented: true, drawable: true)
    presenter.reportVisibility(presented: true, drawable: false)
    presenter.reportVisibility(presented: true, drawable: false)
    presenter.reportVisibility(presented: false, drawable: false)
    XCTAssertEqual(changes.count, 3)
    XCTAssertEqual(changes.map { $0.0 }, [true, true, false])
    XCTAssertEqual(changes.map { $0.1 }, [true, false, false])
    XCTAssertFalse(presenter.isFrozen)
    XCTAssertFalse(presenter.isFreezePending)
  }

  /// MonitorToolsUITests:326. A picture view reports its window, its hidden state
  /// and its window closing; through the coordinator they set the feed's demand.
  func testNativeWindowAttachmentAndHiddenStateReportDemand() {
    let (presenter, _) = portedDetachedPresenter()
    var changes: [(Bool, Bool)] = []
    presenter.onVisibilityChange = { changes.append(($0, $1)) }
    let view = presenter.makeView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 160, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    XCTAssertEqual(changes.last?.0, true)
    XCTAssertEqual(changes.last?.1, false)  // Never ordered on screen.
    view.isHidden = true
    XCTAssertEqual(changes.last?.0, false)
    view.isHidden = false
    XCTAssertEqual(changes.last?.0, true)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    XCTAssertEqual(changes.last?.0, false)
    window.contentView = nil

    // The same view through the coordinator: presented means demand, hidden drops it.
    let value = portedCoordinator()
    var demand: Set<MonitorTargetID> = []
    value.onDemandChange = { demand = $0 }
    let (surface, _, _) = portedSurface(value, portedAlpha)
    XCTAssertEqual(demand, [portedAlpha])
    let attached = surface.makeView()
    let second = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 160, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
    second.isReleasedWhenClosed = false
    second.contentView = attached
    XCTAssertEqual(demand, [portedAlpha], "A presented (even unseen) picture keeps capture demand")
    attached.isHidden = true
    XCTAssertEqual(demand, [], "A hidden picture drops its demand")
    attached.isHidden = false
    XCTAssertEqual(demand, [portedAlpha])
    second.contentView = nil
  }

  /// MonitorToolsUITests:372. A real window: ancestor hide, minimize and close
  /// reach the surface's visibility.
  func testActualWindowMinimizeAncestorHideAndClose() throws {
    let (presenter, _) = portedDetachedPresenter()
    var changes: [(Bool, Bool)] = []
    presenter.onVisibilityChange = { changes.append(($0, $1)) }
    let host = NSHostingView(rootView: MonitorSurfaceVisibility(presenter: presenter))
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
    host.frame = container.bounds
    container.addSubview(host)
    let window = portedWindow(container, size: container.bounds.size, style: [.titled, .closable, .miniaturizable])
    defer {
      window.close()
      window.contentView = nil
    }
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(portedWait { window.isVisible && !changes.isEmpty }, "The window must report its surface")
    XCTAssertEqual(changes.last?.1, window.occlusionState.contains(.visible))
    container.isHidden = true
    XCTAssertEqual(changes.last?.0, false)
    container.isHidden = false
    XCTAssertEqual(changes.last?.0, true)
    XCTAssertEqual(changes.last?.1, window.occlusionState.contains(.visible))
    window.miniaturize(nil)
    if portedWait(until: { window.isMiniaturized }) {
      XCTAssertEqual(changes.last?.0, true)
      XCTAssertEqual(changes.last?.1, false)
      window.deminiaturize(nil)
      XCTAssertTrue(portedWait { !window.isMiniaturized })
      XCTAssertEqual(changes.last?.1, window.isVisible && window.occlusionState.contains(.visible))
    } else {
      print("MONITOR_SURFACE_TEST the window server did not minimize the test window; minimize half not checked")
    }
    window.close()
    XCTAssertEqual(changes.last?.0, false)
    XCTAssertEqual(changes.last?.1, false)
  }

  /// MonitorToolsUITests:750. A picture whose window cannot be seen starts with its
  /// display link paused, and draws once the view becomes drawable.
  func testDisplayLinkStartsPausedWhileTheWindowCannotBeSeen() throws {
    guard portedHasGPU else { throw XCTSkip("No Metal 4 device") }
    let gpu = MonitorCoordinator.sharedGPU
    let host = MonitorFeedHost(target: portedAlpha.rawValue, gpu: gpu)
    let presenter = MonitorSurfacePresenter(target: portedAlpha, host: host, gpu: gpu)
    host.setConsumers([presenter])
    let picture = try XCTUnwrap(presenter.makeView() as? MonitorPictureNSView)
    picture.frame = NSRect(x: 0, y: 0, width: 160, height: 90)
    let window = portedWindow(picture, size: picture.frame.size)
    defer {
      MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = false
      window.close()
      window.contentView = nil
    }
    guard !picture.isDrawable else {
      throw XCTSkip("The test window is visible; the paused start needs an unseen window")
    }
    portedOffer(host, 1, try monitorPixelBuffer(width: 64, height: 36))
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertEqual(presenter.statistics.presentedFrames, 0, "An unseen window's link stays paused")
    MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = true
    picture.reportVisibility()
    if portedWait(until: { presenter.statistics.presentedFrames > 0 }) {
      XCTAssertEqual(presenter.statistics.failures, 0)
      XCTAssertEqual(presenter.statistics.lastPresented?.sequence, 1)
    } else {
      print("MONITOR_SURFACE_TEST display link did not draw within 3 s")
    }
  }

  // MARK: Layer colour

  /// MonitorToolsUITests:614. The picture view's own layer, through its own render
  /// loop: Rec.709 SDR to start, EDR for HLG, back to SDR with the EDR metadata
  /// cleared, and declared log or untagged pictures stay Rec.709 code values.
  func testPictureLayerPresentationFollowsSignalColorimetry() throws {
    guard let core = try? MonitorCoordinator.sharedGPU.core() else { throw XCTSkip("No Metal 4 device") }
    let value = portedCoordinator()
    let (presenter, _, _) = portedSurface(value, portedAlpha)
    let picture = try XCTUnwrap(presenter.makeView() as? MonitorPictureNSView)
    XCTAssertTrue(presenter.pictureLayer === picture.metalLayer)
    let layer = picture.metalLayer
    let loop = try XCTUnwrap(presenter.renderLoop)
    let feed = core.engine.makeFeed()
    let state = presenter.currentEncodeState
    func check(
      _ signal: SignalDescription, _ format: MTLPixelFormat, _ space: CFString, hdr: Bool, line: UInt = #line
    ) {
      loop.applyColor(signal: signal, state: state, feed: feed)
      XCTAssertEqual(layer.pixelFormat, format, line: line)
      XCTAssertEqual(layer.colorspace?.name, space, line: line)
      XCTAssertEqual(layer.wantsExtendedDynamicRangeContent, hdr, line: line)
      XCTAssertEqual(layer.edrMetadata != nil, hdr, line: line)
    }
    let rec709 = SignalDescription(primaries: .rec709)
    check(rec709, .bgr10a2Unorm, CGColorSpace.itur_709, hdr: false)
    check(SignalDescription(matrix: .bt2020, primaries: .rec2020), .bgr10a2Unorm, CGColorSpace.itur_2020, hdr: false)
    check(
      SignalDescription(matrix: .bt2020, encoding: .display(.hlg), primaries: .rec2020), .rgba16Float,
      CGColorSpace.itur_2100_HLG, hdr: true)
    check(
      SignalDescription(matrix: .bt2020, encoding: .display(.pq), primaries: .rec2020), .rgba16Float,
      CGColorSpace.itur_2100_PQ, hdr: true)
    // Back to SDR: EDR off, metadata cleared.
    check(rec709, .bgr10a2Unorm, CGColorSpace.itur_709, hdr: false)
    // Declared log and untagged pictures stay Rec.709 code values.
    let declared = MonitorSignalDeclaration(logProfileID: "sony-slog3-sgamut3cine")
      .applied(to: SignalDescription(matrix: .bt2020, encoding: .display(.hlg), primaries: .rec2020))
    XCTAssertEqual(declared.encoding.log?.curve, .sLog3)
    check(declared, .bgr10a2Unorm, CGColorSpace.itur_709, hdr: false)
    check(SignalDescription(), .bgr10a2Unorm, CGColorSpace.itur_709, hdr: false)
  }

  /// MonitorToolsUITests:662. Drawn through the display link: an HLG frame switches
  /// the picture layer to half-float EDR in the HLG colour space, and a Rec.709
  /// frame switches it back.
  func testDrawnHLGFrameSwitchesThePictureLayerToEDR() throws {
    guard portedHasGPU else { throw XCTSkip("No Metal 4 device") }
    MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = true
    defer { MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = false }
    let value = portedCoordinator()
    let (presenter, host, _) = portedSurface(value, portedAlpha)
    let picture = try XCTUnwrap(presenter.makeView() as? MonitorPictureNSView)
    picture.frame = NSRect(x: 0, y: 0, width: 160, height: 90)
    let window = portedWindow(picture, size: picture.frame.size)
    defer {
      window.close()
      window.contentView = nil
    }
    func tagged(primaries: CFString, transfer: CFString, matrix: CFString) throws -> CVPixelBuffer {
      let buffer = try monitorPixelBuffer(width: 64, height: 36)
      CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
      CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
      CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
      return buffer
    }
    portedOffer(
      host, 1,
      try tagged(
        primaries: kCVImageBufferColorPrimaries_ITU_R_2020, transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
        matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020))
    guard portedWait(until: { presenter.statistics.lastPresented?.sequence == 1 }) else {
      throw XCTSkip("The display link did not fire for this test window")
    }
    XCTAssertEqual(picture.metalLayer.pixelFormat, .rgba16Float)
    XCTAssertEqual(picture.metalLayer.colorspace?.name, CGColorSpace.itur_2100_HLG)
    XCTAssertTrue(picture.metalLayer.wantsExtendedDynamicRangeContent)
    portedOffer(
      host, 2,
      try tagged(
        primaries: kCVImageBufferColorPrimaries_ITU_R_709_2, transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
        matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2))
    XCTAssertTrue(portedWait { presenter.statistics.lastPresented?.sequence == 2 })
    XCTAssertEqual(picture.metalLayer.pixelFormat, .bgr10a2Unorm)
    XCTAssertEqual(picture.metalLayer.colorspace?.name, CGColorSpace.itur_709)
    XCTAssertFalse(picture.metalLayer.wantsExtendedDynamicRangeContent)
    // Let the half-float and 10-bit drawables finish on the GPU.
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(presenter.statistics.failures, 0)
  }

  // MARK: Scopes

  /// MonitorToolsUITests:414. Two windows, each with a picture and a scope of the
  /// same feed. The frozen (and clean) surface keeps its held picture, tools and
  /// scope while the other keeps updating; after unfreezing it holds until the
  /// next live frame.
  func testNativeFrozenCleanScopePairStaysFixedWhileOtherWindowContinues() throws {
    guard portedHasGPU else { throw XCTSkip("No Metal 4 device") }
    MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = true
    defer { MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = false }
    let value = portedCoordinator()
    var original = value.preferences(for: portedAlpha)
    original.toolsEnabled = true
    original.scopes.enabled = true
    value.setPreferences(original, for: portedAlpha)
    let (first, host, firstID) = portedSurface(value, portedAlpha)
    let (second, _, _) = portedSurface(value, portedAlpha)
    let views = try [first, second].map { presenter -> (MonitorPictureNSView, NSView) in
      (try XCTUnwrap(presenter.makeView() as? MonitorPictureNSView), presenter.makeScopeView())
    }
    let windows = views.map { picture, scope -> NSWindow in
      let container = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 180))
      picture.frame = NSRect(x: 0, y: 90, width: 160, height: 90)
      scope.frame = NSRect(x: 0, y: 0, width: 160, height: 90)
      container.addSubview(picture)
      container.addSubview(scope)
      return portedWindow(container, size: container.bounds.size, style: [.titled, .closable])
    }
    defer {
      windows.forEach {
        $0.close()
        $0.contentView = nil
      }
    }
    let buffer = try monitorPixelBuffer(width: 64, height: 36)
    portedOffer(host, 10, buffer)
    first.setClean(false)
    second.setClean(false)
    // Whether the display link fires depends on the windows being on screen.
    let drawn = portedWait {
      first.statistics.lastPresented?.sequence == 10 && second.statistics.lastPresented?.sequence == 10
        && first.statistics.lastScope?.sequence == 10
    }
    if !drawn { print("MONITOR_SURFACE_TEST display link did not draw within 3 s") }
    first.toggleFreeze()
    value.registerSurface(id: firstID, target: portedAlpha, isVisible: true, scopeVisible: false)
    XCTAssertTrue(first.isFrozen)
    var next = original
    next.scopes.settings.waveformMode = .luma
    next.state.guides.enabled = true
    next.state.guides.centerCross = true
    value.setPreferences(next, for: portedAlpha)
    portedOffer(host, 11, buffer)
    first.setClean(true)
    second.setClean(false)
    XCTAssertTrue(first.isFrozen)
    XCTAssertFalse(second.isFrozen)
    XCTAssertEqual(first.currentStamp?.sequence, 10)
    XCTAssertEqual(second.currentStamp?.sequence, 11)
    XCTAssertEqual(first.shownPreferences, original)
    XCTAssertEqual(second.shownPreferences, next)
    if drawn {
      XCTAssertTrue(portedWait { second.statistics.lastPresented?.sequence == 11 })
      // Let the frozen surface run a few refreshes after the newer frame.
      RunLoop.main.run(until: Date().addingTimeInterval(0.15))
      XCTAssertEqual(first.statistics.lastPresented?.sequence, 10, "The held picture stays fixed")
      XCTAssertEqual(first.statistics.lastScope?.sequence, 10, "The held scope stays fixed")
      first.setClean(true)
      XCTAssertTrue(first.detail.contains("Scope PTS 10.000"), first.detail)
      XCTAssertTrue(first.scopeTiming.contains("Frozen"), first.scopeTiming)
      XCTAssertTrue(first.scopeTiming.contains("Scope PTS 10.000"), first.scopeTiming)
      XCTAssertTrue(portedWait { second.statistics.lastScope?.sequence == 11 }, "\(second.statistics)")
    }
    first.setClean(false)
    XCTAssertEqual(first.currentStamp?.sequence, 10)
    first.toggleFreeze()
    value.registerSurface(id: firstID, target: portedAlpha, isVisible: true, scopeVisible: false)
    XCTAssertFalse(first.isFrozen)
    // The frozen surface took no frames, so the hold stays on screen until the next
    // live frame instead of a stale frame from during the freeze.
    XCTAssertEqual(first.currentStamp?.sequence, 10)
    portedOffer(host, 12, buffer)
    XCTAssertEqual(first.currentStamp?.sequence, 12)
    first.setClean(false)
    XCTAssertEqual(first.shownPreferences, next)
    if drawn {
      XCTAssertTrue(
        portedWait { first.statistics.lastPresented?.sequence == 12 && first.statistics.lastScope?.sequence == 12 })
    }
    XCTAssertEqual(first.statistics.failures + second.statistics.failures, 0)
  }

  /// MonitorToolsUITests:514. The scope layer keeps MonitorTools' 768 × 256
  /// drawable and three drawables, and a drawn scope reports its GPU interval to
  /// the context's timing hook and to the surface statistics.
  func testScopePresentationReportsItsGPUInterval() throws {
    guard portedHasGPU else { throw XCTSkip("No Metal 4 device") }
    MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = true
    defer { MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = false }
    let timing = PortedGPUTimingProbe()
    let gpu = MonitorGPUContext(gpuTiming: { start, end in timing.record(start: start, end: end) })
    let value = MonitorCoordinator(gpu: gpu)
    value.updateTargets(feeds: [FeedDescriptor(id: FeedID(rawValue: "alpha"), name: "Alpha")], programAvailable: false)
    var tools = value.preferences(for: portedAlpha)
    tools.toolsEnabled = true
    tools.scopes.enabled = true
    value.setPreferences(tools, for: portedAlpha)
    let (presenter, host, _) = portedSurface(value, portedAlpha)
    let picture = try XCTUnwrap(presenter.makeView() as? MonitorPictureNSView)
    let scope = try XCTUnwrap(presenter.makeScopeView() as? MonitorScopeNSView)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
    picture.frame = NSRect(x: 0, y: 160, width: 320, height: 160)
    scope.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
    container.addSubview(picture)
    container.addSubview(scope)
    let window = portedWindow(container, size: container.bounds.size)
    defer {
      window.close()
      window.contentView = nil
    }
    XCTAssertEqual(scope.metalLayer.maximumDrawableCount, 3)
    XCTAssertEqual(
      scope.metalLayer.drawableSize,
      CGSize(width: ScopeSettings.ultracamLegacyImageWidth, height: ScopeSettings.ultracamLegacyImageHeight))
    XCTAssertEqual(scope.metalLayer.drawableSize, CGSize(width: 768, height: 256))
    portedOffer(host, 1, try monitorPixelBuffer(width: 64, height: 36))
    presenter.setClean(false)
    guard portedWait(until: { presenter.statistics.scopeUpdates > 0 }) else {
      throw XCTSkip("The display link did not fire for this test window (not on screen)")
    }
    XCTAssertTrue(portedWait { timing.count >= 2 }, "The picture and the scope report GPU time")
    // GPU means are published once a second.
    XCTAssertTrue(portedWait(5) { presenter.statistics.scopeGPUMilliseconds != nil })
    XCTAssertNotNil(presenter.statistics.pictureGPUMilliseconds)
    XCTAssertEqual(presenter.statistics.failures, 0)
  }

  /// MonitorToolsUITests:877. Scope visibility belongs to a surface: only a surface
  /// whose scope view is in a window draws scopes, and neither that nor its local
  /// scope registration changes the feed's shared tools.
  func testScopeVisibilityIsLocalAndDoesNotChangeSharedConfiguration() {
    let value = portedCoordinator()
    var tools = value.preferences(for: portedAlpha)
    tools.toolsEnabled = true
    tools.scopes.enabled = true
    value.setPreferences(tools, for: portedAlpha)
    let (shown, _, shownID) = portedSurface(value, portedAlpha)
    let (hidden, _, hiddenID) = portedSurface(value, portedAlpha)
    value.registerSurface(id: shownID, target: portedAlpha, isVisible: true, scopeVisible: true)
    value.registerSurface(id: hiddenID, target: portedAlpha, isVisible: true, scopeVisible: false)
    let scope = shown.makeScopeView()
    scope.frame = NSRect(x: 0, y: 0, width: 160, height: 90)
    let window = NSWindow(
      contentRect: scope.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scope
    defer { window.contentView = nil }
    XCTAssertNotNil(shown.currentScopeLayer, "The surface showing scopes draws them")
    XCTAssertNil(hidden.currentScopeLayer, "A surface with its scopes hidden draws none")
    XCTAssertEqual(value.preferences(for: portedAlpha), tools, "Local scope visibility never changes the feed's tools")
    XCTAssertTrue(hidden.shownPreferences.scopesShown, "The shared tools still say scopes are on")
    window.contentView = nil
    XCTAssertNil(shown.currentScopeLayer, "A scope view out of its window draws nothing")
  }

  // MARK: Layouts and zoom

  /// MonitorToolsUITests:179. Every workspace layout's tiles, bound to feeds, an
  /// empty slot and a missing feed, construct their pictures without starting
  /// capture and without changing the bindings.
  func testAllLayoutsConstructWithoutCaptureOrChangingBindings() {
    for layout in MonitorWorkspacePreferences.Layout.allCases {
      var workspace = MonitorWorkspacePreferences()
      workspace.isConfigured = true
      workspace.layout = layout
      workspace.tileBindings = ["alpha", "beta", nil, "missing"]
      let original = workspace
      let value = MonitorCoordinator(workspace: workspace)
      var demand: Set<MonitorTargetID> = []
      value.onDemandChange = { demand = $0 }
      value.updateTargets(
        feeds: [
          FeedDescriptor(id: FeedID(rawValue: "alpha"), name: "Wide"),
          FeedDescriptor(id: FeedID(rawValue: "beta"), name: "Tight"),
        ], programAvailable: false)
      let tiles = Array(workspace.tileBindings.prefix(layout.tileCount).enumerated())
      let presenters = tiles.map { _, binding in binding.map { value.surface(id: UUID(), target: MonitorTargetID($0)) } }
      let root = VStack {
        ForEach(tiles, id: \.offset) { index, _ in
          if let presenter = presenters[index] {
            Color.black.aspectRatio(16.0 / 9, contentMode: .fit).overlay { MonitorNativePicture(presenter: presenter) }
          } else {
            Text("Choose feed")
          }
        }
      }
      let host = NSHostingView(rootView: root)
      host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
      host.layoutSubtreeIfNeeded()
      XCTAssertEqual(value.workspace, original, "\(layout)")
      XCTAssertGreaterThan(host.fittingSize.width, 0)
      XCTAssertEqual(demand, [], "Constructing tiles never starts capture (\(layout))")
      for target in ["alpha", "beta", "missing"] {
        XCTAssertFalse(value.captureSink(for: MonitorTargetID(target)).hasConsumers, "\(layout) \(target)")
      }
    }
  }

  /// MonitorToolsUITests:200. Two side-by-side tiles with a tall picture column and
  /// scopes measure their whole content, so content after them stays below.
  func testSideBySideMeasuresTallScopedTilesAndFollowingContent() throws {
    let value = portedCoordinator()
    let presenters = [portedAlpha, portedBeta].map { value.surface(id: UUID(), target: $0) }
    for width in [520.0, 800.0] {
      var probes: [String: NSView] = [:]
      let tiles = HStack(alignment: .top, spacing: 10) {
        ForEach(0..<2, id: \.self) { index in
          VStack(spacing: 6) {
            Color.black.aspectRatio(16.0 / 9, contentMode: .fit).overlay {
              MonitorNativePicture(presenter: presenters[index])
            }
            Text("Synthetic timestamp and calibration status for tall scope fixture").font(.caption)
            Color.gray.frame(height: index == 0 ? 220 : 300)
            MonitorNativeScope(presenter: presenters[index]).frame(height: 240)
              .overlay { ScopeIREScaleView(scale: ScopeIREScale(), showsGrid: true) }
          }
          .frame(maxWidth: .infinity)
          .background(PortedLayoutProbe { probes["tile\(index)"] = $0 })
        }
      }.background(PortedLayoutProbe { probes["shell"] = $0 })
      let root = ScrollView {
        VStack(spacing: 12) {
          tiles
          Color.gray.frame(height: 40).background(PortedLayoutProbe { probes["following"] = $0 })
        }.frame(width: width)
      }.frame(width: width, height: 500)
      let host = NSHostingView(rootView: root)
      host.frame = NSRect(x: 0, y: 0, width: width, height: 500)
      host.layoutSubtreeIfNeeded()
      let shell = try XCTUnwrap(probes["shell"])
      let shellRect = shell.convert(shell.bounds, to: host)
      let following = try XCTUnwrap(probes["following"])
      let followingRect = following.convert(following.bounds, to: host)
      XCTAssertGreaterThan(shellRect.height, 600)
      for index in 0...1 {
        let view = try XCTUnwrap(probes["tile\(index)"])
        let tile = view.convert(view.bounds, to: host)
        XCTAssertGreaterThan(tile.width, 200)
        XCTAssertLessThanOrEqual(tile.width, (width - 10) / 2 + 0.5)
        XCTAssertGreaterThanOrEqual(shellRect.height, tile.height)
        XCTAssertFalse(followingRect.intersects(tile), "Following controls must stay below both complete tiles")
        XCTAssertTrue(shellRect.insetBy(dx: -1, dy: -1).contains(tile))
      }
      XCTAssertLessThanOrEqual(shellRect.width, width)
    }
  }

  /// MonitorToolsUITests:558. Four tiles host their pictures and scopes and take
  /// frames independently: each shows its own feed's newest frame, live, with the
  /// feed's tools.
  func testFourUpNativeHostingShowsEverySurface() throws {
    guard portedHasGPU else { throw XCTSkip("No Metal 4 device") }
    MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = true
    defer { MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = false }
    let names = ["tile-0", "tile-1", "tile-2", "tile-3"]
    let value = portedCoordinator(feeds: names)
    var tools = MonitorFeedPreferences()
    tools.toolsEnabled = true
    tools.state.guides.enabled = true
    tools.state.zebras[0].enabled = true
    tools.state.focus.enabled = true
    tools.scopes.enabled = true
    for name in names { value.setPreferences(tools, for: MonitorTargetID(name)) }
    let surfaces = names.map { portedSurface(value, MonitorTargetID($0)) }
    let root = Grid(horizontalSpacing: 8, verticalSpacing: 8) {
      ForEach(0..<2, id: \.self) { row in
        GridRow {
          ForEach(0..<2, id: \.self) { column in
            let presenter = surfaces[row * 2 + column].presenter
            VStack {
              Color.black.aspectRatio(16.0 / 9, contentMode: .fit).overlay { MonitorNativePicture(presenter: presenter) }
              MonitorNativeScope(presenter: presenter).frame(height: 120)
            }
          }
        }
      }
    }.frame(width: 1280)
    let hosting = NSHostingView(rootView: root)
    let window = portedWindow(hosting, size: NSSize(width: 1280, height: 1000))
    defer {
      window.close()
      window.contentView = nil
    }
    hosting.layoutSubtreeIfNeeded()
    let buffer = try monitorPixelBuffer(width: 64, height: 36)
    for (index, surface) in surfaces.enumerated() {
      // Status must not depend on whether the test runner's window is occluded.
      surface.presenter.reportVisibility(presented: true, drawable: true)
      portedOffer(surface.host, UInt64(index + 1), buffer)
      surface.presenter.setClean(false)
      XCTAssertEqual(surface.presenter.currentStamp?.target, names[index])
      XCTAssertEqual(surface.presenter.currentStamp?.sequence, UInt64(index + 1))
      XCTAssertEqual(surface.presenter.status, "Live")
      XCTAssertEqual(surface.presenter.shownPreferences, tools)
    }
    if portedWait(until: { surfaces.allSatisfy { $0.presenter.statistics.presentedFrames > 0 } }) {
      XCTAssertTrue(surfaces.allSatisfy { $0.presenter.statistics.failures == 0 })
    } else {
      print("MONITOR_SURFACE_TEST display link did not draw within 3 s")
    }
  }

  /// MonitorToolsUITests:903. Zoom is a surface's MonitorKit magnification: the
  /// picture scales about its centre, the guides lie on the picture as shown, and
  /// the zoom is bounded as the pass bounds it (non-finite: 1, at most 64). The
  /// old SwiftUI zoom scaled the guide overlay with the picture; MonitorKit's
  /// guides follow the unmagnified picture and are hidden while magnified.
  func testZoomScalesThePictureWithinBoundsAndHidesGuidesWhileMagnified() throws {
    let (presenter, _) = portedDetachedPresenter()
    let frame = MonitorFrameGeometry(width: 80, height: 40)
    func layout(_ state: MonitorState) -> MonitorLayout {
      MonitorLayout(frame: frame, state: state, viewportWidth: 80, viewportHeight: 40)
    }
    var guides = GuideSettings()
    guides.enabled = true
    let fit = layout(presenter.currentEncodeState)
    XCTAssertEqual(fit.imageRect, MonitorRect(x: 0, y: 0, width: 80, height: 40))
    let unzoomedGuides = GuideRaster(layout: fit, guides: guides)
    XCTAssertFalse(unzoomedGuides.segments.isEmpty)
    for segment in unzoomedGuides.segments {
      XCTAssertTrue(
        fit.imageRect.portedInset(-1).portedContains(x: segment.x0, y: segment.y0)
          && fit.imageRect.portedInset(-1).portedContains(x: segment.x1, y: segment.y1), "Guides lie on the shown picture")
    }

    var zoom = Magnification()
    zoom.zoom = 2
    zoom.showsNavigator = false
    presenter.setMagnification(zoom)
    XCTAssertEqual(presenter.zoom, zoom)
    XCTAssertEqual(presenter.currentEncodeState.geometry.magnification, zoom)
    let zoomed = layout(presenter.currentEncodeState)
    XCTAssertEqual(zoomed.imageRect.width, 160, accuracy: 1)
    XCTAssertEqual(zoomed.imageRect.height, 80, accuracy: 1)
    XCTAssertEqual(zoomed.imageRect.x + zoomed.imageRect.width / 2, 40, accuracy: 1)
    XCTAssertEqual(zoomed.imageRect.y + zoomed.imageRect.height / 2, 20, accuracy: 1)
    XCTAssertTrue(GuideRaster(layout: zoomed, guides: guides).segments.isEmpty, "MonitorKit hides guides while magnified")

    for (requested, expected) in [(Double.infinity, 1.0), (.nan, 1), (0.25, 1), (99, 64)] {
      var bounded = Magnification()
      bounded.zoom = requested
      bounded.showsNavigator = false
      presenter.setMagnification(bounded)
      XCTAssertEqual(layout(presenter.currentEncodeState).imageRect.width, 80 * expected, accuracy: 1, "zoom \(requested)")
    }
  }
}

extension MonitorRect {
  fileprivate func portedInset(_ amount: Double) -> MonitorRect {
    MonitorRect(x: x + amount, y: y + amount, width: width - 2 * amount, height: height - 2 * amount)
  }
  fileprivate func portedContains(x px: Double, y py: Double) -> Bool {
    px >= x && px <= x + width && py >= y && py <= y + height
  }
}
