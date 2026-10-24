import Foundation
import Metal
import Synchronization
import XCTest

@testable import MonitorKit

/// The persistent pipeline warm start (`MonitorPipelineArchive`, `MonitorEngine(…, cacheDirectory:)`).
final class PipelineArchiveTests: XCTestCase {
  /// Under GPU shader validation Metal cannot load the archives it records, so the
  /// archive writes none (`PipelineArchiveValidationTests`); these tests need files.
  override func setUpWithError() throws {
    if MonitorPipelineArchive.shaderValidationEnabled {
      throw XCTSkip("MTL_SHADER_VALIDATION: archives are not written (PipelineArchiveValidationTests)")
    }
  }

  /// A unique, empty directory under the temporary directory, removed after the test.
  func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mk-archive-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func archiveFiles(_ directory: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
      .filter { $0.hasSuffix(".mtl4archive") }.sorted().map { directory.appendingPathComponent($0) }
  }

  /// Copies `files` into a fresh directory.
  func copy(_ files: [URL]) throws -> URL {
    let d = try directory()
    for f in files { try FileManager.default.copyItem(at: f, to: d.appendingPathComponent(f.lastPathComponent)) }
    return d
  }

  // MARK: - Engine fixture: one cold build per test run

  static let size = (frame: (width: 96, height: 54), view: (width: 80, height: 45))
  static let formats: [MTLPixelFormat] = [.rgba32Float, .bgra8Unorm]

  static var everyToolState: MonitorState {
    var s = MonitorState()
    everyTool(&s)
    return s
  }

  /// What `warmUp` builds in these tests: the all-tools pipelines of two formats
  /// for v210, the focus and Freeze kernels, and one surface's specialized pipeline.
  static func warmUp(_ engine: MonitorEngine) throws -> Int {
    try engine.warmUp(
      targets: formats.map { MonitorRenderTargetFormat(colorPixelFormat: $0) }, layouts: [.v210],
      surfaces: [
        MonitorSurfaceConfiguration(
          target: MonitorRenderTargetFormat(colorPixelFormat: .rgba32Float), layout: .v210, state: everyToolState,
          frameSize: size.frame, viewportSize: size.view)
      ])
  }

  struct Fixture: @unchecked Sendable {
    let directory: URL
    let engine: MonitorEngine
    let built: Int
    let file: URL
    /// Right after the cold warm-up and its save.
    let statistics: MonitorPipelineArchive.Statistics
  }

  /// A cold engine in a fresh cache directory, warmed up once and saved.
  static let fixture = Result { () throws -> Fixture in
    let gpu = try requireGPU()
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("mk-archive-fixture-\(UUID().uuidString)")
    let engine = try MonitorEngine(device: gpu.device, specialization: .synchronous, cacheDirectory: d)
    let built = try warmUp(engine)
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter {
      $0.hasSuffix(".mtl4archive")
    }
    guard files.count == 1 else { throw MonitorKitError.gpu("fixture wrote \(files.count) archive files") }
    return Fixture(
      directory: d, engine: engine, built: built, file: d.appendingPathComponent(files[0]),
      statistics: engine.pipelineArchive?.statistics ?? .init())
  }

  func fixture() throws -> Fixture {
    _ = try requireGPU()
    return try Self.fixture.get()
  }

  override class func tearDown() {
    if case .success(let f) = fixture { try? FileManager.default.removeItem(at: f.directory) }
    super.tearDown()
  }

