@preconcurrency import CoreVideo
import Darwin
import Foundation
@preconcurrency import Metal
import MonitorToolsCore
import MonitorToolsMetal
import Synchronization

// Counts heap allocations through libmalloc's logger hook (the one malloc
// stack logging uses): all threads, and the encoding thread alone.
typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
let allAllocations = Atomic<Int>(0)
let encoderAllocations = Atomic<Int>(0)
nonisolated(unsafe) var encoderThread: pthread_t?
nonisolated(unsafe) let mallocLogger: MallocLogger = { type, _, _, _, _, _ in
  guard type & 2 != 0 else { return }
  allAllocations.add(1, ordering: .relaxed)
  if let encoderThread, pthread_equal(pthread_self(), encoderThread) != 0 {
    encoderAllocations.add(1, ordering: .relaxed)
  }
}
func installAllocationCounter() -> Bool {
  guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return false }
  encoderThread = pthread_self()
  symbol.assumingMemoryBound(to: MallocLogger?.self).pointee = mallocLogger
  return true
}

// Synthetic GPU monitor benchmark: the surface encode path (picture pass into
// a 1080p target, scopes in their own command buffer) over a recycled pool of
// IOSurface frames, as the capture path delivers them. Never opens devices.

struct BenchmarkFailure: Error { let reason: String }
func require(_ condition: Bool, _ reason: String) throws {
  if !condition { throw BenchmarkFailure(reason: reason) }
}

func makeBuffer(width: Int, height: Int, format: OSType, fill: (UnsafeMutableRawPointer, Int, Int) -> Void)
  throws -> CVPixelBuffer
{
  var buffer: CVPixelBuffer?
  let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
  try require(
    CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer)
      == kCVReturnSuccess, "synthetic allocation failed")
  guard let buffer else { throw BenchmarkFailure(reason: "missing synthetic buffer") }
  CVPixelBufferLockBaseAddress(buffer, [])
  defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
  if CVPixelBufferGetPlaneCount(buffer) == 0 {
    fill(CVPixelBufferGetBaseAddress(buffer)!, CVPixelBufferGetBytesPerRow(buffer), -1)
  } else {
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
      fill(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!,
        CVPixelBufferGetBytesPerRowOfPlane(buffer, plane), plane)
    }
  }
  return buffer
}

/// 4K v210 ramp with texture, so focus and zebra have real edges.
func v210(index: Int) throws -> CVPixelBuffer {
  try makeBuffer(width: 3840, height: 2160, format: kCVPixelFormatType_422YpCbCr10) { base, stride, _ in
    for y in 0..<2160 {
      let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
      for group in 0..<640 {
        let luma = UInt32(64 + (group * 6 + y + index * 7) % 876)
        let edge: UInt32 = (group / 8 + y / 48) % 2 == 0 ? 0 : 120
        let a = min(940, luma + edge)
        row[group * 4] = 512 | (a << 10) | (512 << 20)
        row[group * 4 + 1] = a | (512 << 10) | (a << 20)
        row[group * 4 + 2] = 512 | (a << 10) | (512 << 20)
        row[group * 4 + 3] = a | (512 << 10) | (a << 20)
      }
    }
  }
}

func nv12(index: Int) throws -> CVPixelBuffer {
  try makeBuffer(width: 1920, height: 1080, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
    base, stride, plane in
    let rows = plane == 0 ? 1080 : 540
    for y in 0..<rows {
      let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
      for x in 0..<1920 { row[x] = plane == 0 ? UInt8(16 + (x + y + index) % 219) : 128 }
    }
  }
}

final class Completion: MonitorEncodeCompletion, @unchecked Sendable {
  let lock = NSLock()
  let inFlight = DispatchSemaphore(value: 3)
  var picture: [Double] = []
  var scope: [Double] = []
  var failures = 0
  func encodeCompleted(kind: Int, gpuStart: Double, gpuEnd: Double, failed: Bool) {
    lock.lock()
    if failed { failures += 1 }
    else if kind == 1 { picture.append((gpuEnd - gpuStart) * 1000) }
    else if kind == 2 { scope.append((gpuEnd - gpuStart) * 1000) }
    lock.unlock()
    if kind == 1 { inFlight.signal() }
  }
}

func percentiles(_ values: [Double]) -> [String: Double] {
  let sorted = values.sorted()
  guard !sorted.isEmpty else { return [:] }
  func p(_ q: Double) -> Double { sorted[Int(Double(sorted.count - 1) * q)] }
  return ["p50": p(0.5), "p95": p(0.95), "p99": p(0.99), "max": sorted.last!,
    "mean": sorted.reduce(0, +) / Double(sorted.count)]
}

