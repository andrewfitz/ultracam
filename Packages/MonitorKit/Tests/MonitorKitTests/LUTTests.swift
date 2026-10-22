import Metal
import XCTest
import simd

@testable import MonitorKit

/// `mk_applyLUT` against `CubeLUT.apply`, and the routing of burn-in and monitor LUTs.
final class LUTTests: XCTestCase {
  /// A rough, non-separable lattice: interpolation errors cannot hide in a smooth LUT.
  static func cube(size n: Int, seed: UInt64, domain: (Float, Float) = (0, 1)) throws -> CubeLUT {
    var rng = SeededRandom(seed)
    var text = "TITLE \"test \(n)\"\nLUT_3D_SIZE \(n)\n"
    if domain != (0, 1) { text += "DOMAIN_MIN \(domain.0) \(domain.0) \(domain.0)\nDOMAIN_MAX \(domain.1) \(domain.1) \(domain.1)\n" }
    for b in 0..<n {
      for g in 0..<n {
        for r in 0..<n {
          let base = SIMD3<Float>(Float(r), Float(g), Float(b)) / Float(n - 1)
          let wobble = SIMD3<Float>(
            Float.random(in: -0.2...0.2, using: &rng), Float.random(in: -0.2...0.2, using: &rng),
            Float.random(in: -0.2...0.2, using: &rng))
          let v = SIMD3(base.y * 0.8 + base.z * 0.2, base.x * base.x, 1 - base.z) + wobble
          text += "\(v.x) \(v.y) \(v.z)\n"
        }
      }
    }
    return try CubeLUT(text: text)
  }