  /// One frame with every tool through `engine` into a `format` target, as bytes.
  func render(_ engine: MonitorEngine, format: MTLPixelFormat, file: StaticString = #filePath, line: UInt = #line)
    throws -> [UInt8]
  {
    let gpu = try requireGPU()
    let frame = try PictureTests.picture(width: Self.size.frame.width, height: Self.size.frame.height, seed: 5)
      .frame(gpu, signal: .rec709)
    let state = Self.everyToolState
    let feed = engine.makeFeed(), pass = engine.makePass()
    let t = gpu.texture(format, Self.size.view.width, Self.size.view.height, usage: [.renderTarget, .shaderRead])
    try gpu.run { cb in
      try feed.analyze(frame, focus: state.focus, into: cb)
      try pass.encode(frame: frame, feed: feed, state: state, target: t, into: cb)
    }
    XCTAssertTrue(pass.usesSpecializedPipeline, file: file, line: line)
    return rawBytes(t)
  }

  // MARK: - Round trip

  /// A cold engine compiles and saves every pipeline; an engine started later on
  /// the same directory loads every one of them and compiles none, and saves
  /// nothing new.
  func testRoundTripLoadsEveryPipelineFromTheArchive() throws {
    let f = try fixture()
    let cold = f.statistics
    XCTAssertGreaterThanOrEqual(f.built, 3)
    XCTAssertEqual(cold.hits, 0)
    XCTAssertGreaterThanOrEqual(cold.misses, f.built)
    XCTAssertEqual(cold.saves, 1)
    XCTAssertNil(cold.lastError)
    XCTAssertTrue(f.engine.compiler === f.engine.pipelineArchive?.compiler, "the archive's compiler builds")

    let gpu = try requireGPU()
    let d = try copy([f.file])
    let warm = try MonitorEngine(device: gpu.device, specialization: .synchronous, cacheDirectory: d)
    let archive = try XCTUnwrap(warm.pipelineArchive)
    XCTAssertEqual(archive.statistics.filesLoaded, 1)
    XCTAssertEqual(archive.statistics.filesRejected, 0)
    XCTAssertEqual(try Self.warmUp(warm), f.built, "the same pipelines")
    let s = archive.statistics
    XCTAssertEqual(s.misses, 0, "nothing compiled")
    XCTAssertEqual(s.hits, cold.misses)
    XCTAssertEqual(s.saves, 0, "nothing new to save")
    XCTAssertEqual(archiveFiles(d), [d.appendingPathComponent(f.file.lastPathComponent)])
    XCTAssertEqual(archive.key, f.engine.pipelineArchive?.key)
  }

  /// Cold (compiled), warm (loaded from the archive) and the device-built engine
  /// draw the same bytes, and drawing compiles nothing on the warm engine.
  func testWarmPixelsAreBitIdenticalToCold() throws {
    let f = try fixture()
    let gpu = try requireGPU()
    let warm = try MonitorEngine(
      device: gpu.device, specialization: .synchronous, cacheDirectory: try copy([f.file]))
    _ = try Self.warmUp(warm)
    let reference = try render(gpu.engine, format: .rgba32Float)
    XCTAssertEqual(try render(f.engine, format: .rgba32Float), reference, "cold")
    XCTAssertEqual(try render(warm, format: .rgba32Float), reference, "warm")
    XCTAssertEqual(warm.pipelineArchive?.statistics.misses, 0, "the specialized pipeline came from the archive")
    // A pipeline built after warm-up (the second format's specialized one) compiles on both.
    let cold8 = try render(f.engine, format: .bgra8Unorm)
    XCTAssertEqual(try render(warm, format: .bgra8Unorm), cold8, "warm bgra8")
    XCTAssertEqual(try render(gpu.engine, format: .bgra8Unorm), cold8, "device bgra8")
  }

  // MARK: - Damaged and stale files

  /// Truncated, corrupt and empty files under names of this key are rejected
  /// before Metal reads them (Metal can crash on arbitrary bytes), removed, and the
  /// engine builds and saves as from cold.
  func testCorruptTruncatedAndEmptyFilesAreIgnored() throws {
    let f = try fixture()
    let gpu = try requireGPU()
    let d = try directory()
    let name = f.file.lastPathComponent
    let data = try Data(contentsOf: f.file)
    let keyPart = String(name.dropLast(".mtl4archive".count + 32))
    try data.prefix(data.count / 2).write(to: d.appendingPathComponent(name))
    var corrupt = data
    var i = data.count / 3
    while i < corrupt.count {
      corrupt[i] ^= 0x5A
      i += 101
    }
    try corrupt.write(to: d.appendingPathComponent(keyPart + String(repeating: "a", count: 32) + ".mtl4archive"))
    var rng = SeededRandom(7)
    try Data((0..<4096).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
      .write(to: d.appendingPathComponent(keyPart + String(repeating: "b", count: 32) + ".mtl4archive"))
    try Data().write(to: d.appendingPathComponent(keyPart + String(repeating: "c", count: 32) + ".mtl4archive"))
    try Data([1, 2, 3]).write(to: d.appendingPathComponent(keyPart + "short.mtl4archive"))

    let engine = try MonitorEngine(device: gpu.device, specialization: .synchronous, cacheDirectory: d)
    let archive = try XCTUnwrap(engine.pipelineArchive)
    XCTAssertEqual(archive.statistics.filesLoaded, 0)
    XCTAssertEqual(archive.statistics.filesRejected, 5)
    XCTAssertEqual(archiveFiles(d), [], "rejected files are removed")
    // Rebuilt from cold (the cheap Freeze kernels) and saved; a new engine loads them.
    _ = try engine.copyPipeline(integer: true)
    _ = try engine.copyPipeline(integer: false)
    XCTAssertEqual(archive.statistics.misses, 2)
    XCTAssertTrue(archive.save())
    XCTAssertEqual(archiveFiles(d).count, 1)
    let again = try MonitorEngine(device: gpu.device, specialization: .synchronous, cacheDirectory: d)
    _ = try again.copyPipeline(integer: true)
    _ = try again.copyPipeline(integer: false)
    XCTAssertEqual(again.pipelineArchive?.statistics.filesLoaded, 1)
    XCTAssertEqual(again.pipelineArchive?.statistics.hits, 2)
    XCTAssertEqual(again.pipelineArchive?.statistics.misses, 0)
  }

  /// A file of another key (other shaders, OS build or GPU model) is never opened;
  /// a save removes this GPU's stale files and leaves other engines' and GPUs' alone.
  func testStaleKeyIsIgnoredAndRemovedOnSave() throws {
    let f = try fixture()
    let gpu = try requireGPU()
    let d = try directory()
    let name = f.file.lastPathComponent
    // MonitorKit-<gpu 12>-<key 32>-<content 32>.mtl4archive
    let parts = name.split(separator: "-").map(String.init)
    XCTAssertEqual(parts.count, 4)
    XCTAssertEqual(parts[0], "MonitorKit")
    let staleKey = String(parts[2].map { $0 == "0" ? "1" : "0" })
    let stale = d.appendingPathComponent([parts[0], parts[1], staleKey, parts[3]].joined(separator: "-"))
    let otherGPU = d.appendingPathComponent(
      [parts[0], String(repeating: "0", count: 12), parts[2], parts[3]].joined(separator: "-"))
    let otherEngine = d.appendingPathComponent("MonitorKitScopes-" + parts[1...].joined(separator: "-"))
    let hostFile = d.appendingPathComponent("host-file.mtl4archive")
    for url in [stale, otherGPU, otherEngine, hostFile] { try FileManager.default.copyItem(at: f.file, to: url) }

    let engine = try MonitorEngine(device: gpu.device, specialization: .synchronous, cacheDirectory: d)
    let archive = try XCTUnwrap(engine.pipelineArchive)
    XCTAssertEqual(archive.statistics.filesLoaded, 0, "another key is never opened")
    XCTAssertEqual(archive.statistics.filesRejected, 0)
    _ = try engine.copyPipeline(integer: true)
    XCTAssertEqual(archive.statistics.misses, 1, "nothing found under another key")
    XCTAssertTrue(archive.save())
    XCTAssertEqual(archive.statistics.staleFilesRemoved, 1)
    let left = Set(archiveFiles(d).map(\.lastPathComponent))
    XCTAssertFalse(left.contains(stale.lastPathComponent))
    for url in [otherGPU, otherEngine, hostFile] { XCTAssertTrue(left.contains(url.lastPathComponent), "\(url)") }
    XCTAssertEqual(left.count, 4)
  }

  /// The key covers the source, the compile options, the engine name, the GPU and the OS.
  func testKeyChangesWithSourceOptionsAndName() throws {
    let gpu = try requireGPU()
    let d = try directory()
    let options = MonitorShaders.compileOptions
    func key(_ source: String, _ name: String = "MKTest", _ o: MTLCompileOptions = options) throws -> String {
      try MonitorPipelineArchive(device: gpu.device, directory: d, name: name, source: source, options: o).key
    }
    let base = try key(Self.kernel(2))
    XCTAssertEqual(try key(Self.kernel(2)), base, "deterministic across instances")
    XCTAssertNotEqual(try key(Self.kernel(3)), base)
    XCTAssertNotEqual(try key(Self.kernel(2), "MKOther"), base)
    let fast = MonitorShaders.compileOptions
    fast.mathMode = .fast
    XCTAssertNotEqual(try key(Self.kernel(2), "MKTest", fast), base)
    XCTAssertEqual(base.count, 64)
    XCTAssertTrue(MonitorPipelineArchive.osIdentity.contains("build "))
    XCTAssertFalse(MonitorPipelineArchive.osIdentity.hasSuffix("unknown"))
  }

  // MARK: - Small kernels: content staleness, concurrency, scheduled saves

  static func kernel(_ factor: Int) -> String {
    """
    #include <metal_stdlib>
    using namespace metal;
    constant uint mk_offset [[function_constant(0)]];
    kernel void mk_work(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {
      o[i] = float(i) * \(factor).0f + float(mk_offset);
    }
    """
  }

  static func library(_ archive: MonitorPipelineArchive, _ source: String) throws -> MTLLibrary {
    let d = MTL4LibraryDescriptor()
    d.source = source
    d.options = MonitorShaders.compileOptions
    return try archive.makeLibrary(descriptor: d)
  }

  static func descriptor(_ library: MTLLibrary, offset: UInt32) -> MTL4ComputePipelineDescriptor {
    let f = MTL4LibraryFunctionDescriptor()
    f.name = "mk_work"
    f.library = library
    let s = MTL4SpecializedFunctionDescriptor()
    s.functionDescriptor = f
    let v = MTLFunctionConstantValues()
    var o = offset
    v.setConstantValue(&o, type: .uint, index: 0)
    s.constantValues = v
    let d = MTL4ComputePipelineDescriptor()
    d.computeFunctionDescriptor = s
    return d
  }

  static func run(_ state: MTLComputePipelineState) throws -> [Float] {
    let gpu = try requireGPU()
    let out = gpu.buffer(length: 16 * 4)
    gpu.run { cb in
      let e = cb.makeComputeCommandEncoder()!
      e.setComputePipelineState(state)
      e.setBuffer(out, offset: 0, index: 0)
      e.dispatchThreads(MTLSize(width: 16, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 1, depth: 1))
      e.endEncoding()
    }
    return Array(UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: Float.self), count: 16))
  }

