import AppKit
import MonitorToolsCore
import SwiftUI
import XCTest

/// Captures the registry payload emitted by the real AppModel without opening
/// the installed camera provider or registering CMIO listeners.
@MainActor private final class CapturingRegistryPublisher: AppVirtualCameraRegistryPublishing {
  private(set) var snapshots: [VirtualCameraRegistrySnapshot] = []
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) { snapshots.append(snapshot) }
}

@MainActor @objcMembers final class MonitorAppIntegrationChecks: XCTestCase {
  private let alpha = FeedID(rawValue: "monitor-integration-alpha")
  private let beta = FeedID(rawValue: "monitor-integration-beta")

  func testRemovingIdleFeedRefreshesMonitorAndRegistryProjections() throws {
    for removeSelected in [false, true] {
      let suiteName = "org.ultracam.monitor-app-integration.\(UUID().uuidString)"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }
      let settings = AppSettingsStore(defaults: defaults)
      let registry = VirtualCameraRegistryStore(defaults: defaults)
      let publisher = CapturingRegistryPublisher()
      let removed = removeSelected ? alpha : beta
      let retained = removeSelected ? beta : alpha
      let removedTarget = MonitorTargetID(removed.rawValue)
      let retainedTarget = MonitorTargetID(retained.rawValue)
      var workspace = MonitorWorkspaceState()
      workspace.isConfigured = true
      workspace.tileBindings = [removedTarget, retainedTarget, nil, nil]
      let feeds = [
        FeedDescriptor(id: alpha, name: "Integration Wide", selectedDevice: "integration-device-a",
          applyLUT: false, automaticFeed: false),
        FeedDescriptor(id: beta, name: "Integration Tight", selectedDevice: "integration-device-b",
          applyLUT: false, automaticFeed: false),
      ]
      settings.saveSnapshot(AppSettingsSnapshot(feeds: feeds, selectedFeedID: alpha,
        outputMode: .separateCameras, monitorWorkspace: workspace))
      let model = AppModel(settingsStore: settings, registryStore: registry,
        registryPublisher: publisher, recordingFolderStore: RecordingFolderStore(defaults: defaults),
        hardware: .offline)
      let selectedControllers = Mirror(reflecting: model).children.compactMap {
        $0.value as? CaptureController
      }
      XCTAssertEqual(selectedControllers.count, 1)
      let oldSelectedUpdate = try XCTUnwrap(selectedControllers.first?.onUpdate)
      let coordinator = model.monitorCoordinator
      let removedID = UUID()
      let retainedID = UUID()
      let removedPresenter = coordinator.surface(id: removedID, target: removedTarget)
      let removedSink = coordinator.captureSink(for: removedTarget)
      var demand: Set<MonitorTargetID> = []
      let modelDemandChanged = coordinator.onDemandChange
      coordinator.onDemandChange = { next in
        modelDemandChanged?(next)
        demand = next
      }
      coordinator.registerSurface(id: removedID, target: removedTarget,
        isVisible: true, scopeVisible: false)
      coordinator.registerSurface(id: retainedID, target: retainedTarget,
        isVisible: true, scopeVisible: false)
      defer {
        coordinator.unregisterSurface(id: removedID)
        coordinator.unregisterSurface(id: retainedID)
      }
      XCTAssertEqual(demand, [removedTarget, retainedTarget])
      XCTAssertTrue(removedSink.needsOutput)
      let publishedBefore = try XCTUnwrap(publisher.snapshots.last)
      XCTAssertEqual(publishedBefore.devices.count, 2)
      XCTAssertFalse(model.running)
      XCTAssertTrue(model.recordingModel.feeds.allSatisfy { $0.status == .idle })

      XCTAssertTrue(model.removeFeed(removed))

      XCTAssertEqual(model.feedDescriptors.map(\.id), [retained])
      XCTAssertEqual(model.selectedFeedID, retained)
      XCTAssertEqual(coordinator.targets.map(\.id), [retainedTarget],
        "The real removeFeed path must immediately retire the old chooser option")
      XCTAssertEqual(demand, [retainedTarget])
      XCTAssertFalse(removedSink.needsOutput)
      XCTAssertEqual(removedPresenter.status, "Missing feed")
      XCTAssertEqual(coordinator.workspace.tileBindings[0], removedTarget,
        "A removed feed remains visibly missing instead of silently rebinding")
      let persisted = settings.loadSnapshot()
      XCTAssertEqual(persisted.feeds.map(\.id), [retained])
      XCTAssertEqual(persisted.monitorWorkspace.tileBindings[0], removedTarget)
      let publishedAfter = try XCTUnwrap(publisher.snapshots.last)
      XCTAssertEqual(publishedAfter.devices.compactMap(\.feedID), [retained.rawValue],
        "AppModel must publish its new topology to the camera transport boundary")
      XCTAssertGreaterThan(publishedAfter.generation, publishedBefore.generation)
      XCTAssertEqual(registry.load()?.devices, publishedAfter.devices)
      if removeSelected {
        oldSelectedUpdate(CaptureUpdate(message: "Late stop from removed feed", stopped: true))
        XCTAssertEqual(removedPresenter.status, "Missing feed",
          "A queued stop from a removed controller must not overwrite the missing target")
        XCTAssertEqual(demand, [retainedTarget])
        XCTAssertEqual(coordinator.targets.map(\.id), [retainedTarget])
      }
      XCTAssertFalse(model.running)
      XCTAssertTrue(model.recordingModel.feeds.allSatisfy { $0.status == .idle })
    }
  }

  func testDetachedWindowCanClearAndRebindTheTargetUsedByItsChooser() throws {
    let alphaTarget = MonitorTargetID(alpha.rawValue)
    let betaTarget = MonitorTargetID(beta.rawValue)
    let coordinator = MonitorCoordinator()
    coordinator.updateTargets(feeds: [
      FeedDescriptor(id: alpha, name: "Integration Wide"),
      FeedDescriptor(id: beta, name: "Integration Tight"),
    ], programAvailable: false)
    let workspaceBefore = coordinator.workspace
    var demand: Set<MonitorTargetID> = []
    coordinator.onDemandChange = { demand = $0 }
    let owner = MonitorDetachedWindows.open(coordinator: coordinator, target: alphaTarget)
    let detached = owner.window
    defer { detached.close() }
    XCTAssertTrue(spinUntil { demand == [alphaTarget] })
    XCTAssertEqual(detached.title, "Monitor · Integration Wide")
    XCTAssertGreaterThan(try XCTUnwrap(detached.contentView).fittingSize.height, 100)

    // The actual target picker binds directly to this window-owned state.
    owner.target = nil

    XCTAssertTrue(spinUntil { demand.isEmpty }, "Clearing a detached tile must retire its old surface")
    XCTAssertFalse(coordinator.captureSink(for: alphaTarget).needsOutput)
    detached.contentView?.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(try XCTUnwrap(detached.contentView).fittingSize.height, 100,
      "An empty detached monitor must retain its chooser and visible empty-state picture")
    XCTAssertEqual(detached.title, "Monitor · Choose a feed")

    owner.target = betaTarget

    XCTAssertTrue(spinUntil { demand == [betaTarget] })
    XCTAssertFalse(coordinator.captureSink(for: alphaTarget).needsOutput)
    // OS occlusion may suspend pixel work while the new presented target's
    // capture intent remains active; demand is the rebind contract here.
    XCTAssertEqual(detached.title, "Monitor · Integration Tight")
    XCTAssertGreaterThan(try XCTUnwrap(detached.contentView).fittingSize.height, 100)
    XCTAssertEqual(coordinator.workspace, workspaceBefore,
      "Detached choices must remain independent of main workspace bindings")
    detached.close()
    XCTAssertTrue(spinUntil { demand.isEmpty })
  }

  private func spinUntil(_ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(2)
    repeat {
      if predicate() { return true }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    } while Date() < deadline
    return predicate()
  }

}

NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.finishLaunching()

let suite = XCTestSuite(name: "Ultracam App monitor integration")
suite.addTest(XCTestSuite(forTestCaseClass: MonitorAppIntegrationChecks.self))
suite.addTest(XCTestSuite(forTestCaseClass: MonitorCoordinatorChecks.self))
suite.run()
guard let run = suite.testRun, run.executionCount > 0 else { exit(2) }
exit(run.hasSucceeded ? 0 : 1)
