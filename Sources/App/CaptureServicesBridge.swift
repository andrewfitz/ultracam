import IOSurface
import Metal
import CoreMedia
import CoreVideo
import Foundation

/// Shipping forwards the ordered typed stream directly. Legacy callback
/// fan-out remains available only to injected compatibility fixtures.
struct CaptureLegacyCallbacks: @unchecked Sendable {
  #if ULTRACAM_TEST_SUPPORT
  var frame: ((CVPixelBuffer, CMTime, CMTime, Bool) -> Void)?
  var media: ((CaptureMediaStats) -> Void)?
  var audio: ((CaptureRawAudio) -> Void)?
  var event: ((String) -> Void)?
  #endif
  var typed: ((CaptureDelivery) -> Void)?
}

final class CaptureServicesBridge: @unchecked Sendable {
  typealias CPUIngest = @Sendable (CapturedCPUMemoryFrame, @escaping @Sendable (Result<CapturedPixelBuffer, Error>) -> Void) -> Void
  private let cpuIngestOverride: CPUIngest?
  typealias SessionFactory = (String) throws -> any CaptureSession
  // Serializes lifecycle operations only. Delivery callbacks may read state
  // while start publishes declarations or stop drains the delivery stream.
  private let control = NSLock()
  private let state = NSLock()
  private let makeSession: SessionFactory
  private let compatibilityPolicy: (String) -> RecordingCompatibilityPolicy
  private var copiedIngestFrames: UInt64 = 0
  private var ingestGeneration: UInt64 = 0
  private var session: (any CaptureSession)?
  private var orderedIngest: OrderedGPUIngestStage<CaptureDelivery, CaptureDelivery>?
  private var cpuIngester: CPUMemoryGPUIngest?
  private var cpuIngestActivated = false
  private var ingestTerminated = false

  init(makeSession: @escaping SessionFactory,
    compatibilityPolicy: @escaping (String) -> RecordingCompatibilityPolicy = { _ in .init() },
    cpuIngest: CPUIngest? = nil) {
    self.makeSession = makeSession; self.compatibilityPolicy = compatibilityPolicy
    self.cpuIngestOverride = cpuIngest
  }

