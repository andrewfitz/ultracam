import AppKit
import CoreVideo
import Metal
import MonitorToolsCore
import QuartzCore
import SwiftUI
import XCTest

@testable import MonitorToolsMetal
@testable import MonitorToolsUI

final class MonitorToolsUITests: XCTestCase {
  /// Freeze holds the accepted frame while a picture view exists; the AVSampleBufferDisplayLayer
  /// identity checks this test used to make are retired with that layer.
  @MainActor func testFrozenHoldKeepsStampWithPictureView() throws {
    let presenter = MonitorSurfacePresenter()
    let picture = try XCTUnwrap(presenter.makeView() as? MonitorPictureNSView)
    // 10-bit Rec.709 until a frame's signal says otherwise.
    XCTAssertEqual(picture.metalLayer.pixelFormat, .bgr10a2Unorm)
    XCTAssertEqual(picture.metalLayer.colorspace?.name, CGColorSpace.itur_709)
    XCTAssertFalse(picture.metalLayer.wantsExtendedDynamicRangeContent)
    let result = try fixture(sequence: 1, configuration: MonitorConfiguration())
    presenter.accept(result)
    presenter.setClean(false)
    presenter.toggleFreeze()
    XCTAssertTrue(presenter.isFrozen)
    presenter.accept(try fixture(sequence: 2, configuration: MonitorConfiguration()))
    XCTAssertTrue(presenter.isFrozen, "A newer frame never replaces a held picture")
    XCTAssertEqual(presenter.currentStamp, result.stamp)
  }

  @MainActor func testOcclusionAndHiddenStatusPreserveSuccessfulFreeze() async throws {
    let presenter = MonitorSurfacePresenter()
    presenter.accept(try fixture(sequence: 1, configuration: MonitorConfiguration()))
    await Task.yield()
    presenter.setClean(false)
    presenter.reportVisibility(presented: true, drawable: false)
    XCTAssertEqual(presenter.status, "Occluded")
    presenter.reportVisibility(presented: false, drawable: false)
    XCTAssertEqual(presenter.status, "Paused / hidden")
    presenter.reportVisibility(presented: true, drawable: true)
    presenter.accept(try fixture(sequence: 2, configuration: MonitorConfiguration()))
    await Task.yield()
    presenter.setClean(false)
    presenter.toggleFreeze()
    let frozen = presenter.currentStamp
    presenter.reportVisibility(presented: true, drawable: false)
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertEqual(presenter.status, "Frozen")
    XCTAssertEqual(presenter.currentStamp, frozen)
  }

  @MainActor func testFalseColorOffAndSourceMatteCaptions() {
    var configuration = MonitorConfiguration()
    configuration.toolsEnabled = true
    configuration.pictureStage = .processedOutput
    let toolbar = MonitorToolsToolbar(configuration: .constant(configuration))
    XCTAssertEqual(toolbar.falseColorAnalysisLabel, "Analysis: Off")
    let plain = MonitorTileChrome(
      target: .constant(MonitorTargetID("feed")), configuration: .constant(configuration),
      choices: [], status: "Live", picture: { EmptyView() }, scopes: { EmptyView() })
    XCTAssertEqual(plain.pictureCaption, "Picture: Processed Output")
    configuration.falseColor.mode = .sonySLog3
    let matte = MonitorTileChrome(
      target: .constant(MonitorTargetID("feed")), configuration: .constant(configuration),
      choices: [], status: "Frozen", legendConfiguration: configuration,
      picture: { EmptyView() }, scopes: { EmptyView() })
    XCTAssertTrue(matte.pictureCaption.hasPrefix("False color: Source analysis"))
  }

  @MainActor func testExplicitSonyModeSelectionQualifiesAnExistingSonyDeclaration() {
    for source in ["sony-slog3-sgamut3cine", "sony-slog3-sgamut3"] {
      var selected = MonitorConfiguration()
      selected.sourceProfileID = source
      selected.falseColor.exposureIndex = 12800
      let original = selected
      let toolbar = MonitorToolsToolbar(
        configuration: Binding(get: { selected }, set: { selected = $0.normalized() }))
      let host = NSHostingView(rootView: toolbar)
      host.frame = NSRect(x: 0, y: 0, width: 900, height: 80)
      host.layoutSubtreeIfNeeded()
      XCTAssertEqual(selected, original, "Constructing controls must not migrate stored feed settings")

      toolbar.falseColorModeSelection.wrappedValue = MonitorFalseColorMode(rawValue: "sonySLog3") ?? .arri

      XCTAssertEqual(selected.falseColor.profileID, "sony-slog3-false-color-v1")
      XCTAssertEqual(selected.falseColor.specificationVersion, "sony-monitor-control-pattern2-v1")
      XCTAssertEqual(selected.falseColor.exposureIndex, 12800)
      XCTAssertEqual(selected.normalized().falseColor.mode.rawValue, "sonySLog3")
      let profile = selected.falseColor.profileID
      let specification = selected.falseColor.specificationVersion
      toolbar.falseColorModeSelection.wrappedValue = .off
      XCTAssertEqual(selected.falseColor.mode, .off)
      XCTAssertEqual(selected.falseColor.profileID, profile)
      XCTAssertEqual(selected.falseColor.specificationVersion, specification)
    }
  }

