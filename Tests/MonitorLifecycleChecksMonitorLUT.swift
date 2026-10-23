import Foundation
import Metal
import MonitorKit
import XCTest

// A camera's monitor-only LUT (W4 step 7): saved in its monitor preferences as a
// bookmark (FeedDescriptor.monitorLUTBookmark / monitorLUTEnabled), kept by Reset
// and Copy, and loaded by the camera's feed host into MonitorFeed.monitorLUT.
extension MonitorLifecycleChecks {
  private static let invertCube = """
    TITLE "Monitor Invert"
    LUT_3D_SIZE 2
    1 1 1
    0 1 1
    1 0 1
    0 0 1
    1 1 0
    0 1 0
    1 0 0
    0 0 0
    """

  private static func monitorLUTFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ultracam-monitor-lut-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// A cube file and the bookmark the interface would save for it.
  private static func chosenMonitorLUT(_ text: String, named name: String, in folder: URL) throws -> LoadedLUT {
    let url = folder.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    final class Outcome: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: Result<LoadedLUT, any Error>?
      var value: Result<LoadedLUT, any Error>? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
      }
    }
    let outcome = Outcome()
    Task.detached {
      do { outcome.value = .success(try await MonitorFeedHost.monitorLUTLoader.load(url: url)) } catch {
        outcome.value = .failure(error)
      }
    }
    let deadline = Date().addingTimeInterval(10)
    while outcome.value == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    return try XCTUnwrap(outcome.value).get()
  }

  private func waitForMonitorLUT(
    _ host: MonitorFeedHost, timeout: TimeInterval = 10, until condition: (MonitorFeedHost.MonitorLUTState) -> Bool
  ) -> MonitorFeedHost.MonitorLUTState {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(host.monitorLUTState) && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return host.monitorLUTState
  }

  private var choice: MonitorLUTChoice { MonitorLUTChoice(bookmark: Data([1, 2, 3, 4]), fileName: "Show.cube") }

  func testMonitorLUTRoundTripsUnderTheMonitorKey() throws {
    var feed = FeedDescriptor(id: FeedID(rawValue: "a"), name: "Camera 1", applyLUT: true, lutBookmark: Data([9]))
    XCTAssertNil(feed.monitorLUTBookmark)
    XCTAssertTrue(feed.monitorLUTEnabled, "MonitorState.monitorLUT defaults on")
    feed.monitor.monitorLUT = choice
    feed.monitorLUTEnabled = false
    XCTAssertEqual(feed.monitorLUTBookmark, Data([1, 2, 3, 4]))
    XCTAssertFalse(feed.monitor.state.monitorLUT, "monitorLUTEnabled is MonitorState.monitorLUT")
    let data = try JSONEncoder().encode(AppSettingsSnapshot(feeds: [feed]))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let saved = try XCTUnwrap((object["feeds"] as? [[String: Any]])?.first)
    XCTAssertEqual(saved["version"] as? Int, 1, "The descriptor version stays 1")
    XCTAssertNil(saved["monitorLUTBookmark"], "No top-level key: the monitor preferences carry it")
    let monitor = try XCTUnwrap(saved["monitor"] as? [String: Any])
    let lut = try XCTUnwrap(monitor["monitorLUT"] as? [String: Any])
    XCTAssertEqual(lut["bookmark"] as? String, Data([1, 2, 3, 4]).base64EncodedString())
    XCTAssertEqual(lut["fileName"] as? String, "Show.cube")
    let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: data)
    XCTAssertNotNil(decoded.validated())
    XCTAssertEqual(decoded.feeds[0], feed)
    XCTAssertEqual(decoded.feeds[0].lutBookmark, Data([9]), "The burn-in LUT is separate")
    XCTAssertTrue(decoded.feeds[0].applyLUT)
    XCTAssertFalse(decoded.feeds[0].monitorLUTEnabled)
  }

  func testPreferencesWithoutAMonitorLUTWriteNoKey() throws {
    let data = try JSONEncoder().encode(MonitorFeedPreferences())
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNil(object["monitorLUT"])
    let decoded = try JSONDecoder().decode(MonitorFeedPreferences.self, from: data)
    XCTAssertNil(decoded.monitorLUT)
    XCTAssertTrue(decoded.monitorLUTEnabled)
    XCTAssertEqual(decoded, MonitorFeedPreferences())
  }

  /// A damaged monitorLUT value costs only the monitor LUT, never the camera's tools.
  func testBadMonitorLUTValueKeepsTheRest() throws {
    var tools = MonitorFeedPreferences()
    tools.toolsEnabled = true
    tools.state.guides.enabled = true
    let good = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tools)) as? [String: Any])
    let bad: [Any] = [["bookmark": ""], ["fileName": "x.cube"], ["bookmark": 7], "nope", NSNull()]
    for value in bad {
      var object = good
      object["monitorLUT"] = value
      let data = try JSONSerialization.data(withJSONObject: object)
      let decoded = try JSONDecoder().decode(MonitorFeedPreferences.self, from: data)
      XCTAssertNil(decoded.monitorLUT, "\(value)")
      XCTAssertEqual(decoded, tools, "\(value)")
    }
    var object = good
    object["monitorLUT"] = ["bookmark": Data([5]).base64EncodedString()]
    let nameless = try JSONDecoder().decode(MonitorFeedPreferences.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(nameless.monitorLUT, MonitorLUTChoice(bookmark: Data([5]), fileName: ""))
  }

  /// The monitor LUT is the camera's file choice, like the burn-in LUT and the
  /// signal declaration: Reset, Copy and a camera change keep it.
  func testResetCopyAndCameraChangeKeepTheMonitorLUT() {
    var camera = MonitorFeedPreferences()
    camera.monitorLUT = choice
    camera.monitorLUTEnabled = false
    camera.toolsEnabled = true
    camera.state.guides.enabled = true

    var reset = camera
    reset.resetTools()
    XCTAssertEqual(reset.monitorLUT, choice)
    XCTAssertFalse(reset.monitorLUTEnabled, "Shown or hidden as it was")
    var expected = MonitorFeedPreferences()
    expected.monitorLUT = choice
    expected.monitorLUTEnabled = false
    XCTAssertEqual(reset, expected, "Every tool is back to its default")

    var source = MonitorFeedPreferences()
    source.monitorLUT = MonitorLUTChoice(bookmark: Data([7]), fileName: "Other.cube")
    source.monitorLUTEnabled = true
    source.state.zebras[0].enabled = true
    var copied = camera
    copied.copyTools(from: source)
    XCTAssertEqual(copied.monitorLUT, choice, "The destination keeps its own monitor LUT")
    XCTAssertFalse(copied.monitorLUTEnabled)
    XCTAssertTrue(copied.state.zebras[0].enabled, "The tools are copied")
    var none = MonitorFeedPreferences()
    none.copyTools(from: source)
    XCTAssertNil(none.monitorLUT, "A monitor LUT is never copied to another camera")

    var moved = camera
    moved.forgetCameraCalibration()
    XCTAssertEqual(moved.monitorLUT, choice)
    XCTAssertFalse(moved.monitorLUTEnabled)
  }

  /// What a surface draws: the switch reaches MonitorState.monitorLUT whatever
  /// the master switch, and Program never loads one.
  func testSurfaceStateCarriesTheMonitorLUTSwitch() {
    var value = MonitorFeedPreferences()
    value.monitorLUT = choice
    value.toolsEnabled = false
    XCTAssertTrue(value.surfaceState(isProgram: false).monitorLUT, "The monitor LUT is a picture, not a tool")
    value.monitorLUTEnabled = false
    XCTAssertFalse(value.surfaceState(isProgram: false).monitorLUT)
    var state = MonitorFeedPreferences.defaultState
    state.monitorLUT = true
    state.pictureStage = .monitor
    XCTAssertTrue(state.pictureHasLUT(burnInLUT: false, monitorLUT: true))
    state.pictureStage = .output
    XCTAssertFalse(state.pictureHasLUT(burnInLUT: false, monitorLUT: true), "Only the Monitor picture shows it")
  }

  /// The feed host resolves the bookmark, builds one tetrahedral MonitorLUT on
  /// the shared device and hands it to MonitorFeed.monitorLUT; the same bookmark
  /// does nothing, nil clears it at once, and the burn-in LUT is untouched.
  func testFeedHostLoadsTheMonitorLUTBookmark() throws {
    guard let device = LUTProcessor.sharedDevice else { throw XCTSkip("No Metal device") }
    let folder = try Self.monitorLUTFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try Self.chosenMonitorLUT(Self.invertCube, named: "invert.cube", in: folder)
    let host = MonitorFeedHost(target: "monitor-lut-a", gpu: nil)
    let burnIn = try LUTProcessor.makeLUT(CubeLUT(text: MonitorCoordinatorChecks.identityCube))
    host.burnInLUT = burnIn
    XCTAssertEqual(host.monitorLUTState, .none)

    host.setMonitorLUTBookmark(file.bookmark)
    XCTAssertNotEqual(host.monitorLUTState, .none, "Loading starts at once, off this thread")
    XCTAssertEqual(waitForMonitorLUT(host) { $0 != .loading }, .loaded("Monitor Invert"))
    let lut = try XCTUnwrap(host.monitorLUT)
    XCTAssertEqual(lut.interpolation, .tetrahedral, "Tetrahedral only, like the burn-in LUT")
    XCTAssertTrue(lut.texture.device === device, "Built on the shared device")
    XCTAssertTrue(host.burnInLUT === burnIn)

    host.setMonitorLUTBookmark(file.bookmark)
    XCTAssertEqual(host.monitorLUTState, .loaded("Monitor Invert"), "The same bookmark does not reload")
    XCTAssertTrue(host.monitorLUT === lut)

    if let core = try? MonitorCoordinator.sharedGPU.core(), core.engine.device === device {
      let feed = host.feed(engine: core.engine)
      XCTAssertTrue(feed.monitorLUT === lut, "The host's monitor LUT is the feed's")
      XCTAssertTrue(feed.burnInLUT === burnIn)
      XCTAssertNil(host.lutMismatch)
      host.setMonitorLUTBookmark(nil)
      XCTAssertNil(host.feed(engine: core.engine).monitorLUT)
    } else {
      host.setMonitorLUTBookmark(nil)
    }
    XCTAssertEqual(host.monitorLUTState, .none, "Nil clears it at once")
    XCTAssertNil(host.monitorLUT)
    XCTAssertTrue(host.burnInLUT === burnIn)
  }

  /// A newer choice wins over a load still in flight, and a file that cannot be
  /// read shows nothing and says why.
  func testFeedHostMonitorLUTNewestChoiceWinsAndFailuresClear() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal device") }
    let folder = try Self.monitorLUTFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try Self.chosenMonitorLUT(Self.invertCube, named: "first.cube", in: folder)
    let second = try Self.chosenMonitorLUT(
      Self.invertCube.replacingOccurrences(of: "Monitor Invert", with: "Second"), named: "second.cube", in: folder)
    let host = MonitorFeedHost(target: "monitor-lut-b", gpu: nil)
    host.setMonitorLUTBookmark(first.bookmark)
    host.setMonitorLUTBookmark(second.bookmark)
    XCTAssertEqual(waitForMonitorLUT(host) { $0 != .loading }, .loaded("Second"))
    // Give the first load every chance to land late.
    _ = waitForMonitorLUT(host, timeout: 0.3) { _ in false }
    XCTAssertEqual(host.monitorLUTState, .loaded("Second"))
    XCTAssertEqual(host.monitorLUT?.cube.title, "Second")

    let missing = try Self.chosenMonitorLUT(Self.invertCube, named: "missing.cube", in: folder)
    try FileManager.default.removeItem(at: folder.appendingPathComponent("missing.cube"))
    host.setMonitorLUTBookmark(missing.bookmark)
    let failed = waitForMonitorLUT(host) { $0 != .loading && $0 != .loaded("Second") }
    guard case .failed(let reason) = failed else { return XCTFail("\(failed)") }
    XCTAssertFalse(reason.isEmpty)
    XCTAssertNil(host.monitorLUT, "A file that cannot be read shows no LUT")

    let broken = try Self.chosenMonitorLUT(Self.invertCube, named: "broken.cube", in: folder)
    try "LUT_3D_SIZE 2\n0 0 0".write(to: folder.appendingPathComponent("broken.cube"), atomically: false, encoding: .utf8)
    host.setMonitorLUTBookmark(second.bookmark)
    XCTAssertEqual(waitForMonitorLUT(host) { $0 != .loading && !Self.isFailure($0) }, .loaded("Second"))
    host.setMonitorLUTBookmark(broken.bookmark)
    XCTAssertTrue(Self.isFailure(waitForMonitorLUT(host) { Self.isFailure($0) }), "A file that does not parse")
    XCTAssertNil(host.monitorLUT)
  }

  func testProgramHostNeverLoadsAMonitorLUT() throws {
    let folder = try Self.monitorLUTFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try Self.chosenMonitorLUT(Self.invertCube, named: "program.cube", in: folder)
    let program = MonitorFeedHost(target: MonitorFeedHost.programTarget, gpu: nil)
    program.setMonitorLUTBookmark(file.bookmark)
    XCTAssertEqual(program.monitorLUTState, .none)
    _ = waitForMonitorLUT(program, timeout: 0.3) { _ in false }
    XCTAssertNil(program.monitorLUT, "Program's frames are processed; a monitor LUT is per camera")
  }

  private static func isFailure(_ state: MonitorFeedHost.MonitorLUTState) -> Bool {
    if case .failed = state { return true }
    return false
  }
}