  func start(deviceID: String, timing: CaptureTiming, callbacks: CaptureLegacyCallbacks) throws {
    try control.withLock {
      let prior = state.withLock { () -> (any CaptureSession)? in
        defer { session = nil }
        return session
      }
      prior?.stop()
      state.withLock { orderedIngest }?.cancel()
      let next = try makeSession(deviceID)
      let sessionPolicy = compatibilityPolicy(deviceID)
      let generation = state.withLock { () -> UInt64 in
        ingestGeneration &+= 1
        session = next; cpuIngestActivated = false; ingestTerminated = false; copiedIngestFrames = 0
        return ingestGeneration
      }
      do {
        let publish: @Sendable (CaptureDelivery) -> Void = { delivery in
          guard self.state.withLock({ self.ingestGeneration == generation }) else { return }
          callbacks.typed?(delivery)
          #if ULTRACAM_TEST_SUPPORT
          switch delivery.payload {
          case .frame(let buffer, let info):
            callbacks.frame?(buffer.value, info.presentationTime, info.duration, info.signalValid)
          case .cpuMemory:
            callbacks.event?("Capture error: CPU-memory frames require ordered GPU ingest")
          case .media(let info):
            let format: SourceAudioFormat?
            if case .present(let value) = info.audioDeclaration { format = value } else { format = nil }
            let tc = info.timecode.map {
              String(format: "%02d:%02d:%02d%@%02d", $0.hours, $0.minutes, $0.seconds,
                $0.dropFrame ? ";" : ":", $0.frames)
            }
            callbacks.media?(CaptureMediaStats(timecode: tc,
              audioPacketTime: info.audioPacketTime ?? .invalid,
              audioSampleFrames: UInt64(max(0, info.sampleFrameCount)), audioChannels: format?.channels ?? 0,
              leftPeak: info.peaks.first ?? 0, rightPeak: info.peaks.dropFirst().first ?? 0,
              leftRMS: info.rms.first ?? 0, rightRMS: info.rms.dropFirst().first ?? 0,
              audioBytes: UInt64(max(0, info.byteCount)), audioPresent: format != nil))
          case .rawAudio(let packet):
            // Part A's legacy raw path accepts interleaved PCM32 only. Other
            // contracts remain available intact through the typed delivery.
            guard packet.format.interleaved, packet.planes.count == 1,
              packet.format.sample == .int32 else { return }
            callbacks.audio?(CaptureRawAudio(samples: packet.planes[0], packetTime: packet.packetTime,
              sampleFrames: UInt64(packet.sampleFrameCount), channels: packet.format.channels,
              bytesPerSample: packet.format.sample.bytesPerSample))
          case .event(let event):
            if let message = Self.message(event) { callbacks.event?(message) }
          }
          #endif
        }
        let stage = OrderedGPUIngestStage<CaptureDelivery, CaptureDelivery>(capacity: 32, minimumSlots: 3, maximumBytes: 384 * 1024 * 1024,
          maximumDuration: 0.5, weight: { Self.ingestWeight($0) }, transform: { [weak self] delivery, complete in
          guard case .cpuMemory(let memory, let info) = delivery.payload else {
            complete(.success(delivery)); return
          }
          do {
            guard let self else { throw PluginError.invalidState("Capture bridge released during ingest") }
            let finish: @Sendable (Result<CapturedPixelBuffer, Error>) -> Void = { result in
              let payload: CaptureDelivery.Payload
              switch result {
              case .success(let buffer):
                Self.attachHostTime(buffer, info: info)
                payload = .frame(buffer, info)
              case .failure(let error):
                do {
                  guard self.state.withLock({ self.ingestGeneration == generation }),
                    Self.permitsCPUWrapFallback(error) else { throw error }
                  let available = MTLCreateSystemDefaultDevice()?.supportsFamily(.metal4) == true
                  let copy = try CPUCompatibilityConverter(policy: sessionPolicy).copyIngest(memory,
                    metal4Available: available, onCopied: {
                      self.state.withLock { if self.ingestGeneration == generation { self.copiedIngestFrames &+= 1 } }
                    })
                  Self.attachHostTime(copy, info: info)
                  payload = .frame(copy, info)
                } catch { payload = .event(.fatal("CPU-memory GPU ingest failed: " + String(describing: error))) }
              }
              complete(.success(CaptureDelivery(sequence: delivery.sequence, epochID: delivery.epochID,
                formatSignature: delivery.formatSignature, clockBindings: delivery.clockBindings,
                mappingRevision: delivery.mappingRevision, payload: payload)))
            }
            if let override = self.cpuIngestOverride { override(memory, finish) }
            else {
              let ingest: CPUMemoryGPUIngest
              if let existing = self.state.withLock({ self.cpuIngester }) { ingest = existing }
              else {
                let made = try CPUMemoryGPUIngest()
                self.state.withLock { self.cpuIngester = made }
                ingest = made
              }
              ingest.ingest(memory, completion: finish)
            }
          } catch {
            complete(.success(CaptureDelivery(sequence: delivery.sequence, epochID: delivery.epochID,
              formatSignature: delivery.formatSignature, clockBindings: delivery.clockBindings,
              mappingRevision: delivery.mappingRevision, payload: .event(.fatal("CPU-memory GPU ingest failed: " + String(describing: error))))))
          }
        }, emit: { result in
          switch result {
          case .success(let delivery):
            if case .event(.fatal) = delivery.payload {
              let current = self.state.withLock { () -> OrderedGPUIngestStage<CaptureDelivery, CaptureDelivery>? in
                guard self.ingestGeneration == generation else { return nil }
                self.ingestTerminated = true
                return self.orderedIngest
              }
              current?.cancel()
            }
            publish(delivery)
          case .failure(let error):
            // The bridge cannot fabricate a contract envelope for an error.
            // Publish a fatal against the rejected envelope via the enqueue path.
            _ = error
          }
        })
        state.withLock { orderedIngest = stage }
        try next.start(deviceID: deviceID, timing: timing, handlers: CaptureHandlers { delivery in
          guard self.state.withLock({ self.ingestGeneration == generation && !self.ingestTerminated }) else { return }
          if case .cpuMemory(_, let info) = delivery.payload {
            do { try info.validate() }
            catch {
              self.state.withLock { self.ingestTerminated = true }
              stage.terminate(with: CaptureDelivery(sequence: delivery.sequence, epochID: delivery.epochID,
                formatSignature: delivery.formatSignature, clockBindings: delivery.clockBindings,
                mappingRevision: delivery.mappingRevision, payload: .event(.fatal("Invalid CPU-memory frame timing: " + String(describing: error)))))
              return
            }
          }
          let ordered = self.state.withLock { () -> Bool in
            if case .cpuMemory = delivery.payload { self.cpuIngestActivated = true }
            return self.cpuIngestActivated
          }
          if !ordered { publish(delivery); return }
          if !stage.enqueue(delivery) {
            self.state.withLock { self.ingestTerminated = true }
            stage.terminate(with: CaptureDelivery(sequence: delivery.sequence, epochID: delivery.epochID,
              formatSignature: delivery.formatSignature, clockBindings: delivery.clockBindings,
              mappingRevision: delivery.mappingRevision, payload: .event(.fatal("Capture ingest queue is full"))))
          }
        })
      } catch {
        let failed = state.withLock { () -> OrderedGPUIngestStage<CaptureDelivery, CaptureDelivery>? in
          ingestGeneration &+= 1
          session = nil; ingestTerminated = true
          defer { orderedIngest = nil }
          return orderedIngest
        }
        failed?.cancel()
        next.stop()
        throw error
      }
    }
  }

