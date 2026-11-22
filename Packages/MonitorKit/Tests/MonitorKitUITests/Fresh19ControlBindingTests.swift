// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitCore
import SwiftUI
import XCTest

@testable import MonitorKitUI

@MainActor
final class Fresh19ControlBindingTests: XCTestCase {
  func testSelectingNoFrameClearsAllActiveFrameGuides() {
    var state = MonitorState()
    state.guides.frameGuides = [FrameGuide(aspect: 16.0 / 9), FrameGuide(aspect: 2.39)]
    let binding = Binding(get: { state }, set: { state = $0 }).normalizing.guides
    let aspect = GuideControls.aspectBinding(binding)

    aspect.wrappedValue = 0

    XCTAssertEqual(aspect.wrappedValue, 0)
    XCTAssertTrue(state.guides.frameGuides.isEmpty)
  }

  func testFifthSafeAreaDoesNotReplaceAnExistingSelection() {
    var state = MonitorState()
    state.guides.safeAreas = [85, 90, 93, 95]
    let binding = Binding(get: { state }, set: { state = $0 }).normalizing.guides

    GuideControls.safeAreaBinding(binding, 80).wrappedValue = true

    XCTAssertEqual(state.guides.safeAreas, [85, 90, 93, 95])
    GuideControls.safeAreaBinding(binding, 90).wrappedValue = false
    GuideControls.safeAreaBinding(binding, 80).wrappedValue = true
    XCTAssertEqual(state.guides.safeAreas, [80, 85, 93, 95])
  }
}
