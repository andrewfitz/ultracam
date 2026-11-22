// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitCore
import SwiftUI
import XCTest

@testable import MonitorKitUI

@MainActor
final class SwiftUIGeometryAuditTests: XCTestCase {
  func testScaleCaptionDoesNotConvertUnboundedAxisValuesToIntegers() {
    let text = ScopeIREScale(axis: -1e20...1e20).rangeText
    XCTAssertTrue(text.hasPrefix("−"))
    XCTAssertTrue(text.contains("…"))
    XCTAssertFalse(ScopeIREScale(axis: -Double.infinity...Double.infinity).caption.isEmpty)
  }

  func testOverlayRejectsGeometryThatCannotDescribeADrawable() {
    let invalidSizes = [
      CGSize(width: CGFloat.infinity, height: 100),
      CGSize(width: 100, height: CGFloat.nan),
      CGSize(width: CGFloat.greatestFiniteMagnitude, height: 100),
      CGSize(width: -1, height: 100),
    ]
    for size in invalidSizes {
      XCTAssertNil(MonitorStatusOverlay.frame(of: .full, in: size, scale: 2))
    }
    for scale in [CGFloat.infinity, CGFloat.nan, CGFloat.greatestFiniteMagnitude] {
      XCTAssertNil(MonitorStatusOverlay.frame(of: .full, in: CGSize(width: 100, height: 100), scale: scale))
    }
    // A tiny positive view still maps to the minimum one-pixel drawable.
    XCTAssertEqual(
      MonitorStatusOverlay.frame(of: .full, in: CGSize(width: 0.1, height: 0.1), scale: 2),
      CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
  }
}
