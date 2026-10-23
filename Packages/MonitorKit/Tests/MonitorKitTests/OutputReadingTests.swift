import Metal
import simd
import XCTest

@testable import MonitorKit

/// The per-stage decode: a signal whose Output and Monitor stages read the codes
/// differently from the source (`SignalDescription.outputReading`: a camera
/// declared full range on a legal link, a full-range format declared legal, a
/// SMPTE 240M source whose output path decodes BT.709). Each stage, and every
/// tool and the focus analysis measuring it, decodes the codes with its own
/// reading: what drawing a frame labelled with that stage's reading alone gives,
/// bit for bit, and exact at integral codes against the Double reference.
final class OutputReadingTests: XCTestCase {
  struct Case {
    var name: String
    var picture: SyntheticFrame
    var signal: SignalDescription
  }

  /// Full-range camera codes on a legal v210 link; a full-range P010 buffer whose
  /// codes are legal; a 240M source read as BT.709 downstream; legal 8-bit RGB
  /// in a full container.
  static func cases(width: Int = 64, height: Int = 24, seed: UInt64 = 5) -> [Case] {
    // Codes inside the 8-bit-scaled 16…234 luma range with modest chroma: no
    // picture pixel is pure white, so an overlay mark always shows.
    let v210 = PictureTests.picture(.v210, width: width, height: height, seed: seed)
    let p010 = PictureTests.picture(.p010, width: width, height: height, seed: seed + 1)
    let uyvy = PictureTests.picture(.uyvy8, width: width, height: height, seed: seed + 2)
    let bgra = PictureTests.picture(.bgra8, width: width, height: height, seed: seed + 3)
    return [
      Case(
        name: "v210 declared full, output legal", picture: v210,
        signal: SignalDescription(range: .full, outputReading: SignalReading(range: .legal, matrix: .bt709))),
      Case(
        name: "P010 full container declared legal", picture: p010,
        signal: SignalDescription(range: .legal, outputReading: SignalReading(range: .full, matrix: .bt709))),
      Case(
        name: "SMPTE 240M, output BT.709", picture: uyvy,
        signal: SignalDescription(matrix: .smpte240m, outputReading: SignalReading(range: .legal, matrix: .bt709))),
      Case(
        name: "240M declared full, output legal BT.709", picture: v210,
        signal: SignalDescription(
          range: .full, matrix: .smpte240m, outputReading: SignalReading(range: .legal, matrix: .bt709))),
      Case(
        name: "bgra8 declared legal, output full", picture: bgra,
        signal: SignalDescription(range: .legal, outputReading: SignalReading(range: .full, matrix: .bt709))),
    ]
  }

  /// `frame` relabelled with one reading only: the source's (`.source`) or the
  /// output reading (`.output`, `.monitor`), as a host drawing one reading per pass.
  static func single(_ frame: MonitorFrame, _ stage: SignalStage) -> MonitorFrame {
    var f = frame
    var s = frame.signal.signal(for: stage)
    s.outputReading = nil
    f.signal = s
    return f
  }

