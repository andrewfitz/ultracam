import CoreVideo
import Foundation
import XCTest

@objcMembers final class LUTBoundaryAuditChecks: XCTestCase {
  private func packed(_ type: OSType, width: Int, fullRamp: Bool = false, edge: Bool = false) throws -> CVPixelBuffer {
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, 64, type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &made), kCVReturnSuccess)
    let image = try XCTUnwrap(made)
    CVPixelBufferLockBaseAddress(image, []); defer { CVPixelBufferUnlockBaseAddress(image, []) }
    let stride = CVPixelBufferGetBytesPerRow(image)
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(image))
    func y(_ x: Int) -> UInt32 { fullRamp ? (x < width / 2 ? 0 : 1023) : (x == width - 1 ? 940 : 504) }
    func cb(_ pair: Int) -> UInt32 { edge ? (pair < 32 ? 512 : 800) : (pair == (width + 1) / 2 - 1 ? 256 : 512) }
    for row in 0..<64 {
      if type == kCVPixelFormatType_422YpCbCr10 {
        let p = base.advanced(by: row * stride).assumingMemoryBound(to: UInt32.self)
        for group in 0..<((width + 5) / 6) {
          let x = group * 6, pair = group * 3
          p[group*4] = cb(pair) | (y(x)<<10) | (512<<20)
          p[group*4+1] = y(x+1) | (cb(pair+1)<<10) | (y(x+2)<<20)
          p[group*4+2] = 512 | (y(x+3)<<10) | (cb(pair+2)<<20)
          p[group*4+3] = y(x+4) | (512<<10) | (y(x+5)<<20)
        }
      } else {
        let p = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
        for pair in 0..<((width + 1) / 2) {
          let x = pair*2, c = UInt8(cb(pair)/4), a = UInt8(y(x)/4), b = UInt8(y(x+1)/4)
          let values: [UInt8] = type == kCVPixelFormatType_422YpCbCr8 ? [c,a,128,b] : [a,c,b,128]
          for lane in 0..<4 { p[pair*4+lane] = values[lane] }
        }
      }
    }
    return image
  }

  private func code(_ image: CVPixelBuffer, plane: Int, x: Int, row: Int = 32) throws -> Int {
    CVPixelBufferLockBaseAddress(image, .readOnly); defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let p = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, plane)).assumingMemoryBound(to: UInt8.self)
    return Int(p[row * CVPixelBufferGetBytesPerRowOfPlane(image, plane) + x])
  }

  func testOddPackedFinalLumaAndChromaGroupsSurviveResizing() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal") }
    for type in [kCVPixelFormatType_422YpCbCr10, kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs] {
      for width in [1, 129] {
        let processor = try LUTProcessor()
        var config = PipelineConfiguration(downscale: true)
        config.resizeTarget = .source; config.sourceWidth = width; config.sourceHeight = 64
        let output = try processor.process(packed(type, width: width), configuration: config)
        let ow = CVPixelBufferGetWidth(output), oh = CVPixelBufferGetHeight(output)
        let plan = try ProgramScalingPolicy.plan(sourceWidth: width, sourceHeight: 64, targetWidth: ow, targetHeight: oh)
        let right = min(ow-1, plan.offsetX + plan.scaledWidth - 1)
        func horizontal(_ ox: Int, chroma: Bool) -> Double {
          guard ox >= plan.offsetX, ox < plan.offsetX + plan.scaledWidth else { return 0 }
          let scale = Double(width) / Double(plan.scaledWidth), radiusScale = max(scale, 1)
          let center = (Double(ox-plan.offsetX)+0.5)*scale-0.5
          var sum = 0.0, total = 0.0
          for tap in Int(ceil(center-3*radiusScale))...Int(floor(center+3*radiusScale)) {
            let t = abs((Double(tap)-center)/radiusScale)
            let w = t < 0.00001 ? 1 : (t >= 3 ? 0 : sin(.pi*t)*sin(.pi*t/3)/(.pi * .pi * t*t/3))
            let x = min(width-1,max(0,tap))
            let value: Double
            if chroma {
              let pair = x/2, fraction = Double(x%2)/2
              func component(_ p: Int) -> Double { min((width+1)/2-1,p) == (width+1)/2-1 ? 64 : 128 }
              value = (component(pair)*(1-fraction)+component(pair+1)*fraction-128)/224
            } else { value = Double((x == width-1 ? 235 : 126)-16)/219 }
            sum += value*w; total += w
          }
          return sum/total
        }
        let expectedY = min(255,max(0,Int((16+219*horizontal(right,chroma:false)).rounded())))
        let pairX = right-right%2
        let expectedCb = min(255,max(0,Int((128+224*(horizontal(pairX,chroma:true)+horizontal(pairX+1,chroma:true))/2).rounded())))
        XCTAssertEqual(try code(output, plane: 0, x: right, row: oh/2), expectedY, accuracy: 1, "Final luma \(type),\(width)")
        XCTAssertEqual(try code(output, plane: 1, x: pairX, row: oh/4), expectedCb, accuracy: 1, "Final partial pair chroma \(type),\(width)")
      }
    }
  }

  func testV210DeclaredFullRangeAndCenteredSitingOverrideMissingAttachments() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal") }
    let processor = try LUTProcessor()
    var config = PipelineConfiguration(downscale: false)
    let fullDeclaration = Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709,
      range: .full, horizontalChromaSiting: .center, verticalChromaSiting: .center)
    let full = try processor.process(packed(kCVPixelFormatType_422YpCbCr10, width: 128, fullRamp: true),
      configuration: config, declaredSourceColorimetry: fullDeclaration)
    XCTAssertEqual(try code(full, plane: 0, x: 0), 16, accuracy: 1)
    XCTAssertEqual(try code(full, plane: 0, x: 127), 235, accuracy: 1)
    let source = try packed(kCVPixelFormatType_422YpCbCr10, width: 128, edge: true)
    config.sourceColorimetryOverride = Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709,
      range: .video, horizontalChromaSiting: .center, verticalChromaSiting: .center)
    let declaration = try XCTUnwrap(config.sourceColorimetryOverride)
    let format = try SourceFormat(width: 128, height: 64, pixel: .v210, colour: declaration,
      rate: .constant(VideoContract.fastDuration))
    let admission = try SourceAdmissionSnapshot(format: format,
      epochID: CaptureEpochID(sessionID: UUID(), epoch: 1),
      clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .lut)
    let metadata = SourceAdmissionMetadata(pixelBuffer: source, presentationTime: .zero,
      duration: VideoContract.fastDuration, epochID: admission.epochID, formatSignature: admission.formatSignature)
    final class Box: @unchecked Sendable {
      let lock = NSLock(); var result: Result<CVPixelBuffer, Error>?
      func set(_ result: Result<CVPixelBuffer, Error>) { lock.withLock { self.result = result } }
      func get() -> Result<CVPixelBuffer, Error>? { lock.withLock { result } }
    }
    let box = Box(), done = DispatchSemaphore(value: 0)
    config.sourceColorimetryOverride = nil
    try processor.submit(source, configuration: config, source: admission, metadata: metadata) {
      box.set($0.result); done.signal()
    }
    XCTAssertEqual(done.wait(timeout: .now()+5), .success)
    let declared = try XCTUnwrap(box.get()).get()
    CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
    config.sourceColorimetryOverride = nil
    let attached = try processor.process(source, configuration: config)
    XCTAssertEqual(try code(declared, plane: 1, x: 62, row: 16), try code(attached, plane: 1, x: 62, row: 16), accuracy: 1)
  }

  func testNoLUTColorConversionDropsSourceHDRMasteringMetadata() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal") }
    let source = try packed(kCVPixelFormatType_422YpCbCr10, width: 128)
    let from = Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020,
      range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
    CVBufferSetAttachment(source, kCVImageBufferMasteringDisplayColorVolumeKey, Data([1,2,3]) as CFData, .shouldPropagate)
    CVBufferSetAttachment(source, kCVImageBufferContentLightLevelInfoKey, Data([4,5]) as CFData, .shouldPropagate)
    let config = PipelineConfiguration(downscale: false)
    let output = try LUTProcessor().process(source, configuration: config,
      colorConversion: .sourceToLUTInput(from: from, to: .rec709Video), destinationColorimetry: .rec709Video,
      declaredSourceColorimetry: from)
    XCTAssertNil(CVBufferCopyAttachment(output, kCVImageBufferMasteringDisplayColorVolumeKey, nil))
    XCTAssertNil(CVBufferCopyAttachment(output, kCVImageBufferContentLightLevelInfoKey, nil))
    XCTAssertEqual(try LUTProcessor.sourceColorimetry(output).transfer, .rec709)
  }
}
