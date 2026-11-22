// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import MonitorKitUI

final class Perf17ScenePublicationTests: XCTestCase {
  func testIdenticalMembershipDoesNotInvalidateScene() {
    let source = MonitorSource()
    let a = MonitorSurface(source: source), b = MonitorSurface(source: source)
    let x = MonitorScopeOverlay(source: source), y = MonitorScopeOverlay(source: source)
    let scene = MonitorScene(surfaces: [a, b], scopes: [x, y])
    let revision = scene.revision()
    for _ in 0..<100 {
      scene.surfaces = [a, b]
      scene.scopes = [x, y]
    }
    XCTAssertEqual(scene.revision(), revision)
    scene.surfaces = [b, a]
    XCTAssertEqual(scene.revision(), revision + 1)
    scene.scopes = [y, x]
    XCTAssertEqual(scene.revision(), revision + 2)
    scene.surfaces = [b, b]
    XCTAssertEqual(scene.revision(), revision + 3)
    scene.scopes = [y]
    XCTAssertEqual(scene.revision(), revision + 4)
    scene.scopes = [y]
    XCTAssertEqual(scene.revision(), revision + 4)
  }
}
