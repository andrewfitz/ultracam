import CoreMedia
import CoreVideo
import Foundation

/// Consumes the bounded Program output route and forwards its image buffers to
/// the Program virtual camera. The bridge deliberately creates a sample around
/// the existing `CVPixelBuffer`; it never scales, converts, or copies pixels.
///
/// All state and sink calls are serialized. This matters because capture
/// callbacks can publish frames while a CMIO client is connecting or closing.
/// A route lease is released after `CMSampleBufferCreateReadyWithImageBuffer`
/// and the sink enqueue return, so the sample retains the pixel buffer for
/// CMIO independently of the route queue.
final class ProgramOutputBridge: @unchecked Sendable {
  struct Statistics: Equatable, Sendable {
    var delivered: UInt64 = 0
    var dropped: UInt64 = 0
    var invalid: UInt64 = 0
    var sendErrors: UInt64 = 0
  }

  typealias Connect = (PipelineConfiguration, OSType) throws -> Void
  typealias Disconnect = () -> Void
  typealias Send = (CMSampleBuffer) throws -> Bool

  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let route: FrameRoute<CVPixelBuffer>
  private let connectSink: Connect
  private let disconnectSink: Disconnect
  private let sendSink: Send
  private let sampleFactory = VideoSampleFactory()
  private var connected = false
  private var demand = false
  // Keep the most recent negotiated contract so a transient CMIO enqueue
  // failure can be recovered while the camera client is still demanding the
  // route. Without this, `connected` becomes false and every subsequent pump
  // silently returns until a new demand transition arrives.
  private var demandConfiguration: PipelineConfiguration?
  private var demandPassthroughFormat: OSType?
  private var statistics = Statistics()

  /// The production bridge uses the dedicated Program CMIO destination.
  convenience init(route: FrameRoute<CVPixelBuffer>, queueLabel: String = "org.ultracam.program-output-bridge") {
    let sink = CameraSink(program: true)
    self.init(route: route, connect: { configuration, passthroughFormat in
      try sink.connect(configuration: configuration, passthroughFormat: passthroughFormat)
    }, disconnect: { sink.disconnect() }, send: { sample in
      try sink.send(sample)
    }, queueLabel: queueLabel)
  }

  /// Injectable sink operations keep lifecycle and ownership tests independent
  /// of an installed camera extension. The production initializer above is the
  /// only path that supplies the real `CameraSink`.
  init(route: FrameRoute<CVPixelBuffer>, connect: @escaping Connect,
       disconnect: @escaping Disconnect, send: @escaping Send,
       queueLabel: String = "org.ultracam.program-output-bridge") {
    self.route = route
    connectSink = connect
    disconnectSink = disconnect
    sendSink = send
    queue = DispatchQueue(label: queueLabel, qos: .userInteractive)
    queue.setSpecific(key: queueKey, value: 1)
  }

  deinit {
    sync {
      if connected { disconnectSink() }
      connected = false
      demand = false
      drainLocked()
    }
  }

  var isDemanded: Bool { sync { demand } }
  var isConnected: Bool { sync { connected } }
  var currentStatistics: Statistics { sync { statistics } }

  /// Opens the Program sink only while there is an active CMIO consumer. A
  /// false transition closes the sink before draining queued leases.
  func setDemand(_ active: Bool, configuration: PipelineConfiguration,
                 passthroughFormat: OSType) throws {
    try sync {
      demand = active
      guard active else {
        if connected { disconnectSink() }
        connected = false
        demandConfiguration = nil
        demandPassthroughFormat = nil
        drainLocked()
        return
      }
      let contractChanged = connected && !Self.sameContract(demandConfiguration, configuration,
        demandPassthroughFormat, passthroughFormat)
      demandConfiguration = configuration
      demandPassthroughFormat = passthroughFormat
      if contractChanged {
        disconnectSink()
        connected = false
      }
      guard !connected else {
        pumpLocked()
        return
      }
      do {
        try connectSink(configuration, passthroughFormat)
      } catch {
        demand = false
        connected = false
        drainLocked()
        throw error
      }
      connected = true
      pumpLocked()
    }
  }