  private static func attachHostTime(_ buffer: CapturedPixelBuffer, info: CaptureFrameInfo) {
    guard let host = info.captureHostTime, host.isNumeric, host.epoch == 0,
      host.seconds.isFinite, host.seconds > 0 else { return }
    CVBufferSetAttachment(buffer.value, DeviceAPI.captureHostTimeAttachmentKey as CFString,
      NSNumber(value: host.seconds), .shouldPropagate)
  }

  private static func permitsCPUWrapFallback(_ error: Error) -> Bool {
    if let value = error as? NoCopyIngestError { return value == .splitVMRegion || value == .roundedRangeOutsideAllocation }
    let value = error as NSError
    return value.domain == "Ultracam.CPUMemoryIngest" && value.localizedDescription.contains("unwrappable SDK allocation")
  }

  private static func ingestWeight(_ delivery: CaptureDelivery) -> OrderedGPUIngestStage<CaptureDelivery, CaptureDelivery>.Weight {
    switch delivery.payload {
    case .cpuMemory(let memory, let info):
      return .init(bytes: memory.allocation.length, duration: info.duration.seconds)
    case .frame(let buffer, let info):
      let image = buffer.value
      let count = CVPixelBufferGetPlaneCount(image)
      let planes: [MediaStorageExtent.Plane] = count == 0
        ? [.init(rowBytes: CVPixelBufferGetBytesPerRow(image), rows: CVPixelBufferGetHeight(image))]
        : (0..<count).map { .init(rowBytes: CVPixelBufferGetBytesPerRowOfPlane(image, $0), rows: CVPixelBufferGetHeightOfPlane(image, $0)) }
      let surface = CVPixelBufferGetIOSurface(image).map { IOSurfaceGetAllocSize($0.takeUnretainedValue()) }
      let bytes = (try? MediaStorageExtent.allocationBytes(planes: planes,
        pixelBufferDataSize: CVPixelBufferGetDataSize(image), ioSurfaceAllocationSize: surface)) ?? Int.max
      return .init(bytes: bytes, duration: info.duration.seconds)
    case .rawAudio(let packet):
      var bytes = 0
      for plane in packet.planes {
        let sum = bytes.addingReportingOverflow(plane.count)
        if sum.overflow { return .init(bytes: Int.max, duration: .infinity) }
        bytes = sum.partialValue
      }
      return .init(bytes: bytes, duration: Double(packet.sampleFrameCount) / packet.format.sampleRate)
    case .event, .media: return .init(bytes: 0, duration: 0)
    }
  }