  @MainActor func testSourceProfileSwitchIsAtomicAcrossCoordinatorNormalization() {
    for sonySource in ["sony-slog3-sgamut3cine", "sony-slog3-sgamut3"] {
      var selected = MonitorConfiguration()
      selected.sourceProfileID = "arri-logc3-ei800"
      selected.falseColor.mode = .arri
      selected.falseColor.profileID = "arri-logc3-ei800"
      selected.falseColor.specificationVersion = ARRIFalseColorProfile.specificationVersion
      let toolbar = MonitorToolsToolbar(
        configuration: Binding(get: { selected }, set: { selected = $0.normalized() }))

      toolbar.sourceProfileSelection.wrappedValue = sonySource

      XCTAssertEqual(selected.falseColor.mode.rawValue, "sonySLog3")
      XCTAssertEqual(selected.sourceProfileID, sonySource)
      XCTAssertEqual(selected.falseColor.profileID, "sony-slog3-false-color-v1")

      selected.falseColor.mode = .arri
      toolbar.sourceProfileSelection.wrappedValue = "arri-alexa35-logc4-ei800"

      XCTAssertEqual(selected.falseColor.mode, .arri)
      XCTAssertEqual(selected.sourceProfileID, "arri-alexa35-logc4-ei800")
      XCTAssertEqual(selected.falseColor.profileID, "arri-alexa35-logc4-ei800")
    }
  }

  @MainActor func testSelectingEitherSonyLogSourceEnablesSonyFalseColorForOnlyThatFeed() {
    for source in ["sony-slog3-sgamut3cine", "sony-slog3-sgamut3"] {
      var selected = MonitorConfiguration()
      selected.toolsEnabled = true
      selected.falseColor.mode = .arri
      selected.falseColor.exposureIndex = 1600
      selected.sourceCodeRange = .full
      selected.sourceLogMapping = .fullRescaledToLegal10Bit
      selected.guides.enabled = true
      var otherFeed = selected
      let toolbar = MonitorToolsToolbar(
        configuration: Binding(get: { selected }, set: { selected = $0 }))
      let otherToolbar = MonitorToolsToolbar(
        configuration: Binding(get: { otherFeed }, set: { otherFeed = $0 }))

      toolbar.sourceProfileSelection.wrappedValue = source

      XCTAssertEqual(selected.sourceProfileID, source)
      XCTAssertEqual(selected.falseColor.profileID, "sony-slog3-false-color-v1")
      XCTAssertEqual(selected.falseColor.specificationVersion, "sony-monitor-control-pattern2-v1")
      XCTAssertEqual(selected.falseColor.exposureIndex, 1600)
      XCTAssertTrue(toolbar.isSonyFalseColorAvailable)
      XCTAssertEqual(selected.normalized().falseColor.mode.rawValue, "sonySLog3")
      XCTAssertEqual(selected.sourceCodeRange, .full)
      XCTAssertEqual(selected.sourceLogMapping, .fullRescaledToLegal10Bit)
      XCTAssertTrue(selected.guides.enabled)
      XCTAssertNil(otherFeed.sourceProfileID)
      XCTAssertNil(otherFeed.falseColor.profileID)
      let selectedSnapshot = selected
      otherToolbar.sourceProfileSelection.wrappedValue = "arri-logc3-ei800"
      XCTAssertEqual(selected, selectedSnapshot)
      XCTAssertEqual(otherFeed.sourceProfileID, "arri-logc3-ei800")
      XCTAssertFalse(MonitorToolsToolbar(
        configuration: Binding(get: { selected }, set: { selected = $0 }),
        supportsSourceAnalysis: false).isSonyFalseColorAvailable)
    }
  }

  @MainActor func testSelectingLiteralARRISourcesPreservesTheirCameraProfiles() {
    for source in ["arri-logc3-ei800", "arri-alexa35-logc4-ei800"] {
      var selected = MonitorConfiguration()
      selected.falseColor.mode = .arri
      let toolbar = MonitorToolsToolbar(
        configuration: Binding(get: { selected }, set: { selected = $0 }))

      toolbar.sourceProfileSelection.wrappedValue = source

      XCTAssertEqual(selected.sourceProfileID, source)
      XCTAssertEqual(selected.falseColor.profileID, source)
      XCTAssertEqual(selected.falseColor.specificationVersion, ARRIFalseColorProfile.specificationVersion)
      XCTAssertEqual(selected.falseColor.exposureIndex, 800)
      XCTAssertEqual(selected.normalized().falseColor.mode, .arri)
    }
  }