  /// An archive of other shader code under this key's name (as if the key had
  /// collided) is opened, but Metal matches the whole descriptor: nothing is
  /// found, the current code compiles and computes its own results.
  func testForeignArchiveContentNeverGivesWrongResults() throws {
    let gpu = try requireGPU()
    let a = try directory(), b = try directory()
    let old = try MonitorPipelineArchive(
      device: gpu.device, directory: a, name: "MKTest", source: Self.kernel(2), options: MonitorShaders.compileOptions)
    let oldLibrary = try Self.library(old, Self.kernel(2))
    XCTAssertEqual(try Self.run(try old.makeComputePipelineState(descriptor: Self.descriptor(oldLibrary, offset: 1)))[3], 7)
    XCTAssertTrue(old.save())
    let new = try MonitorPipelineArchive(
      device: gpu.device, directory: b, name: "MKTest", source: Self.kernel(3), options: MonitorShaders.compileOptions)
    let file = try XCTUnwrap(archiveFiles(a).first).lastPathComponent
    let renamed = file.replacingOccurrences(of: old.key.prefix(32), with: new.key.prefix(32))
    XCTAssertNotEqual(renamed, file)
    try FileManager.default.copyItem(at: a.appendingPathComponent(file), to: b.appendingPathComponent(renamed))

    let reopened = try MonitorPipelineArchive(
      device: gpu.device, directory: b, name: "MKTest", source: Self.kernel(3), options: MonitorShaders.compileOptions)
    XCTAssertEqual(reopened.statistics.filesLoaded, 1, "verified bytes, opened")
    let state = try reopened.makeComputePipelineState(descriptor: Self.descriptor(try Self.library(reopened, Self.kernel(3)), offset: 1))
    XCTAssertEqual(reopened.statistics.hits, 0)
    XCTAssertEqual(reopened.statistics.misses, 1)
    XCTAssertEqual(try Self.run(state)[3], 10, "the current code's result")
    reopened.save()  // Not left for a scheduled save after the directory is gone.
  }

