import Foundation
import Metal
import XCTest

@testable import MonitorKit

/// Cold versus warm start of the picture engine's pipelines. Opt-in
/// (`MONITORKIT_WARMSTART_BENCH=1`): a cold round compiles every pipeline, tens of
/// seconds. Each figure is the minimum of `MONITORKIT_WARMSTART_ROUNDS` (default 3)
/// interleaved rounds; results are printed as `WARMSTART …` lines. In one process the
/// system shader cache is warm after the first compile, so "cold" here means an
/// empty archive directory, not a cold compiler: measure a truly cold start with a
/// shader change in a fresh process.
final class PipelineArchiveBenchmarks: XCTestCase {
  override func setUpWithError() throws {
    try skipTimingUnderValidation()
    guard ProcessInfo.processInfo.environment["MONITORKIT_WARMSTART_BENCH"] == "1" else {
      throw XCTSkip("set MONITORKIT_WARMSTART_BENCH=1 to measure cold and warm starts")
    }
  }

  var rounds: Int { Int(ProcessInfo.processInfo.environment["MONITORKIT_WARMSTART_ROUNDS"] ?? "") ?? 3 }

  func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mk-archive-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  static func milliseconds(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
  }

  enum Start: String, CaseIterable {
    /// The host's `MTL4Compiler`, no cache: the app before the warm start.
    case compiler = "compiler, no cache"
    case cold = "archive cold (empty directory)"
    case warm = "archive warm"
    /// The device builds (the system shader cache applies).
    case device = "device-built"
  }

  func engine(_ start: Start, _ gpu: TestGPU, _ dir: URL, specialization: PipelineSpecialization) throws -> MonitorEngine {
    switch start {
    case .compiler:
      return try MonitorEngine(
        device: gpu.device, specialization: specialization,
        compiler: try gpu.device.makeCompiler(descriptor: MTL4CompilerDescriptor()))
    case .cold, .warm: return try MonitorEngine(device: gpu.device, specialization: specialization, cacheDirectory: dir)
    case .device: return try MonitorEngine(device: gpu.device, specialization: specialization)
    }
  }

  /// Engine init plus `warmUp()` with its defaults (three formats, five layouts:
  /// 15 all-tools picture pipelines, 15 focus kernels, 2 Freeze kernels).
  func testWarmUpDuration() throws {
    let gpu = try requireGPU()
    var best: [Start: (initMs: Double, warmUpMs: Double)] = [:]
    var built: [Start: Int] = [:]
    for _ in 0..<rounds {
      let dir = try directory()
      for start in [Start.cold, .warm, .compiler, .device] {
        var e: MonitorEngine?
        let initMs = try Self.milliseconds { e = try engine(start, gpu, dir, specialization: .asynchronous) }
        var n = 0
        let warmMs = try Self.milliseconds { n = try e!.warmUp() }
        built[start] = n
        if start == .warm { XCTAssertEqual(e!.pipelineArchive?.statistics.misses, 0) }
        let old = best[start] ?? (.infinity, .infinity)
        best[start] = (min(old.initMs, initMs), min(old.warmUpMs, warmMs))
      }
    }
    for start in Start.allCases {
      let b = best[start]!
      print(
        String(
          format: "WARMSTART (system shader cache warm) warmUp %@: init %.1f ms, warmUp %.1f ms (%d pipelines), min of %d", start.rawValue,
          b.initMs, b.warmUpMs, built[start] ?? 0, rounds))
    }
  }

