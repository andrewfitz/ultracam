import CoreVideo
@preconcurrency import Metal
import MonitorToolsCore
import XCTest

@testable import MonitorToolsMetal

/// Pixel cases from the composited monitor, retargeted to the one-pass renderer
/// (`MonitorRuntime.renderSnapshot`). The admission, fairness, deadline, owned
/// copy, working-set and critical-pipeline cases retired with those mechanisms.
final class MonitorMetalTests: XCTestCase {
  func buffer(_ format: OSType = kCVPixelFormatType_32BGRA, width: Int = 64, height: Int = 32)
    throws -> CVPixelBuffer
  {
    var b: CVPixelBuffer?
    guard
      CVPixelBufferCreate(
        nil, width, height, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &b)
        == kCVReturnSuccess, let b
    else { throw XCTSkip("Native format allocation unavailable") }
    CVPixelBufferLockBaseAddress(b, [])
    if let base = CVPixelBufferGetBaseAddress(b) { memset(base, 192, CVPixelBufferGetDataSize(b)) }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
  }
  func stamp() -> MonitorFrameStamp {
    MonitorFrameStamp(
      target: MonitorTargetID("fixture"), generation: 1, sequence: 1, sourcePTS: 1, hostTime: 1,
      configurationRevision: 1)
  }
  private func runtime() throws -> MonitorRuntime {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    return MonitorRuntime()
  }