func heapBlocks() -> (blocks: Int, bytes: Int) {
  var stats = malloc_statistics_t()
  malloc_zone_statistics(nil, &stats)
  return (Int(stats.blocks_in_use), Int(stats.size_in_use))
}

struct Scenario {
  let name: String
  let configuration: MonitorConfiguration
  let output: Bool
}

func run() throws {
  let outputDirectory = CommandLine.arguments.dropFirst().first.map(URL.init(fileURLWithPath:))
  guard let device = MTLCreateSystemDefaultDevice() else { throw BenchmarkFailure(reason: "no Metal device") }
  let runtime = MonitorRuntime(sharedDevice: { device })
  let counting = installAllocationCounter()
  let pool = try (0..<8).map { try v210(index: $0) }
  let outputs = try (0..<8).map { try nv12(index: $0) }
  let descriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false)
  descriptor.usage = [.shaderRead, .shaderWrite]
  descriptor.storageMode = .private
  let targets = (0..<3).map { _ in device.makeTexture(descriptor: descriptor)! }
  let scopeDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: MonitorToolsRenderer.scopeWidth,
    height: MonitorToolsRenderer.scopeHeight, mipmapped: false)
  scopeDescriptor.usage = [.shaderRead, .shaderWrite]
  scopeDescriptor.storageMode = .private
  let scopeTargets = (0..<3).map { _ in device.makeTexture(descriptor: scopeDescriptor)! }
  // Benchmark targets stand in for drawables; make them resident like a layer's set.
  let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
  for texture in targets + scopeTargets { residency.addAllocation(texture) }
  residency.commit()
  runtime.attachDrawables(residency)

  var base = MonitorConfiguration()
  base.pictureStage = .source
  var tools = base
  tools.toolsEnabled = true
  tools.zebra.enabled = true
  tools.focus.enabled = true
  tools.scopes.enabled = true
  tools.scopes.mode = .rgbParade
  var elZone = tools
  elZone.sourceProfileID = "sony-slog3-sgamut3cine"
  elZone.falseColor.mode = .elZone
  elZone = elZone.normalized()
  var processed = tools
  processed.pictureStage = .processedOutput
  processed.scopeStage = .processedOutput
  let scenarios = [
    Scenario(name: "source-4K-v210-tools-off", configuration: base, output: false),
    Scenario(name: "source-4K-v210-zebra-focus-parade", configuration: tools, output: false),
    Scenario(name: "source-4K-v210-elzone-focus-parade", configuration: elZone, output: false),
    Scenario(name: "processed-1080p-420-zebra-focus-parade", configuration: processed, output: true),
  ]
  let frames = 600
  let warmup = 60
  var results: [[String: Any]] = []
  for scenario in scenarios {
    let renderer = MonitorToolsRenderer(runtime: runtime)
    let completion = Completion()
    var encodeMicroseconds: [Double] = []
    var stepAllocations: [String: Int] = [:]
    encodeMicroseconds.reserveCapacity(frames + warmup)
    completion.picture.reserveCapacity(frames + warmup)
    completion.scope.reserveCapacity(frames + warmup)
    var heapStart = heapBlocks()
    var gpuStart = runtime.gpuStatistics
    var allocationStart = (all: 0, encoder: 0)
    for index in 0..<(frames + warmup) {
      if index == warmup {
        heapStart = heapBlocks()
        gpuStart = runtime.gpuStatistics
        allocationStart = (allAllocations.load(ordering: .relaxed), encoderAllocations.load(ordering: .relaxed))
        completion.lock.lock()
        completion.picture.removeAll(keepingCapacity: true)
        completion.scope.removeAll(keepingCapacity: true)
        completion.lock.unlock()
        encodeMicroseconds.removeAll(keepingCapacity: true)
      }
      completion.inFlight.wait()
      try autoreleasepool {
      let source = pool[index % pool.count]
      let stamp = MonitorFrameStamp(
        target: MonitorTargetID("benchmark"), generation: 1, sequence: UInt64(index + 1),
        sourcePTS: Double(index) / 59.94, hostTime: ProcessInfo.processInfo.systemUptime,
        configurationRevision: 1)
      let signal = MonitorFrameSignal(
        range: .legal, matrix: .bt709,
        transfer: scenario.configuration.sourceProfileID ?? "ITU_R_709_2",
        profileID: scenario.configuration.sourceProfileID)
      let bundle = MonitorFrameBundle(
        stamp: stamp, source: source, output: scenario.output ? outputs[index % outputs.count] : nil,
        correspondence: scenario.output
          ? MonitorCorrespondence(scaleX: 0.5, scaleY: 0.5, offsetX: 0, offsetY: 0) : .identity,
        sourceSignal: signal,
        outputSignal: MonitorFrameSignal(range: .legal, matrix: .bt709, transfer: "ITU_R_709_2"))
      let state = MonitorRenderState(configuration: scenario.configuration)
      let started = DispatchTime.now().uptimeNanoseconds
      let a0 = encoderAllocations.load(ordering: .relaxed)
      let frame = try runtime.gpuFrame(bundle)
      let a1 = encoderAllocations.load(ordering: .relaxed)
      let context = try runtime.beginEncoding()
      let a2 = encoderAllocations.load(ordering: .relaxed)
      let target = targets[index % targets.count]
      try renderer.encode(
        frame: frame, state: state, target: target,
        viewport: MonitorViewport(width: target.width, height: target.height), into: context)
      let a3 = encoderAllocations.load(ordering: .relaxed)
      runtime.commit(context, completion: completion, kind: 1)
      let a4 = encoderAllocations.load(ordering: .relaxed)
      if index == warmup + 10 {
        stepAllocations = ["wrap": a1 - a0, "begin": a2 - a1, "encode": a3 - a2, "commit": a4 - a3]
      }
      // Scopes at 30 Hz from a 59.94 source: every other frame, own command buffer.
      if renderer.wantsScopes(state) && index % 2 == 0 {
        let scopeContext = try runtime.beginEncoding()
        try renderer.encodeScopes(
          frame: frame, state: state, target: scopeTargets[index % scopeTargets.count],
          into: scopeContext)
        runtime.commit(scopeContext, completion: completion, kind: 2)
      }
      encodeMicroseconds.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1000)
      }
    }
    for _ in 0..<3 { completion.inFlight.wait() }
    Thread.sleep(forTimeInterval: 0.1)
    for _ in 0..<3 { completion.inFlight.signal() }
    let heapEnd = heapBlocks()
    let encoderPerFrame = Double(encoderAllocations.load(ordering: .relaxed) - allocationStart.encoder) / Double(frames)
    let allPerFrame = Double(allAllocations.load(ordering: .relaxed) - allocationStart.all) / Double(frames)
    let gpuEnd = runtime.gpuStatistics
    completion.lock.lock()
    let picture = completion.picture, scope = completion.scope, failures = completion.failures
    completion.lock.unlock()
    let result: [String: Any] = [
      "scenario": scenario.name, "frames": frames, "picture_gpu_ms": percentiles(picture),
      "scope_gpu_ms": percentiles(scope), "cpu_encode_us_per_frame": percentiles(encodeMicroseconds),
      "gpu_failures": failures,
      "steady_state_new_iosurface_textures": gpuEnd.wrappedTextures - gpuStart.wrappedTextures,
      "steady_state_new_encode_contexts": gpuEnd.encodeContexts - gpuStart.encodeContexts,
      "encode_contexts_total": gpuEnd.encodeContexts,
      "net_heap_blocks_over_run": heapEnd.blocks - heapStart.blocks,
      "allocation_counter": counting,
      "heap_allocations_per_frame_encoding_thread": encoderPerFrame,
      "heap_allocations_per_frame_all_threads": allPerFrame,
      "heap_allocations_by_step_one_frame": stepAllocations,
      "net_heap_bytes_over_run": heapEnd.bytes - heapStart.bytes,
      "status": renderer.status,
    ]
    results.append(result)
    renderer.invalidate()
    print(
      "\(scenario.name): picture GPU p50 \(String(format: "%.3f", percentiles(picture)["p50"] ?? -1)) ms p95 \(String(format: "%.3f", percentiles(picture)["p95"] ?? -1)) ms · scope GPU p50 \(String(format: "%.3f", percentiles(scope)["p50"] ?? -1)) ms · CPU encode p50 \(String(format: "%.1f", percentiles(encodeMicroseconds)["p50"] ?? -1)) µs · new textures \(gpuEnd.wrappedTextures - gpuStart.wrappedTextures) · new contexts \(gpuEnd.encodeContexts - gpuStart.encodeContexts) · net heap blocks \(heapEnd.blocks - heapStart.blocks) · mallocs/frame encode thread \(String(format: "%.1f", encoderPerFrame)) all threads \(String(format: "%.1f", allPerFrame)) · steps \(stepAllocations.sorted { $0.key < $1.key }) · failures \(failures)"
    )
  }
  if let outputDirectory {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: outputDirectory.appendingPathComponent("monitor-benchmark.json"))
  }
}

do { try run() } catch {
  print("Benchmark failed: \(error)")
  exit(1)
}
