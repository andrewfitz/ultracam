import CoreVideo
import Foundation
import Metal
import MonitorKit
import XCTest
import simd

/// The burned-in LUT is MonitorKit's: the app's kernels apply `mk_applyLUT`
/// (tetrahedral) from MonitorKit's MKLUT.msl, on the same `MonitorLUT` the monitor
/// shows, compiled with `MonitorShaders.compileOptions`. So the app's burn-in and
/// MonitorKit's output stage are bit-identical for every input layout the app
/// processes, and both match the CPU reference `CubeLUT.apply`.
///
/// The comparison is at the LUT: a probe kernel, appended to the app's own
/// processing source, writes the app's decoded R'G'B' (`Source.pixel`) and its
/// burned-in R'G'B' (`graded`, the function every processing kernel calls) for each
/// pixel. MonitorKit then shows those decoded values (a float RGB frame) on its
/// output stage. The decode itself is the app's (MonitorKit's `mk_decode` is
/// different arithmetic, and the published frame is quantized to 10 or 8 bits), so
/// the end-to-end check ties the probe to the real processed output within a code.
@objcMembers final class LUTGoldenChecks: XCTestCase {
  private static let probeSource = """
    kernel void probePacked(texture2d<uint, access::read> groups [[texture(0)]],
      texture3d<float, access::sample> lut [[texture(2)]],
      texture2d<float, access::write> decoded [[texture(3)]], texture2d<float, access::write> burned [[texture(4)]],
      constant Parameters &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= p.geometry.x || gid.y >= p.geometry.y) return;
      PackedSource s{groups};
      decoded.write(float4(s.pixel(gid.x, gid.y, p), 1), gid);
      burned.write(float4(graded(s, gid.x, gid.y, lut, p), 1), gid);
    }
    kernel void probePlanar(texture2d<float, access::read> luma [[texture(0)]],
      texture2d<float, access::sample> chroma [[texture(1)]], texture3d<float, access::sample> lut [[texture(2)]],
      texture2d<float, access::write> decoded [[texture(3)]], texture2d<float, access::write> burned [[texture(4)]],
      constant Parameters &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= p.geometry.x || gid.y >= p.geometry.y) return;
      PlanarSource s{luma, chroma};
      decoded.write(float4(s.pixel(gid.x, gid.y, p), 1), gid);
      burned.write(float4(graded(s, gid.x, gid.y, lut, p), 1), gid);
    }
    """

  /// One input layout the app processes (`VideoContract.tenBit422`) with its labels.
  private struct Layout: CustomStringConvertible {
    let type: OSType
    let matrix: CFString
    let centered: Bool
    var description: String {
      "\(VideoContract.fourCC(type)) \(matrix) \(centered ? "centred" : "left-sited")"
    }
  }

  private static let layouts = [
    Layout(type: kCVPixelFormatType_422YpCbCr10, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2, centered: false),
    Layout(type: kCVPixelFormatType_422YpCbCr10, matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020, centered: true),
    Layout(type: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
      centered: false),
    Layout(type: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
      centered: true),
    Layout(type: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
      centered: false),
  ]

  private struct Random {
    var state: UInt64
    mutating func next() -> UInt64 {
      state = state &* 6364136223846793005 &+ 1442695040888963407
      return state >> 33
    }
    mutating func float(_ range: ClosedRange<Float>) -> Float {
      range.lowerBound + (range.upperBound - range.lowerBound) * Float(next() % 1_000_001) / 1_000_000
    }
  }

  /// A rough, non-separable lattice: trilinear and tetrahedral differ on it, and
  /// interpolation errors cannot hide in a smooth table.
  static func roughCube(size n: Int, seed: UInt64, domain: (Float, Float) = (0, 1)) throws -> CubeLUT {
    var random = Random(state: seed)
    var text = "TITLE \"golden \(n)\"\nLUT_3D_SIZE \(n)\n"
    if domain != (0, 1) {
      text += "DOMAIN_MIN \(domain.0) \(domain.0) \(domain.0)\nDOMAIN_MAX \(domain.1) \(domain.1) \(domain.1)\n"
    }
    for b in 0..<n {
      for g in 0..<n {
        for r in 0..<n {
          let base = SIMD3<Float>(Float(r), Float(g), Float(b)) / Float(n - 1)
          let wobble = SIMD3<Float>(random.float(-0.15...0.15), random.float(-0.15...0.15), random.float(-0.15...0.15))
          let v = SIMD3(base.y * 0.7 + base.z * 0.2, base.x * base.x, 0.9 - base.z * base.y) + wobble
          text += "\(v.x) \(v.y) \(v.z)\n"
        }
      }
    }
    return try CubeLUT(text: text)
  }

