#if SOURCE_DECLARATION_CHECKS
import XCTest

/// Compiled with the actual UISupport declaration by test-source-declarations.py.
@objcMembers final class SourceDeclarationChecks: XCTestCase {
  func testSupportedSonyDeclarations() {
    XCTAssertEqual(UIMonitorBridge.sourceProfile(forGamut: "S-Gamut3.Cine / S-Log3"),
      "sony-slog3-sgamut3cine")
    XCTAssertEqual(UIMonitorBridge.sourceProfile(forGamut: "S-Gamut3 / S-Log3"),
      "sony-slog3-sgamut3")
  }

  func testUnmatchedDeclarationsDoNotInventSonyProfile() {
    for declaration in ["Unspecified / custom LUT", "Rec.709", "Rec.2020 / PQ",
      "Rec.2020 / HLG", "Canon Cinema Gamut / C-Log2", "Canon Cinema Gamut / C-Log3",
      "ARRI Wide Gamut 3 / LogC3", "ARRI Wide Gamut 4 / LogC4", "", "unknown Cine"] {
      XCTAssertNil(UIMonitorBridge.sourceProfile(forGamut: declaration), declaration)
    }
  }
}
#endif
