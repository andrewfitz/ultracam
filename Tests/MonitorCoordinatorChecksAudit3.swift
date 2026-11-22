import Combine
import Foundation
import MonitorKit
import XCTest

// Audit round 3 (app glue): regressions for the coordinator's diagnostics.
extension MonitorCoordinatorChecks {
  /// One transient failure marks the target degraded only while it is recent
  /// (`MonitorSurfacePresenter.failureShownFor`, as the tile shows it); after
  /// that the status is the picture's again and the failure stays counted.
  func testAudit3DiagnosticsDegradeOnlyOnARecentFailure() throws {
    _ = try requireMonitorGPU()
    let value = MonitorCoordinator()
    value.updateTargets(feeds: [FeedDescriptor(id: FeedID(rawValue: "alpha"), name: "Wide")], programAvailable: false)
    let target = MonitorTargetID("alpha")
    let id = UUID()
    let presenter = value.surface(id: id, target: target)
    value.registerSurface(id: id, target: target, isVisible: true, scopeVisible: false)
    defer { value.unregisterSurface(id: id) }
    func degraded() -> Bool {
      if case .degraded = value.diagnostics(for: target).availability { return true }
      return false
    }
    value.refreshDiagnostics()
    XCTAssertFalse(degraded())
    var publishedFailure = false
    let observation = value.diagnosticsPublisher.sink { _ in publishedFailure = degraded() }
    defer { observation.cancel() }
    presenter.recordFailure(MonitorKitError.gpu("one transient encode failure"))
    value.refreshDiagnostics()
    XCTAssertTrue(publishedFailure, "A diagnostics observer can read the current snapshot")
    XCTAssertTrue(degraded(), "A failure just now degrades the target")
    XCTAssertNotNil(presenter.statistics.lastFailure)
    RunLoop.main.run(until: Date().addingTimeInterval(MonitorSurfacePresenter.failureShownFor + 0.15))
    value.refreshDiagnostics()
    XCTAssertFalse(degraded(), "An old failure no longer pins the target as degraded")
    XCTAssertNil(presenter.statistics.lastFailure)
    XCTAssertEqual(presenter.statistics.failures, 1, "The failure stays counted")
    XCTAssertEqual(value.diagnostics(for: target).failures, 1)
  }
}
