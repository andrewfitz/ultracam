import Foundation
import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// The scopes' persistent pipeline warm start (`ScopeEngine(…, cacheDirectory:)`).
final class ScopePipelineArchiveTests: XCTestCase {
  func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mk-scope-archive-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func archiveFiles(_ directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter {
      $0.hasSuffix(".mtl4archive")
    }.sorted()
  }

  static var cases: [ScopeSettings] {
    var parade = ScopeSettings(kind: .waveform, stage: .source)
    parade.waveformMode = .ycbcrParade
    var histogram = ScopeSettings(kind: .histogram, stage: .source)
    histogram.histogramMode = .rgbParade
    var vector = ScopeSettings(kind: .vectorscope, stage: .source)
    vector.display.trace = .colorized
    return [parade, histogram, vector]
  }

  /// Bins and drawn bytes of every case, each scope on its own and the three fused in a group.
  func results(_ engine: ScopeEngine) throws -> (bins: [[UInt32]], images: [[UInt8]], fused: [[UInt32]]) {
    let (device, _, _) = try GPU.require()
    let frame = try TestFrame.natural(.v210, width: 320, height: 180, seed: 21, mirror: false)
    var bins: [[UInt32]] = [], images: [[UInt8]] = []
    for s in Self.cases {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 300, height: 200, mipmapped: false)
      d.usage = .renderTarget
      d.storageMode = .shared
      let target = try XCTUnwrap(device.makeTexture(descriptor: d))
      let accumulator = try engine.makeAccumulator(settings: s)
      try GPU.run { cb in
        try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb)
      }
      var bytes = [UInt8](repeating: 0, count: 300 * 200 * 4)
      target.getBytes(&bytes, bytesPerRow: 1200, from: MTLRegionMake2D(0, 0, 300, 200), mipmapLevel: 0)
      images.append(bytes)
      bins.append(try readBins(accumulator))
    }
    let members = try Self.cases.map { try engine.makeAccumulator(settings: $0) }
    let group = try engine.makeGroup(members)
    try GPU.run { cb in try group.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    return (bins, images, try members.map { try readBins($0) })
  }

  func prepare(_ engine: ScopeEngine) throws {
    try engine.prepare(settings: Self.cases, layouts: [.v210], pixelFormats: [.bgra8Unorm])
  }

  /// A cold archive engine compiles and saves; a later one loads every pipeline
  /// (init's kernels, the graticule, the prepared and the fused ones) and compiles
  /// none. Both give exactly the device-built engine's bins and pixels.
  func testRoundTripIsBitIdenticalToTheDeviceEngine() throws {
    let (device, _, _) = try GPU.require()
    let reference = try results(try XCTUnwrap(GPU.synchronousEngine))
    let d = try directory()
    let cold = try ScopeEngine(device: device, specialization: .synchronous, cacheDirectory: d)
    try prepare(cold)
    let coldResults = try results(cold)
    // The fused kernels built since prepare (unless the scheduled save ran first).
    try XCTUnwrap(cold.pipelineArchive).save()
    let coldStatistics = try XCTUnwrap(cold.pipelineArchive?.statistics)
    XCTAssertEqual(coldStatistics.hits, 0)
    XCTAssertGreaterThan(coldStatistics.misses, 10)
    XCTAssertGreaterThanOrEqual(coldStatistics.saves, 2, "prepare saved, and what was built after it")
    XCTAssertEqual(archiveFiles(d).count, coldStatistics.saves)
    XCTAssertTrue(archiveFiles(d).allSatisfy { $0.hasPrefix("MonitorKitScopes-") })

    let warm = try ScopeEngine(device: device, specialization: .synchronous, cacheDirectory: d)
    try prepare(warm)
    let warmResults = try results(warm)
    let s = try XCTUnwrap(warm.pipelineArchive?.statistics)
    XCTAssertEqual(s.filesLoaded, coldStatistics.saves)
    XCTAssertEqual(s.misses, 0, "nothing compiled")
    XCTAssertEqual(s.hits, coldStatistics.misses)
    XCTAssertEqual(s.saves, 0)

    for (i, c) in Self.cases.enumerated() {
      XCTAssertEqual(coldResults.bins[i], reference.bins[i], "cold bins \(c.kind)")
      XCTAssertEqual(warmResults.bins[i], reference.bins[i], "warm bins \(c.kind)")
      XCTAssertEqual(coldResults.images[i], reference.images[i], "cold pixels \(c.kind)")
      XCTAssertEqual(warmResults.images[i], reference.images[i], "warm pixels \(c.kind)")
      XCTAssertEqual(coldResults.fused[i], reference.fused[i], "cold fused \(c.kind)")
      XCTAssertEqual(warmResults.fused[i], reference.fused[i], "warm fused \(c.kind)")
    }
    XCTAssertEqual(warm.pipelineBuildFailures, [])
  }

  /// An asynchronous archive engine builds through compiler tasks: the general
  /// render pipelines it starts at init become ready and are saved without a call,
  /// and a damaged file of its key is ignored.
  func testAsynchronousEngineBuildsAndSavesInTheBackground() throws {
    let (device, _, _) = try GPU.require()
    let d = try directory()
    let first = try ScopeEngine(device: device, specialization: .asynchronous, cacheDirectory: d)
    let deadline = Date().addingTimeInterval(120)
    while !ScopeEngine.prewarmedPixelFormats.allSatisfy({ first.isPrepared(pixelFormat: $0) }), Date() < deadline {
      usleep(20_000)
    }
    XCTAssertTrue(ScopeEngine.prewarmedPixelFormats.allSatisfy { first.isPrepared(pixelFormat: $0) })
    let archive = try XCTUnwrap(first.pipelineArchive)
    while archive.statistics.saves == 0, Date() < deadline { usleep(20_000) }
    XCTAssertGreaterThanOrEqual(archive.statistics.saves, 1, "saved shortly after the last build")
    // Any save still scheduled runs within `saveDelay` of the last build.
    usleep(useconds_t((MonitorPipelineArchive.saveDelay + 1) * 1e6))
    let files = archiveFiles(d)
    XCTAssertEqual(files.count, archive.statistics.saves)
    // A truncated copy under another content name of the same key is rejected.
    let data = try Data(contentsOf: d.appendingPathComponent(files[0]))
    let damaged = String(files[0].dropLast(".mtl4archive".count + 32)) + String(repeating: "f", count: 32) + ".mtl4archive"
    try data.prefix(data.count - 1).write(to: d.appendingPathComponent(damaged))

    let second = try ScopeEngine(device: device, specialization: .asynchronous, cacheDirectory: d)
    XCTAssertEqual(second.pipelineArchive?.statistics.filesRejected, 1)
    XCTAssertEqual(second.pipelineArchive?.statistics.filesLoaded, files.count)
    try second.prepare()
    XCTAssertTrue(ScopeEngine.drawablePixelFormats.allSatisfy { second.isPrepared(pixelFormat: $0) })
    XCTAssertEqual(second.pipelineArchive?.statistics.misses, 0)
    XCTAssertEqual(archiveFiles(d), files)
  }

  /// `prepare(target:)` (a host may call it on its render thread) builds the one
  /// pipeline and returns without saving: the scheduled save writes it shortly after.
  func testPrepareTargetLeavesTheSaveToTheScheduledOne() throws {
    let (device, _, _) = try GPU.require()
    let d = try directory()
    let engine = try ScopeEngine(device: device, specialization: .synchronous, cacheDirectory: d)
    let archive = try XCTUnwrap(engine.pipelineArchive)
    archive.save()
    // Any save scheduled by init's builds has run (and found nothing new).
    usleep(useconds_t((MonitorPipelineArchive.saveDelay + 0.5) * 1e6))
    let saves = archive.statistics.saves
    let misses = archive.statistics.misses
    let target = MonitorRenderTargetFormat(colorPixelFormat: .rgba32Float)
    try engine.prepare(target: target)
    XCTAssertTrue(engine.isPrepared(target: target))
    XCTAssertEqual(archive.statistics.misses, misses + 1)
    XCTAssertEqual(archive.statistics.saves, saves, "not saved on the caller's thread")
    let deadline = Date().addingTimeInterval(MonitorPipelineArchive.saveDelay + 20)
    while archive.statistics.saves == saves, Date() < deadline { usleep(20_000) }
    XCTAssertEqual(archive.statistics.saves, saves + 1, "saved by the scheduled save")
    XCTAssertNil(archive.statistics.lastError)
  }
}
