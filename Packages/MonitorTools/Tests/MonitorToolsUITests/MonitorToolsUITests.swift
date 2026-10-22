import AppKit
import AVFoundation
import CoreVideo
import MetalKit
import MonitorToolsCore
import SwiftUI
import XCTest

@testable import MonitorToolsMetal
@testable import MonitorToolsUI

final class MonitorToolsUITests: XCTestCase {
  @MainActor func testFailedLayerClearsIdentityWithoutUnfreezingSuccessfulHold() throws {
    let presenter = MonitorSurfacePresenter()
    let picture = try XCTUnwrap(presenter.makeView() as? MonitorPictureNSView)
    let result = try fixture(sequence: 1, configuration: MonitorConfiguration(), requiresIOSurface: false)
    presenter.accept(result)
    presenter.setClean(false)
    presenter.toggleFreeze()
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertTrue(picture.heldFrame === result.clean)
    picture.flushIfFailed(.rendering)
    XCTAssertTrue(picture.heldFrame === result.clean, "A successful frozen display stays held")
    picture.flushIfFailed(.failed)
    XCTAssertNil(picture.heldFrame, "Failure invalidates the identity even for the same frozen frame")
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertEqual(presenter.currentStamp, result.clean.stamp)
  }

  @MainActor func testOcclusionAndHiddenStatusPreserveSuccessfulFreeze() async throws {
    let presenter = MonitorSurfacePresenter()
    presenter.accept(try fixture(sequence: 1, configuration: MonitorConfiguration(), requiresIOSurface: false))
    await Task.yield()
    presenter.setClean(false)
    presenter.reportVisibility(presented: true, drawable: false)
    XCTAssertEqual(presenter.status, "Occluded")
    presenter.reportVisibility(presented: false, drawable: false)
    XCTAssertEqual(presenter.status, "Paused / hidden")
    presenter.reportVisibility(presented: true, drawable: true)
    presenter.accept(try fixture(sequence: 2, configuration: MonitorConfiguration(), requiresIOSurface: false))
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
    var diagnostic = MonitorDiagnostics()
    diagnostic.softDeadlineStatus = .exceeded
    let view = MonitorDiagnosticsView(snapshot: diagnostic, surfaceScopeTiming: "", presentationEstimate: "")
    XCTAssertEqual(view.deadline, "exceeded; last delivered picture is older than limit")
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
    XCTAssertEqual(first.configuration, nextConfiguration)
    XCTAssertFalse(first.isFrozen)
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
  @MainActor func testNativeFrozenCleanScopePairStaysFixedWhileOtherWindowContinues() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
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
    let old = try scopedFixture(sequence: 10, configuration: original, device: device)
    first.accept(old)
    second.accept(old)
    await Task.yield()
    first.setClean(false)
    second.setClean(false)
    try await waitFor {
      first.setClean(false)
      return firstPicture.heldFrame === old.decorated
    }
    first.toggleFreeze()
    XCTAssertTrue(firstPicture.heldFrame === old.decorated)
    var next = original
    next.scopes.mode = .lumaWaveform
    next.guides.centerCross = true
    let newer = try scopedFixture(sequence: 11, configuration: next, device: device)
    first.accept(newer)
    second.accept(newer)
    await Task.yield()
    first.setClean(true)
    second.setClean(false)
    try await waitFor {
      first.setClean(true)
      return firstPicture.heldFrame === old.clean
    }
    XCTAssertTrue(firstScope.result === old.scope)
    XCTAssertEqual(first.configuration, original)
    XCTAssertTrue(first.detail.contains("Scope PTS 10.000"))
    XCTAssertTrue(first.scopeTiming.contains("Frozen"))
    XCTAssertTrue(first.scopeTiming.contains("Scope PTS 10.000"))
    try await waitFor {
      second.setClean(false)
      return secondPicture.heldFrame === newer.decorated
    }
    XCTAssertTrue(secondScope.result === newer.scope)
    XCTAssertEqual(second.configuration, next)
    first.setClean(false)
    try await waitFor {
      first.setClean(false)
      return firstPicture.heldFrame === old.decorated
    }
    XCTAssertTrue(firstScope.result === old.scope)
    first.toggleFreeze()
    try await waitFor {
      first.setClean(false)
      return firstPicture.heldFrame === newer.decorated
    }
    XCTAssertTrue(firstScope.result === newer.scope)
  }
  @MainActor private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(condition(), "Synthetic native window transition must complete within 3 seconds")
  }
  private func scopedFixture(
    sequence: UInt64, configuration: MonitorConfiguration, device: MTLDevice,
    target: String = "synthetic", sharedLedger: MonitorAdmissionLedger? = nil
  ) throws -> MonitorDisplayResult {
    let cleanResult = try fixture(sequence: sequence, configuration: configuration, target: target)
    let decoratedPixels = try fixture(sequence: sequence + 20, configuration: configuration).clean
      .pixelBuffer
    let decorated = MonitorOwnedFrame(
      stamp: cleanResult.clean.stamp, pixelBuffer: decoratedPixels, releaseBudget: {})
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: 768, height: 256, mipmapped: false)
    descriptor.storageMode = .shared
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    let syntheticPixels = [UInt8](
      repeating: UInt8(truncatingIfNeeded: sequence * 3), count: 768 * 256 * 4)
    syntheticPixels.withUnsafeBytes { bytes in
      texture.replace(
        region: MTLRegionMake2D(0, 0, 768, 256), mipmapLevel: 0, withBytes: bytes.baseAddress!,
        bytesPerRow: 768 * 4)
    }
    let ledger = sharedLedger ?? MonitorAdmissionLedger()
    let lease = try XCTUnwrap(
      ledger.tryAcquire(
        target: cleanResult.clean.stamp.target, generation: 1, kind: .presentation,
        bytes: 768 * 256 * 4))
    let scope = MonitorScopeResult(
      texture: texture, stamp: cleanResult.clean.stamp, mode: configuration.scopes.mode,
      lease: lease,
      signal: MonitorFrameSignal(range: .legal, matrix: .bt709, transfer: "Synthetic scope"))
    return MonitorDisplayResult(
      clean: cleanResult.clean, decorated: decorated, scope: scope, configuration: configuration)
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
    XCTAssertEqual(presenter.currentStamp, accepted.clean.stamp)
    XCTAssertTrue(presenter.detail.contains("4.000"))
    XCTAssertFalse(other.isFrozen)
    XCTAssertEqual(other.currentStamp?.sequence, 5)
    presenter.toggleFreeze()
    XCTAssertTrue(presenter.isFrozen)
    presenter.cancelPendingFreeze()  // Preserve an already published freeze.
    XCTAssertTrue(presenter.isFrozen)
    XCTAssertEqual(presenter.currentStamp, accepted.clean.stamp)
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
    XCTAssertEqual(presenter.currentStamp, newest.clean.stamp)
    presenter.accept(newest)  // Equal sequence is a valid matching-result update.
    presenter.setUnavailable("Feed stopped")
    presenter.accept(try fixture(sequence: 7, configuration: config, revision: 3, processing: 4))
    XCTAssertNil(presenter.currentStamp)
    let restarted = try fixture(sequence: 1, configuration: config, generation: 2, revision: 1)
    presenter.accept(restarted)
    presenter.accept(newest)  // The retired generation cannot return after restart.
    await Task.yield()
    presenter.setClean(false)
    XCTAssertEqual(presenter.currentStamp, restarted.clean.stamp)
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
    XCTAssertEqual(presenter.currentStamp, current.clean.stamp)
  }
  @MainActor func testPresentationAdmissionRejectsSecondSurfaceAndRetriesAfterHide() async throws {
    let ledger = MonitorAdmissionLedger(maximumBytes: 20 * 1024 * 1024, cleanReserveBytes: 0)
    let first = MonitorSurfacePresenter(
      target: MonitorTargetID("first"), presentationLedger: ledger)
    let second = MonitorSurfacePresenter(
      target: MonitorTargetID("detached"), presentationLedger: ledger)
    first.reportVisibility(presented: true, drawable: true)
    second.reportVisibility(presented: true, drawable: true)
    first.setPresentationDemand(picture: true, scopes: true)
    second.setPresentationDemand(picture: true, scopes: true)
    XCTAssertTrue(first.isPresentationAdmitted)
    XCTAssertFalse(second.isPresentationAdmitted)
    XCTAssertTrue(second.presentationStatus.contains("unavailable"))
    XCTAssertLessThanOrEqual(ledger.snapshot.retainedBytes, ledger.maximumBytes)
    first.reportVisibility(presented: true, drawable: false)
    try await waitFor { second.isPresentationAdmitted }
    XCTAssertGreaterThan(ledger.snapshot.retainedBytes, 0)
    second.reportVisibility(presented: false, drawable: false)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    // The existing native preview carries no additional module surface allowance.
    first.setPresentationDemand(picture: false, scopes: false)
    first.reportVisibility(presented: true, drawable: true)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
  }
  @MainActor func testBackingResizeFailureClearsPresentationAndSmallerResizeRecovers() {
    let ledger = MonitorAdmissionLedger(maximumBytes: 20 * 1024 * 1024, cleanReserveBytes: 0)
    let presenter = MonitorSurfacePresenter(
      target: MonitorTargetID("resize"), presentationLedger: ledger)
    presenter.reportVisibility(presented: true, drawable: true)
    presenter.setPresentationDemand(picture: true, scopes: false)
    XCTAssertTrue(presenter.isPresentationAdmitted)
    XCTAssertFalse(presenter.resizePresentationBacking(CGSize(width: 4096, height: 2160)))
    XCTAssertFalse(presenter.isPresentationAdmitted)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    XCTAssertTrue(presenter.resizePresentationBacking(CGSize(width: 1280, height: 720)))
    XCTAssertTrue(presenter.isPresentationAdmitted)
    XCTAssertEqual(
      ledger.snapshot.retainedBytes,
      MonitorPresentationEstimate.pictureBytes(backingWidth: 1280, backingHeight: 720))
    presenter.setPresentationDemand(picture: false, scopes: false)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
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
  @MainActor func testScopePresentationReportsItsGPUInterval() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let timing = ScopeTimingProbe()
    let presenter = MonitorSurfacePresenter(gpuTiming: { start, end in
      timing.record(start: start, end: end)
    })
    let scope = try XCTUnwrap(presenter.makeScopeView() as? MonitorScopeNSView)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 160), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scope
    window.orderFrontRegardless()
    defer {
      window.close()
      window.contentView = nil
    }
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.scopes.enabled = true
    presenter.accept(try scopedFixture(sequence: 1, configuration: config, device: device))
    await Task.yield()
    presenter.setClean(false)
    XCTAssertEqual((scope.layer as? CAMetalLayer)?.maximumDrawableCount, 2)
    guard scope.currentDrawable != nil else { throw XCTSkip("Native scope drawable unavailable") }
    scope.draw()
    try await waitFor { timing.count > 0 }
  }
  @MainActor func testFeedRetirementDoesNotRetireLiveSurfaceEstimate() {
    let feed = MonitorTargetID("real-feed")
    let ledger = MonitorAdmissionLedger(maximumBytes: 64 * 1024 * 1024, cleanReserveBytes: 0)
    let presenter = MonitorSurfacePresenter(target: feed, presentationLedger: ledger)
    presenter.reportVisibility(presented: true, drawable: true)
    presenter.setPresentationDemand(picture: true, scopes: true)
    let retained = ledger.snapshot.retainedBytes
    XCTAssertGreaterThan(retained, 0)
    ledger.retire(target: feed, generation: 0)
    XCTAssertEqual(ledger.snapshot.retiredBytes, 0)
    XCTAssertEqual(ledger.snapshot.retainedBytes, retained)
    presenter.setPresentationDemand(picture: false, scopes: false)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
  }
  @MainActor func testFourUpNativeHostingReservesAllSurfaceEstimatesWithinSharedBudget() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let ledger = MonitorAdmissionLedger()
    let presenters = (0..<4).map {
      MonitorSurfacePresenter(target: MonitorTargetID("tile-\($0)"), presentationLedger: ledger)
    }
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
      presenters.forEach { $0.setPresentationDemand(picture: false, scopes: false) }
      window.close()
      window.contentView = nil
    }
    host.layoutSubtreeIfNeeded()
    for (index, presenter) in presenters.enumerated() {
      // Exercise admission even if the test runner's windows are OS-occluded.
      presenter.reportVisibility(presented: true, drawable: true)
      presenter.setPresentationDemand(picture: true, scopes: true)
      presenter.accept(
        try scopedFixture(
          sequence: 1, configuration: config, device: device, target: "tile-\(index)",
          sharedLedger: ledger))
      presenter.setClean(false)
      XCTAssertTrue(presenter.isPresentationAdmitted)
      XCTAssertTrue(presenter.presentationStatus.contains("allowance"))
    }
    XCTAssertGreaterThan(ledger.snapshot.retainedBytes, MonitorPresentationEstimate.scopeBytes * 4)
    XCTAssertLessThanOrEqual(ledger.snapshot.retainedBytes, ledger.maximumBytes)
    XCTAssertEqual(ledger.snapshot.retiredBytes, 0)
  }
  private func fixture(
    sequence: UInt64, configuration: MonitorConfiguration, transfer: String = "Synthetic signal",
    generation: UInt64 = 1, revision: UInt64? = nil, processing: UInt64 = 0,
    target: String = "synthetic", requiresIOSurface: Bool = true
  ) throws -> MonitorDisplayResult {
    var buffer: CVPixelBuffer?
    let result = CVPixelBufferCreate(
      kCFAllocatorDefault, 16, 9, kCVPixelFormatType_32BGRA,
      requiresIOSurface ? [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary : nil, &buffer)
    XCTAssertEqual(result, kCVReturnSuccess)
    let pixelBuffer = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let address = CVPixelBufferGetBaseAddress(pixelBuffer) {
      memset(address, Int32(sequence * 20), CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    let stamp = MonitorFrameStamp(
      target: MonitorTargetID(target), generation: generation, sequence: sequence,
      sourcePTS: Double(sequence), hostTime: ProcessInfo.processInfo.systemUptime,
      configurationRevision: revision ?? sequence, processingRevision: processing)
    let frame = MonitorOwnedFrame(stamp: stamp, pixelBuffer: pixelBuffer, releaseBudget: {})
    return MonitorDisplayResult(
      clean: frame, decorated: nil, scope: nil, configuration: configuration, availability: [],
      pictureSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: transfer))
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