  /// Each save writes a new file holding the whole session; at most
  /// `maximumFiles` per key are kept and the oldest go first.
  func testSavesKeepTheNewestFiles() throws {
    let gpu = try requireGPU()
    let d = try directory()
    let archive = try MonitorPipelineArchive(
      device: gpu.device, directory: d, name: "MKTest", source: Self.kernel(4), options: MonitorShaders.compileOptions,
      maximumFiles: 2)
    let lib = try Self.library(archive, Self.kernel(4))
    var written: [String] = []
    var offset: UInt32 = 0
    while offset < 3 {
      _ = try archive.makeComputePipelineState(descriptor: Self.descriptor(lib, offset: offset))
      XCTAssertTrue(archive.save())
      let names = Set(archiveFiles(d).map(\.lastPathComponent)).subtracting(written)
      XCTAssertEqual(names.count, 1, "one new file per save")
      written += names
      usleep(20_000)  // distinct modification dates
      offset += 1
    }
    XCTAssertEqual(Set(archiveFiles(d).map(\.lastPathComponent)), Set(written.suffix(2)), "the oldest is removed")
    XCTAssertEqual(archive.files.count, 2)
    // The newest file alone holds the whole session.
    let newest = try copy([d.appendingPathComponent(written[2])])
    let reader = try MonitorPipelineArchive(
      device: gpu.device, directory: newest, name: "MKTest", source: Self.kernel(4), options: MonitorShaders.compileOptions)
    let readerLibrary = try Self.library(reader, Self.kernel(4))
    offset = 0
    while offset < 3 {
      _ = try reader.makeComputePipelineState(descriptor: Self.descriptor(readerLibrary, offset: offset))
      offset += 1
    }
    XCTAssertEqual(reader.statistics.hits, 3)
    XCTAssertEqual(reader.statistics.misses, 0)
  }