  var ingestCPUCopyFrames: UInt64 { state.withLock { copiedIngestFrames } }

  func stop() {
    control.withLock {
      let prior = state.withLock { session }
      // The SDK barrier drains already accepted native deliveries. Keep this
      // attempt's generation and counters live until that barrier completes.
      prior?.stop()
      let pending = state.withLock { () -> OrderedGPUIngestStage<CaptureDelivery, CaptureDelivery>? in
        ingestGeneration &+= 1
        session = nil
        defer { orderedIngest = nil }
        return orderedIngest
      }
      // GPU work can outlive the SDK barrier. Cancel publication synchronously
      // before returning, while its completion retains committed resources.
      pending?.cancel()
    }
  }
  var deviceDroppedFrames: UInt64 {
    let current = state.withLock { session }
    return current?.counters.deviceDroppedFrames ?? 0
  }

  #if ULTRACAM_TEST_SUPPORT
  static func message(_ event: CaptureEvent) -> String? {
    switch event {
    case .formatChanged, .audioFormatChanged, .clockMappingChanged: nil
    case .discontinuity: "Source clock restarted"
    case .waitingForSignal: "Waiting for signal…"
    case .signalLost(let reason): "No video signal: \(reason)"
    case .unsupportedInput(let reason): "Unsupported input: \(reason)"
    case .fatal(let reason): "Capture error: \(reason)"
    case .info(let message): message
    }
  }
  #endif
}

extension CaptureServices {
  /// Builds one typed source start over a per-feed session owner, plus
  /// compatibility entry points in tests. Resolution remains inside `start`,
  /// so changing the source vendor keeps the same services.
  static func registryBridge(feedID: FeedID,
    compatibilityPolicy: @escaping (String) -> RecordingCompatibilityPolicy = { _ in .init() }, makeSession: @escaping CaptureServicesBridge.SessionFactory) -> CaptureServices {
    let bridge = CaptureServicesBridge(makeSession: makeSession, compatibilityPolicy: compatibilityPolicy)
    let sink = CameraSink(feedID: feedID)
    #if ULTRACAM_TEST_SUPPORT
    func timing(_ fast: Bool) throws -> CaptureTiming {
      .fixed(try SourceFormat(width: 3840, height: 2160, pixel: .v210,
        rate: .constant(fast ? VideoContract.fastDuration : VideoContract.slowDuration)))
    }
    var services = CaptureServices(start: { id, fast, frame, event in
      try bridge.start(deviceID: id, timing: timing(fast), callbacks: CaptureLegacyCallbacks(
        frame: { image, pts, _, valid in frame(image, pts, valid) }, event: event))
    }, stop: { bridge.stop() },
      connect: { try sink.connect(configuration: $0, passthroughFormat: $1) },
      disconnect: { sink.disconnect() }, send: { try sink.send($0) })
    services.startWithMedia = { id, fast, frame, media, event in
      try bridge.start(deviceID: id, timing: timing(fast), callbacks: CaptureLegacyCallbacks(
        frame: { image, pts, _, valid in frame(image, pts, valid) }, media: media, event: event))
    }
    services.startWithRawAudio = { id, fast, frame, audio, event in
      try bridge.start(deviceID: id, timing: timing(fast), callbacks: CaptureLegacyCallbacks(
        frame: { image, pts, _, valid in frame(image, pts, valid) }, audio: audio, event: event))
    }
    services.startWithSourceAudio = { id, fast, frame, media, audio, event in
      try bridge.start(deviceID: id, timing: timing(fast), callbacks: CaptureLegacyCallbacks(
        frame: { image, pts, _, valid in frame(image, pts, valid) }, media: media, audio: audio, event: event))
    }
    services.startAutomatic = { id, frame, event in
      try bridge.start(deviceID: id, timing: .automatic, callbacks: CaptureLegacyCallbacks(frame: frame, event: event))
    }
    services.startAutomaticWithMedia = { id, frame, media, event in
      try bridge.start(deviceID: id, timing: .automatic, callbacks: CaptureLegacyCallbacks(frame: frame, media: media, event: event))
    }
    services.startAutomaticWithRawAudio = { id, frame, audio, event in
      try bridge.start(deviceID: id, timing: .automatic, callbacks: CaptureLegacyCallbacks(frame: frame, audio: audio, event: event))
    }
    services.startAutomaticWithSourceAudio = { id, frame, media, audio, event in
      try bridge.start(deviceID: id, timing: .automatic, callbacks: CaptureLegacyCallbacks(frame: frame, media: media, audio: audio, event: event))
    }
    #else
    var services = CaptureServices(startTyped: { id, timing, handlers in
      try bridge.start(deviceID: id, timing: timing, callbacks: CaptureLegacyCallbacks(typed: handlers.deliver))
    }, stop: { bridge.stop() }, connect: { try sink.connect(configuration: $0, passthroughFormat: $1) },
      disconnect: { sink.disconnect() }, send: { try sink.send($0) })
    #endif
    services.startTyped = { id, timing, handlers in
      try bridge.start(deviceID: id, timing: timing, callbacks: CaptureLegacyCallbacks(typed: handlers.deliver))
    }
    services.connectWithSource = { configuration, type, source in
      try sink.connect(configuration: configuration, passthroughFormat: type, sourceFormat: source)
    }
    services.ingestCPUCopyFrames = { bridge.ingestCPUCopyFrames }
    services.deviceDroppedFrames = { bridge.deviceDroppedFrames }
    return services
  }
}