  func testMissingShadersReportsUnavailableGPUInsteadOfDrawing() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let b = try buffer()
    let r = MonitorRuntime(shaderSource: "invalid shader")
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.zebra.enabled = true
    XCTAssertThrowsError(
      try r.renderSnapshot(MonitorFrameBundle(stamp: stamp(), source: b), configuration: c))
    XCTAssertNotNil(r.unavailableReason)
  }

  /// A failed build is kept and reported; callers within the retry delay get
  /// the stored error instead of recompiling on every frame. Status and
  /// drawable attachment never build.
  func testFailedBuildBacksOffInsteadOfRecompilingEveryCall() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let builds = BuildCounter()
    let r = MonitorRuntime(
      sharedDevice: {
        builds.increment()
        return MTLCreateSystemDefaultDevice()
      }, shaderSource: "invalid shader")
    XCTAssertNil(r.unavailableReason)
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let set = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
    r.attachDrawables(set)
    r.detachDrawables(set)
    XCTAssertEqual(builds.value, 0, "Attaching drawables must not build the GPU context")
    let bundle = MonitorFrameBundle(stamp: stamp(), source: try buffer())
    for _ in 0..<5 {
      XCTAssertThrowsError(try r.renderSnapshot(bundle, configuration: MonitorConfiguration()))
    }
    XCTAssertEqual(builds.value, 1, "One failed build, then the stored failure until the retry delay")
    XCTAssertNotNil(r.unavailableReason)
  }

  /// Flushing a target drops only its cached IOSurface textures; the idle
  /// sweep (run by the maintenance timer and by acquire) drops the rest.
  func testTextureCacheFlushesATargetAndSweepsIdleEntries() throws {
    let r = try runtime()
    func bundle(_ target: String) throws -> MonitorFrameBundle {
      MonitorFrameBundle(
        stamp: MonitorFrameStamp(
          target: MonitorTargetID(target), generation: 1, sequence: 1, sourcePTS: 1, hostTime: 1,
          configurationRevision: 1),
        source: try buffer())
    }
    _ = try r.renderSnapshot(try bundle("a"), configuration: MonitorConfiguration(), scopes: false)
    _ = try r.renderSnapshot(try bundle("b"), configuration: MonitorConfiguration(), scopes: false)
    XCTAssertEqual(r.gpuStatistics.cachedTextures, 2)
    r.flushTextures(for: MonitorTargetID("a"))
    XCTAssertEqual(r.gpuStatistics.cachedTextures, 1)
    let metal = try XCTUnwrap(r.builtContext)
    metal.textures.sweepIdle(now: ProcessInfo.processInfo.systemUptime)
    XCTAssertEqual(r.gpuStatistics.cachedTextures, 1, "A texture in use is kept")
    metal.textures.sweepIdle(
      now: ProcessInfo.processInfo.systemUptime + MonitorSurfaceTextureCache.idleLifetime + 1)
    XCTAssertEqual(r.gpuStatistics.cachedTextures, 0)
  }

  func testActualGPUZebraAndSpatialScope() throws {
    let b = try buffer()
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.zebra.enabled = true
    c.zebra.thresholdIRE = 50
    c.scopes.enabled = true
    let out = try runtime().renderSnapshot(
      MonitorFrameBundle(
        stamp: stamp(), source: b, output: b,
        sourceSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709"),
        outputSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")),
      configuration: c.normalized())
    XCTAssertTrue(out.availability.isEmpty, "\(out.availability)")
    XCTAssertNotNil(out.scope)
    let p = out.pictureBytes
    XCTAssertGreaterThan(p[0], 192)
    XCTAssertEqual(p[32], 192, accuracy: 2)
  }

  func testARRIUsesSourceBeforeOutputLUT() throws {
    let source = try buffer()
    let output = try buffer()
    for (b, value) in [(source, UInt8(250)), (output, UInt8(10))] {
      CVPixelBufferLockBaseAddress(b, [])
      memset(CVPixelBufferGetBaseAddress(b), Int32(value), CVPixelBufferGetDataSize(b))
      CVPixelBufferUnlockBaseAddress(b, [])
    }
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.falseColor.mode = .arri
    c.falseColor.profileID = ARRIFalseColorProfile.logC3EI800.rawValue
    c.sourceProfileID = ARRIFalseColorProfile.logC3EI800.rawValue
    let signal = MonitorFrameSignal(
      range: .full, matrix: .bt709, transfer: "logc3",
      profileID: ARRIFalseColorProfile.logC3EI800.rawValue)
    let out = try runtime().renderSnapshot(
      MonitorFrameBundle(
        stamp: stamp(), source: source, output: output, correspondence: .identity,
        sourceSignal: signal,
        outputSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")),
      configuration: c.normalized())
    let pixel = out.pictureBytes
    XCTAssertEqual(pixel[2], 255)
    XCTAssertEqual(pixel[1], 0)
    XCTAssertEqual(pixel[0], 0)
  }

  func testSourceFocusUsesSourceEdgeDespiteFlatOutput() throws {
    let source = try buffer()
    let output = try buffer()
    CVPixelBufferLockBaseAddress(source, [])
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(
      to: UInt8.self)
    for y in 0..<32 {
      for x in 0..<64 {
        for channel in 0..<4 {
          base[y * CVPixelBufferGetBytesPerRow(source) + x * 4 + channel] = x < 32 ? 0 : 255
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(source, [])
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.focus.enabled = true
    let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")
    let out = try runtime().renderSnapshot(
      MonitorFrameBundle(
        stamp: stamp(), source: source, output: output, correspondence: .identity,
        sourceSignal: signal, outputSignal: signal),
      configuration: c.normalized())
    let bytes = out.pictureBytes
    let rowBytes = out.width * 4
    let edge = 16 * rowBytes + 31 * 4
    XCTAssertGreaterThan(bytes[edge + 2], bytes[edge + 1])
    let flat = 16 * rowBytes + 8 * 4
    XCTAssertEqual(bytes[flat], bytes[flat + 2])
  }

  func testScopeRGBOrderAndExtendedRangeAxesOnGPU() throws {
    let b = try buffer()
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.scopes.enabled = true
    let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")
    let out = try runtime().renderSnapshot(
      MonitorFrameBundle(stamp: stamp(), source: b, output: b, sourceSignal: signal, outputSignal: signal),
      configuration: c.normalized())
    let bytes = try XCTUnwrap(out.scopeBytes, "scope unavailable")
    // Independent axis calculation: 192/255 =75.29IRE, -10...110 maps tobin181,row74.
    let red = 74 * 768 * 4
    let green = red + 256 * 4
    let blue = red + 512 * 4
    XCTAssertGreaterThan(bytes[red + 2], bytes[red])
    XCTAssertGreaterThan(bytes[green + 1], bytes[green + 2])
    XCTAssertGreaterThan(bytes[blue], bytes[blue + 1])
  }

  func testZebraBandIsCenteredLikeIndependentScalarClassifier() throws {
    let runtime = try runtime()
    for code in [UInt8(166), UInt8(196)] {
      let b = try buffer()
      CVPixelBufferLockBaseAddress(b, [])
      memset(CVPixelBufferGetBaseAddress(b), Int32(code), CVPixelBufferGetDataSize(b))
      CVPixelBufferUnlockBaseAddress(b, [])
      var c = MonitorConfiguration()
      c.toolsEnabled = true
      c.zebra.enabled = true
      c.zebra.mode = .band
      c.zebra.thresholdIRE = 70
      c.zebra.widthIRE = 10
      let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")
      let out = try runtime.renderSnapshot(
        MonitorFrameBundle(stamp: stamp(), source: b, output: b, sourceSignal: signal, outputSignal: signal),
        configuration: c.normalized())
      let value = out.pictureBytes[0]
      if code == 166 {
        XCTAssertGreaterThan(value, code)
      } else {
        XCTAssertEqual(value, code, accuracy: 1)
      }
    }
  }

  /// An unqualified transfer keeps the plain picture (no tools) and says why;
  /// scopes of the signal still run.
  func testUnknownOrHDRTransferDoesNotGetRetaggedAsSDR() throws {
    let runtime = try runtime()
    for transfer in ["Unknown", "SMPTE_ST_2084_PQ", "HLG"] {
      let b = try buffer()
      var c = MonitorConfiguration()
      c.toolsEnabled = true
      c.zebra.enabled = true
      c.zebra.thresholdIRE = 50
      c.scopes.enabled = true
      let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: transfer)
      let out = try runtime.renderSnapshot(
        MonitorFrameBundle(stamp: stamp(), source: b, output: b, sourceSignal: signal, outputSignal: signal),
        configuration: c.normalized())
      XCTAssertNotNil(out.scope)
      XCTAssertTrue(out.availability.contains { $0.contains("unsupported SDR") }, "\(out.availability)")
      // Pixel 0 is on a zebra stripe; 75 IRE would be striped if tools were drawn.
      XCTAssertEqual(Array(out.pictureBytes[0..<3]), [192, 192, 192], "\(transfer)")
    }
  }

  func testARRIFullRescaledToLegalUsesIndependentlyRoundedFullTable() throws {
    let source = try buffer(kCVPixelFormatType_422YpCbCr10)
    let output = try buffer()
    CVPixelBufferLockBaseAddress(source, [])
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(source))
    let patterns: [UInt32] = [
      512 | (878 << 10) | (512 << 20), 878 | (512 << 10) | (878 << 20),
      512 | (878 << 10) | (512 << 20), 878 | (512 << 10) | (878 << 20),
    ]
    for y in 0..<32 {
      let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(source)).assumingMemoryBound(
        to: UInt32.self)
      for x in 0..<64 { row[x] = patterns[x % 4] }
    }
    CVPixelBufferUnlockBaseAddress(source, [])
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.falseColor.mode = .arri
    c.falseColor.profileID = ARRIFalseColorProfile.logC3EI800.rawValue
    c.sourceProfileID = ARRIFalseColorProfile.logC3EI800.rawValue
    c.sourceLogMapping = .fullRescaledToLegal10Bit
    let signal = MonitorFrameSignal(
      range: .legal, matrix: .bt709, transfer: "logc3",
      profileID: ARRIFalseColorProfile.logC3EI800.rawValue)
    let out = try runtime().renderSnapshot(
      MonitorFrameBundle(
        stamp: stamp(), source: source, output: output, correspondence: .identity,
        sourceSignal: signal,
        outputSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")),
      configuration: c.normalized())
    let bytes = out.pictureBytes
    XCTAssertEqual(bytes[2], 255)
    XCTAssertEqual(bytes[1], 255)
    XCTAssertEqual(bytes[0], 0)
  }

  /// The clean aperture (CoreVideo offsets already resolved to a top-left
  /// rect by the producer) is what the picture shows: output pixel (0,0) is
  /// aperture origin (5,3), measured from the top, not mirrored vertically.
  func testAsymmetricApertureShowsTheTopLeftOriginedCleanRect() throws {
    func patterned() throws -> CVPixelBuffer {
      let b = try buffer()
      CVPixelBufferLockBaseAddress(b, [])
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(b)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(b)
      for y in 0..<32 { for x in 0..<64 {
        let p = y * stride + x * 4
        base[p] = UInt8(x * 3); base[p + 1] = UInt8(y * 5); base[p + 2] = 0; base[p + 3] = 255
      }}
      CVPixelBufferUnlockBaseAddress(b, [])
      return b
    }
    let source = try patterned()
    let output = try patterned()
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.zebra.enabled = true
    let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")
    let geometry = MonitorGeometry(
      width: 64, height: 32, cleanAperture: MonitorRect(x: 5, y: 3, width: 40, height: 20))
    let out = try runtime().renderSnapshot(
      MonitorFrameBundle(
        stamp: stamp(), source: source, output: output, outputGeometry: geometry,
        sourceSignal: signal, outputSignal: signal),
      configuration: c.normalized(), width: 40, height: 20)
    XCTAssertTrue(out.availability.isEmpty, "\(out.availability)")
    let bytes = out.pictureBytes
    XCTAssertEqual(Array(bytes[0..<2]), [15, 15])
    let last = (19 * 40 + 39) * 4
    XCTAssertEqual(Array(bytes[last..<last + 2]), [132, 110])
  }

  func testGraticuleToggleChangesOnlyScopeGridPixels() throws {
    let runtime = try runtime()
    for enabled in [false, true] {
      let b = try buffer()
      var c = MonitorConfiguration()
      c.toolsEnabled = true
      c.scopes.enabled = true
      c.scopes.graticule = enabled
      let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")
      let out = try runtime.renderSnapshot(
        MonitorFrameBundle(stamp: stamp(), source: b, output: b, sourceSignal: signal, outputSignal: signal),
        configuration: c.normalized())
      XCTAssertEqual(out.pictureSignal?.transfer, "rec709")
      XCTAssertEqual(out.scopeSignal?.range, .full)
      let bytes = try XCTUnwrap(out.scopeBytes, "scope unavailable")
      let value = bytes[(128 * 768 + 1) * 4]
      if enabled { XCTAssertGreaterThan(value, 0) } else { XCTAssertEqual(value, 0) }
    }
  }

  /// A short chroma plane is refused before any GPU read.
  func testMalformedPlanarHeightCannotBeRead() throws {
    let storage = UnsafeMutableRawPointer.allocate(byteCount: 64 * 47, alignment: 64)
    memset(storage, 0, 64 * 47)
    var addresses: [UnsafeMutableRawPointer?] = [storage, storage.advanced(by: 64 * 32)]
    var widths = [64, 32]
    var heights = [32, 15]
    var strides = [64, 64]
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreateWithPlanarBytes(
      nil, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, storage, 64 * 47, 2, &addresses,
      &widths, &heights, &strides,
      { _, data, _, _, _ in if let data { UnsafeMutableRawPointer(mutating: data).deallocate() } },
      nil, nil, &image)
    guard status == kCVReturnSuccess, let image else {
      storage.deallocate()
      return
    }  // Some OS versions reject malformed planes themselves.
    XCTAssertThrowsError(
      try runtime().renderSnapshot(
        MonitorFrameBundle(stamp: stamp(), source: image), configuration: MonitorConfiguration())
    ) { XCTAssertTrue($0 is MonitorPreviewError, "\($0)") }
  }

  func testEveryPublishedARRINativeTenBitBoundaryOnGPU() throws {
    let runtime = try runtime()
    for profile in ARRIFalseColorProfile.allCases {
      for range in [MonitorCodeRange.legal, .full] {
        let codes = profile.zones(range: range).flatMap {
          [max(0, Int($0.lower) - 1), Int($0.lower), Int($0.upper) - 1, Int($0.upper)]
        }
        let b = try buffer(kCVPixelFormatType_422YpCbCr10, width: codes.count * 6, height: 32)
        CVPixelBufferLockBaseAddress(b, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(b))
        for row in 0..<32 {
          let words = base.advanced(by: row * CVPixelBufferGetBytesPerRow(b)).assumingMemoryBound(
            to: UInt32.self)
          for (index, code) in codes.enumerated() {
            let y = UInt32(code)
            words[index * 4] = 512 | (y << 10) | (512 << 20)
            words[index * 4 + 1] = y | (512 << 10) | (y << 20)
            words[index * 4 + 2] = 512 | (y << 10) | (512 << 20)
            words[index * 4 + 3] = y | (512 << 10) | (y << 20)
          }
        }
        CVPixelBufferUnlockBaseAddress(b, [])
        var config = MonitorConfiguration()
        config.toolsEnabled = true
        config.pictureStage = .source
        config.falseColor.mode = .arri
        config.falseColor.profileID = profile.rawValue
        config.sourceProfileID = profile.rawValue
        let out = try runtime.renderSnapshot(
          MonitorFrameBundle(
            stamp: MonitorFrameStamp(
              target: MonitorTargetID("boundaries"), generation: 1, sequence: 1, sourcePTS: 1,
              hostTime: 1, configurationRevision: 1),
            source: b, correspondence: .identity,
            sourceSignal: MonitorFrameSignal(
              range: range, matrix: .bt709, transfer: profile.rawValue,
              profileID: profile.rawValue)),
          configuration: config.normalized())
        let bytes = out.pictureBytes
        for (index, code) in codes.enumerated() {
          let gray = range.normalizeLuma(code: Double(code), bitDepth: 10)!
          let rgb =
            profile.category(achromaticCode: Double(code), range: range)?.color
            ?? MonitorRGB(r: gray, g: gray, b: gray)
          let expected = [rgb.b, rgb.g, rgb.r]
          for channel in 0..<3 {
            XCTAssertEqual(
              Double(bytes[index * 6 * 4 + channel]), min(1, max(0, expected[channel])) * 255,
              accuracy: 1, "\(profile.rawValue) \(range.rawValue) native code\(code)")
          }
        }
      }
    }
  }

  func testDeclaredSourceLogShowsCodeViewWithNumericZebraAndSourceFocus() throws {
    let b = try buffer()
    CVPixelBufferLockBaseAddress(b, [])
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(b)).assumingMemoryBound(to: UInt8.self)
    for y in 0..<32 {
      for x in 0..<64 {
        for c in 0..<4 { base[y * CVPixelBufferGetBytesPerRow(b) + x * 4 + c] = x < 32 ? 0 : 192 }
      }
    }
    CVPixelBufferUnlockBaseAddress(b, [])
    let profile = "sony-slog3-sgamut3cine"
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.pictureStage = .source
    config.sourceProfileID = profile
    config.zebra.enabled = true
    config.zebra.thresholdIRE = 50
    config.focus.enabled = true
    let result = try runtime().renderSnapshot(
      MonitorFrameBundle(
        stamp: stamp(), source: b, correspondence: .identity,
        sourceSignal: MonitorFrameSignal(
          range: .full, matrix: .bt709, transfer: profile, profileID: profile)),
      configuration: config.normalized())
    XCTAssertTrue(result.availability.contains { $0.contains("code-value view") })
    XCTAssertEqual(result.pictureSignal?.profileID, profile)
    let bytes = result.pictureBytes
    XCTAssertGreaterThan(bytes[48 * 4], 192)
    let edge = 16 * result.width * 4 + 32 * 4
    XCTAssertGreaterThan(bytes[edge + 2], bytes[edge + 1])
  }
}

private final class BuildCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}