  /// Drains all currently queued frames. Calling this while demand is false is
  /// intentionally a no-op: frames are discarded at the route boundary and no
  /// hardware or GPU work is started in the background.
  func pump() {
    sync {
      guard demand else { return }
      if !connected {
        guard let configuration = demandConfiguration,
          let passthroughFormat = demandPassthroughFormat else { return }
        do {
          try connectSink(configuration, passthroughFormat)
          connected = true
        } catch {
          // Keep demand asserted. The next frame gives the bridge another
          // opportunity to reconnect without requiring a second CMIO client
          // transition, while retaining queued frames for the eventual sink.
          return
        }
      }
      pumpLocked()
    }
  }

  /// Closes the Program sink and releases any pending leases. The route itself
  /// remains registered so a later demand transition can resume output.
  func disconnect() {
    sync {
      demand = false
      if connected { disconnectSink() }
      connected = false
      demandConfiguration = nil
      demandPassthroughFormat = nil
      drainLocked()
    }
  }

  private func pumpLocked() {
    while let lease = route.dequeue() {
      defer { lease.release() }
      guard let image = lease.payload, let metadata = lease.metadata else { continue }
      guard metadata.presentationTime.isValid, metadata.presentationTime.isNumeric,
        metadata.presentationTime.epoch == 0,
        metadata.duration.isValid, metadata.duration.isNumeric,
        metadata.duration.epoch == 0, metadata.duration.value > 0,
        CVPixelBufferGetWidth(image) == metadata.width,
        CVPixelBufferGetHeight(image) == metadata.height,
        CVPixelBufferGetPixelFormatType(image) == OSType(metadata.pixelFormat) else {
        statistics.invalid &+= 1
        continue
      }
      var staged: CMSampleBuffer?
      do {
        let sample = try sampleFactory.sample(image, at: metadata.presentationTime,
          duration: metadata.duration)
        staged = sample
        if try sendSink(sample) { statistics.delivered &+= 1 }
        else { statistics.dropped &+= 1 }
      } catch {
        statistics.sendErrors &+= 1
        let mismatch = (error as? LocalizedError)?.errorDescription?
          .contains("negotiated format") == true
        if let sample = staged, mismatch, reconnectLocked(to: metadata) {
          do {
            if try sendSink(sample) {
              statistics.delivered &+= 1
              continue
            }
            statistics.dropped &+= 1
            continue
          } catch {
            statistics.sendErrors &+= 1
          }
        }
        // A failed enqueue usually means the CMIO client released the
        // virtual camera between our demand check and this send. Keep demand
        // asserted so the next demanded frame can reconnect the sink.
        if connected { disconnectSink() }
        connected = false
        drainLocked()
        break
      }
    }
  }

  /// Rebuilds the sink around the frame that was just rejected. Program
  /// sources can change resolution, chroma, or frame rate at a cut, and the
  /// sink's previous negotiation would otherwise drop every following frame.
  private func reconnectLocked(to metadata: ProcessedFrameMetadata) -> Bool {
    if connected { disconnectSink() }
    connected = false
    var configuration = PipelineConfiguration()
    configuration.downscale = metadata.width <= 1920
    configuration.convertTo420 = metadata.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    configuration.inputFast = metadata.duration == VideoContract.fastDuration
    configuration.reduceFrameRate = false
    // The rejected frame's own format is the contract. Reusing the previous
    // packed v210 passthrough makes CameraSink reject every later bi-planar frame.
    let passthrough = OSType(metadata.pixelFormat)
    do {
      try connectSink(configuration, passthrough)
      connected = true
      demandConfiguration = configuration
      demandPassthroughFormat = passthrough
      return true
    } catch {
      connected = false
      return false
    }
  }

  private static func sameContract(_ current: PipelineConfiguration?, _ next: PipelineConfiguration,
                                   _ currentPassthrough: OSType?, _ nextPassthrough: OSType) -> Bool {
    guard let current, let currentPassthrough else { return false }
    return current.width == next.width && current.height == next.height &&
      current.pixelFormat == next.pixelFormat && current.duration == next.duration &&
      currentPassthrough == nextPassthrough
  }

  private func drainLocked() {
    while let lease = route.dequeue() { lease.release() }
  }

  private func sync<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
    return try queue.sync(execute: body)
  }
}