extension CaptureServices {

  static func registry(feedID: FeedID, plugins: [any CaptureSourcePlugin],
    claims: CaptureDeviceClaims = CaptureDeviceClaims(),
    compatibilityPolicy: @escaping (String) -> RecordingCompatibilityPolicy = { _ in .init() }) -> CaptureServices {
    var services = registryBridge(feedID: feedID, compatibilityPolicy: compatibilityPolicy) { deviceID in
      let prefix = try VendorRegistry.pluginID(for: deviceID)
      guard let plugin = plugins.first(where: { $0.descriptor.id == prefix }) else {
        throw PluginError.unavailable("Unknown capture plugin: \(prefix)")
      }
      guard let device = try plugin.devices().first(where: { $0.id == deviceID }) else {
        throw PluginError.unavailable("Capture device is unavailable: \(deviceID)")
      }
      return claims.makeSession(plugin: plugin, device: device, ownerID: feedID.rawValue)
    }
    services.sourcePauseAllowance = { deviceID in
      let prefix = try VendorRegistry.pluginID(for: deviceID)
      guard let plugin = plugins.first(where: { $0.descriptor.id == prefix }),
        let device = try plugin.devices().first(where: { $0.id == deviceID }), let pause = device.mayPause else { return nil }
      let value = pause.components
      return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    return services
  }

  static func registryLive(feedID: FeedID) -> CaptureServices {
    registryBridge(feedID: feedID) { _ in
      throw PluginError.unavailable("Capture requires a configured application registry")
    }
  }
}

#if ULTRACAM_TEST_SUPPORT
extension CaptureServices {
  /// A typed fixture uses the shipping-shaped initializer while old fixtures
  /// retain the synthesized closure-injection initializer during migration.
  init(startTyped: @escaping (String, CaptureTiming, CaptureHandlers) throws -> Void,
    stop: @escaping () -> Void, connect: @escaping (PipelineConfiguration, OSType) throws -> Void,
    disconnect: @escaping () -> Void, send: @escaping (CMSampleBuffer) throws -> Bool,
    preview: ((CMSampleBuffer) -> Void)? = nil) {
    self.init(start: { _, _, _, _ in throw PluginError.invalidState("Typed fixture has no legacy start") },
      stop: stop, connect: connect, disconnect: disconnect, send: send, preview: preview)
    self.startTyped = startTyped
  }
}
#endif