  /// Only the newest file is opened at init. A pipeline it lacks opens the older
  /// files (verified and primed then) before anything compiles, and is found there;
  /// a launch that finds everything in the newest never opens them.
  func testOlderFilesOpenAtTheFirstMiss() throws {
    let gpu = try requireGPU()
    let d = try directory()
    let source = Self.kernel(6)
    func open() throws -> MonitorPipelineArchive {
      try MonitorPipelineArchive(
        device: gpu.device, directory: d, name: "MKTest", source: source, options: MonitorShaders.compileOptions)
    }
    // Two sessions of their own: the older file holds offset 0, the newer offset 1.
    var offset: UInt32 = 0
    while offset < 2 {
      let writer = try open()
      _ = try writer.makeComputePipelineState(descriptor: Self.descriptor(try Self.library(writer, source), offset: offset))
      XCTAssertTrue(writer.save())
      usleep(20_000)  // distinct modification dates
      offset += 1
    }
    XCTAssertEqual(archiveFiles(d).count, 2)
    let newestOnly = try open()
    XCTAssertEqual(newestOnly.statistics.filesLoaded, 1)
    XCTAssertEqual(newestOnly.files.count, 1)
    XCTAssertEqual(
      try Self.run(try newestOnly.makeComputePipelineState(
        descriptor: Self.descriptor(try Self.library(newestOnly, source), offset: 1)))[2], 13)
    XCTAssertEqual(newestOnly.statistics.hits, 1)
    XCTAssertEqual(newestOnly.statistics.filesLoaded, 1, "a hit in the newest opens nothing more")

    let reader = try open()
    let library = try Self.library(reader, source)
    XCTAssertEqual(try Self.run(try reader.makeComputePipelineState(descriptor: Self.descriptor(library, offset: 0)))[2], 12)
    XCTAssertEqual(reader.statistics.filesLoaded, 2, "the older file, opened at the miss")
    XCTAssertEqual(reader.files.count, 2)
    XCTAssertEqual(reader.statistics.hits, 1, "found in the older file, not compiled")
    XCTAssertEqual(reader.statistics.misses, 0)
    XCTAssertEqual(try Self.run(try reader.makeComputePipelineState(descriptor: Self.descriptor(library, offset: 3)))[2], 15)
    XCTAssertEqual(reader.statistics.misses, 1)
    XCTAssertEqual(reader.statistics.filesLoaded, 2, "opened once")
  }

