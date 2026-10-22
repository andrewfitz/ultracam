import CoreVideo
import Metal
import XCTest

@testable import MonitorKit

/// `mk_decode` against the Double CPU reference for every layout, bit depth,
/// range, matrix and chroma siting, from raw textures and from IOSurface pixel
/// buffers mapped through `CVMetalTextureCache`.
final class DecodeTests: XCTestCase {
  static let yuvLayouts: [PixelLayout] = [.v210, .uyvy8, .yuyv8] + [ChromaSubsampling.s420, .s422, .s444].flatMap { s in
    [8, 10, 12, 16].map { PixelLayout.biplanar(s, bitDepth: $0) }
  }
  static let rgbLayouts: [PixelLayout] = [
    .rgb(bitDepth: 8, float: false), .rgb(bitDepth: 10, float: false), .rgb(bitDepth: 16, float: false),
    .rgba16Float, .rgba32Float,
  ]

  /// Contract: ≤ 1/1023 at integral codes. The decode is far tighter than that.
  static let tolerance = 2e-6

  func compare(
    _ gpu: [SIMD4<Float>], _ cpu: [(rgb: SIMD3<Double>, luma: Double)], _ what: String,
    tolerance: Double = tolerance
  ) {
    var worst = 0.0
    for (g, c) in zip(gpu, cpu) {
      let e = max(
        abs(Double(g.x) - c.rgb.x), abs(Double(g.y) - c.rgb.y), abs(Double(g.z) - c.rgb.z), abs(Double(g.w) - c.luma))
      worst = max(worst, e.isNaN ? .infinity : e)
    }
    XCTAssertLessThanOrEqual(worst, tolerance, what)
  }

  func testEveryYCbCrLayoutDepthRangeMatrixAndSitingFromRawTextures() throws {
    let gpu = try requireGPU()
    var seed: UInt64 = 1
    for layout in Self.yuvLayouts {
      // Odd sizes exercise partial v210 groups, odd chroma columns and the last 4:2:0 row.
      let picture = SyntheticFrame.random(layout, width: 27, height: 9, seed: seed)
      seed += 1
      for range in [CodeRange.legal, .full] {
        for matrix in [YCbCrMatrix.bt601, .bt709, .bt2020] {
          for siting in layout.subsampling == .s444 ? [ChromaSiting.left] : [.left, .center] {
            let signal = SignalDescription(range: range, matrix: matrix, chromaSiting: siting)
            let frame = try picture.frame(gpu, signal: signal)
            compare(gpu.decode(frame), picture.reference(signal), "\(layout) \(range) \(matrix) \(siting)")
          }
        }
      }
    }
  }

  func testEveryRGBLayoutAndTextureFormatFromRawTextures() throws {
    let gpu = try requireGPU()
    let formats: [(PixelLayout, [MTLPixelFormat])] = [
      (.rgb(bitDepth: 8, float: false), [.bgra8Unorm, .rgba8Unorm]),
      (.rgb(bitDepth: 10, float: false), [.bgr10a2Unorm, .rgb10a2Unorm]),
      (.rgb(bitDepth: 16, float: false), [.rgba16Unorm]), (.rgba16Float, [.rgba16Float]),
      (.rgba32Float, [.rgba32Float]),
    ]
    for (i, (layout, textureFormats)) in formats.enumerated() {
      let picture = SyntheticFrame.random(layout, width: 19, height: 7, seed: 100 + UInt64(i))
      for format in textureFormats {
        for range in layout.isFloat ? [CodeRange.full] : [.legal, .full] {
          let signal = SignalDescription(range: range, matrix: .bt709)
          let frame = try picture.frame(gpu, signal: signal, rgbFormat: format)
          compare(gpu.decode(frame), picture.reference(signal), "\(layout) \(format.rawValue) \(range)")
        }
      }
    }
  }

