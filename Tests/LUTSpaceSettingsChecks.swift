#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@MainActor @objcMembers final class LUTSpaceSettingsChecks: XCTestCase {
  func testLegacyLUTSpacesStay709AndExplicitIDsRoundTrip() throws {
    let legacy = try JSONDecoder().decode(FeedDescriptor.self, from: Data(#"{"id":"feed","gamut":"S-Gamut3.Cine / S-Log3"}"#.utf8))
    XCTAssertEqual(legacy.lutInputSpaceID, "rec709-video")
    XCTAssertEqual(legacy.lutOutputSpaceID, "rec709-video")
    var declared = legacy
    declared.lutInputSpaceID = "canon-log2-cinemagamut"
    declared.lutOutputSpaceID = "rec2020-pq-video"
    let decoded = try JSONDecoder().decode(FeedDescriptor.self, from: JSONEncoder().encode(declared))
    XCTAssertEqual(decoded.lutInputSpaceID, declared.lutInputSpaceID)
    XCTAssertEqual(decoded.lutOutputSpaceID, declared.lutOutputSpaceID)
    XCTAssertEqual(try decoded.lutColorSpaceContract().input.transfer, .canonLog2)
    declared.lutInputSpaceID = "future-input"
    XCTAssertThrowsError(try declared.lutColorSpaceContract())
  }
  func testSourceProfileIsIndependentFromLUTEdges() {
    var feed = FeedDescriptor()
    feed.setSourceProfile("panasonic-vlog-vgamut")
    XCTAssertEqual(feed.sourceProfileID, "panasonic-vlog-vgamut")
    XCTAssertEqual(feed.monitor.signal.logProfileID, "panasonic-vlog-vgamut")
    XCTAssertEqual(feed.lutInputSpaceID, "rec709-video")
    XCTAssertEqual(feed.lutOutputSpaceID, "rec709-video")
  }
  func testUnknownDeclarationsRefuseProcessingAndPreserveIDs() {
    var feed = FeedDescriptor()
    feed.programColorSpaceID = "future-program"
    XCTAssertNotNil(feed.processingDeclarationError)
    XCTAssertEqual(feed.programColorSpaceID, "future-program")
    feed.programColorSpaceID = "rec709-video"
    feed.sourceProfileID = "future-source"
    XCTAssertNotNil(feed.processingDeclarationError)
    feed.sourceProfileID = "unspecified"
    XCTAssertNil(feed.processingDeclarationError)
  }
  func testExplicitProgramTargetsRemainIndependentFromLUTOutput() {
    var feed = FeedDescriptor()
    feed.programColorSpaceID = "rec2020-pq-video"
    XCTAssertEqual(feed.configuration.programColorimetry.transfer, .pq)
    XCTAssertEqual(feed.lutOutputSpaceID, "rec709-video")
    XCTAssertNil(feed.configuration.lutOutputColorimetry)
    feed.applyLUT = true; feed.lutBookmark = Data([1])
    feed.lutOutputSpaceID = "rec2020-hlg-video"
    XCTAssertEqual(feed.configuration.lutOutputColorimetry?.transfer, .hlg)
    XCTAssertNil(feed.processingDeclarationError)
  }
  func testExplicitMonitorDeclarationWinsOnlyWhenSourceIDMissing() throws {
    var preferences = MonitorFeedPreferences()
    preferences.signal.logProfileID = "panasonic-vlog-vgamut"
    let raw: [String: Any] = ["id": "feed", "gamut": "S-Gamut3.Cine / S-Log3",
      "monitor": try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences))]
    let conflict = try JSONSerialization.data(withJSONObject: raw)
    let migrated = try JSONDecoder().decode(FeedDescriptor.self, from: conflict)
    XCTAssertEqual(migrated.sourceProfileID, "panasonic-vlog-vgamut")
    XCTAssertEqual(migrated.monitor.signal.logProfileID, migrated.sourceProfileID)
    XCTAssertEqual(migrated.gamut, "S-Gamut3.Cine / S-Log3")
    XCTAssertEqual(migrated.lutInputSpaceID, "rec709-video")
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: conflict) as? [String: Any])
    object["sourceProfileID"] = "canon-log2-cinemagamut"
    let explicit = try JSONDecoder().decode(FeedDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(explicit.sourceProfileID, "canon-log2-cinemagamut")
    XCTAssertEqual(explicit.monitor.signal.logProfileID, explicit.sourceProfileID)
    object["sourceProfileID"] = "future-profile"
    let unknown = try JSONDecoder().decode(FeedDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(unknown.sourceProfileID, "future-profile")
    XCTAssertNotNil(unknown.processingDeclarationError)
    XCTAssertEqual(unknown.monitor.signal.logProfileID, "future-profile")
    object.removeValue(forKey: "sourceProfileID")
    preferences.signal.logProfileID = nil
    object["monitor"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences))
    let fallback = try JSONDecoder().decode(FeedDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(fallback.sourceProfileID, "sony-slog3-sgamut3cine")
    XCTAssertEqual(fallback.monitor.signal.logProfileID, fallback.sourceProfileID)
  }

}
#endif
