import CoreVideo
@preconcurrency import Metal
import MonitorToolsCore
import XCTest
@testable import MonitorToolsMetal

final class MonitorQualityTests: XCTestCase {
  func testShaderCompilesAndExplicitParameterLayoutMatches() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    XCTAssertEqual(MemoryLayout<KernelParameters>.stride, 160)
    XCTAssertEqual(MemoryLayout<KernelParameters>.offset(of: \.aperture), 144)
    XCTAssertEqual(MemoryLayout<KernelParameters>.offset(of: \.scopeWidth), 64)
    XCTAssertEqual(MemoryLayout<KernelParameters>.offset(of: \.referenceOffsetStops), 80)
    XCTAssertEqual(MemoryLayout<KernelParameters>.offset(of: \.coefficients), 96)
    XCTAssertEqual(MemoryLayout<KernelParameters>.offset(of: \.mapping), 112)
    XCTAssertEqual(MemoryLayout<KernelParameters>.offset(of: \.peak), 128)
    _ = try device.makeLibrary(source: shaderText(), options: nil)
  }

  private func shaderText() throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("Sources/MonitorToolsMetal/Resources/MonitorTools.metal.txt"), encoding: .utf8)
  }

  func testSonyEveryNativeCodeUsesPublishedPattern2AcrossTransport() throws {
    let runtime = try metalRuntime()
    for mapping in [MonitorSourceLogMapping.native10Bit, .fullRescaledToLegal10Bit] {
      for start in stride(from: 0, through: 1023, by: 256) {
        let codes = Array(start..<(start + 256))
        let transported = codes.map { mapping == .native10Bit ? $0 : Int((64 + Double($0) * 876 / 1023).rounded()) }
        var config = MonitorConfiguration()
        config.toolsEnabled = true; config.pictureStage = .source
        config.sourceProfileID = "sony-slog3-sgamut3cine"
        config.sourceLogMapping = mapping
        config.falseColor.mode = .sonySLog3
        config.falseColor.profileID = SonySLog3FalseColor.profileID
        config.falseColor.specificationVersion = SonySLog3FalseColor.specificationVersion
        config.falseColor.exposureIndex = 1250
        let result = try render(runtime, source: packed(codes: transported), config: config,
          range: .legal, sourceProfile: config.sourceProfileID!)
        let bytes = try pixels(result)
        for (index, code) in transported.enumerated() {
          let native = mapping == .native10Bit ? Double(code) / 1023 : Double(code - 64) / 876
          let rgb = try XCTUnwrap(SonySLog3FalseColor.color(nativeSignalLuma: native))
          assertPixel(bytes, at: index * 6, rgb: [rgb.r, rgb.g, rgb.b].map { Int(($0 * 255).rounded()) }, message: "mapping \(mapping), code \(code)")
        }
      }
    }
  }

  func testSonySignalIREUsesDeclaredMatrixForColoredSource() throws {
    let runtime=try metalRuntime()
    var config=MonitorConfiguration();config.toolsEnabled=true;config.pictureStage = .source
    config.sourceProfileID="sony-slog3-sgamut3cine";config.falseColor.mode = .sonySLog3
    config.falseColor.profileID=SonySLog3FalseColor.profileID
    for matrix in [MonitorYCbCrMatrix.bt709,.bt2020] {
      let display=try render(runtime,source:bgra(r:204,g:76,b:51),config:config,range:.full,
        sourceProfile:config.sourceProfileID!,matrix:matrix)
      let expected=try XCTUnwrap(SonySLog3FalseColor.color(rgb:.init(r:204.0/255,g:76.0/255,b:51.0/255),matrix:matrix))
      assertPixel(try pixels(display),at:0,rgb:[expected.r,expected.g,expected.b].map { Int(($0*255).rounded()) })
    }
  }

  func testPreviewMinificationAveragesCheckerboardAtTwoAndFourToOne() throws {
    for ratio in [2, 4] {
      let source = try image(width: 192, height: 1080 * ratio) { x, y in (x + y) % 2 == 0 ? 0 : 255 }
      var config = MonitorConfiguration(); config.toolsEnabled = true
      config.zebra.enabled = true; config.zebra.thresholdIRE = 110
      let display = try render(metalRuntime(), source: source, config: config, range: .full, sourceProfile: "rec709", transfer: "rec709")
      let bytes = try pixels(display)
      XCTAssertEqual(display.height, 1080)
      for x in 2..<(192 / ratio - 2) {
        XCTAssertEqual(Int(bytes[x * 4]), 128, accuracy: 1, "Area minification must reject checkerboard aliasing at \(ratio):1")
      }
    }
  }

  func testFocusRejectsIsolatedImpulseButPreservesSupportedEdge() throws {
    let source = try image(width: 48, height: 32) { x, y in
      if x == 8 && y == 8 { return 255 }
      return x >= 32 ? 240 : 100
    }
    var config = MonitorConfiguration(); config.toolsEnabled = true
    config.focus.enabled = true; config.focus.color = .red; config.focus.opacity = 1
    let display = try render(metalRuntime(), source: source, config: config, range: .full, sourceProfile: "rec709", transfer: "rec709")
    let base = display.pictureBytes
    let stride = display.width * 4
    for y in 6...10 { for x in 6...10 {
      let p = y * stride + x * 4
      XCTAssertEqual(base[p], base[p + 2], "A single impulse has no directional edge support")
    }}
    XCTAssertEqual(base[16 * stride + 31 * 4 + 2], 255)
    XCTAssertEqual(base[16 * stride + 31 * 4], 0)
  }

  func testScharrConfidenceMatchesIndependentCPUOracleOnSlantedEdgeAndNoise() throws {
    let w = 48, h = 32
    func value(_ x: Int, _ y: Int) -> UInt8 {
      UInt8(x >= 20 + y / 4 ? 155 : 100 + (x * 7 + y * 3) % 5)
    }
    let source = try image(width: w, height: h, value: value)
    var config = MonitorConfiguration(); config.toolsEnabled = true
    config.focus.enabled = true; config.focus.opacity = 1
    let display = try render(metalRuntime(), source: source, config: config, range: .full,
      sourceProfile: "rec709", transfer: "rec709")
    let base = display.pictureBytes
    let stride = display.width * 4
    func v(_ x: Int, _ y: Int) -> Double { Double(value(max(0,min(w-1,x)),max(0,min(h-1,y)))) / 255 }
    func median(_ a: Double, _ b: Double, _ c: Double) -> Double { [a,b,c].sorted()[1] }
    for y in 0..<h { for x in 0..<w {
      let dx = (-1...1).map { v(x+1,y+$0)-v(x-1,y+$0) }
      let dy = (-1...1).map { v(x+$0,y+1)-v(x+$0,y-1) }
      let gx = (3*dx[0]+10*dx[1]+3*dx[2])/16
      let gy = (3*dy[0]+10*dy[1]+3*dy[2])/16
      let support = max(abs(median(dx[0],dx[1],dx[2])),abs(median(dy[0],dy[1],dy[2])))
      let confidence = support > 0.02 ? max(0,min(1,(max(abs(gx),abs(gy))-0.17)/0.085)) : 0
      let quantized = (confidence * 255).rounded() / 255
      let expectedGreen = Int((Double(value(x,y)) * (1-quantized)).rounded())
      XCTAssertEqual(Int(base[y * stride+x*4+1]), expectedGreen, accuracy: 1, "Scharr confidence at \(x),\(y)")
    }}
  }

  func testThinSourceFocusSurvivesTwoToOnePreviewMinification() throws {
    let source = try image(width:192,height:2160) { x, _ in x == 48 ? 255 : 100 }
    var config = MonitorConfiguration(); config.toolsEnabled = true
    config.focus.enabled = true; config.focus.opacity = 1
    let display = try render(metalRuntime(),source:source,config:config,range:.full,sourceProfile:"rec709",transfer:"rec709")
    let bytes = try pixels(display)
    XCTAssertEqual(bytes[24*4+2],255)
    XCTAssertEqual(bytes[24*4+1],0,"Footprint maximum retains the line's neighboring source gradient")
  }

  func testFractionalMinificationMatchesBoundedBilinearQuadratureOracle() throws {
    let width=13,height=2700
    func sample(_ x:Int,_ y:Int)->UInt8 { UInt8(20+(x*37+y*17)%200) }
    let source=try image(width:width,height:height,value:sample)
    var config=MonitorConfiguration();config.toolsEnabled=true;config.zebra.enabled=true;config.zebra.thresholdIRE=110
    let display=try render(metalRuntime(),source:source,config:config,range:.full,sourceProfile:"rec709",transfer:"rec709")
    let ow=display.width,oh=display.height
    let bytes=try pixels(display)
    let sx=Double(width)/Double(ow),sy=Double(height)/Double(oh),nx=min(8,Int(ceil(sx))),ny=min(8,Int(ceil(sy)))
    for x in 0..<ow {
      var total=0.0
      for iy in 0..<ny { for ix in 0..<nx {
        let px=max(0,min(Double(width-1),(Double(x)+(Double(ix)+0.5)/Double(nx))*sx-0.5))
        let py=max(0,min(Double(height-1),(Double(iy)+0.5)/Double(ny)*sy-0.5))
        let lx=Int(floor(px)),ly=Int(floor(py)),hx=min(width-1,lx+1),hy=min(height-1,ly+1),fx=px-Double(lx),fy=py-Double(ly)
        let top=Double(sample(lx,ly))*(1-fx)+Double(sample(hx,ly))*fx
        let bottom=Double(sample(lx,hy))*(1-fx)+Double(sample(hx,hy))*fx
        total += top*(1-fy)+bottom*fy
      }}
      XCTAssertEqual(Int(bytes[x*4]),Int((total/Double(nx*ny)).rounded()),accuracy:1)
    }
  }

  func testScopeDensityIsStableAcrossSourceWidth() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    var values = [UInt8]()
    for width in [512, 1024] {
      var config = MonitorConfiguration(); config.toolsEnabled = true
      config.scopes.enabled = true; config.scopes.graticule = false
      let result = try render(metalRuntime(), source: image(width: width, height: 8) { _, _ in 100 }, config: config,
        range: .full, sourceProfile: "rec709", transfer: "rec709")
      let bytes = try XCTUnwrap(result.scopeBytes)
      values.append(bytes[(151 * 768 + 4) * 4 + 2])
    }
    XCTAssertGreaterThan(values[0], 0)
    XCTAssertEqual(Int(values[0]), Int(values[1]), accuracy: 1, "Density must normalize source samples per raster column")
  }

  private func image(width: Int, height: Int, value: (Int, Int) -> UInt8) throws -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pb)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height { for x in 0..<width {
      let p = base + y * stride + x * 4
      p[0] = value(x,y); p[1] = value(x,y); p[2] = value(x,y); p[3] = 255
    }}
    return buffer
  }
  private func metalRuntime() throws -> MonitorRuntime {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    return MonitorRuntime()
  }

  private func render(
    _ runtime: MonitorRuntime, source: CVPixelBuffer, output: CVPixelBuffer? = nil,
    config: MonitorConfiguration, range: MonitorCodeRange, sourceProfile: String,
    transfer: String = "S-Log3", correspondence: MonitorCorrespondence? = .identity,
    matrix: MonitorYCbCrMatrix = .bt709
  ) throws -> MonitorSnapshot {
    let stamp = MonitorFrameStamp(
      target: MonitorTargetID(UUID().uuidString), generation: 1, sequence: 1, sourcePTS: 1,
      hostTime: 1, configurationRevision: 1)
    let frame = MonitorFrameBundle(
      stamp: stamp, source: source, output: output, correspondence: correspondence,
      sourceSignal: MonitorFrameSignal(
        range: range, matrix: matrix, transfer: transfer, profileID: sourceProfile),
      outputSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "Rec709"))
    return try runtime.renderSnapshot(frame, configuration: config.normalized())
  }

  private func allocate(_ format: OSType, width: Int) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      nil, width, 32, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
    guard status == kCVReturnSuccess, let result else {
      throw XCTSkip("Native Metal fixture allocation unavailable")
    }
    return result
  }

  private func packed(codes: [Int]) throws -> CVPixelBuffer {
    let buffer = try allocate(kCVPixelFormatType_422YpCbCr10, width: codes.count * 6)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
    for y in 0..<32 {
      let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(
        to: UInt32.self)
      for (index, code) in codes.enumerated() {
        let value = UInt32(code)
        row[index * 4] = 512 | (value << 10) | (512 << 20)
        row[index * 4 + 1] = value | (512 << 10) | (value << 20)
        row[index * 4 + 2] = row[index * 4]
        row[index * 4 + 3] = row[index * 4 + 1]
      }
    }
    return buffer
  }

  private func bgra(r: UInt8, g: UInt8, b: UInt8, width: Int = 6) throws -> CVPixelBuffer {
    let buffer = try allocate(kCVPixelFormatType_32BGRA, width: width)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
    for y in 0..<32 {
      let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(
        to: UInt8.self)
      for x in 0..<width {
        row[x * 4] = b
        row[x * 4 + 1] = g
        row[x * 4 + 2] = r
        row[x * 4 + 3] = 255
      }
    }
    return buffer
  }

  private func pixels(_ display: MonitorSnapshot) throws -> [UInt8] {
    XCTAssertTrue(display.availability.isEmpty, "\(display.availability)")
    return Array(display.pictureBytes.prefix(display.width * 4))
  }

  private func assertPixel(
    _ bytes: [UInt8], at x: Int, rgb: [Int], message: String = "",
    file: StaticString = #filePath, line: UInt = #line
  ) {
    for channel in 0..<3 {
      XCTAssertEqual(
        Int(bytes[x * 4 + 2 - channel]), min(255, max(0, rgb[channel])), accuracy: 1, message,
        file: file, line: line)
    }
  }
}
