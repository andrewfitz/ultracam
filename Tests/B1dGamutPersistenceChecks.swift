#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@MainActor @objcMembers final class B1dGamutPersistenceChecks: XCTestCase {
    func testGamutMutationUpdatesStableProfileAndRoundTrips() throws {
        var feed = FeedDescriptor(id: .primary, name: "Camera 1", gamut: "S-Gamut3.Cine / S-Log3")
        XCTAssertEqual(feed.sourceProfileID, "sony-slog3-sgamut3cine")
        feed.setGamut("S-Gamut3 / S-Log3")
        XCTAssertEqual(feed.sourceProfileID, "sony-slog3-sgamut3")
        let decoded = try JSONDecoder().decode(FeedDescriptor.self, from: JSONEncoder().encode(feed))
        XCTAssertEqual(decoded.gamut, "S-Gamut3 / S-Log3")
        XCTAssertEqual(decoded.sourceProfileID, "sony-slog3-sgamut3")
        feed.setGamut("A future localized gamut")
        XCTAssertEqual(feed.sourceProfileID, "unspecified")
    }
}
#endif