  func testFloatRGBIgnoresALegalRangeLabel() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.random(.rgba16Float, width: 8, height: 2, seed: 7)
    let frame = try picture.frame(gpu, signal: SignalDescription(range: .legal))
    compare(gpu.decode(frame), picture.reference(SignalDescription(range: .full)), "float RGB stays normalized")
    XCTAssertEqual(frame.parameters.options.y, 1)
  }

  func testEveryPixelBufferFormatThroughTheTextureCache() throws {
    let gpu = try requireGPU()
    var covered: [String] = []
    for (i, layout) in (Self.yuvLayouts + Self.rgbLayouts).enumerated() {
      let picture = SyntheticFrame.random(layout, width: 48, height: 10, seed: 200 + UInt64(i))
      // CoreVideo's packed 4:2:2 and RGB formats carry one range each.
      let packed = layout == .v210 || layout == .uyvy8 || layout == .yuyv8
      for range in layout.isRGB ? [CodeRange.full] : packed ? [.legal] : [.legal, .full] {
        guard let type = picture.pixelFormat(range: range) else { continue }
        // CoreVideo has only video-range 16-bit biplanar formats.
        if case .biplanar(_, 16) = layout, range == .full { continue }
        let pb = try XCTUnwrap(picture.pixelBuffer(range: range), "CoreVideo cannot create \(fourCC(type))")
        XCTAssertEqual(MonitorFrame.layout(for: type)?.layout, layout)
        XCTAssertEqual(MonitorFrame.layout(for: type)?.range, range)
        for siting in layout.subsampling == .s444 ? [ChromaSiting.left] : [.left, .center] {
          let signal = SignalDescription(range: range, matrix: .bt2020, chromaSiting: siting)
          let frame = try MonitorFrame.wrap(pb, cache: gpu.cache, signal: signal)
          XCTAssertEqual(frame.layout, layout)
          compare(gpu.decode(frame), picture.reference(signal), "\(fourCC(type)) \(siting)")
        }
        covered.append(fourCC(type))
      }
    }
    XCTAssertEqual(covered.count, 22, "\(covered)")
  }

  func testAttachmentsDescribeTheSignal() throws {
    let picture = SyntheticFrame.random(.p010, width: 16, height: 4, seed: 9)
    let pb = try XCTUnwrap(picture.pixelBuffer(range: .legal))
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
    let signal = MonitorFrame.signal(of: pb, range: .legal)
    XCTAssertEqual(signal.matrix, .bt2020)
    XCTAssertEqual(signal.encoding, .display(.hlg))
    XCTAssertEqual(signal.chromaSiting, .center)
  }

  /// 4:2:0 vertical siting: centred (MPEG-2), top (HEVC/BT.2020 "top-left") and bottom.
  func testEveryVerticalChromaSitingOf420() throws {
    let gpu = try requireGPU()
    for layout in [PixelLayout.nv12, .p010, .biplanar(.s420, bitDepth: 16)] {
      let picture = SyntheticFrame.random(layout, width: 27, height: 11, seed: 40)
      for vertical in ChromaVerticalSiting.allCases {
        for siting in ChromaSiting.allCases {
          let signal = SignalDescription(range: .legal, matrix: .bt2020, chromaSiting: siting, chromaVerticalSiting: vertical)
          let frame = try picture.frame(gpu, signal: signal)
          XCTAssertEqual(frame.parameters.matrix.w, Float(vertical.offset))
          compare(gpu.decode(frame), picture.reference(signal), "\(layout) \(siting) \(vertical)")
        }
      }
    }
    // Top-sited chroma is co-sited with even rows: an even row reads its chroma row unblended.
    let t = DecodeReference.chromaTaps(x: 0, y: 4, width: 8, height: 8, subsampling: .s420, siting: .left, vertical: .top)
    XCTAssertEqual(t.y0, 2)
    XCTAssertEqual(t.fy, 0)
    // 4:2:2 ignores it.
    let picture = SyntheticFrame.random(.p210, width: 12, height: 4, seed: 41)
    let a = try picture.frame(gpu, signal: SignalDescription(chromaVerticalSiting: .top))
    let b = try picture.frame(gpu, signal: SignalDescription())
    XCTAssertEqual(gpu.decode(a), gpu.decode(b))
  }

  /// SMPTE 240M decodes with its own coefficients (Kr 0.212, Kb 0.087), not BT.601's.
  func testSMPTE240MMatrix() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.random(.v210, width: 30, height: 4, seed: 42)
    let signal = SignalDescription(matrix: .smpte240m)
    compare(gpu.decode(try picture.frame(gpu, signal: signal)), picture.reference(signal), "240M")
    let pb = try XCTUnwrap(SyntheticFrame.random(.p010, width: 16, height: 4, seed: 9).pixelBuffer(range: .legal))
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995, .shouldPropagate)
    XCTAssertEqual(MonitorFrame.signal(of: pb, range: .legal).matrix, .smpte240m)
    // R from Cr: 2 (1 - Kr) = 1.576 for 240M (1.402 under BT.601).
    let red = DecodeReference.rgb(lumaCode: 64, cbCode: 512, crCode: 512 + 448, bitDepth: 10, range: .legal, matrix: .smpte240m)
    XCTAssertEqual(red.rgb.r, 1.576 * 0.5, accuracy: 1e-12)
  }

  func testChromaLocationAttachmentsMapBothAxes() throws {
    let cases: [(CFString, ChromaSiting, ChromaVerticalSiting)] = [
      (kCVImageBufferChromaLocation_Left, .left, .center), (kCVImageBufferChromaLocation_Center, .center, .center),
      (kCVImageBufferChromaLocation_TopLeft, .left, .top), (kCVImageBufferChromaLocation_Top, .center, .top),
      (kCVImageBufferChromaLocation_BottomLeft, .left, .bottom), (kCVImageBufferChromaLocation_Bottom, .center, .bottom),
    ]
    for (location, horizontal, vertical) in cases {
      let pb = try XCTUnwrap(SyntheticFrame.random(.p010, width: 16, height: 4, seed: 9).pixelBuffer(range: .legal))
      CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, location, .shouldPropagate)
      let signal = MonitorFrame.signal(of: pb, range: .legal)
      XCTAssertEqual(signal.chromaSiting, horizontal, "\(location)")
      XCTAssertEqual(signal.chromaVerticalSiting, vertical, "\(location)")
    }
    // Unlabelled: left-sited, vertically centred, BT.709.
    let pb = try XCTUnwrap(SyntheticFrame.random(.p010, width: 16, height: 4, seed: 9).pixelBuffer(range: .legal))
    let plain = MonitorFrame.signal(of: pb, range: .legal)
    XCTAssertEqual(plain, SignalDescription(range: .legal))
  }

  func testPixelAspectAttachment() throws {
    let gpu = try requireGPU()
    let pb = try XCTUnwrap(SyntheticFrame.random(.p010, width: 16, height: 4, seed: 9).pixelBuffer(range: .legal))
    XCTAssertEqual(try MonitorFrame.wrap(pb, cache: gpu.cache).pixelAspectRatio, 1)
    let aspect = [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 4, kCVImageBufferPixelAspectRatioVerticalSpacingKey: 3] as CFDictionary
    CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
    XCTAssertEqual(try MonitorFrame.wrap(pb, cache: gpu.cache).pixelAspectRatio, 4.0 / 3, accuracy: 1e-12)
  }

  /// `wrap`, the per-frame entry point, allocates nothing beyond the texture
  /// cache's own calls, even with every attachment set.
  func testWrapAllocatesOnlyWhatTheTextureCacheDoes() throws {
    let gpu = try requireGPU()
    let pb = try XCTUnwrap(SyntheticFrame.random(.p010, width: 64, height: 16, seed: 9).pixelBuffer(range: .legal))
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_TopLeft, .shouldPropagate)
    let aspect = [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 1, kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1] as CFDictionary
    CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
    for _ in 0..<3 { _ = try MonitorFrame.wrap(pb, cache: gpu.cache) }
    var library: [Int] = [], control: [Int] = []
    for _ in 0..<20 {
      guard let a = try AllocationCounter.measure({ _ = try MonitorFrame.wrap(pb, cache: gpu.cache) }) else {
        throw XCTSkip("malloc_logger is unavailable")
      }
      let b = AllocationCounter.measure {
        var y: CVMetalTexture?, c: CVMetalTexture?
        _ = CVMetalTextureCacheCreateTextureFromImage(
          nil, gpu.cache, pb, nil, .r16Unorm, CVPixelBufferGetWidthOfPlane(pb, 0), CVPixelBufferGetHeightOfPlane(pb, 0), 0, &y)
        _ = CVMetalTextureCacheCreateTextureFromImage(
          nil, gpu.cache, pb, nil, .rg16Unorm, CVPixelBufferGetWidthOfPlane(pb, 1), CVPixelBufferGetHeightOfPlane(pb, 1), 1, &c)
        _ = y.flatMap(CVMetalTextureGetTexture)
        _ = c.flatMap(CVMetalTextureGetTexture)
        // CoreVideo copies a dictionary attachment when it is read.
        _ = CVBufferCopyAttachment(pb, kCVImageBufferPixelAspectRatioKey, nil)
      }!
      library.append(a)
      control.append(b)
    }
    let a = library.sorted()[library.count / 2], b = control.sorted()[control.count / 2]
    print("BENCH heap allocations per wrap: \(a); the texture cache calls alone: \(b)")
    XCTAssertLessThanOrEqual(a, b)
  }

  func testFrameValidationRejectsMismatchedTextures() throws {
    let gpu = try requireGPU()
    let luma = gpu.texture(.r8Unorm, 16, 16)
    XCTAssertThrowsError(try MonitorFrame(layout: .p010, width: 16, height: 16, luma: luma, chroma: luma, signal: .rec709))
    XCTAssertThrowsError(try MonitorFrame(layout: .nv12, width: 32, height: 16, luma: luma, chroma: luma, signal: .rec709))
    XCTAssertThrowsError(try MonitorFrame(layout: .v210, width: 16, height: 16, signal: .rec709))
    XCTAssertThrowsError(try MonitorFrame(layout: .biplanar(.s420, bitDepth: 9), width: 16, height: 16, signal: .rec709))
  }

  /// Neutral samples decode exactly: chroma at its centre reconstructs Y' in every channel.
  func testNeutralIntegralCodesDecodeExactly() throws {
    let gpu = try requireGPU()
    for layout in [PixelLayout.v210, .p010, .p210] {
      let picture = SyntheticFrame.neutral(layout, width: 1024, height: 2) { x, _ in x }
      for range in [CodeRange.legal, .full] {
        let signal = SignalDescription(range: range, matrix: .bt2020)
        let decoded = gpu.decode(try picture.frame(gpu, signal: signal))
        for x in 0..<1024 {
          let v = decoded[x]
          XCTAssertTrue(v.x == v.y && v.y == v.z && v.z == v.w, "\(layout) code \(x)")
          let expected = range.normalizeLuma(code: Double(x), bitDepth: 10)!
          XCTAssertEqual(Double(v.w), expected, accuracy: 1e-6)
        }
      }
    }
  }
}