  /// Several archives of one key on one directory build and save at the same time
  /// as other threads: every file stays valid, and a later archive loads them all
  /// and finds every pipeline any of them built.
  func testConcurrentArchivesShareADirectory() throws {
    let gpu = try requireGPU()
    let d = try directory()
    let source = Self.kernel(5)
    // Enough files kept that no pipeline is evicted (`testSavesKeepTheNewestFiles`).
    let archives = try (0..<3).map { _ in
      try MonitorPipelineArchive(
        device: gpu.device, directory: d, name: "MKTest", source: source, options: MonitorShaders.compileOptions,
        maximumFiles: 64)
    }
    let libraries = try archives.map { try Self.library($0, source) }
    let failures = Atomic<Int>(0)
    DispatchQueue.concurrentPerform(iterations: 12) { i in
      let k = i % archives.count
      do {
        let state = try archives[k].makeComputePipelineState(descriptor: Self.descriptor(libraries[k], offset: UInt32(i)))
        if try Self.run(state)[2] != 10 + Float(i) { failures.add(1, ordering: .relaxed) }
      } catch {
        failures.add(1, ordering: .relaxed)
      }
      archives[k].save()
    }
    XCTAssertEqual(failures.load(ordering: .relaxed), 0)
    for a in archives {
      a.save()
      XCTAssertNil(a.statistics.lastError)
    }
    let files = archiveFiles(d)
    XCTAssertGreaterThan(files.count, 0)
    let reader = try MonitorPipelineArchive(
      device: gpu.device, directory: d, name: "MKTest", source: source, options: MonitorShaders.compileOptions,
      maximumFiles: 64)
    XCTAssertEqual(reader.statistics.filesRejected, 0)
    XCTAssertEqual(reader.statistics.filesLoaded, 1, "the newest file at init")
    let readerLibrary = try Self.library(reader, source)
    var i = 0
    while i < 12 {
      let state = try reader.makeComputePipelineState(descriptor: Self.descriptor(readerLibrary, offset: UInt32(i)))
      XCTAssertEqual(try Self.run(state)[2], 10 + Float(i))
      i += 1
    }
    XCTAssertEqual(reader.statistics.hits, 12)
    XCTAssertEqual(reader.statistics.misses, 0)
    XCTAssertEqual(reader.statistics.filesRejected, 0)
    XCTAssertEqual(reader.statistics.filesLoaded, files.count, "the older files, at the first pipeline the newest lacked")
  }

  /// Two engines on one cache directory warm up at the same time, both from the archive.
  func testConcurrentEnginesWarmUpFromOneArchive() throws {
    let f = try fixture()
    let gpu = try requireGPU()
    let d = try copy([f.file])
    let engines = try (0..<2).map { _ in
      try MonitorEngine(device: gpu.device, specialization: .synchronous, cacheDirectory: d)
    }
    let built = Mutex<[Int]>([])
    DispatchQueue.concurrentPerform(iterations: engines.count) { i in
      let n = (try? Self.warmUp(engines[i])) ?? -1
      built.withLock { $0.append(n) }
    }
    XCTAssertEqual(built.withLock { $0 }, [f.built, f.built])
    for e in engines {
      XCTAssertEqual(e.pipelineArchive?.statistics.misses, 0)
      XCTAssertEqual(try render(e, format: .rgba32Float), try render(gpu.engine, format: .rgba32Float))
    }
    XCTAssertEqual(archiveFiles(d).count, 1)
  }

  /// A pipeline built after warm-up (here asynchronously, as specialization does)
  /// is saved by itself shortly afterwards, off the caller's thread.
  func testPipelinesBuiltLaterAreSavedWithoutACall() async throws {
    let gpu = try requireGPU()
    let d = try directory()
    let archive = try MonitorPipelineArchive(
      device: gpu.device, directory: d, name: "MKTest", source: Self.kernel(7), options: MonitorShaders.compileOptions)
    let lib = try Self.library(archive, Self.kernel(7))
    _ = try await archive.makeComputePipelineState(descriptor: Self.descriptor(lib, offset: 4))
    XCTAssertEqual(archive.statistics.misses, 1)
    let deadline = Date().addingTimeInterval(MonitorPipelineArchive.saveDelay + 20)
    while archive.statistics.saves == 0, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    XCTAssertEqual(archive.statistics.saves, 1)
    XCTAssertEqual(archiveFiles(d).count, 1)
    XCTAssertFalse(archive.save(), "nothing new")
  }

  // MARK: - Files removed under a live archive

