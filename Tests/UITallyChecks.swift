import Foundation
import SwiftUI
import XCTest

/// README section 4's tally: red needs frames arriving, not just a client, and the
/// word says which route. Every line of the rule, in both output modes.
@objcMembers final class UITallyChecks: XCTestCase {
  private func camera(_ index: Int, running: Bool = true, signal: UISignal = .live(format: "2160p 59.94"),
    client: Bool = false, sink: Bool = false) -> UICameraSnapshot {
    var camera = UICameraSnapshot(id: "camera-\(index)", name: "Camera \(index)")
    camera.running = running
    camera.signal = running ? signal : .none
    camera.inUse = client
    camera.sinkConnected = sink
    return camera
  }

  private func program(_ cameras: [UICameraSnapshot], client: Bool = true, sink: Bool = true,
    pending: String? = nil) -> UISessionSnapshot {
    var session = UISessionSnapshot()
    session.cameras = cameras
    session.onAirID = cameras.first?.id
    session.pendingCutID = pending
    session.programInUse = client
    session.programSinkConnected = sink
    return session
  }

  private func separate(_ cameras: [UICameraSnapshot]) -> UISessionSnapshot {
    var session = UISessionSnapshot()
    session.cameras = cameras
    return session
  }

  private func tally(_ session: UISessionSnapshot, _ index: Int = 0) -> UITally {
    UIPresentationBuilder.tally(for: session.cameras[index], in: session)
  }

  func testOnAirNeedsAClientASinkAndFrames() {
    let two = [camera(1), camera(2)]
    XCTAssertEqual(tally(program(two)), .onAir)
    XCTAssertEqual(tally(program(two, client: false)), .program, "Nobody is watching")
    XCTAssertEqual(tally(program(two, sink: false)), .program, "A connect failure is red on black")
    XCTAssertEqual(tally(program([camera(1, signal: .noSignal), camera(2)])), .noPicture, "No frames, no red")
    XCTAssertEqual(tally(program([camera(1, signal: .connecting), camera(2)])), .program)
    XCTAssertEqual(tally(program([camera(1, running: false), camera(2)])), .program, "Red on a stopped camera")
  }

  func testProgramWordNeedsTwoCameras() {
    XCTAssertEqual(tally(program([camera(1)], client: false)), .none, "One camera has nothing to switch")
    XCTAssertEqual(tally(program([camera(1), camera(2)], client: false)), .program)
  }

  func testISONeedsItsOwnClientSinkAndFrames() {
    XCTAssertEqual(tally(separate([camera(1, client: true, sink: true)])), .iso)
    XCTAssertEqual(tally(separate([camera(1, client: false, sink: true)])), .none,
      "An open sink is not a viewer: this was the false ON AIR")
    XCTAssertEqual(tally(separate([camera(1, client: true, sink: false)])), .none)
    XCTAssertEqual(tally(separate([camera(1, signal: .noSignal, client: true, sink: true)])), .none)
    XCTAssertEqual(tally(separate([camera(1, running: false, client: true, sink: true)])), .none)
  }

  func testProgramWinsOverISOSoTwoRedsNeverHideWhichIsOnProgram() {
    let session = program([camera(1, client: true, sink: true), camera(2, client: true, sink: true)])
    XCTAssertEqual(tally(session, 0), .onAir)
    XCTAssertEqual(tally(session, 1), .iso)
    XCTAssertEqual(UITally.iso.badge, "ISO")
    XCTAssertEqual(UITally.iso.label, "ISO")
    XCTAssertTrue(UITally.iso.isRed)
    XCTAssertTrue(UITally.onAir.isRed)
    XCTAssertFalse(UITally.program.isRed)
    XCTAssertFalse(UITally.next.isRed)
  }

  func testNextNeverHidesRed() {
    let session = program([camera(1), camera(2, client: true, sink: true)], pending: "camera-2")
    XCTAssertEqual(tally(session, 1), .iso, "A pending camera seen on its own device is live")
    let output = UIPresentationBuilder.camera(session.cameras[1], index: 1, in: session).outputLine
    XCTAssertEqual(output, "Next", "A red camera still says Next on its output line")
    XCTAssertEqual(tally(program([camera(1), camera(2)], pending: "camera-2"), 1), .next)
    XCTAssertEqual(tally(program([camera(1), camera(2)], pending: "camera-1"), 0), .onAir)
  }

  func testRedAsksBeforeStoppingEitherRoute() {
    let iso = UIPresentationBuilder.session(separate([camera(1, client: true, sink: true)]))
    XCTAssertTrue(iso.cameras[0].stopNeedsConfirmation)
    XCTAssertEqual(iso.cameras[0].stopConfirmationMessage, "Camera 1 is on air. Stopping the camera ends its video output.")
    XCTAssertNotNil(UIAction.stopAllCameras.needsConfirmation(in: iso))
    let waiting = UIPresentationBuilder.session(separate([camera(1, signal: .noSignal, client: true, sink: true)]))
    XCTAssertFalse(waiting.cameras[0].stopNeedsConfirmation, "Nothing is reaching anyone")
  }