  static func luts(_ gpu: TestGPU) throws -> (MonitorLUT, MonitorLUT) {
    (
      try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 11)),
      try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 33, seed: 12))
    )
  }

  func feed(_ gpu: TestGPU, luts: (MonitorLUT, MonitorLUT)?) -> MonitorFeed {
    let f = gpu.engine.makeFeed()
    f.burnInLUT = luts?.0
    f.monitorLUT = luts?.1
    return f
  }

  // MARK: - Core

  func testReadingsOfEachStage() {
    let declared = SignalDescription(range: .full, matrix: .smpte240m, encoding: .log(.sLog3SGamut3Cine))
    XCTAssertFalse(declared.hasDistinctOutputReading)
    XCTAssertEqual(declared.signal(for: .output), declared)
    var same = declared
    same.outputReading = declared.sourceReading
    XCTAssertFalse(same.hasDistinctOutputReading, "a reading equal to the source's is no difference")
    var distinct = declared
    distinct.outputReading = SignalReading(range: .legal, matrix: .bt709)
    XCTAssertTrue(distinct.hasDistinctOutputReading)
    XCTAssertEqual(distinct.signal(for: .source), distinct)
    let output = distinct.signal(for: .monitor)
    XCTAssertEqual(output.range, .legal)
    XCTAssertEqual(output.matrix, .bt709)
    XCTAssertEqual(output.encoding, declared.encoding, "only the range and matrix change")
    XCTAssertNil(output.outputReading)
    XCTAssertEqual(distinct.signal(for: .output), distinct.outputSignal)
  }

  func testFrameParametersOfEachStage() throws {
    let gpu = try requireGPU()
    for c in Self.cases() {
      let frame = try c.picture.frame(gpu, signal: c.signal)
      XCTAssertEqual(frame.parameters(for: .source), frame.parameters, c.name)
      XCTAssertEqual(frame.parameters(for: .output), Self.single(frame, .output).parameters, c.name)
      XCTAssertEqual(frame.parameters(for: .monitor), frame.parameters(for: .output), c.name)
      XCTAssertNotEqual(frame.parameters(for: .output), frame.parameters, c.name)
    }
  }

  // MARK: - Picture

  /// Each picture stage with no LUT: its own reading's Double decode, to the
  /// float decode's rounding.
  func testEachPictureStageIsItsReadingsDecode() throws {
    let gpu = try requireGPU()
    for c in Self.cases() {
      let frame = try c.picture.frame(gpu, signal: c.signal)
      for stage in SignalStage.allCases {
        var state = MonitorState()
        state.pictureStage = stage
        let out = try gpu.render(frame, state: state)
        let reference = c.picture.reference(c.signal.signal(for: stage))
        var worst = 0.0
        for y in 0..<c.picture.height {
          for x in 0..<c.picture.width {
            let r = simd_clamp(reference[y * c.picture.width + x].rgb, .zero, SIMD3(repeating: 1))
            worst = max(worst, simd_reduce_max(simd_abs(SIMD3<Double>(out.rgb(x, y)) - r)))
          }
        }
        XCTAssertLessThan(worst, 2e-6, "\(c.name) \(stage)")
      }
    }
  }

  /// One code ramp of 10-bit v210 (a column per code), the camera's codes
  /// declared full range and the output read legal: a zebra at 100 IRE and the
  /// clip indicator at 100 % / 0 % mark exactly the codes the Double reference
  /// puts there in each stage's reading: 940 and up, 64 and down on the Output
  /// stage, 1023 and 0 on the source. Exact at the boundary, whatever stage the
  /// picture shows.
  func testZebrasAndClipIndicatorsAreExactAtEachStagesWhiteAndBlack() throws {
    let gpu = try requireGPU()
    let (w, h) = (1024, 16)
    let ramp = SyntheticFrame.neutral(.v210, width: w, height: h) { x, _ in x }
    let signal = SignalDescription(range: .full, outputReading: SignalReading(range: .legal, matrix: .bt709))
    let frame = try ramp.frame(gpu, signal: signal)
    for picture in SignalStage.allCases {
      for stage in SignalStage.allCases {
        let reading = signal.signal(for: stage)
        func ire(_ code: Int) -> Double {
          DecodeReference.rgb(
            lumaCode: Double(code), cbCode: 512, crCode: 512, bitDepth: 10, range: reading.range, matrix: reading.matrix
          ).luma * 100
        }
        var base = MonitorState()
        base.pictureStage = picture
        let plain = try gpu.render(frame, state: base)
        var zebra = base
        zebra.zebras[0] = ZebraSet(mode: .lowerLimit, level: 100, stage: stage)
        zebra.zebras[0].opacity = 1
        let striped = try gpu.render(frame, state: zebra)
        var clip = base
        clip.clipIndicators.enabled = true
        clip.clipIndicators.stage = stage
        clip.clipIndicators.red = false
        clip.clipIndicators.green = false
        clip.clipIndicators.blue = false
        clip.clipIndicators.luma = true
        clip.clipIndicators.coloring = .uniform
        clip.clipIndicators.overColor = ColorRGB(r: 1, g: 0, b: 1)
        clip.clipIndicators.underColor = ColorRGB(r: 0, g: 1, b: 1)
        clip.clipIndicators.opacity = 1
        let clipped = try gpu.render(frame, state: clip)
        var marked = (zebra: 0, over: 0, under: 0)
        for x in 0..<w {
          let v = ire(x)
          let label = "picture \(picture), tools on \(stage), code \(x)"
          for y in 0..<h {
            // Stripes: 16-pixel period at one pixel per point, light half first.
            let stripe = (x + y) % 16 < 8
            let expected = v >= 100 && stripe ? SIMD3<Float>(1, 1, 1) : plain.rgb(x, y)
            // Opacity 1 mixes to the overlay colour within a rounding.
            XCTAssertLessThan(simd_reduce_max(simd_abs(striped.rgb(x, y) - expected)), 1e-6, label)
            let flag: SIMD3<Float>? = v >= 100 ? SIMD3(1, 0, 1) : (v <= 0 ? SIMD3(0, 1, 1) : nil)
            XCTAssertLessThan(simd_reduce_max(simd_abs(clipped.rgb(x, y) - (flag ?? plain.rgb(x, y)))), 1e-6, label)
            if flag == nil { XCTAssertEqual(clipped.rgb(x, y), plain.rgb(x, y), label) }
            if !(v >= 100 && stripe) { XCTAssertEqual(striped.rgb(x, y), plain.rgb(x, y), label) }
          }
          if v >= 100 { marked.zebra += 1; marked.over += 1 }
          if v <= 0 { marked.under += 1 }
        }
        XCTAssertEqual(marked.over, stage == .source ? 1 : 84, "\(stage): codes at or over white")
        XCTAssertEqual(marked.under, stage == .source ? 1 : 65, "\(stage): codes at or under black")
      }
    }
  }

  /// Every tool on every stage, with both LUTs: the picture of a stage, its
  /// zebras, clip indicators, six-band and custom false colour (IRE and stops)
  /// and peaking match a frame labelled with that stage's reading alone, bit for
  /// bit; with the picture on another stage, the tools mark exactly the pixels
  /// they mark there.
  func testEveryToolOnEveryStageMatchesItsStagesSingleReading() throws {
    let gpu = try requireGPU()
    let luts = try Self.luts(gpu)
    for c in Self.cases() {
      let frame = try c.picture.frame(gpu, signal: c.signal)
      for withLUTs in [false, true] {
        for stage in SignalStage.allCases {
          let lut = withLUTs ? luts : nil
          let single = Self.single(frame, stage)
          let label = "\(c.name), \(stage)\(withLUTs ? ", LUTs" : "")"
          var tools: [(String, (inout MonitorState) -> Void)] = [
            ("zebras", {
              $0.zebras[0] = ZebraSet(mode: .lowerLimit, level: 60, stage: stage)
              $0.zebras[1] = ZebraSet(mode: .band, level: 30, range: 8, stage: stage)
            }),
            ("clip", {
              $0.clipIndicators.enabled = true
              $0.clipIndicators.stage = stage
              $0.clipIndicators.high = 90
              $0.clipIndicators.low = 8
            }),
          ]
          let falseColors: [(String, (inout MonitorState) -> Void)] = [
            ("six-band", { $0.falseColor.mode = .sixBand; $0.falseColor.stage = stage }),
            ("custom IRE", {
              $0.falseColor.mode = .custom
              $0.falseColor.customUnit = .ire
              $0.falseColor.stage = stage
              $0.falseColor.customBands = [
                FalseColorBand(lower: -10, upper: 20, color: ColorRGB(r: 0, g: 0, b: 1)),
                FalseColorBand(lower: 40, upper: 60, color: ColorRGB(r: 0, g: 1, b: 0)),
                FalseColorBand(lower: 85, upper: .infinity, color: ColorRGB(r: 1, g: 0, b: 0)),
              ]
            }),
            ("custom stops", {
              $0.falseColor.mode = .custom
              $0.falseColor.customUnit = .stops
              $0.falseColor.stage = stage
              $0.falseColor.customBands = [
                FalseColorBand(lower: -3, upper: -1, color: ColorRGB(r: 0, g: 0, b: 1)),
                FalseColorBand(lower: -0.5, upper: 0.5, color: ColorRGB(r: 0, g: 1, b: 0)),
                FalseColorBand(lower: 1.5, upper: .infinity, color: ColorRGB(r: 1, g: 0, b: 0)),
              ]
            }),
          ]
          tools += falseColors
          for (name, configure) in tools {
            // The picture on the tool's stage: the whole image is the single reading's.
            var state = MonitorState()
            state.pictureStage = stage
            configure(&state)
            if state.falseColor.mode != .off {
              let status = gpu.engine.makePass()
              _ = try gpu.render(frame, state: state, feed: feed(gpu, luts: lut), pass: status)
              XCTAssertTrue(status.status.isActive(.falseColor), "\(label) \(name)")
            }
            let got = try gpu.render(frame, state: state, feed: feed(gpu, luts: lut))
            let expected = try gpu.render(single, state: state, feed: feed(gpu, luts: lut))
            assertSamePixels(got.values, expected.values, "\(label) \(name)")
            // The picture on every other stage: the tool marks the same pixels.
            for picture in SignalStage.allCases where picture != stage {
              var mixed = state
              mixed.pictureStage = picture
              var plainState = MonitorState()
              plainState.pictureStage = picture
              let marked = try gpu.render(frame, state: mixed, feed: feed(gpu, luts: lut))
              let plain = try gpu.render(frame, state: plainState, feed: feed(gpu, luts: lut))
              if falseColors.contains(where: { $0.0 == name }) {
                // False colour replaces the picture: the same image whatever it shows.
                assertSamePixels(marked.values, expected.values, "\(label) \(name), picture \(picture)")
                continue
              }
              var plainExpected = MonitorState()
              plainExpected.pictureStage = stage
              let reference = try gpu.render(single, state: plainExpected, feed: feed(gpu, luts: lut))
              // A pixel is marked where the tool changed it. An opaque mark (the
              // clip colours) on a picture that already has its colour changes
              // nothing, so both renders showing the same mark also agree.
              var differing = 0
              for i in 0..<marked.values.count
              where (marked.values[i] != plain.values[i]) != (expected.values[i] != reference.values[i])
                && marked.values[i] != expected.values[i]
              {
                differing += 1
              }
              XCTAssertEqual(differing, 0, "\(label) \(name), picture \(picture): pixels marked differently")
            }
          }
        }
      }
    }
  }

  /// Focus analysis of the Output and Monitor stages decodes with the output
  /// reading (its mask is the single reading's, bit for bit), and a mask analysed
  /// on another reading is not taken for the stage a surface shows.
  func testFocusAnalysisReadsItsStage() throws {
    let gpu = try requireGPU()
    let luts = try Self.luts(gpu)
    for c in Self.cases(width: 96, height: 40) {
      let frame = try c.picture.frame(gpu, signal: c.signal)
      for withLUTs in [false, true] {
        for stage in SignalStage.allCases {
          var focus = FocusSettings()
          focus.enabled = true
          focus.stage = stage
          let a = feed(gpu, luts: withLUTs ? luts : nil), b = feed(gpu, luts: withLUTs ? luts : nil)
          try gpu.run { try a.analyze(frame, focus: focus, into: $0) }
          try gpu.run { try b.analyze(Self.single(frame, stage), focus: focus, into: $0) }
          XCTAssertEqual(gpu.readMask(a), gpu.readMask(b), "\(c.name) \(stage) LUTs \(withLUTs)")
        }
      }
      // No LUT: the source and an Output-stage surface read the same textures
      // differently, so a source mask does not serve the Output stage.
      let f = feed(gpu, luts: nil)
      var focus = FocusSettings()
      focus.enabled = true
      focus.stage = .source
      try gpu.run { try f.analyze(frame, focus: focus, into: $0) }
      XCTAssertTrue(f.hasFocusMask(for: frame, stage: .source, monitorLUTEnabled: true), c.name)
      XCTAssertFalse(f.hasFocusMask(for: frame, stage: .output, monitorLUTEnabled: true), c.name)
      var state = MonitorState()
      state.focus.enabled = true
      state.focus.stage = .output
      let pass = gpu.engine.makePass()
      _ = try gpu.render(frame, state: state, feed: f, pass: pass)
      XCTAssertEqual(pass.status.reason(for: .focusPeaking), .focusNotAnalyzed, c.name)
    }
  }

  /// No output reading, or one equal to the source's: the second decode is off
  /// (`outputReading.w == 0`) and every tool draws exactly what it drew before.
  func testAReadingEqualToTheSourcesChangesNothing() throws {
    let gpu = try requireGPU()
    let luts = try Self.luts(gpu)
    var state = MonitorState()
    everyTool(&state)
    state.clipIndicators.enabled = true
    state.clipIndicators.stage = .monitor
    let picture = PictureTests.picture(.v210, width: 96, height: 54)
    for signal in [SignalDescription.rec709, SignalDescription(range: .full, matrix: .smpte240m)] {
      var same = signal
      same.outputReading = signal.sourceReading
      let plainPass = gpu.engine.makePass(), samePass = gpu.engine.makePass()
      let plainFeed = feed(gpu, luts: luts), sameFeed = feed(gpu, luts: luts)
      let plain = try gpu.render(
        try picture.frame(gpu, signal: signal), state: state, feed: plainFeed, pass: plainPass, analyze: true)
      let got = try gpu.render(
        try picture.frame(gpu, signal: same), state: state, feed: sameFeed, pass: samePass, analyze: true)
      XCTAssertEqual(samePass.currentParameters.outputReading, .zero)
      XCTAssertEqual(plainPass.currentParameters.outputReading, .zero)
      assertSamePixels(got.values, plain.values, "\(signal)")
    }
  }

  /// The second reading is a uniform: switching it on and off rebuilds the
  /// parameters once each and draws the right reading every time.
  func testSwitchingTheOutputReadingFollowsEachFrame() throws {
    let gpu = try requireGPU()
    let c = Self.cases()[0]
    let distinct = try c.picture.frame(gpu, signal: c.signal)
    let plain = Self.single(distinct, .source)
    var state = MonitorState()
    state.pictureStage = .output
    let pass = gpu.engine.makePass()
    for round in 0..<2 {
      let a = try gpu.render(distinct, state: state, pass: pass)
      XCTAssertEqual(pass.currentParameters.outputReading.w, 1)
      assertSamePixels(a.values, try gpu.render(Self.single(distinct, .output), state: state).values, "round \(round)")
      let b = try gpu.render(plain, state: state, pass: pass)
      XCTAssertEqual(pass.currentParameters.outputReading, .zero)
      assertSamePixels(b.values, try gpu.render(plain, state: state).values, "round \(round)")
    }
  }
}