  /// A loaded archive whose file is removed before any build used it (a host
  /// clearing its caches, another engine evicting it) still builds: hits load,
  /// misses compile. Metal converts an archive at its first compiler use and
  /// raises an uncaught exception there when the file is gone, so each archive is
  /// used once when it is opened.
  func testRemovedFilesNeverBreakABuild() throws {
    let gpu = try requireGPU()
    let d = try directory()
    let source = Self.kernel(8)
    let writer = try MonitorPipelineArchive(
      device: gpu.device, directory: d, name: "MKTest", source: source, options: MonitorShaders.compileOptions)
    _ = try writer.makeComputePipelineState(descriptor: Self.descriptor(try Self.library(writer, source), offset: 1))
    XCTAssertTrue(writer.save())
    let reader = try MonitorPipelineArchive(
      device: gpu.device, directory: d, name: "MKTest", source: source, options: MonitorShaders.compileOptions)
    XCTAssertEqual(reader.statistics.filesLoaded, 1)
    let readerLibrary = try Self.library(reader, source)
    for f in archiveFiles(d) { try FileManager.default.removeItem(at: f) }
    // The saved file's archive, removed before any build used it.
    XCTAssertEqual(
      try Self.run(try writer.makeComputePipelineState(descriptor: Self.descriptor(try Self.library(writer, source), offset: 2)))[3],
      26)
    // The loaded file's archive: a hit and a miss.
    XCTAssertEqual(try Self.run(try reader.makeComputePipelineState(descriptor: Self.descriptor(readerLibrary, offset: 1)))[3], 25)
    XCTAssertEqual(try Self.run(try reader.makeComputePipelineState(descriptor: Self.descriptor(readerLibrary, offset: 3)))[3], 27)
    XCTAssertEqual(reader.statistics.hits + reader.statistics.misses, 2)
    XCTAssertGreaterThanOrEqual(reader.statistics.misses, 1)
    XCTAssertTrue(writer.save())
    XCTAssertTrue(reader.save())
  }

  /// Two archives of one key at their file cap on one directory: one saves and
  /// evicts the oldest file, which the other loaded but has not built with yet;
  /// the other's next builds still work.
  func testEvictionByAnotherArchiveNeverBreaksABuild() throws {
    let gpu = try requireGPU()
    let d = try directory()
    let source = Self.kernel(9)
    func open() throws -> MonitorPipelineArchive {
      try MonitorPipelineArchive(
        device: gpu.device, directory: d, name: "MKTest", source: source, options: MonitorShaders.compileOptions,
        maximumFiles: 2)
    }
    let seed = try open()
    let seedLibrary = try Self.library(seed, source)
    var offset: UInt32 = 0
    while offset < 2 {
      _ = try seed.makeComputePipelineState(descriptor: Self.descriptor(seedLibrary, offset: offset))
      XCTAssertTrue(seed.save())
      usleep(20_000)  // distinct modification dates
      offset += 1
    }
    let oldest = Set(archiveFiles(d))
    XCTAssertEqual(oldest.count, 2)
    let a = try open(), b = try open()
    XCTAssertEqual(a.statistics.filesLoaded, 1, "the newest at init")
    XCTAssertEqual(b.statistics.filesLoaded, 1)
    _ = try b.makeComputePipelineState(descriptor: Self.descriptor(try Self.library(b, source), offset: 5))
    XCTAssertEqual(b.statistics.filesLoaded, 2, "the older file, opened at the miss")
    XCTAssertTrue(b.save())
    XCTAssertEqual(Set(archiveFiles(d)).intersection(oldest).count, 1, "the oldest file was evicted")
    let aLibrary = try Self.library(a, source)
    XCTAssertEqual(try Self.run(try a.makeComputePipelineState(descriptor: Self.descriptor(aLibrary, offset: 0)))[2], 18)
    XCTAssertEqual(try Self.run(try a.makeComputePipelineState(descriptor: Self.descriptor(aLibrary, offset: 7)))[2], 25)
    a.save()
    seed.save()
  }

  // MARK: - Failed saves, duplicate builds