  @MainActor func testAllLayoutsConstructWithoutCaptureOrChangingBindings() {
    for layout in MonitorWorkspaceLayout.allCases {
      var workspace = MonitorWorkspaceState()
      workspace.layout = layout
      workspace.tileBindings = [
        MonitorTargetID("a"), MonitorTargetID("b"), nil, MonitorTargetID("missing"),
      ]
      let original = workspace
      let view = MonitorWorkspaceShell(
        workspace: Binding(get: { workspace }, set: { workspace = $0 })
      ) { index, _ in
        Text("Synthetic tile \(index)").frame(height: 100)
      }
      let host = NSHostingView(rootView: view)
      host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
      host.layoutSubtreeIfNeeded()
      XCTAssertEqual(workspace, original)
      XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
  }

  @MainActor func testSideBySideMeasuresTallScopedTilesAndFollowingContent() throws {
    for width in [520.0, 800.0] {
      var workspace = MonitorWorkspaceState()
      workspace.layout = .sideBySide
      var config = MonitorConfiguration()
      config.toolsEnabled = true
      config.scopes.enabled = true
      var probes: [String: NSView] = [:]
      let shell = MonitorWorkspaceShell(workspace: .constant(workspace)) { index, _ in
        MonitorTileChrome(
          target: .constant(MonitorTargetID("synthetic-\(index)")),
          configuration: .constant(config),
          choices: [
            MonitorTargetOption(
              id: MonitorTargetID("synthetic-\(index)"), title: "Synthetic feed \(index)")
          ], status: "Live",
          detail: "Synthetic timestamp and calibration status for tall scope fixture"
        ) {
          Color.black.aspectRatio(16.0 / 9, contentMode: .fit)
          Color.gray.frame(height: index == 0 ? 220 : 300)
        } scopes: {
          Color.black.frame(height: 240).overlay { MonitorScopeGraticule() }
        }
        .background(LayoutProbe { probes["tile\(index)"] = $0 })
      }.background(LayoutProbe { probes["shell"] = $0 })
      let root = ScrollView {
        VStack(spacing: 12) {
          shell
          Color.gray.frame(height: 40).background(LayoutProbe { probes["following"] = $0 })
        }.frame(width: width)
      }.frame(width: width, height: 500)
      let host = NSHostingView(rootView: root)
      host.frame = NSRect(x: 0, y: 0, width: width, height: 500)
      host.layoutSubtreeIfNeeded()
      let shellRect = try XCTUnwrap(probes["shell"]).convert(
        try XCTUnwrap(probes["shell"]).bounds, to: host)
      let following = try XCTUnwrap(probes["following"]).convert(
        try XCTUnwrap(probes["following"]).bounds, to: host)
      XCTAssertGreaterThan(shellRect.height, 600)
      for index in 0...1 {
        let view = try XCTUnwrap(probes["tile\(index)"])
        let tile = view.convert(view.bounds, to: host)
        XCTAssertGreaterThan(tile.width, 200)
        XCTAssertLessThanOrEqual(tile.width, (width - 10) / 2)
        XCTAssertGreaterThanOrEqual(shellRect.height, tile.height)
        XCTAssertFalse(
          following.intersects(tile),
          "Following controls must stay below both complete tile contents")
        XCTAssertTrue(shellRect.insetBy(dx: -1, dy: -1).contains(tile))
      }
      XCTAssertLessThanOrEqual(shellRect.width, width)
    }
  }

  @MainActor func testFreezeCleanKeepsConfigurationAndDoesNotFreezeOtherSurface() async throws {
    let first = MonitorSurfacePresenter()
    let second = MonitorSurfacePresenter()
    let native = first.makeView()
    native.frame = NSRect(x: 0, y: 0, width: 160, height: 90)
    var firstConfiguration = MonitorConfiguration()
    firstConfiguration.toolsEnabled = true
    firstConfiguration.guides.enabled = true
    first.accept(
      try fixture(sequence: 1, configuration: firstConfiguration, transfer: "Source Log"))
    second.accept(try fixture(sequence: 1, configuration: firstConfiguration))
    await Task.yield()
    first.toggleFreeze()
    first.setClean(true)
    var nextConfiguration = firstConfiguration
    nextConfiguration.guides.thirds = false
    first.accept(
      try fixture(sequence: 2, configuration: nextConfiguration, transfer: "New transfer"))
    second.accept(try fixture(sequence: 2, configuration: nextConfiguration))
    await Task.yield()
    // Explicit refresh also verifies clean switches don't replace a frozen legend.
    first.setClean(false)
    second.setClean(false)
    XCTAssertTrue(first.isFrozen)
    XCTAssertFalse(second.isFrozen)
    XCTAssertEqual(first.configuration, firstConfiguration)
    XCTAssertTrue(first.pictureInterpretation.contains("Source Log"))
    XCTAssertEqual(second.configuration, nextConfiguration)
    XCTAssertTrue(first.detail.contains("1.000"))
    XCTAssertTrue(second.detail.contains("2.000"))
    first.setClean(true)
    XCTAssertTrue(first.isFrozen)
    XCTAssertEqual(first.configuration, firstConfiguration)
    first.toggleFreeze()
    XCTAssertFalse(first.isFrozen)
    // The surface took no frames while frozen: the hold stays until the next one.
    XCTAssertEqual(first.configuration, firstConfiguration)
    first.accept(try fixture(sequence: 3, configuration: nextConfiguration))
    await Task.yield()
    first.setClean(false)
    XCTAssertEqual(first.configuration, nextConfiguration)
  }

  @MainActor func testStaleAvailabilityAndMissingSignalDoNotUnfreezeSnapshot() async throws {
    let presenter = MonitorSurfacePresenter()
    presenter.accept(try fixture(sequence: 1, configuration: MonitorConfiguration()))
    await Task.yield()
    presenter.toggleFreeze()
    presenter.setUnavailable("Feed stopped")
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertEqual(presenter.status, "Frozen")
    presenter.toggleFreeze()
    XCTAssertEqual(presenter.status, "Feed stopped")
    presenter.setUnavailable("Missing feed")
    XCTAssertEqual(presenter.status, "Missing feed")
    XCTAssertFalse(presenter.isFrozen)
  }

  @MainActor func testVisibilityTransitionsAreIndependentFromFreezeIntent() {
    let presenter = MonitorSurfacePresenter()
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
  }

  @MainActor func testNativeWindowAttachmentAndHiddenStateReportDemand() {
    let presenter = MonitorSurfacePresenter()
    var changes: [(Bool, Bool)] = []
    presenter.onVisibilityChange = { changes.append(($0, $1)) }
    let view = presenter.makeView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 160, height: 90), styleMask: [.titled],
      backing: .buffered, defer: false)
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
  }

  @MainActor func testPendingFreezeUsesNextAdmittedPictureAndCanCancel() async throws {
    let presenter = MonitorSurfacePresenter()
    presenter.accept(try fixture(sequence: 1, configuration: MonitorConfiguration()))
    await Task.yield()
    presenter.requestFreezeOnNextFrame()
    XCTAssertTrue(presenter.isFreezePending)
    XCTAssertFalse(presenter.isFrozen)
    var next = MonitorConfiguration()
    next.guides.centerCross = true
    presenter.accept(try fixture(sequence: 2, configuration: next))
    await Task.yield()
    presenter.setClean(true)
    XCTAssertFalse(presenter.isFreezePending)
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertEqual(presenter.configuration, next)
    XCTAssertTrue(presenter.detail.contains("2.000"))
    presenter.toggleFreeze()
    presenter.requestFreezeOnNextFrame()
    presenter.cancelPendingFreeze()
    presenter.accept(try fixture(sequence: 3, configuration: next))
    await Task.yield()
    XCTAssertFalse(presenter.isFreezePending)
    XCTAssertFalse(presenter.isFrozen)
  }

  @MainActor func testActualWindowMinimizeAncestorHideAndClose() async throws {
    _ = NSApplication.shared
    let presenter = MonitorSurfacePresenter()
    var changes: [(Bool, Bool)] = []
    presenter.onVisibilityChange = { changes.append(($0, $1)) }
    let host = NSHostingView(rootView: MonitorSurfaceVisibility(presenter: presenter))
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
    host.frame = container.bounds
    container.addSubview(host)
    let window = NSWindow(
      contentRect: container.bounds, styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Synthetic monitor lifecycle fixture"
    window.contentView = container
    defer {
      window.close()
      window.contentView = nil
    }
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    try await waitFor { window.isVisible && !changes.isEmpty }
    XCTAssertEqual(changes.last?.1, window.occlusionState.contains(.visible))
    container.isHidden = true
    XCTAssertEqual(changes.last?.0, false)
    container.isHidden = false
    XCTAssertEqual(changes.last?.0, true)
    XCTAssertEqual(changes.last?.1, window.occlusionState.contains(.visible))
    window.miniaturize(nil)
    try await waitFor { window.isMiniaturized }
    XCTAssertEqual(changes.last?.0, true)
    XCTAssertEqual(changes.last?.1, false)
    window.deminiaturize(nil)
    try await waitFor { !window.isMiniaturized }
    XCTAssertEqual(changes.last?.1, window.isVisible && window.occlusionState.contains(.visible))
    window.close()
    XCTAssertEqual(changes.last?.0, false)
    XCTAssertEqual(changes.last?.1, false)
  }

  /// Two real windows, each with a picture and a scope. The frozen surface keeps
  /// its held frame, configuration and scope while the other keeps updating.
  @MainActor func testNativeFrozenCleanScopePairStaysFixedWhileOtherWindowContinues() async throws {
    MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = true
    defer { MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = false }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("Metal device unavailable for native scope fixture")
    }
    let first = MonitorSurfacePresenter()
    let second = MonitorSurfacePresenter()
    let firstPicture = try XCTUnwrap(first.makeView() as? MonitorPictureNSView)
    let secondPicture = try XCTUnwrap(second.makeView() as? MonitorPictureNSView)
    let firstScope = try XCTUnwrap(first.makeScopeView() as? MonitorScopeNSView)
    let secondScope = try XCTUnwrap(second.makeScopeView() as? MonitorScopeNSView)
    let windows = [(firstPicture, firstScope), (secondPicture, secondScope)].map {
      picture, scope -> NSWindow in
      let container = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 180))
      picture.frame = NSRect(x: 0, y: 90, width: 160, height: 90)
      scope.frame = NSRect(x: 0, y: 0, width: 160, height: 90)
      container.addSubview(picture)
      container.addSubview(scope)
      let window = NSWindow(
        contentRect: container.bounds, styleMask: [.titled, .closable], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      window.title = "Synthetic freeze fixture"
      window.contentView = container
      window.orderFrontRegardless()
      return window
    }
    defer {
      windows.forEach {
        $0.close()
        $0.contentView = nil
      }
    }
    var original = MonitorConfiguration()
    original.toolsEnabled = true
    original.scopes.enabled = true
    let old = try fixture(sequence: 10, configuration: original)
    first.accept(old)
    second.accept(old)
    await Task.yield()
    first.setClean(false)
    second.setClean(false)
    // Whether the display link fires depends on the windows being on screen.
    let drawn = await waitQuietly {
      first.statistics.lastPresented?.sequence == 10 && second.statistics.lastPresented?.sequence == 10
        && first.statistics.lastScope?.sequence == 10
    }
    first.toggleFreeze()
    XCTAssertTrue(first.isFrozen)
    var next = original
    next.scopes.mode = .lumaWaveform
    next.guides.centerCross = true
    let newer = try fixture(sequence: 11, configuration: next)
    first.accept(newer)
    second.accept(newer)
    await Task.yield()
    first.setClean(true)
    second.setClean(false)
    XCTAssertTrue(first.isFrozen)
    XCTAssertFalse(second.isFrozen)
    XCTAssertEqual(first.currentStamp, old.stamp)
    XCTAssertEqual(second.currentStamp, newer.stamp)
    XCTAssertEqual(first.configuration, original)
    XCTAssertEqual(second.configuration, next)
    if drawn {
      try await waitFor { second.statistics.lastPresented?.sequence == 11 }
      // Let the frozen surface run a few refreshes after the newer frame.
      try await Task.sleep(for: .milliseconds(150))
      XCTAssertEqual(first.statistics.lastPresented?.sequence, 10, "The held picture stays fixed")
      XCTAssertEqual(first.statistics.lastScope?.sequence, 10, "The held scope stays fixed")
      first.setClean(true)
      XCTAssertTrue(first.detail.contains("Scope PTS 10.000"))
      XCTAssertTrue(first.scopeTiming.contains("Frozen"))
      XCTAssertTrue(first.scopeTiming.contains("Scope PTS 10.000"))
      try await waitFor { second.statistics.lastScope?.sequence == 11 }
      XCTAssertEqual(second.statistics.lastScope?.sequence, 11, "\(second.statistics)")
    }
    first.setClean(false)
    XCTAssertEqual(first.currentStamp, old.stamp)
    first.toggleFreeze()
    XCTAssertFalse(first.isFrozen)
    // The frozen surface took no frames, so the hold stays on screen until
    // the next live frame instead of a stale frame from during the freeze.
    XCTAssertEqual(first.currentStamp, old.stamp)
    let newest = try fixture(sequence: 12, configuration: next)
    first.accept(newest)
    XCTAssertEqual(first.currentStamp, newest.stamp)
    await Task.yield()
    first.setClean(false)
    XCTAssertEqual(first.configuration, next)
    if drawn {
      try await waitFor {
        first.statistics.lastPresented?.sequence == 12 && first.statistics.lastScope?.sequence == 12
      }
    }
  }

  /// A drawn scope reports its GPU interval to the runtime's timing hook and
  /// to the surface statistics.
  @MainActor func testScopePresentationReportsItsGPUInterval() async throws {
    MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = true
    defer { MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = false }
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let timing = ScopeTimingProbe()
    let runtime = MonitorRuntime(gpuTiming: { start, end in timing.record(start: start, end: end) })
    let presenter = MonitorSurfacePresenter(runtime: runtime)
    let picture = try XCTUnwrap(presenter.makeView() as? MonitorPictureNSView)
    let scope = try XCTUnwrap(presenter.makeScopeView() as? MonitorScopeNSView)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
    picture.frame = NSRect(x: 0, y: 160, width: 320, height: 160)
    scope.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
    container.addSubview(picture)
    container.addSubview(scope)
    let window = NSWindow(
      contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    window.orderFrontRegardless()
    defer {
      window.close()
      window.contentView = nil
    }
    XCTAssertEqual(scope.metalLayer.maximumDrawableCount, 3)
    XCTAssertEqual(
      scope.metalLayer.drawableSize,
      CGSize(width: MonitorToolsRenderer.scopeWidth, height: MonitorToolsRenderer.scopeHeight))
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.scopes.enabled = true
    presenter.accept(try fixture(sequence: 1, configuration: config))
    await Task.yield()
    presenter.setClean(false)
    guard await waitQuietly({ presenter.statistics.scopeUpdates > 0 }) else {
      throw XCTSkip("The display link did not fire for this test window (not on screen)")
    }
    try await waitFor { timing.count >= 2 }  // the picture and the scope
    try await waitFor { presenter.statistics.scopeGPUMilliseconds != nil }
    XCTAssertNotNil(presenter.statistics.pictureGPUMilliseconds)
    XCTAssertEqual(presenter.statistics.failures, 0)
  }

  /// Four tiles host their pictures and scopes and take frames independently.
  /// (The per-surface presentation budget this test used to check is retired.)
  @MainActor func testFourUpNativeHostingShowsEverySurface() async throws {
    MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = true
    defer { MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = false }
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let presenters = (0..<4).map { _ in MonitorSurfacePresenter() }
    var workspace = MonitorWorkspaceState()
    workspace.layout = .fourUp
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.guides.enabled = true
    config.zebra.enabled = true
    config.focus.enabled = true
    config.scopes.enabled = true
    let root = ScrollView {
      MonitorWorkspaceShell(workspace: .constant(workspace)) { index, _ in
        MonitorTileChrome(
          target: .constant(MonitorTargetID("tile-\(index)")), configuration: .constant(config),
          choices: [], status: "Synthetic"
        ) {
          Color.black.aspectRatio(16.0 / 9, contentMode: .fit).overlay {
            MonitorNativePicture(presenter: presenters[index])
          }
        } scopes: {
          MonitorNativeScope(presenter: presenters[index]).frame(height: 120)
        }
      }.frame(width: 1280)
    }
    let host = NSHostingView(rootView: root)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 1000), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    defer {
      window.close()
      window.contentView = nil
    }
    host.layoutSubtreeIfNeeded()
    for (index, presenter) in presenters.enumerated() {
      // Status must not depend on whether the test runner's window is OS-occluded.
      presenter.reportVisibility(presented: true, drawable: true)
      let frame = try fixture(sequence: 1, configuration: config, target: "tile-\(index)")
      presenter.accept(frame)
      presenter.setClean(false)
      XCTAssertEqual(presenter.currentStamp, frame.stamp)
      XCTAssertEqual(presenter.status, "Live")
      XCTAssertEqual(presenter.configuration, config)
    }
    if await waitQuietly({ presenters.allSatisfy { $0.statistics.presentedFrames > 0 } }) {
      XCTAssertTrue(presenters.allSatisfy { $0.statistics.failures == 0 })
    }
  }

  /// The picture layer's format, colorspace and EDR state follow the frame's
  /// signal tags, through the render loop's own path.
  @MainActor func testPictureLayerPresentationFollowsSignalColorimetry() throws {
    let presenter = MonitorSurfacePresenter()
    let picture = try XCTUnwrap(presenter.makeView() as? MonitorPictureNSView)
    let layer = picture.metalLayer
    let loop = picture.renderLoop
    func signal(_ primaries: CFString?, _ transfer: CFString?, profile: String? = nil)
      -> MonitorFrameSignal
    {
      MonitorFrameSignal(
        range: .legal, matrix: primaries == kCVImageBufferColorPrimaries_ITU_R_2020 ? .bt2020 : .bt709,
        transfer: profile ?? (transfer as String?) ?? "Unknown", profileID: profile,
        primaries: primaries as String?, transferFunction: transfer as String?)
    }
    func check(
      _ value: MonitorFrameSignal?, _ format: MTLPixelFormat, _ space: CFString, hdr: Bool,
      line: UInt = #line
    ) {
      loop.applyColor(value)
      XCTAssertEqual(layer.pixelFormat, format, line: line)
      XCTAssertEqual(layer.colorspace?.name, space, line: line)
      XCTAssertEqual(layer.wantsExtendedDynamicRangeContent, hdr, line: line)
      XCTAssertEqual(layer.edrMetadata != nil, hdr && CAEDRMetadata.isAvailable, line: line)
    }
    let rec709 = signal(kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2)
    check(rec709, .bgr10a2Unorm, CGColorSpace.itur_709, hdr: false)
    check(
      signal(kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_2020),
      .bgr10a2Unorm, CGColorSpace.itur_2020, hdr: false)
    check(
      signal(kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_2100_HLG),
      .rgba16Float, CGColorSpace.itur_2100_HLG, hdr: true)
    check(
      signal(kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
      .rgba16Float, CGColorSpace.itur_2100_PQ, hdr: true)
    // Back to SDR: EDR off, metadata cleared.
    check(rec709, .bgr10a2Unorm, CGColorSpace.itur_709, hdr: false)
    // Untagged and declared-log pictures stay Rec.709 code values, as before.
    check(nil, .bgr10a2Unorm, CGColorSpace.itur_709, hdr: false)
    check(
      signal(
        kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_2100_HLG,
        profile: "sony-slog3-sgamut3cine"),
      .bgr10a2Unorm, CGColorSpace.itur_709, hdr: false)
    check(signal(nil, nil), .bgr10a2Unorm, CGColorSpace.itur_709, hdr: false)
  }

  /// Drawn through the display link: an HLG frame switches the picture layer
  /// to half-float EDR in the HLG colorspace, and a Rec.709 frame switches it back.
  @MainActor func testDrawnHLGFrameSwitchesThePictureLayerToEDR() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = true
    defer { MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = false }
    let presenter = MonitorSurfacePresenter(runtime: MonitorRuntime())
    let picture = try XCTUnwrap(presenter.makeView() as? MonitorPictureNSView)
    picture.frame = NSRect(x: 0, y: 0, width: 160, height: 90)
    let window = NSWindow(
      contentRect: picture.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = picture
    window.orderFrontRegardless()
    defer {
      window.close()
      window.contentView = nil
    }
    func frame(_ sequence: UInt64, primaries: CFString, transfer: CFString) throws -> Fixture {
      let base = try fixture(sequence: sequence, configuration: MonitorConfiguration())
      return Fixture(
        bundle: MonitorFrameBundle(
          stamp: base.stamp, source: base.bundle.source,
          sourceSignal: MonitorFrameSignal(
            range: .full, matrix: .bt2020, transfer: transfer as String,
            primaries: primaries as String, transferFunction: transfer as String)),
        configuration: base.configuration)
    }
    presenter.accept(
      try frame(1, primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
        transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG))
    guard await waitQuietly({ presenter.statistics.lastPresented?.sequence == 1 }) else {
      throw XCTSkip("The display link did not fire for this test window")
    }
    XCTAssertEqual(picture.metalLayer.pixelFormat, .rgba16Float)
    XCTAssertEqual(picture.metalLayer.colorspace?.name, CGColorSpace.itur_2100_HLG)
    XCTAssertTrue(picture.metalLayer.wantsExtendedDynamicRangeContent)
    presenter.accept(
      try frame(2, primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
        transfer: kCVImageBufferTransferFunction_ITU_R_709_2))
    try await waitFor { presenter.statistics.lastPresented?.sequence == 2 }
    XCTAssertEqual(picture.metalLayer.pixelFormat, .bgr10a2Unorm)
    XCTAssertEqual(picture.metalLayer.colorspace?.name, CGColorSpace.itur_709)
    XCTAssertFalse(picture.metalLayer.wantsExtendedDynamicRangeContent)
    // Let the half-float and 10-bit drawables finish on the GPU.
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(presenter.statistics.failures, 0)
  }

  /// A frozen surface takes no frames, and its hold becomes a GPU copy at
  /// once (no window, no display link), so no capture buffer stays pinned.
  /// A surface that stops being drawable drops its waiting frame.
  @MainActor func testFreezeAndHiddenSurfacesHoldNoProducerBuffer() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let presenter = MonitorSurfacePresenter(runtime: MonitorRuntime())
    let first = try fixture(sequence: 1, configuration: MonitorConfiguration())
    presenter.accept(first)
    presenter.toggleFreeze()
    XCTAssertTrue(presenter.isFrozen)
    presenter.accept(try fixture(sequence: 2, configuration: MonitorConfiguration()))
    XCTAssertEqual(presenter.statistics.acceptedFrames, 1, "A frozen surface keeps no new frame")
    XCTAssertEqual(presenter.currentStamp, first.stamp)
    try await waitFor { !presenter.holdsProducerFrame }
    XCTAssertEqual(presenter.statistics.failures, 0)
    presenter.toggleFreeze()
    presenter.reportVisibility(presented: true, drawable: true)
    presenter.accept(try fixture(sequence: 3, configuration: MonitorConfiguration()))
    XCTAssertTrue(presenter.holdsProducerFrame)
    // Hidden: the waiting frame is dropped; frames replaced while the display
    // link is paused are not counted as superseded.
    presenter.reportVisibility(presented: false, drawable: false)
    XCTAssertFalse(presenter.holdsProducerFrame)
    XCTAssertEqual(presenter.status, "Paused / hidden")
    presenter.accept(try fixture(sequence: 4, configuration: MonitorConfiguration()))
    presenter.accept(try fixture(sequence: 5, configuration: MonitorConfiguration()))
    XCTAssertEqual(presenter.statistics.supersededFrames, 0)
    // Freezing while hidden still swaps the producer frame for a GPU copy.
    presenter.toggleFreeze()
    XCTAssertTrue(presenter.isFrozen)
    try await waitFor { !presenter.holdsProducerFrame }
    XCTAssertEqual(presenter.currentStamp?.sequence, 5)
    presenter.toggleFreeze()
    presenter.reportVisibility(presented: true, drawable: true)
    presenter.accept(try fixture(sequence: 6, configuration: MonitorConfiguration()))
    XCTAssertEqual(presenter.currentStamp?.sequence, 6)
  }

  /// A picture whose window cannot be seen starts with its display link
  /// paused (it used to draw until the first visibility change), and runs
  /// once the view becomes drawable.
  @MainActor func testDisplayLinkStartsPausedWhileTheWindowCannotBeSeen() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let presenter = MonitorSurfacePresenter(runtime: MonitorRuntime())
    let picture = try XCTUnwrap(presenter.makeView() as? MonitorPictureNSView)
    picture.frame = NSRect(x: 0, y: 0, width: 160, height: 90)
    let window = NSWindow(
      contentRect: picture.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = picture
    window.orderFrontRegardless()
    defer {
      MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = false
      window.close()
      window.contentView = nil
    }
    guard !picture.isDrawable else {
      throw XCTSkip("The test window is visible; the paused start needs an unseen window")
    }
    presenter.accept(try fixture(sequence: 1, configuration: MonitorConfiguration()))
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(presenter.statistics.presentedFrames, 0, "An unseen window's link stays paused")
    MonitorVisibilityNSView.treatsPresentedViewsAsDrawable = true
    picture.reportVisibility()
    if await waitQuietly({ presenter.statistics.presentedFrames > 0 }) {
      XCTAssertEqual(presenter.statistics.failures, 0)
      XCTAssertEqual(presenter.statistics.lastPresented?.sequence, 1)
    }
  }

  /// Like waitFor, but reports instead of failing (for display-link-dependent checks).
  @MainActor private func waitQuietly(_ condition: () -> Bool) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    let met = condition()
    if !met { print("MONITOR_UI_TEST display link did not draw within 3 s") }
    return met
  }

  @MainActor private func waitFor(
    _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(
      condition(), "Synthetic native window transition must complete within 3 seconds",
      file: file, line: line)
  }

  @MainActor func testCancelWinsAcceptedButNotPublishedPendingFreeze() async throws {
    let presenter = MonitorSurfacePresenter()
    let other = MonitorSurfacePresenter()
    presenter.requestFreezeOnNextFrame()
    let accepted = try fixture(sequence: 4, configuration: MonitorConfiguration())
    presenter.accept(accepted)
    other.accept(try fixture(sequence: 5, configuration: MonitorConfiguration()))
    // No main-queue publication can run between admission and cancellation.
    XCTAssertTrue(presenter.isFreezePending)
    presenter.cancelPendingFreeze()
    await Task.yield()
    presenter.setClean(true)
    other.setClean(false)
    XCTAssertFalse(presenter.isFreezePending)
    XCTAssertFalse(presenter.isFrozen)
    XCTAssertEqual(presenter.currentStamp, accepted.stamp)
    XCTAssertTrue(presenter.detail.contains("4.000"))
    XCTAssertFalse(other.isFrozen)
    XCTAssertEqual(other.currentStamp?.sequence, 5)
    presenter.toggleFreeze()
    XCTAssertTrue(presenter.isFrozen)
    presenter.cancelPendingFreeze()  // Preserve an already published freeze.
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertEqual(presenter.currentStamp, accepted.stamp)
  }

  @MainActor func testOutOfOrderCompletionCannotRollBackOrChangePresenterTarget() async throws {
    let presenter = MonitorSurfacePresenter()
    let config = MonitorConfiguration()
    let newest = try fixture(sequence: 8, configuration: config, revision: 3, processing: 4)
    presenter.accept(newest)
    presenter.accept(try fixture(sequence: 7, configuration: config, revision: 3, processing: 4))
    presenter.accept(try fixture(sequence: 9, configuration: config, revision: 2, processing: 4))
    presenter.accept(try fixture(sequence: 9, configuration: config, revision: 3, processing: 3))
    presenter.accept(
      try fixture(sequence: 9, configuration: config, revision: 3, processing: 4, target: "other"))
    XCTAssertEqual(presenter.currentStamp, newest.stamp)
    presenter.accept(newest)  // Equal sequence is a valid matching-result update.
    presenter.setUnavailable("Feed stopped")
    presenter.accept(try fixture(sequence: 7, configuration: config, revision: 3, processing: 4))
    XCTAssertNil(presenter.currentStamp)
    let restarted = try fixture(sequence: 1, configuration: config, generation: 2, revision: 1)
    presenter.accept(restarted)
    presenter.accept(newest)  // The retired generation cannot return after restart.
    await Task.yield()
    presenter.setClean(false)
    XCTAssertEqual(presenter.currentStamp, restarted.stamp)
    XCTAssertEqual(presenter.status, "Live")
  }

  @MainActor func testInvalidPublicationCannotResurrectOrSatisfyPendingFreeze() async throws {
    let presenter = MonitorSurfacePresenter()
    let config = MonitorConfiguration()
    presenter.accept(try fixture(sequence: 1, configuration: config))
    presenter.setUnavailable("Preview hidden")
    let stale = try fixture(sequence: 2, configuration: config)
    presenter.accept(stale, ifCurrent: { false })
    await Task.yield()
    XCTAssertNil(presenter.currentStamp)
    XCTAssertEqual(presenter.status, "Preview hidden")
    presenter.requestFreezeOnNextFrame()
    presenter.accept(stale, ifCurrent: { false })
    await Task.yield()
    XCTAssertTrue(presenter.isFreezePending)
    XCTAssertFalse(presenter.isFrozen)
    XCTAssertNil(presenter.currentStamp)
    let current = try fixture(sequence: 3, configuration: config)
    presenter.accept(current, ifCurrent: { true })
    await Task.yield()
    presenter.setClean(false)
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertFalse(presenter.isFreezePending)
    XCTAssertEqual(presenter.currentStamp, current.stamp)
  }

  @MainActor func testScopeVisibilityIsLocalAndDoesNotChangeSharedConfiguration() throws {
    var configuration = MonitorConfiguration()
    configuration.toolsEnabled = true
    configuration.scopes.enabled = true
    var probes: [String: NSView] = [:]
    let root = HStack {
      ForEach([false, true], id: \.self) { visible in
        MonitorTileChrome(
          target: .constant(MonitorTargetID("shared")), configuration: .constant(configuration),
          choices: [], status: "Frozen", showsScopes: visible
        ) {
          Color.black.frame(height: 90)
        } scopes: {
          Color.gray.frame(height: 120).background(
            LayoutProbe { probes[visible ? "shown" : "hidden"] = $0 })
        }
      }
    }.frame(width: 600)
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
    host.layoutSubtreeIfNeeded()
    XCTAssertNil(probes["hidden"])
    XCTAssertNotNil(probes["shown"])
    XCTAssertTrue(configuration.scopes.enabled)
  }

  @MainActor func testZoomTransformsPictureAndGuideTogetherAtBoundedScale() throws {
    XCTAssertEqual(MonitorPictureZoom(.infinity).scale, 1)
    XCTAssertEqual(MonitorPictureZoom(99).scale, 4)
    var probes: [String: NSView] = [:]
    let root = ZStack {
      Color.black.background(LayoutProbe { probes["picture"] = $0 })
      Color.clear.background(LayoutProbe { probes["guide"] = $0 })
    }.frame(width: 80, height: 40).modifier(MonitorPictureZoom(2)).frame(width: 80, height: 40)
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: 80, height: 40)
    host.layoutSubtreeIfNeeded()
    let picture = try XCTUnwrap(probes["picture"])
    let guide = try XCTUnwrap(probes["guide"])
    let pictureRect = picture.convert(picture.bounds, to: host)
    let guideRect = guide.convert(guide.bounds, to: host)
    XCTAssertEqual(pictureRect, guideRect)
    XCTAssertEqual(pictureRect.width, 160, accuracy: 1)
    XCTAssertEqual(pictureRect.height, 80, accuracy: 1)
    XCTAssertEqual(pictureRect.midX, host.bounds.midX, accuracy: 1)
    XCTAssertEqual(pictureRect.midY, host.bounds.midY, accuracy: 1)
  }

  private func fixture(
    sequence: UInt64, configuration: MonitorConfiguration, transfer: String = "Synthetic signal",
    generation: UInt64 = 1, revision: UInt64? = nil, processing: UInt64 = 0,
    target: String = "synthetic"
  ) throws -> Fixture {
    var buffer: CVPixelBuffer?
    let result = CVPixelBufferCreate(
      kCFAllocatorDefault, 16, 9, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    XCTAssertEqual(result, kCVReturnSuccess)
    let pixelBuffer = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let address = CVPixelBufferGetBaseAddress(pixelBuffer) {
      memset(address, Int32(truncatingIfNeeded: sequence * 20), CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    let stamp = MonitorFrameStamp(
      target: MonitorTargetID(target), generation: generation, sequence: sequence,
      sourcePTS: Double(sequence), hostTime: ProcessInfo.processInfo.systemUptime,
      configurationRevision: revision ?? sequence, processingRevision: processing)
    return Fixture(
      bundle: MonitorFrameBundle(
        stamp: stamp, source: pixelBuffer,
        sourceSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: transfer)),
      configuration: configuration)
  }
}

private struct Fixture {
  let bundle: MonitorFrameBundle
  let configuration: MonitorConfiguration
  var stamp: MonitorFrameStamp { bundle.stamp }
}

extension MonitorSurfacePresenter {
  fileprivate func accept(_ fixture: Fixture, ifCurrent: () -> Bool = { true }) {
    accept(fixture.bundle, configuration: fixture.configuration, ifCurrent: ifCurrent)
  }
}

@MainActor private struct LayoutProbe: NSViewRepresentable {
  let capture: (NSView) -> Void
  init(_ capture: @escaping (NSView) -> Void) { self.capture = capture }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    capture(view)
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) { capture(nsView) }
}

private final class ScopeTimingProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var intervals = 0
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return intervals
  }
  func record(start: Double, end: Double) {
    lock.lock()
    if end > start { intervals += 1 }
    lock.unlock()
  }
}
