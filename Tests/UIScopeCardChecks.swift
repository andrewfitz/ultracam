import AppKit
import Foundation
import MonitorKitScopes
import XCTest

/// The scope card over a picture: where it starts, how a drag moves and resizes it, that it
/// stays on the picture and square for a vectorscope, and that its place is saved as a
/// share of the picture so it keeps it on any picture size.
@MainActor @objcMembers final class UIScopeCardChecks: XCTestCase {
  private let picture = CGSize(width: 1280, height: 720)

  private func inside(_ rect: CGRect, _ size: CGSize, file: StaticString = #filePath, line: UInt = #line) {
    let m = UIScopeCardFrame.margin
    XCTAssertGreaterThanOrEqual(rect.minX, m - 0.001, file: file, line: line)
    XCTAssertGreaterThanOrEqual(rect.minY, m - 0.001, file: file, line: line)
    XCTAssertLessThanOrEqual(rect.maxX, size.width - m + 0.001, file: file, line: line)
    XCTAssertLessThanOrEqual(rect.maxY, size.height - m + 0.001, file: file, line: line)
  }

  func testShapesFollowTheScope() {
    XCTAssertEqual(UIScopeCardShape(.vectorscope), .square)
    XCTAssertEqual(UIScopeCardShape(.waveform), .wide)
    XCTAssertEqual(UIScopeCardShape(.histogram), .wide)
  }

  func testDefaultsSitAboveTheBottomLabels() {
    let wide = UIScopeCardFrame.defaultRect(.wide, in: picture)
    XCTAssertEqual(wide.width / wide.height, 3, accuracy: 0.01, "A waveform starts 3:1")
    XCTAssertEqual(wide.minX, 10)
    XCTAssertEqual(wide.maxY, picture.height - UIScopeCardFrame.bottomLabels, accuracy: 0.01)
    let square = UIScopeCardFrame.defaultRect(.square, in: picture)
    XCTAssertEqual(square.width, square.height, "A vectorscope is square")
    XCTAssertEqual(square.maxX, picture.width - 10, accuracy: 0.01)
    XCTAssertEqual(square.maxY, picture.height - UIScopeCardFrame.bottomLabels, accuracy: 0.01)
    for size in [CGSize(width: 320, height: 180), CGSize(width: 100, height: 60), CGSize(width: 3840, height: 2160)] {
      for shape in UIScopeCardShape.allCases { inside(UIScopeCardFrame.defaultRect(shape, in: size), size) }
    }
  }

  func testAMoveStaysOnThePicture() {
    let start = UIScopeCardFrame.defaultRect(.wide, in: picture)
    let moved = UIScopeCardFrame.moved(start, by: CGSize(width: 300, height: -200), .wide, in: picture)
    XCTAssertEqual(moved.origin, CGPoint(x: start.minX + 300, y: start.minY - 200))
    XCTAssertEqual(moved.size, start.size, "Moving never resizes")
    let far = UIScopeCardFrame.moved(start, by: CGSize(width: 5000, height: 5000), .wide, in: picture)
    inside(far, picture)
    XCTAssertEqual(far.size, start.size)
  }

  func testAResizeKeepsTheCornerAndAVectorscopeSquare() {
    let start = CGRect(x: 100, y: 100, width: 300, height: 100)
    let wider = UIScopeCardFrame.resized(start, by: CGSize(width: 200, height: 50), .wide, in: picture)
    XCTAssertEqual(wider, CGRect(x: 100, y: 100, width: 500, height: 150))
    let tiny = UIScopeCardFrame.resized(start, by: CGSize(width: -1000, height: -1000), .wide, in: picture)
    XCTAssertEqual(tiny.size, UIScopeCardShape.wide.minimumSize)
    XCTAssertEqual(tiny.origin, start.origin, "Resizing never moves the card")

    let square = CGRect(x: 900, y: 300, width: 200, height: 200)
    let grown = UIScopeCardFrame.resized(square, by: CGSize(width: 40, height: 90), .square, in: picture)
    XCTAssertEqual(grown, CGRect(x: 900, y: 300, width: 290, height: 290), "The larger move wins")
    let capped = UIScopeCardFrame.resized(square, by: CGSize(width: 2000, height: 10), .square, in: picture)
    XCTAssertEqual(capped.width, capped.height)
    XCTAssertEqual(capped.origin, square.origin)
    inside(capped, picture)
  }

  func testAPlaceIsAShareOfThePicture() {
    let rect = CGRect(x: 320, y: 180, width: 480, height: 160)
    let frame = UIScopeCardFrame(rect, .wide, in: picture)
    XCTAssertEqual(frame.rect(.wide, in: picture), rect)
    let half = CGSize(width: 640, height: 360)
    XCTAssertEqual(frame.rect(.wide, in: half), CGRect(x: 160, y: 90, width: 240, height: 80))

    let square = CGRect(x: 1000, y: 400, width: 240, height: 240)
    let squareFrame = UIScopeCardFrame(square, .square, in: picture)
    let wider = squareFrame.rect(.square, in: CGSize(width: 1920, height: 720))
    XCTAssertEqual(wider.width, wider.height, "A vectorscope stays square on a wider picture")
    XCTAssertEqual(wider.height, 240, accuracy: 0.01, "Its side follows the picture's height")
  }

  func testPlacesAreSavedPerShapeAndReset() throws {
    let suiteName = "org.ultracam.tests.scope-card.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let places = UIScopeCardPlaces(defaults: defaults)
    XCTAssertEqual(places.rect(.wide, in: picture), UIScopeCardFrame.defaultRect(.wide, in: picture))
    let rect = CGRect(x: 40, y: 60, width: 600, height: 200)
    places.save(rect, .wide, in: picture)
    XCTAssertEqual(UIScopeCardPlaces(defaults: defaults).rect(.wide, in: picture), rect, "Saved")
    XCTAssertEqual(UIScopeCardPlaces(defaults: defaults).rect(.square, in: picture),
      UIScopeCardFrame.defaultRect(.square, in: picture), "Each shape has its own place")
    places.reset(.wide)
    XCTAssertEqual(UIScopeCardPlaces(defaults: defaults).rect(.wide, in: picture),
      UIScopeCardFrame.defaultRect(.wide, in: picture))
    defaults.set(Data("nonsense".utf8), forKey: UIScopeCardPlaces.key(.square))
    XCTAssertEqual(UIScopeCardPlaces(defaults: defaults).rect(.square, in: picture),
      UIScopeCardFrame.defaultRect(.square, in: picture), "An unreadable place falls back")
  }

  func testLabelsFollowTheDrawnShape() {
    var scopes = MonitorScopePreferences()
    scopes.settings = ScopeSettings(kind: .vectorscope)
    let description = UIScopeDescription(scopes: scopes, signal: nil, stageLUT: false, isProgram: false)
    let square = description.labels(width: 400, height: 400).filter { $0.role == .target }
    let wide = description.labels(width: 768, height: 256).filter { $0.role == .target }
    XCTAssertFalse(square.isEmpty)
    // On a square image the plot fills the width; on a 3:1 one it is the middle third.
    let squareSpan = (square.map(\.position.x).max() ?? 0) - (square.map(\.position.x).min() ?? 0)
    let wideSpan = (wide.map(\.position.x).max() ?? 0) - (wide.map(\.position.x).min() ?? 0)
    XCTAssertEqual(squareSpan / wideSpan, 3, accuracy: 0.05)
  }
}