  /// A save that fails (here: the cache directory cannot be created) keeps the
  /// session's pipelines, so the next save, once it can, writes them.
  func testFailedSaveIsRetriedByTheNextSave() throws {
    let gpu = try requireGPU()
    let parent = try directory()
    let d = parent.appendingPathComponent("cache")
    try Data([1]).write(to: d)  // a file where the directory should be
    let source = Self.kernel(10)
    let archive = try MonitorPipelineArchive(
      device: gpu.device, directory: d, name: "MKTest", source: source, options: MonitorShaders.compileOptions)
    _ = try archive.makeComputePipelineState(descriptor: Self.descriptor(try Self.library(archive, source), offset: 1))
    XCTAssertFalse(archive.save())
    XCTAssertNotNil(archive.statistics.lastError)
    XCTAssertEqual(archive.statistics.saves, 0)
    try FileManager.default.removeItem(at: d)
    XCTAssertTrue(archive.save(), "the failed save's pipelines are saved now")
    XCTAssertEqual(archive.statistics.saves, 1)
    XCTAssertEqual(archiveFiles(d).count, 1)
    XCTAssertFalse(archive.save(), "nothing new")
    let reader = try MonitorPipelineArchive(
      device: gpu.device, directory: d, name: "MKTest", source: source, options: MonitorShaders.compileOptions)
    _ = try reader.makeComputePipelineState(descriptor: Self.descriptor(try Self.library(reader, source), offset: 1))
    XCTAssertEqual(reader.statistics.hits, 1)
  }

  /// A pipeline built twice (two threads racing for one key) is recorded once;
  /// a hit made from an archive is the archive's pipeline and computes the same.
  func testRepeatedBuildsAreRecordedOnce() throws {
    let gpu = try requireGPU()
    let d = try directory()
    let source = Self.kernel(11)
    let archive = try MonitorPipelineArchive(
      device: gpu.device, directory: d, name: "MKTest", source: source, options: MonitorShaders.compileOptions)
    let lib = try Self.library(archive, source)
    DispatchQueue.concurrentPerform(iterations: 4) { i in
      _ = try? archive.makeComputePipelineState(descriptor: Self.descriptor(lib, offset: UInt32(i % 2)))
    }
    XCTAssertEqual(archive.statistics.misses, 4)
    XCTAssertEqual(archive.recipeCount, 2)
    XCTAssertTrue(archive.save())
    let again = try archive.makeComputePipelineState(descriptor: Self.descriptor(lib, offset: 1))
    XCTAssertEqual(archive.statistics.hits, 1, "made from the saved file")
    XCTAssertEqual(archive.recipeCount, 2)
    XCTAssertEqual(try Self.run(again)[3], 34)
  }
}

/// The archive under Metal's GPU shader validation, whose recorded binaries Metal
/// refuses to load ("deployment target … not compatible with current OS"): it
/// writes no file and builds as without a cache, with the reason in `lastError`.
final class PipelineArchiveValidationTests: XCTestCase {
  func testShaderValidationIsReadFromTheEnvironment() {
    XCTAssertTrue(MonitorPipelineArchive.shaderValidation(["MTL_SHADER_VALIDATION": "1"]))
    XCTAssertFalse(MonitorPipelineArchive.shaderValidation(["MTL_SHADER_VALIDATION": "0"]))
    XCTAssertFalse(MonitorPipelineArchive.shaderValidation(["MTL_DEBUG_LAYER": "1"]), "the API layer alone records loadable archives")
    XCTAssertFalse(MonitorPipelineArchive.shaderValidation([:]))
  }

  func testAValidatedSessionBuildsAndWritesNothing() throws {
    guard MonitorPipelineArchive.shaderValidationEnabled else {
      throw XCTSkip("runs under MTL_SHADER_VALIDATION=1 (the validation pass of test.sh)")
    }
    let gpu = try requireGPU()
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("mk-archive-validated-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: d) }
    let archive = try MonitorPipelineArchive(
      device: gpu.device, directory: d, name: "MKTest", source: PipelineArchiveTests.kernel(11),
      options: MonitorShaders.compileOptions)
    let library = try PipelineArchiveTests.library(archive, PipelineArchiveTests.kernel(11))
    let state = try archive.makeComputePipelineState(descriptor: PipelineArchiveTests.descriptor(library, offset: 2))
    XCTAssertEqual(try PipelineArchiveTests.run(state)[1], 13, "built as without a cache")
    XCTAssertFalse(archive.save())
    XCTAssertEqual(archive.statistics.saves, 0)
    XCTAssertEqual(archive.statistics.lastError, MonitorPipelineArchive.shaderValidationNote)
    XCTAssertFalse(FileManager.default.fileExists(atPath: d.path), "no file, no directory")
  }
}