  func testUnknownClientIsNeitherInUseNorNotInUse() {
    var unknown = camera(1, sink: true)
    unknown.clientUnknown = true
    let session = separate([unknown])
    XCTAssertEqual(unknown.clientLine, "Use unknown")
    XCTAssertEqual(tally(session), .none, "Unknown is not red")
    let presentation = UIPresentationBuilder.session(session)
    XCTAssertEqual(presentation.cameras[0].outputLine, "Ultracam · Camera 1, use unknown")
    XCTAssertEqual(presentation.outputSummary, "Ultracam · Camera 1, use unknown")
    var known = camera(1)
    known.clientUnknown = false
    XCTAssertEqual(known.clientLine, "Not in use")
    var programUnknown = program([camera(1), camera(2)], client: false)
    programUnknown.programClientUnknown = true
    XCTAssertEqual(programUnknown.programClientLine, "Use unknown")
    XCTAssertEqual(UIPresentationBuilder.session(programUnknown).outputSummary, "Ultracam cameras: use unknown")
  }

  /// The Program picture's tally is Program's: a client of the on-air camera's own device
  /// isn't watching Program, so it's never red "ISO" there (it was the camera's own tally).
  @MainActor func testProgramTallyIsProgramsNeverISO() {
    let iso = program([camera(1, client: true, sink: true), camera(2)], client: false)
    XCTAssertEqual(tally(iso), .iso, "The camera's own picture says ISO")
    XCTAssertEqual(UIPresentationBuilder.programTally(iso), .program)
    XCTAssertEqual(UIPresentationBuilder.session(iso).programTally, .program)
    XCTAssertEqual(UIPresentationBuilder.programTally(program([camera(1), camera(2)])), .onAir)
    XCTAssertEqual(UIPresentationBuilder.programTally(program([camera(1, signal: .noSignal), camera(2)])), .noPicture)
    let waiting = program([camera(1, signal: .noSignal, client: true, sink: true), camera(2)])
    XCTAssertEqual(UIPresentationBuilder.programTally(waiting), .noPicture)
    var none = program([camera(1), camera(2)])
    none.onAirID = nil
    XCTAssertEqual(UIPresentationBuilder.programTally(none), .none)
    XCTAssertEqual(UIProgramPictureView.accessibilityLabel(onAir: "Camera 1", tally: .program), "Program, Camera 1 in Program",
      "Not \"selected\": selection isn't Program's")
    XCTAssertEqual(UIProgramPictureView.accessibilityLabel(onAir: "Camera 1", tally: .noPicture), "Program, Camera 1, no picture")
    XCTAssertEqual(UIProgramPictureView.accessibilityLabel(onAir: "Camera 1", tally: .onAir), "Program, Camera 1 on air")
  }

  /// J 13: the toolbar's dot is red only while frames reach Program's clients, not for being on Program.
  @MainActor func testCutButtonDotIsRedOnlyOnAir() {
    func dot(_ session: UISessionSnapshot, _ index: Int = 0) -> Color? {
      UICutButtonLabel.dot(UIPresentationBuilder.session(session).cutButtons[index])
    }
    XCTAssertEqual(dot(program([camera(1), camera(2)])), .red)
    XCTAssertEqual(dot(program([camera(1), camera(2)], client: false)), .secondary, "On Program, nobody watching: gray")
    XCTAssertEqual(dot(program([camera(1, client: true, sink: true), camera(2)], client: false)), .secondary,
      "An ISO client isn't Program's")
    XCTAssertEqual(dot(program([camera(1, signal: .noSignal), camera(2)])), .orange, "A meeting waiting on a picture")
    XCTAssertNil(dot(program([camera(1), camera(2)]), 1))
    XCTAssertEqual(dot(program([camera(1), camera(2)], pending: "camera-2"), 1), .green)
    XCTAssertEqual(UIToolbarCutGroup.programWords(UIPresentationBuilder.session(program([camera(1), camera(2)], client: false))
      .cutButtons[0]), "on Program")
  }

  /// D7: the menu bar's icon is about the camera a meeting sees, never the window's selection.
  func testMenuBarIconFollowsTheCameraAMeetingSees() {
    var bypassed = camera(1)
    bypassed.processing = false
    var session = program([bypassed, camera(2)])
    session.defaultFolderPath = "/Volumes/8TB/Takes"
    XCTAssertEqual(UIPresentationBuilder.problems(session).map(\.id), [])
    session.selectedID = "camera-2"
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(session), .bypass, "Program's camera has its effects off")
    session.selectedID = "camera-1"
    session.onAirID = "camera-2"
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(session), .live, "Selecting the bypassed camera changes nothing")
    var iso = separate([camera(1), { var c = camera(2, client: true, sink: true); c.processing = false; return c }()])
    iso.selectedID = "camera-1"
    iso.defaultFolderPath = "/Volumes/8TB/Takes"
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(iso), .bypass, "The meeting's camera, not the selected one")
  }

  func testPreviewPrefersOnAirThenISO() {
    let session = program([camera(1), camera(2, client: true, sink: true)])
    XCTAssertEqual(UIPresentationBuilder.session(session).previewCamera?.id, "camera-1")
    var offAir = session
    offAir.programInUse = false
    XCTAssertEqual(UIPresentationBuilder.session(offAir).previewCamera?.id, "camera-2")
  }
}
