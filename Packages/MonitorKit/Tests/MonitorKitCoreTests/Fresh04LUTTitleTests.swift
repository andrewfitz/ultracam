// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitCore
import XCTest

final class Fresh04LUTTitleTests: XCTestCase {
  func testWhitespaceOnlyTitleUsesTheDisplayableFallback() throws {
    let text = "TITLE \"   \t  \"\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n"
    XCTAssertEqual(try CubeLUT(text: text, fallbackTitle: "Camera look").title, "Camera look")
    XCTAssertEqual(try CubeLUT(text: text, fallbackTitle: " \t ").title, "Untitled LUT")
  }

  func testNonemptyTitlePreservesIntentionalWhitespace() throws {
    let text = "TITLE \" Look #1 \"\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n"
    XCTAssertEqual(try CubeLUT(text: text).title, " Look #1 ")
  }
}