  func gpuApply(_ lut: MonitorLUT, _ inputs: [SIMD3<Float>]) throws -> [SIMD3<Float>] {
    let gpu = try requireGPU()
    let input = gpu.buffer(inputs.map { SIMD4($0, 1) })
    let out = gpu.buffer(length: inputs.count * 16)
    gpu.run { cb in
      let e = cb.makeComputeCommandEncoder()!
      e.setComputePipelineState(gpu.lut)
      e.setBuffer(input, offset: 0, index: 0)
      e.setTexture(lut.texture, index: 0)
      var p = lut.parameters
      e.setBytes(&p, length: MemoryLayout<LUTParameters>.stride, index: 1)
      e.setBuffer(out, offset: 0, index: 2)
      e.dispatchThreads(MTLSize(width: inputs.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
      e.endEncoding()
    }
    let v = UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: inputs.count)
    return v.map { SIMD3($0.x, $0.y, $0.z) }
  }

  /// Random points, every lattice point's neighbourhood, the six tetrahedron
  /// ordering ties, the domain edges and points outside the domain.
  static func inputs(size n: Int, seed: UInt64, domain: (Float, Float) = (0, 1)) -> [SIMD3<Float>] {
    var rng = SeededRandom(seed)
    let span = domain.1 - domain.0
    var v: [SIMD3<Float>] = (0..<4000).map { _ in
      SIMD3(Float.random(in: -0.1...1.1, using: &rng), Float.random(in: -0.1...1.1, using: &rng), Float.random(in: -0.1...1.1, using: &rng))
    }
    let cell = 1 / Float(n - 1)
    for i in 0..<n {
      let c = Float(i) * cell
      v += [SIMD3(c, c, c), SIMD3(c, 0.3, 0.7), SIMD3(c + cell * 0.25, c + cell * 0.25, c + cell * 0.75),
            SIMD3(c + cell * 0.5, c + cell * 0.25, c + cell * 0.25), SIMD3(c + cell * 0.1, c + cell * 0.9, c + cell * 0.5)]
    }
    v += [.zero, SIMD3(repeating: 1), SIMD3(1, 0, 0), SIMD3(0, 1, 1), SIMD3(-5, 0.5, 9)]
    return v.map { $0 * span + SIMD3(repeating: domain.0) }
  }

  func testTetrahedralAndTrilinearMatchTheCPUReferenceForEverySize() throws {
    let gpu = try requireGPU()
    for (i, n) in [2, 17, 33, 65].enumerated() {
      for domain in [(Float(0), Float(1)), (Float(-0.25), Float(1.5))] {
        let cube = try Self.cube(size: n, seed: UInt64(i), domain: domain)
        let inputs = Self.inputs(size: n, seed: 10 + UInt64(i), domain: domain)
        for mode in [LUTInterpolation.tetrahedral, .trilinear] {
          let lut = try MonitorLUT(device: gpu.device, cube: cube, interpolation: mode)
          XCTAssertEqual(lut.interpolation, mode)
          let out = try gpuApply(lut, inputs)
          var worst: Float = 0
          for (input, g) in zip(inputs, out) {
            worst = max(worst, simd_reduce_max(simd_abs(g - cube.apply(input, interpolation: mode))))
          }
          XCTAssertLessThanOrEqual(worst, 1e-4, "\(n)³ \(mode) \(domain)")
          XCTAssertLessThanOrEqual(worst, 2e-6, "\(n)³ \(mode) \(domain): same Float operations as the reference")
        }
      }
    }
  }

  /// The texture unit filters with reduced weight precision (8 fractional bits on
  /// Apple GPUs), so `.hardware` is bounded by the lattice step it interpolates.
  func testHardwareFilteringStaysWithinItsWeightPrecision() throws {
    let gpu = try requireGPU()
    guard gpu.device.supports32BitFloatFiltering else { throw XCTSkip("No 32-bit float filtering") }
    for (i, n) in [2, 17, 33, 65].enumerated() {
      let cube = try Self.cube(size: n, seed: UInt64(i))
      let lut = try MonitorLUT(device: gpu.device, cube: cube, interpolation: .hardware)
      XCTAssertEqual(lut.interpolation, .hardware)
      let inputs = Self.inputs(size: n, seed: 20 + UInt64(i))
      let out = try gpuApply(lut, inputs)
      var worst: Float = 0
      for (input, g) in zip(inputs, out) {
        worst = max(worst, simd_reduce_max(simd_abs(g - cube.apply(input, interpolation: .trilinear))))
      }
      // Lattice neighbours differ by at most ~0.4 + 1/(n-1) here; 1/256 of that per axis, three axes.
      XCTAssertLessThanOrEqual(worst, 3 * (0.4 + 1 / Float(n - 1)) / 256 + 1e-5, "\(n)³ hardware")
      print("BENCH hardware LUT \(n)³ worst error vs trilinear: \(worst)")
    }
  }

  func testIdentityLUTIsExactAtLatticePoints() throws {
    var text = "LUT_3D_SIZE 33\n"
    for b in 0..<33 { for g in 0..<33 { for r in 0..<33 { text += "\(Float(r) / 32) \(Float(g) / 32) \(Float(b) / 32)\n" } } }
    let cube = try CubeLUT(text: text)
    let gpu = try requireGPU()
    let lut = try MonitorLUT(device: gpu.device, cube: cube)
    let inputs = (0..<33).map { SIMD3<Float>(repeating: Float($0) / 32) }
    XCTAssertEqual(try gpuApply(lut, inputs), inputs)
    // Neutral stays neutral under tetrahedral interpolation of a neutral-preserving LUT.
    let grey = (0..<200).map { SIMD3<Float>(repeating: Float($0) / 199) }
    for g in try gpuApply(lut, grey) { XCTAssertTrue(g.x == g.y && g.y == g.z) }
  }

  // MARK: - 1D shapers

  /// A Resolve-style shaper LUT: a log-like 1D table over `range1`, then a rough 3D table.
  static func shaperCube(size: Int, shaper: Int, seed: UInt64, range1: (Float, Float) = (-0.1, 1.2)) throws -> CubeLUT {
    var rng = SeededRandom(seed)
    var text = "TITLE \"shaper \(shaper) + \(size)\"\nLUT_1D_SIZE \(shaper)\nLUT_1D_INPUT_RANGE \(range1.0) \(range1.1)\n"
    text += "LUT_3D_SIZE \(size)\nLUT_3D_INPUT_RANGE 0 1\n"
    for i in 0..<shaper {
      let x = Float(i) / Float(shaper - 1)
      // Monotonic, different per channel, steep near black like a log shaper.
      text += "\(x.squareRoot()) \(pow(x, 0.4)) \(min(1, x * 1.3))\n"
    }
    for b in 0..<size {
      for g in 0..<size {
        for r in 0..<size {
          let base = SIMD3<Float>(Float(r), Float(g), Float(b)) / Float(size - 1)
          let v = SIMD3(base.z, base.x * base.y, 1 - base.y) + Float.random(in: -0.1...0.1, using: &rng)
          text += "\(v.x) \(v.y) \(v.z)\n"
        }
      }
    }
    return try CubeLUT(text: text)
  }

  func testShaperLUTsMatchTheCPUReference() throws {
    let gpu = try requireGPU()
    // A small lattice with a long shaper (Resolve exports 65536-entry shapers)
    // used to throw: its rows were the lattice's width, n² entries a slice.
    for (size, shaper) in [(17, 1024), (33, 4096), (2, 256), (65, 2), (2, 65536), (5, 65536), (3, 16384)] {
      let cube = try Self.shaperCube(size: size, shaper: shaper, seed: UInt64(size))
      XCTAssertEqual(cube.shaperSize, shaper)
      XCTAssertEqual(cube.dimension, size)
      var inputs = Self.inputs(size: size, seed: 30, domain: (-0.2, 1.3))
      // Every shaper entry and the midpoints between them.
      inputs += (0..<min(shaper, 600)).map { i in SIMD3(repeating: -0.1 + 1.3 * (Float(i) + 0.5) / Float(shaper - 1)) }
      for mode in [LUTInterpolation.tetrahedral, .trilinear] {
        let lut = try MonitorLUT(device: gpu.device, cube: cube, interpolation: mode)
        let side = max(size, MonitorLUT.shaperOnlyLattice)
        XCTAssertEqual(lut.texture.width, side)
        XCTAssertEqual(lut.texture.depth, size + (shaper + side * side - 1) / (side * side))
        let out = try gpuApply(lut, inputs)
        var worst: Float = 0
        for (input, g) in zip(inputs, out) { worst = max(worst, simd_reduce_max(simd_abs(g - cube.apply(input, interpolation: mode)))) }
        XCTAssertLessThanOrEqual(worst, 2e-6, "\(shaper) + \(size)³ \(mode)")
      }
      if gpu.device.supports32BitFloatFiltering {
        let lut = try MonitorLUT(device: gpu.device, cube: cube, interpolation: .hardware)
        let out = try gpuApply(lut, inputs)
        var worst: Float = 0
        for (input, g) in zip(inputs, out) { worst = max(worst, simd_reduce_max(simd_abs(g - cube.apply(input, interpolation: .trilinear)))) }
        XCTAssertLessThanOrEqual(worst, 3 * (0.3 + 1 / Float(size - 1)) / 256 + 1e-5, "\(shaper) + \(size)³ hardware")
      }
    }
  }

  /// An Adobe 1D-only LUT with a per-channel domain, up to the 65536-entry limit.
  func testOneDimensionalLUTs() throws {
    let gpu = try requireGPU()
    for size in [2, 1024, 65536] {
      var text = "LUT_1D_SIZE \(size)\nDOMAIN_MIN 0 -0.5 0.1\nDOMAIN_MAX 1 1.5 0.9\n"
      for i in 0..<size {
        let x = Double(i) / Double(size - 1)
        text += "\(Float(x * x)) \(Float(1 - x)) \(Float(0.25 + x * 2))\n"
      }
      let cube = try CubeLUT(text: text)
      XCTAssertFalse(cube.hasCube)
      XCTAssertEqual(cube.shaperDomainMin, SIMD3(0, -0.5, 0.1))
      let lut = try MonitorLUT(device: gpu.device, cube: cube)
      XCTAssertEqual(lut.parameters.shaperLow.w, 1, "no 3D stage")
      let inputs = Self.inputs(size: 9, seed: 31, domain: (-0.6, 1.6))
      let out = try gpuApply(lut, inputs)
      var worst: Float = 0
      for (input, g) in zip(inputs, out) { worst = max(worst, simd_reduce_max(simd_abs(g - cube.apply(input)))) }
      XCTAssertLessThanOrEqual(worst, 2e-6, "1D \(size)")
      // Not clamped to 0…1 by any 3D stage: HDR outputs survive.
      XCTAssertEqual(try gpuApply(lut, [SIMD3(1, 1, 0.9)])[0].z, 2.25, accuracy: 1e-5)
    }
    // A tiny lattice holds the largest shaper: its slices are at least 8 × 8.
    var text = "LUT_1D_SIZE 65536\nLUT_3D_SIZE 2\n"
    for i in 0..<65536 { let x = Float(i) / 65535; text += "\(x) \(x) \(x)\n" }
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(r) \(g) \(b)\n" } } }
    let cube = try CubeLUT(text: text)
    let lut = try MonitorLUT(device: gpu.device, cube: cube)
    let inputs = Self.inputs(size: 9, seed: 32, domain: (0, 1))
    for (input, g) in zip(inputs, try gpuApply(lut, inputs)) {
      XCTAssertLessThanOrEqual(simd_reduce_max(simd_abs(g - cube.apply(input))), 2e-6)
    }
  }

  /// The burned-in preview of a shaper LUT is still bit-identical to the host's fused output.
  func testShaperLUTPreviewMatchesTheHostsOutput() throws {
    let gpu = try requireGPU()
    let frame = try routeFrame()
    let burn = try MonitorLUT(device: gpu.device, cube: try Self.shaperCube(size: 33, shaper: 1024, seed: 8))
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = burn
    XCTAssertEqual(try gpu.render(frame, state: MonitorState(), feed: feed).values,
                   try hostOutput(frame, burn: burn, monitor: nil).values)
  }

  // MARK: - Routing

  func routeFrame() throws -> MonitorFrame {
    let gpu = try requireGPU()
    return try PictureTests.picture(width: 80, height: 45, seed: 77).frame(gpu, signal: .rec709)
  }

  /// What a fused host writes to its output with `mk_applyLUT`.
  func hostOutput(_ frame: MonitorFrame, burn: MonitorLUT, monitor: MonitorLUT?) throws -> Pixels {
    let gpu = try requireGPU()
    let t = gpu.texture(.rgba32Float, frame.width, frame.height, usage: [.shaderWrite, .shaderRead])
    gpu.run { cb in
      let e = cb.makeComputeCommandEncoder()!
      e.setComputePipelineState(gpu.hostOutput)
      e.setTexture(frame.packed ?? gpu.engine.emptyPacked, index: 0)
      e.setTexture(frame.luma ?? gpu.engine.emptyFloat, index: 1)
      e.setTexture(frame.chroma ?? gpu.engine.emptyFloat, index: 2)
      e.setTexture(burn.texture, index: 3)
      e.setTexture(monitor?.texture ?? gpu.engine.emptyLUT, index: 4)
      e.setTexture(t, index: 5)
      var f = frame.parameters, b = burn.parameters, m = monitor?.parameters ?? .disabled
      e.setBytes(&f, length: MemoryLayout<FrameParameters>.stride, index: 0)
      e.setBytes(&b, length: MemoryLayout<LUTParameters>.stride, index: 1)
      e.setBytes(&m, length: MemoryLayout<LUTParameters>.stride, index: 2)
      e.dispatchThreads(MTLSize(width: frame.width, height: frame.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
      e.endEncoding()
    }
    return Pixels(t)
  }

  /// The output-stage preview equals a host's `mk_decodeRGB` + `mk_applyLUT` kernel
  /// bit for bit on every layout family, chroma siting and range, not only v210.
  func testOutputStagePreviewMatchesTheHostOnEveryLayout() throws {
    let gpu = try requireGPU()
    let burn = try MonitorLUT(device: gpu.device, cube: try Self.cube(size: 33, seed: 9))
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = burn
    let layouts: [PixelLayout] = [
      .v210, .uyvy8, .yuyv8, .nv12, .p010, .p210, .p410, .biplanar(.s420, bitDepth: 16), .bgra8, .rgb10a2,
      .rgb(bitDepth: 16, float: false), .rgba16Float, .rgba32Float,
    ]
    for layout in layouts {
      var picture = PictureTests.picture(layout, width: 78, height: 44, seed: 21)
      if layout.isRGB { picture = SyntheticFrame.random(layout, width: 78, height: 44, seed: 21) }
      for (range, siting, vertical) in [
        (CodeRange.legal, ChromaSiting.left, ChromaVerticalSiting.center), (.full, .center, .top), (.legal, .left, .bottom),
      ] {
        let signal = SignalDescription(range: range, matrix: .bt2020, chromaSiting: siting, chromaVerticalSiting: vertical)
        let frame = try picture.frame(gpu, signal: signal)
        XCTAssertEqual(
          try gpu.render(frame, state: MonitorState(), feed: feed).values,
          try hostOutput(frame, burn: burn, monitor: nil).values, "\(layout) \(range) \(siting) \(vertical)")
      }
    }
  }

  func testPreviewOfTheOutputStageIsBitIdenticalToTheHostsBurnedInOutput() throws {
    let gpu = try requireGPU()
    let frame = try routeFrame()
    for mode in LUTInterpolation.allCases {
      let burn = try MonitorLUT(device: gpu.device, cube: try Self.cube(size: 33, seed: 5), interpolation: mode)
      let feed = gpu.engine.makeFeed()
      feed.burnInLUT = burn
      let preview = try gpu.render(frame, state: MonitorState(), feed: feed)
      let output = try hostOutput(frame, burn: burn, monitor: nil)
      XCTAssertEqual(preview.values, output.values, "\(mode)")
      // A monitor LUT stacks on top, and the surface can switch it off.
      let monitor = try MonitorLUT(device: gpu.device, cube: try Self.cube(size: 17, seed: 6), interpolation: mode)
      feed.monitorLUT = monitor
      XCTAssertEqual(try gpu.render(frame, state: MonitorState(), feed: feed).values,
                     try hostOutput(frame, burn: burn, monitor: monitor).values, "\(mode) stacked")
      var noMonitor = MonitorState()
      noMonitor.monitorLUT = false
      XCTAssertEqual(try gpu.render(frame, state: noMonitor, feed: feed).values, output.values, "\(mode) monitor off")
    }
  }

  func testOverlaysNeverReachTheOutputStageMeasuredByTools() throws {
    // Zebras on the output stage measure the burned-in result, not the monitor LUT.
    let gpu = try requireGPU()
    let frame = try SyntheticFrame.neutral(.v210, width: 64, height: 16) { x, _ in 64 + x * 13 }.frame(gpu, signal: .rec709)
    var dark = "LUT_3D_SIZE 2\n"
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { dark += "\(Float(r) * 0.5) \(Float(g) * 0.5) \(Float(b) * 0.5)\n" } } }
    let feed = gpu.engine.makeFeed()
    feed.monitorLUT = try MonitorLUT(device: gpu.device, cube: try CubeLUT(text: dark))
    var state = MonitorState()
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 60, opacity: 1, stage: .output)
    let out = try gpu.render(frame, state: state, feed: feed)
    var stage = state
    stage.zebras[0].stage = .monitor
    let monitorStage = try gpu.render(frame, state: stage, feed: feed)
    // Column 48 (a stripe): code 688, 71 IRE at the output, 36 IRE after the monitor LUT.
    XCTAssertEqual(out.rgb(48, 0), SIMD3(repeating: 1), "output stage is striped")
    XCTAssertNotEqual(monitorStage.rgb(48, 0), SIMD3(repeating: 1), "monitor stage is below 60 IRE")
  }
}
