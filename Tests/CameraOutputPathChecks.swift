import CoreMedia
import CoreVideo
import Foundation
import XCTest

// A 2160p59.94 v210 source through the real capture controller, LUT and
// sample factory, checked by the app sink's own contract check
// (`CameraSink.mismatch`), staged like a real send, then admitted by the
// camera extension's own runtime as the authorized producer. No CMIO, no
// installed extension, no hardware.
@objcMembers final class CameraOutputPathChecks: XCTestCase {
  private final class Path: @unchecked Sendable {
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var duration: CMTime?
    private var handler: ((CVPixelBuffer, CMTime, CMTime, Bool) -> Void)?
    private(set) var connects = 0
    private(set) var refusals: [String] = []
    private(set) var accepted = 0
    private(set) var forwarded = 0
    private var stager = CameraFrameStager()
    let runtime: CameraDeviceRuntime

    init() {
      runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false,
        output: { _, _, _ in }, descriptor: .feed(feedID: "camera-output-path"))
      runtime.queue.sync { runtime.consumers = 1 }
    }

    var counts: (accepted: Int, forwarded: Int, refusals: [String], connects: Int) {
      lock.withLock { (accepted, forwarded, refusals, connects) }
    }

    /// The driver has started: it delivers frames from here on, as a real one does.
    var driverStarted: Bool { lock.withLock { handler != nil } }

    /// Delivers one frame; false when the driver isn't started (a frame no
    /// real driver could deliver).
    @discardableResult
    func emit(_ image: CVPixelBuffer, at time: CMTime, duration: CMTime) -> Bool {
      guard let handler = lock.withLock({ self.handler }) else { return false }
      handler(image, time, duration, true)
      return true
    }

    func services() -> CaptureServices {
      var services = CaptureServices(
        start: { _, _, _, _ in }, stop: {},
        connect: { configuration, passthrough in
          // Exercise production negotiation, including the GPU encoder's
          // centered chroma, instead of constructing a legacy colour identity.
          let format = try CameraSink.requestedFormat(configuration: configuration,
            passthroughFormat: passthrough, sourceFormat: nil)
          self.lock.withLock {
            self.format = format
            self.duration = configuration.duration
            self.connects += 1
          }
        },
        disconnect: {},
        send: { sample in
          let (format, duration) = self.lock.withLock { (self.format, self.duration) }
          guard let format, let duration else { throw VideoError.message("Not connected") }
          if let mismatch = CameraSink.mismatch(sample, format: format, duration: duration) {
            self.lock.withLock { self.refusals.append("app: \(mismatch)") }
            throw VideoError.message(mismatch)
          }
          let staged = try self.lock.withLock { try self.stager.stage(sample) }
          let admitted = self.runtime.queue.sync {
            self.runtime.receive(staged, discontinuity: [], producerCanNegotiate: true)
          }
          self.lock.withLock {
            self.accepted += 1
            if admitted { self.forwarded += 1 } else { self.refusals.append("extension refused a frame") }
          }
          return true
        })
      services.startAutomatic = { _, frames, _ in self.lock.withLock { self.handler = frames } }
      services.capturePixelFormat = kCVPixelFormatType_422YpCbCr10
      return services
    }
  }

  private func v210Source() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
    XCTAssertEqual(status, kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return image
  }

  private func run(_ configuration: PipelineConfiguration, frames: Int, expected: Int, label: String) throws {
    let path = Path()
    let controller = CaptureController(services: path.services())
    defer { controller.stop() }
    let loaded = expectation(description: "LUT loaded")
    controller.load(try CubeLUT(text: cubeText(size: 17, transform: { $0 * $0 }))) { result in
      if case .failure(let error) = result { XCTFail("LUT load: \(error)") }
      loaded.fulfill()
    }
    wait(for: [loaded], timeout: 10)
    controller.start(feedID: FeedID(rawValue: "camera-output-path"), deviceID: "synthetic",
      configuration: configuration, pipelineEnabled: true, previewEnabled: false)
    // Frames flow once the driver is started, after the controller has warmed
    // up and connected the camera. The burn-in decision is published earlier.
    let deadline = Date().addingTimeInterval(10)
    while !(controller.burnInLUT != nil && path.driverStarted) && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertNotNil(controller.burnInLUT, "\(label): the LUT is burned in")
    XCTAssertTrue(path.driverStarted, "\(label): the driver starts")
    let source = try v210Source()
    for index in 0..<frames {
      XCTAssertTrue(path.emit(source, at: CMTimeMultiply(VideoContract.fastDuration, multiplier: Int32(index + 1)),
        duration: VideoContract.fastDuration), "\(label): frame \(index) delivered by the driver")
      // The driver's cadence, compressed: the pipeline never sees a burst.
      Thread.sleep(forTimeInterval: 0.004)
    }
    let settle = Date().addingTimeInterval(10)
    while path.counts.accepted < expected && path.counts.refusals.isEmpty && Date() < settle {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let counts = path.counts
    XCTAssertEqual(counts.refusals, [], "\(label): nothing refused on the way to the camera")
    XCTAssertEqual(counts.accepted, expected, "\(label): every output frame reaches the camera queue")
    XCTAssertEqual(counts.forwarded, expected, "\(label): the extension forwards every frame")
    XCTAssertLessThanOrEqual(counts.connects, 2, "\(label): one warm connect, at most one more for the detected rate")
  }

  /// 2160p, 10-bit 4:2:2, every frame, LUT and processing on.
  func testFull2160pOutputWithLUTReachesTheCamera() throws {
    var configuration = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false,
      reduceFrameRate: false)
    configuration.sourceDuration = VideoContract.fastDuration
    configuration.lutOutputColorimetry = .rec709Video
    try run(configuration, frames: 24, expected: 24, label: "2160p59.94 4:2:2 LUT")
  }

  /// 1080p 4:2:0 at 29.97 from 59.94, LUT and processing on.
  func testReduced1080pOutputWithLUTReachesTheCamera() throws {
    var configuration = PipelineConfiguration(applyLUT: true, downscale: true, convertTo420: true,
      reduceFrameRate: true)
    configuration.sourceDuration = VideoContract.fastDuration
    configuration.lutOutputColorimetry = .rec709Video
    try run(configuration, frames: 24, expected: 12, label: "1080p29.97 4:2:0 LUT")
  }

}
