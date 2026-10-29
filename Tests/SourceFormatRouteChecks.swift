import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import XCTest

/// Actual source storage -> declared-source GPU encoder -> published camera contract.
@objcMembers final class SourceFormatRouteChecks: XCTestCase {
  func testEveryNewSourceReachesAnExactPublishedProcessedCameraFormat() throws {
    let catalog = try OutputFormatCatalog.descriptions()
    for pixel in [PixelFormatID.twoVuy, .yuvs, .video420, .full420, .bgra8, .r210, .r12L, .uyva, .p216, .i420, .pa16] {
      for size in [ResizeTarget.hd720, .hd1080] {
        do {
          let fixture = try SourceRouteFixture(pixel: pixel)
          let processor = try LUTProcessor()
          defer { processor.releaseIdleResources() }
          try processor.load(CubeLUT(text: cubeText(size: 17, transform: { $0 * $0 })),
            colorSpace: LUTColorSpaceContract(input: fixture.format.colour, output: .rec709Video))
          var configuration = PipelineConfiguration(applyLUT: true, downscale: true)
          configuration.resizeTarget = size
          configuration.sourceWidth = fixture.format.width
          configuration.sourceHeight = fixture.format.height
          configuration.sourceDuration = VideoContract.fastDuration
          configuration.lutOutputColorimetry = .rec709Video
          let snapshot = try SourceAdmissionSnapshot(format: fixture.format,
            epochID: CaptureEpochID(sessionID: UUID(), epoch: 0),
            clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .lut)
          let metadata = SourceAdmissionMetadata(pixelBuffer: fixture.image, presentationTime: .zero,
            duration: VideoContract.fastDuration, epochID: snapshot.epochID, formatSignature: snapshot.formatSignature)
          let completed = expectation(description: "production GPU completion")
          let result = Mutex<Result<CVPixelBuffer, Error>?>(nil)
          try processor.submit(fixture.image, configuration: configuration, source: snapshot, metadata: metadata) { completion in
            result.withLock { $0 = completion.result }; completed.fulfill()
          }
          wait(for: [completed], timeout: 10)
          let output = try XCTUnwrap(result.withLock { $0 }).get()
          XCTAssertFalse(output === fixture.image)
          XCTAssertEqual(CVPixelBufferGetWidth(output), size.width)
          XCTAssertEqual(CVPixelBufferGetHeight(output), size.height)
          let sample = try VideoContract.sample(output, at: .zero, duration: configuration.duration)
          let requested = try CameraSink.requestedFormat(configuration: configuration,
            passthroughFormat: pixel.rawValue, sourceFormat: fixture.format)
          XCTAssertNil(CameraSink.mismatch(sample, format: requested, duration: configuration.duration))
          let derived = DerivedOutputContract(format: requested, duration: configuration.duration)
          let index = try XCTUnwrap(derived.matchingPublishedIndex(in: catalog))
          XCTAssertTrue(OutputFormatCatalog.matches(sample, description: catalog[index]))
          XCTAssertNil(derived.mismatch(sample))
          // Read only the finished result: a nonlinear LUT turns 50% gray into 25%.
          CVPixelBufferLockBaseAddress(output, .readOnly)
          defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
          let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt8.self)
          let middle = size.height / 2 * CVPixelBufferGetBytesPerRowOfPlane(output, 0) + size.width / 2
          XCTAssertEqual(Int(y[middle]), 71, accuracy: 2, "Source pixels must actually decode and pass through the LUT")
        }
      }
    }
  }
}