  /// Engine init plus `warmUp()` on a directory written by several launches, each
  /// adding one specialized pipeline (a new file holding the whole session), against
  /// the host-compiler path with no cache. Only the newest file is opened at init,
  /// so the cost stays that of one file however many are kept.
  func testInitAndWarmUpWithSeveralFiles() throws {
    let gpu = try requireGPU()
    let target = MonitorRenderTargetFormat(colorPixelFormat: .bgr10a2Unorm)
    let states: [(inout MonitorState) -> Void] = [
      { $0.zebras[0].enabled = true }, { $0.clipIndicators.enabled = true }, { $0.falseColor.mode = .sixBand },
      { $0.guides.enabled = true }, { $0.display.monochrome = .luma },
    ]
    func surface(_ i: Int) -> MonitorSurfaceConfiguration {
      var state = MonitorState()
      states[i](&state)
      return MonitorSurfaceConfiguration(
        target: target, layout: .v210, state: state, frameSize: (1920, 1080), viewportSize: (1280, 720))
    }
    for sessions in [1, 3, 5] {
      var best = (initMs: Double.infinity, warmUpMs: Double.infinity, plainInit: Double.infinity, plainWarmUp: Double.infinity)
      var files = 0, opened = 0
      for _ in 0..<rounds {
        let dir = try directory()
        var i = 0
        while i < sessions {
          let e = try engine(.cold, gpu, dir, specialization: .asynchronous)
          try e.warmUp(surfaces: [surface(i)])
          usleep(20_000)  // distinct modification dates
          i += 1
        }
        files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter {
          $0.hasSuffix(".mtl4archive")
        }.count
        var e: MonitorEngine?
        let initMs = try Self.milliseconds { e = try engine(.warm, gpu, dir, specialization: .asynchronous) }
        let warmMs = try Self.milliseconds { _ = try e!.warmUp() }
        XCTAssertEqual(e!.pipelineArchive?.statistics.misses, 0)
        opened = e!.pipelineArchive?.statistics.filesLoaded ?? 0
        var p: MonitorEngine?
        let plainInit = try Self.milliseconds { p = try engine(.compiler, gpu, dir, specialization: .asynchronous) }
        let plainWarm = try Self.milliseconds { _ = try p!.warmUp() }
        best = (min(best.initMs, initMs), min(best.warmUpMs, warmMs), min(best.plainInit, plainInit), min(best.plainWarmUp, plainWarm))
      }
      print(
        String(
          format: "WARMSTART (system shader cache warm) %d launches, %d files kept, %d opened: archive init %.1f ms + warmUp %.1f ms = %.1f ms; compiler, no cache: init %.1f ms + warmUp %.1f ms = %.1f ms, min of %d",
          sessions, files, opened, best.initMs, best.warmUpMs, best.initMs + best.warmUpMs, best.plainInit, best.plainWarmUp,
          best.plainInit + best.plainWarmUp, rounds))
    }
  }

  /// From engine init to the first frame drawn with the pipeline specialized to
  /// its tool set (asynchronous specialization, no warm-up), into a 1080p
  /// `bgr10a2Unorm` target with every tool on; also the first frame drawn at all.
  func testTimeToFirstSpecializedFrame() throws {
    let gpu = try requireGPU()
    let frame = try PictureTests.picture(width: 1920, height: 1080, seed: 3).frame(gpu, signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    let target = gpu.texture(.bgr10a2Unorm, 1920, 1080, usage: [.renderTarget, .shaderRead])
    func run(_ start: Start, _ dir: URL) throws -> (first: Double, specialized: Double, engine: MonitorEngine) {
      let t0 = DispatchTime.now().uptimeNanoseconds
      let e = try engine(start, gpu, dir, specialization: .asynchronous)
      let feed = e.makeFeed(), pass = e.makePass()
      var first = 0.0
      let deadline = Date().addingTimeInterval(300)
      repeat {
        try gpu.run { cb in
          try feed.analyze(frame, focus: state.focus, into: cb)
          try pass.encode(frame: frame, feed: feed, state: state, target: target, into: cb)
        }
        if first == 0 { first = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
        if pass.usesSpecializedPipeline { break }
        usleep(1000)
      } while Date() < deadline
      XCTAssertTrue(pass.usesSpecializedPipeline, start.rawValue)
      return (first, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6, e)
    }
    var best: [Start: (first: Double, specialized: Double)] = [:]
    for _ in 0..<rounds {
      let dir = try directory()
      for start in [Start.cold, .warm, .compiler, .device] {
        let r = try run(start, dir)
        if start == .cold { r.engine.pipelineArchive?.save() }
        if start == .warm { XCTAssertEqual(r.engine.pipelineArchive?.statistics.misses, 0, "everything loaded") }
        let old = best[start] ?? (.infinity, .infinity)
        best[start] = (min(old.first, r.first), min(old.specialized, r.specialized))
      }
    }
    for start in Start.allCases {
      let b = best[start]!
      print(
        String(
          format: "WARMSTART (system shader cache warm) %@: first frame %.1f ms, first specialized frame %.1f ms, min of %d",
          start.rawValue, b.first, b.specialized, rounds))
    }
  }
}