  /// A Resolve-style shaper LUT (1D, then 3D) and a 1D-only LUT.
  static func shaperCube(entries: Int, size: Int?) throws -> CubeLUT {
    var text = "LUT_1D_SIZE \(entries)\nLUT_1D_INPUT_RANGE -0.05 1.1\n"
    if let size { text += "LUT_3D_SIZE \(size)\n" }
    for i in 0..<entries {
      let x = Float(i) / Float(entries - 1)
      text += "\(pow(x, 0.6)) \(x * x) \(0.2 + 0.7 * x)\n"
    }
    if let size {
      var random = Random(state: 7)
      for b in 0..<size {
        for g in 0..<size {
          for r in 0..<size {
            let base = SIMD3<Float>(Float(r), Float(g), Float(b)) / Float(size - 1)
            text += "\(base.z * 0.5 + random.float(0...0.3)) \(base.x) \(base.y * base.x + random.float(0...0.2))\n"
          }
        }
      }
    }
    return try CubeLUT(text: text)
  }

  /// A frame of the layout with pseudo-random codes, footroom and headroom included.
  private func frame(_ layout: Layout, width: Int, height: Int, seed: UInt64) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, layout.type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer),
      kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    var random = Random(state: seed)
    func code() -> UInt32 { UInt32(4 + random.next() % 1016) }
    CVPixelBufferLockBaseAddress(image, [])
    if layout.type == kCVPixelFormatType_422YpCbCr10 {
      let stride = CVPixelBufferGetBytesPerRow(image) / 4
      let words = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt32.self)
      for y in 0..<height {
        for group in 0..<(width / 6) {
          let w = words.advanced(by: y * stride + group * 4)
          w[0] = code() | code() << 10 | code() << 20
          w[1] = code() | code() << 10 | code() << 20
          w[2] = code() | code() << 10 | code() << 20
          w[3] = code() | code() << 10 | code() << 20
        }
      }
    } else {
      for plane in 0..<2 {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane) / 2
        let values = CVPixelBufferGetBaseAddressOfPlane(image, plane)!.assumingMemoryBound(to: UInt16.self)
        for y in 0..<height { for x in 0..<width { values[y * stride + x] = UInt16(code() << 6) } }
      }
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, layout.matrix, .shouldPropagate)
    if layout.centered {
      CVBufferSetAttachment(image, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center,
        .shouldPropagate)
    }
    return image
  }

  private final class GPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let probes: [String: MTLComputePipelineState]
    var cache: CVMetalTextureCache?
    init() throws {
      device = try XCTUnwrap(LUTProcessor.sharedDevice)
      queue = try XCTUnwrap(device.makeCommandQueue())
      // The app's own compilation unit (MKLUT.msl, LUTShaders.metal, compile
      // options) through the Metal 4 compiler, as LUTProcessor builds it.
      let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
      let library = try compiler.makeLibrary(descriptor: LUTProcessor.libraryDescriptor(extra: LUTGoldenChecks.probeSource))
      var probes: [String: MTLComputePipelineState] = [:]
      for name in ["probePacked", "probePlanar"] {
        probes[name] = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: name)))
      }
      self.probes = probes
      XCTAssertEqual(CVMetalTextureCacheCreate(nil, nil, device, nil, &cache), kCVReturnSuccess)
    }

    func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, renderTarget: Bool = false) -> MTLTexture {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
      d.usage = renderTarget ? [.renderTarget, .shaderRead] : [.shaderRead, .shaderWrite]
      d.storageMode = .shared
      return device.makeTexture(descriptor: d)!
    }

    func view(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, width: Int, height: Int) throws
      -> (CVMetalTexture, MTLTexture) {
      var wrapper: CVMetalTexture?
      XCTAssertEqual(CVMetalTextureCacheCreateTextureFromImage(nil, cache!, buffer, nil, format, width, height, plane,
        &wrapper), kCVReturnSuccess)
      let mapped = try XCTUnwrap(wrapper)
      return (mapped, try XCTUnwrap(CVMetalTextureGetTexture(mapped)))
    }

    func run(_ encode: (MTLCommandBuffer) throws -> Void) rethrows {
      let commandBuffer = queue.makeCommandBuffer()!
      try encode(commandBuffer)
      commandBuffer.commit()
      commandBuffer.waitUntilCompleted()
      XCTAssertNil(commandBuffer.error)
    }
  }

  private static func pixels(_ texture: MTLTexture) -> [SIMD4<Float>] {
    var values = [SIMD4<Float>](repeating: .zero, count: texture.width * texture.height)
    values.withUnsafeMutableBytes { bytes in
      texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 16,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    }
    return values
  }

  /// The app's decoded and burned-in R'G'B' for every pixel of `input`, from the
  /// production `Parameters` and the processing kernels' own `graded`.
  private func probe(_ gpu: GPU, _ input: CVPixelBuffer, lut: MonitorLUT) throws
    -> (decoded: MTLTexture, burned: MTLTexture) {
    let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
    let matrix = CVBufferCopyAttachment(input, kCVImageBufferYCbCrMatrixKey, nil) as? String
    var parameters = LUTProcessor.parameters(for: input, matrix: matrix, lut: lut)
    XCTAssertEqual(parameters.lut, lut.parameters, "the burned-in LUT is the MonitorLUT's own parameters")
    XCTAssertEqual(parameters.lut.shape.y, 0, "tetrahedral")
    let decoded = gpu.texture(.rgba32Float, width, height), burned = gpu.texture(.rgba32Float, width, height)
    var wrappers: [CVMetalTexture] = []
    var inputs: [MTLTexture] = []
    let packed = CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_422YpCbCr10
    if packed {
      let (w, t) = try gpu.view(input, plane: 0, format: .rgba32Uint, width: (width + 5) / 6, height: height)
      wrappers.append(w)
      inputs.append(t)
    } else {
      let (yw, y) = try gpu.view(input, plane: 0, format: .r16Unorm, width: width, height: height)
      let (cw, c) = try gpu.view(input, plane: 1, format: .rg16Unorm, width: width / 2, height: height)
      wrappers += [yw, cw]
      inputs += [y, c]
    }
    gpu.run { commandBuffer in
      let encoder = commandBuffer.makeComputeCommandEncoder()!
      let state = gpu.probes[packed ? "probePacked" : "probePlanar"]!
      encoder.setComputePipelineState(state)
      for (index, texture) in inputs.enumerated() { encoder.setTexture(texture, index: index) }
      encoder.setTexture(lut.texture, index: 2)
      encoder.setTexture(decoded, index: 3)
      encoder.setTexture(burned, index: 4)
      encoder.setBytes(&parameters, length: MemoryLayout<LUTProcessor.Parameters>.size, index: 0)
      encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
      encoder.endEncoding()
    }
    withExtendedLifetime(wrappers) {}
    return (decoded, burned)
  }

  /// MonitorKit's output stage (`pictureStage = .output`, the feed's burn-in LUT)
  /// of `decoded` shown 1:1 as a float RGB frame.
  private func monitorKitOutput(_ gpu: GPU, decoded: MTLTexture, lut: MonitorLUT) throws -> MTLTexture {
    let engine = try MonitorEngine(device: gpu.device, specialization: .synchronous)
    let feed = engine.makeFeed()
    feed.burnInLUT = lut
    var state = MonitorState()
    state.pictureStage = .output
    let frame = try MonitorFrame(layout: .rgba32Float, width: decoded.width, height: decoded.height, luma: decoded,
      signal: SignalDescription(range: .full))
    let target = gpu.texture(.rgba32Float, decoded.width, decoded.height, renderTarget: true)
    let pass = engine.makePass()
    try gpu.run { try pass.encode(frame: frame, feed: feed, state: state, target: target, into: $0) }
    return target
  }

  private func bits(_ v: SIMD4<Float>) -> SIMD3<UInt32> { SIMD3(v.x.bitPattern, v.y.bitPattern, v.z.bitPattern) }

  func testBurnInIsBitIdenticalToMonitorKitOutputStageForEveryInputLayout() throws {
    let gpu = try GPU()
    let luts = [try Self.roughCube(size: 33, seed: 1), try Self.roughCube(size: 17, seed: 2, domain: (-0.1, 1.2))]
    for cube in luts {
      let lut = try LUTProcessor.makeLUT(cube)
      XCTAssertEqual(lut.interpolation, .tetrahedral)
      for (index, layout) in Self.layouts.enumerated() {
        let input = try frame(layout, width: 384, height: 48, seed: UInt64(index + 1))
        let (decoded, burned) = try probe(gpu, input, lut: lut)
        let shown = Self.pixels(try monitorKitOutput(gpu, decoded: decoded, lut: lut))
        let source = Self.pixels(decoded), app = Self.pixels(burned)
        var mismatches = 0, worst: Float = 0, outside = 0
        for i in 0..<app.count {
          // MonitorKit writes the picture clipped to 0…1 (an SDR target).
          let clipped = simd_clamp(app[i], SIMD4(repeating: 0), SIMD4(repeating: 1))
          if bits(clipped) != bits(shown[i]) { mismatches += 1 }
          let rgb = SIMD3(source[i].x, source[i].y, source[i].z)
          if simd_reduce_max(rgb) > 1 || simd_reduce_min(rgb) < 0 { outside += 1 }
          let reference = cube.apply(rgb, interpolation: .tetrahedral)
          worst = max(worst, simd_reduce_max(simd_abs(SIMD3(app[i].x, app[i].y, app[i].z) - reference)))
        }
        XCTAssertEqual(mismatches, 0, "\(cube.title), \(layout): burn-in and MonitorKit's output stage differ")
        XCTAssertLessThanOrEqual(worst, 1e-5, "\(cube.title), \(layout): burn-in vs CubeLUT.apply (tetrahedral)")
        XCTAssertGreaterThan(outside, 0, "\(layout): the frame exercises the LUT's domain clamp")
      }
    }
  }

  /// Ties the probe to the published frame: the real 4K processing writes the
  /// probe's burned-in values, Rec.709-encoded and quantized, within a code.
  func testPublishedFrameCarriesTheProbedBurnIn() throws {
    let gpu = try GPU()
    let cube = try Self.roughCube(size: 33, seed: 3)
    let lut = try LUTProcessor.makeLUT(cube)
    let processor = try LUTProcessor()
    try processor.load(lut)
    for (index, layout) in Self.layouts.enumerated() {
      let input = try frame(layout, width: 3840, height: 2160, seed: UInt64(20 + index))
      let output = try processor.process(input, configuration: PipelineConfiguration(applyLUT: true, downscale: false,
        convertTo420: false))
      let burned = Self.pixels(try probe(gpu, input, lut: lut).burned)
      CVPixelBufferLockBaseAddress(output, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
      let yStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0) / 2
      let cStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1) / 2
      let luma = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt16.self)
      let chroma = CVPixelBufferGetBaseAddressOfPlane(output, 1)!.assumingMemoryBound(to: UInt16.self)
      func encode(_ c: SIMD4<Float>) -> SIMD3<Double> {
        let rgb = SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z))
        let y = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        return SIMD3(y, (rgb.z - y) / (2 * (1 - 0.0722)), (rgb.x - y) / (2 * (1 - 0.2126)))
      }
      var worst = 0.0
      for row in [0, 1, 1079, 2159] {
        for x in Swift.stride(from: 0, to: 3840, by: 2) {
          let a = burned[row * 3840 + x], b = burned[row * 3840 + x + 1]
          let ya = min(1023, max(0, 64 + 876 * encode(a).x)), yb = min(1023, max(0, 64 + 876 * encode(b).x))
          let pair = encode((a + b) / 2)
          let cb = min(1023, max(0, 512 + 896 * pair.y)), cr = min(1023, max(0, 512 + 896 * pair.z))
          worst = max(worst, abs(Double(luma[row * yStride + x] >> 6) - ya), abs(Double(luma[row * yStride + x + 1] >> 6) - yb),
            abs(Double(chroma[row * cStride + x] >> 6) - cb), abs(Double(chroma[row * cStride + x + 1] >> 6) - cr))
        }
      }
      XCTAssertLessThanOrEqual(worst, 1, "\(layout): the published frame is the probed burn-in")
    }
  }

  /// 1D-only and shaper (1D, then 3D) LUTs burn in correctly: the shaper rows
  /// are in the MonitorLUT texture and its parameters carry them.
  func testOneDimensionalAndShaperLUTsBurnInCorrectly() throws {
    let gpu = try GPU()
    for cube in [try Self.shaperCube(entries: 1024, size: nil), try Self.shaperCube(entries: 4096, size: 17)] {
      XCTAssertGreaterThan(cube.shaperSize, 0)
      let lut = try LUTProcessor.makeLUT(cube)
      XCTAssertEqual(lut.parameters.shape.w, UInt32(cube.shaperSize))
      for (index, layout) in Self.layouts.enumerated() {
        let input = try frame(layout, width: 384, height: 32, seed: UInt64(40 + index))
        let (decoded, burned) = try probe(gpu, input, lut: lut)
        let shown = Self.pixels(try monitorKitOutput(gpu, decoded: decoded, lut: lut))
        let source = Self.pixels(decoded), app = Self.pixels(burned)
        var worst: Float = 0, mismatches = 0, changed = 0
        for i in 0..<app.count {
          let rgb = SIMD3(source[i].x, source[i].y, source[i].z), out = SIMD3(app[i].x, app[i].y, app[i].z)
          worst = max(worst, simd_reduce_max(simd_abs(out - cube.apply(rgb, interpolation: .tetrahedral))))
          if simd_reduce_max(simd_abs(out - rgb)) > 0.01 { changed += 1 }
          if bits(simd_clamp(app[i], SIMD4(repeating: 0), SIMD4(repeating: 1))) != bits(shown[i]) { mismatches += 1 }
        }
        XCTAssertLessThanOrEqual(worst, 1e-5, "\(cube.sizeDescription), \(layout)")
        XCTAssertEqual(mismatches, 0, "\(cube.sizeDescription), \(layout): burn-in and MonitorKit's output stage differ")
        XCTAssertGreaterThan(changed, app.count / 2, "\(cube.sizeDescription), \(layout): the LUT is applied")
      }
    }
    XCTAssertEqual(try Self.shaperCube(entries: 1024, size: nil).sizeDescription, "1D 1024")
    XCTAssertEqual(try Self.shaperCube(entries: 4096, size: 17).sizeDescription, "1D 4096 + 17³")
    XCTAssertEqual(try Self.roughCube(size: 17, seed: 1).sizeDescription, "17³")
  }

  /// Loading a LUT never waits for the GPU: frames already committed finish with
  /// the LUT they were encoded with, which only those frames keep alive, and later
  /// frames get the new one at once. Frame 0's completion is held on a gate, so
  /// frames 0 and 1 are provably unfinished while the load runs; a load that
  /// waited for them would hang until the gate timed out.
  func testLoadSwapsWithoutWaitingAndFramesInFlightKeepTheirLUT() throws {
    let processor = try LUTProcessor()
    let square = try LUTProcessor.makeLUT(CubeLUT(text: cubeText(size: 17, transform: { $0 * $0 })))
    weak var weakInvert: MonitorLUT?
    do {
      let invert = try LUTProcessor.makeLUT(CubeLUT(text: cubeText(transform: { 1 - $0 })))
      weakInvert = invert
      try processor.load(invert)
    }
    let configuration = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false)
    let source = try syntheticRamp()
    _ = try processor.process(source, configuration: configuration)
    final class Results: @unchecked Sendable {
      let lock = NSLock()
      var buffers: [Int: CVPixelBuffer] = [:]
      var gateTimedOut = false
      let gate = DispatchSemaphore(value: 0)
      let done = DispatchSemaphore(value: 0)
    }
    let results = Results()
    func submit(_ index: Int) throws {
      try processor.submit(source, configuration: configuration) { completed in
        // Completions run in order on one queue: holding frame 0's holds them all.
        if index == 0, results.gate.wait(timeout: .now() + 10) == .timedOut {
          results.lock.withLock { results.gateTimedOut = true }
        }
        results.lock.withLock { results.buffers[index] = try? completed.result.get() }
        results.done.signal()
      }
    }
    try submit(0)
    try submit(1)
    try processor.load(square)
    XCTAssertTrue(processor.lut === square)
    XCTAssertTrue(results.lock.withLock { results.buffers.isEmpty && !results.gateTimedOut },
      "load returned while frames 0 and 1 were unfinished")
    XCTAssertNotNil(weakInvert, "the unfinished frames keep their LUT alive")
    try submit(2)
    results.gate.signal()
    for _ in 0..<3 { XCTAssertEqual(results.done.wait(timeout: .now() + 12), .success) }
    XCTAssertFalse(results.lock.withLock { results.gateTimedOut }, "load waited for the frames in flight")
    func middle(_ buffer: CVPixelBuffer?) throws -> Double {
      let buffer = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      return Double(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)[2880] >> 6)
    }
    // Ramp code 0.75: inverted 0.25, squared 0.5625.
    let buffers = results.lock.withLock { results.buffers }
    for index in [0, 1] { XCTAssertEqual(try middle(buffers[index]), 64 + 876 * 0.25, accuracy: 2, "frame \(index)") }
    XCTAssertEqual(try middle(buffers[2]), 64 + 876 * 0.5625, accuracy: 2)
    // The frames were the old LUT's last owners: it goes once they completed.
    let deadline = Date().addingTimeInterval(2)
    while weakInvert != nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    XCTAssertNil(weakInvert, "completed frames release their LUT")
  }

  /// The monitor's burn-in LUT (`CaptureController.burnInLUT`) is exactly what the
  /// camera burns in: the loaded LUT while Apply LUT and the pipeline are on, nil
  /// otherwise (Apply LUT off or forgotten, complete bypass), so the monitor's
  /// output stage never shows a LUT that Program, recording and the camera lack.
  func testBurnInLUTFollowsTheEffectiveApplyLUT() throws {
    let services = CaptureServices(start: { _, _, _, _ in }, stop: {}, connect: { _, _ in }, disconnect: {},
      send: { _ in true })
    let controller = CaptureController(services: services)
    defer { controller.onUpdate = nil; controller.stop() }
    let started = expectation(description: "Capture start completed")
    started.assertForOverFulfill = false
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { started.fulfill() } }
    var off = PipelineConfiguration(applyLUT: false, downscale: false, convertTo420: false)
    off.inputFast = true
    var on = off
    on.applyLUT = true
    controller.start(feedID: FeedID(rawValue: "test"), deviceID: "synthetic", configuration: off)
    wait(for: [started], timeout: 5)
    XCTAssertNil(controller.burnInLUT, "nothing loaded")
    let lut = try LUTProcessor.makeLUT(CubeLUT(text: cubeText(size: 17, transform: { $0 * $0 })))
    let loaded = expectation(description: "LUT loaded")
    controller.load(lut) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
      loaded.fulfill()
    }
    wait(for: [loaded], timeout: 5)
    XCTAssertNil(controller.burnInLUT, "loaded with Apply LUT off: nothing is burned in")
    func settle(_ label: String, _ condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(5)
      while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
      XCTAssertTrue(condition(), label)
    }
    controller.reconfigure(configuration: on, pipelineEnabled: true)
    settle("Apply LUT on burns the loaded LUT in") { controller.burnInLUT === lut }
    controller.reconfigure(configuration: off, pipelineEnabled: true)
    settle("Apply LUT off (or Forget LUT) burns nothing in") { controller.burnInLUT == nil }
    controller.reconfigure(configuration: on, pipelineEnabled: true)
    settle("Apply LUT back on") { controller.burnInLUT === lut }
    controller.reconfigure(configuration: on, pipelineEnabled: false)
    settle("complete bypass burns nothing in") { controller.burnInLUT == nil }
    controller.reconfigure(configuration: on, pipelineEnabled: true)
    settle("processing back on") { controller.burnInLUT === lut }
  }

  /// Only tetrahedral LUTs on the processor's own device are accepted.
  func testLoadRejectsOtherInterpolationsAndDevices() throws {
    let processor = try LUTProcessor()
    let device = try XCTUnwrap(LUTProcessor.sharedDevice)
    let cube = try CubeLUT(text: cubeText())
    XCTAssertThrowsError(try processor.load(MonitorLUT(device: device, cube: cube, interpolation: .trilinear)))
    XCTAssertNil(processor.lut)
    try processor.load(cube)
    XCTAssertEqual(processor.lut?.interpolation, .tetrahedral)
    XCTAssertTrue(processor.lut?.texture.device === device)
  }

  static let allTests = [
    ("burn-in bit-identical to MonitorKit's output stage", testBurnInIsBitIdenticalToMonitorKitOutputStageForEveryInputLayout),
    ("published frame carries the probed burn-in", testPublishedFrameCarriesTheProbedBurnIn),
    ("1D and shaper LUTs burn in", testOneDimensionalAndShaperLUTsBurnInCorrectly),
    ("LUT load swaps without waiting", testLoadSwapsWithoutWaitingAndFramesInFlightKeepTheirLUT),
    ("burn-in LUT follows the effective Apply LUT", testBurnInLUTFollowsTheEffectiveApplyLUT),
    ("tetrahedral only, shared device", testLoadRejectsOtherInterpolationsAndDevices),
  ]
}
