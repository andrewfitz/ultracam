import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal
import MonitorKit

/// A monitor surface on the delivery side: it takes each frame of the feed it shows.
protocol MonitorFeedConsumer: AnyObject, Sendable {
  /// Called under the host's lock on the delivery thread, for every frame in order.
  /// Swap a latest-frame slot; never call back into the host and never wait.
  func accept(_ delivery: MonitorFeedHost.Delivery)
}

/// The monitor's endpoint for one camera feed or Program, on MonitorKit.
///
/// Delivery side (any thread, one short lock): every frame the capture delivery
/// queue (or the Program route) offers is stamped, its colorimetry and geometry are
/// read (cached per IOSurface, so a steady stream allocates nothing), and it goes
/// straight into each live consumer's slot. Offers never visit the main actor, never
/// copy pixels and never wait on the GPU. Only the source frame is offered: the
/// Output stage is the source plus the burn-in LUT in MonitorKit's shader.
///
/// Render side (the monitor render thread only): the feed's `MonitorFeed`, made on
/// first use with the current LUTs, and `frame(_:in:core:)`, which maps a delivery's
/// IOSurface through the shared texture cache at encode time.
final class MonitorFeedHost: MonitorFrameSink, @unchecked Sendable {
  /// The Program target's raw ID.
  static let programTarget = "program"

  /// Identifies one offered frame. Generations are unique across hosts and grow
  /// with every new capture generation (a start, or a Program cut), so a frame from
  /// an older source never replaces a newer one.
  struct Stamp: Hashable, Sendable {
    var target: String
    var generation: UInt64
    var sequence: UInt64
    var sourcePTS: Double
    var hostTime: Double
    /// Bumped when what the frames mean changes: their signal or geometry, the
    /// signal declaration, the consumer set coming or going, an invalidation.
    var revision: UInt64

    /// Whether a consumer that last took `previous` should take this frame: same
    /// target; a newer generation; or, within a generation, not an older revision
    /// and, for the same revision, not an older sequence.
    func follows(_ previous: Stamp?) -> Bool {
      guard let previous else { return true }
      guard target == previous.target, generation >= previous.generation else { return false }
      guard generation == previous.generation else { return true }
      guard revision >= previous.revision else { return false }
      return revision != previous.revision || sequence > previous.sequence
    }
  }

  /// One offered frame as the delivery thread read it: what a surface needs to draw it.
  struct Delivery: @unchecked Sendable {
    let stamp: Stamp
    /// Retained here so the capture buffer lives while a surface may draw it.
    let pixelBuffer: CVPixelBuffer
    /// Nil for a pixel format MonitorKit does not read.
    let layout: PixelLayout?
    /// The attachments' signal with the feed's declaration applied, carrying both
    /// readings of the codes. Its range and matrix are the Source stage's (and the
    /// log classifiers'). Its `outputReading`, set when it differs, is how the
    /// Output and Monitor stages read them: as the camera's processing decodes the
    /// frame for the burn-in LUT (`LUTProcessor.parameters`: the pixel format's
    /// code range and its Y'CbCr matrix, BT.709 for any but BT.2020 and BT.601); a
    /// frame the camera publishes untouched keeps its tagged matrix, as its
    /// passthrough copy does. A declared code range is the Source stage's alone,
    /// so the Output (LUT) picture, and every tool on the Output and Monitor
    /// stages, read what Program, recording and the virtual camera get. MonitorKit
    /// decodes each stage with its own reading in the same pass. Program's frames
    /// have one reading.
    let signal: SignalDescription
    /// Size, pixel aspect ratio and clean aperture (top-left origin, ISO/IEC 14496-12).
    let geometry: MonitorFrameGeometry
    /// The `MonitorFrame.id` every surface of the feed gives this frame, so the
    /// feed analyses it once.
    let frameID: UInt64
    /// Program's frames are a mix, not a camera's signal: no log false colour, no peaking.
    let isProcessed: Bool

    init(
      stamp: Stamp, pixelBuffer: CVPixelBuffer, layout: PixelLayout?, signal: SignalDescription,
      geometry: MonitorFrameGeometry, frameID: UInt64, isProcessed: Bool
    ) {
      self.stamp = stamp
      self.pixelBuffer = pixelBuffer
      self.layout = layout
      self.signal = signal
      self.geometry = geometry
      self.frameID = frameID
      self.isProcessed = isProcessed
    }

    /// The Output and Monitor stages' reading as a signal of its own
    /// (`SignalDescription.outputSignal`); `signal` when there is no other reading.
    var outputSignal: SignalDescription { signal.signal(for: .output) }

    /// The signal a pass that measures `stage` alone reads the frame with
    /// (`SignalDescription.signal(for:)`).
    func signal(reading stage: SignalStage) -> SignalDescription { signal.signal(for: stage) }
  }

  /// The stage whose reading a picture of `state` shows, for describing it: its
  /// picture stage, or, while false colour replaces the picture, the stage it
  /// classifies (the Source for a log mode that reads the signal's log encoding;
  /// six-band and custom bands their own stage). It does not change how a frame
  /// is decoded: every stage's tools read that stage's own reading.
  static func pictureReading(_ state: MonitorState, signal: SignalDescription) -> SignalStage {
    let falseColor = state.falseColor
    guard !state.clean else { return state.pictureStage }
    switch falseColor.mode {
    case .off: return state.pictureStage
    case .sixBand: return falseColor.stage
    case .custom: return falseColor.customBands.isEmpty ? state.pictureStage : falseColor.stage
    case .sonySLog3, .arriStyleSLog3, .arriLogC, .elZone:
      return logFalseColor(falseColor.mode, reads: signal.encoding.log) ? .source : state.pictureStage
    }
  }

  /// Whether log false colour `mode` classifies `log`, as MonitorKit resolves it:
  /// Sony's tables need S-Log3, the ARRI-style and EL Zone scales S-Log3 in
  /// S-Gamut3 or S-Gamut3.Cine, ARRI's an ARRI LogC curve. Otherwise MonitorKit
  /// reports it unavailable and the picture stage shows.
  private static func logFalseColor(_ mode: FalseColorMode, reads log: LogEncoding?) -> Bool {
    guard let log else { return false }
    let sony = log.curve == .sLog3
    let sGamut = sony && (log.gamut == .sGamut3 || log.gamut == .sGamut3Cine)
    switch mode {
    case .sonySLog3: return sony
    case .arriStyleSLog3, .elZone: return sGamut
    case .arriLogC: return FalseColorTable.arriProfile(for: log.curve) != nil
    case .off, .sixBand, .custom: return false
    }
  }

  /// One lock for the process-wide generation and frame-ID counters.
  private static let counterLock = NSLock()
  nonisolated(unsafe) private static var nextGeneration: UInt64 = 0
  nonisolated(unsafe) private static var nextOwner: UInt64 = 0
  /// Frame IDs live above MonitorKit's own (which count up from 1), so a host ID
  /// never equals a library-made frame's.
  nonisolated(unsafe) private static var nextFrameID: UInt64 = 1 << 62

  let target: String
  /// Program: processed frames, no burn-in LUT, no signal declaration.
  let isProgram: Bool
  /// Tags this host's textures in the shared cache, for `MonitorTextureCache.flush(owner:)`.
  let owner: UInt64
  private let gpu: MonitorGPUContext?

  private let lock = NSLock()
  private var consumers: [any MonitorFeedConsumer] = []
  private var declaration: MonitorSignalDeclaration?
  private var captureGeneration: UInt64?
  private var rejectedCaptureGeneration: UInt64?
  private var generation: UInt64 = 0
  private var revision: UInt64 = 1
  private struct Identity: Equatable {
    let layout: PixelLayout?
    let signal: SignalDescription
    let geometry: MonitorFrameGeometry
  }
  private var identity: Identity?
  /// The last signal, reused while the buffer's colour tags, format and the
  /// declaration are unchanged.
  private var interpretation: Interpretation?
  /// Geometry per pooled IOSurface. Core Video rebuilds a dictionary attachment
  /// (clean aperture, pixel aspect) on every read, so they are read once per
  /// surface, size and format, and again after the capture generation changes.
  private struct GeometryKey: Hashable {
    let surface: IOSurfaceID
    let width: Int
    let height: Int
    let format: OSType
  }
  private var geometries: [GeometryKey: MonitorFrameGeometry] = [:]
  private static let geometryCacheLimit = 32
  private var lastSourcePTS: CMTime?
  private var sourceFrameHz = 0.0
  private var offered: UInt64 = 0
  private var rateWindow = (start: 0.0, offered: UInt64(0))
  private var offeredFPS = 0.0
  /// The newest delivery sent to consumers. A producer retry with the same
  /// generation, revision, and sequence is the same source frame and must not
  /// inflate offer statistics or make every consumer inspect it again.
  private var lastOfferedStamp: Stamp?
  private var burnIn: MonitorLUT?
  private var monitorOnly: MonitorLUT?
  private var lutVersion: UInt64 = 0
  /// The monitor-only LUT's file: the choice being shown or loaded, the load
  /// that may still replace it (older loads are ignored), and how it went.
  private let lutLoader: LUTFileLoader
  private var monitorLUTChoice: MonitorLUTChoice?
  private var monitorLUTLoad: UInt64 = 0
  private var monitorLUTPhase = MonitorLUTState.none
  /// When the shown choice last failed to load: it is read again no sooner than
  /// `monitorLUTRetryInterval` later.
  private var monitorLUTFailedAt: Double?
  /// The choice a refresh replaced, until another is made: the owner may still
  /// hand it back before it has saved the refreshed one, and that is no new choice.
  private var monitorLUTRefreshedFrom: MonitorLUTChoice?
  private let clock: @Sendable () -> Double
  /// A failed monitor LUT is read again at most this often (seconds): the
  /// coordinator refreshes its hosts on every preferences change, and each read
  /// resolves the bookmark and parses the whole file.
  static let monitorLUTRetryInterval = 5.0
  /// Called (on the loading task) when the shown choice's file resolved to another
  /// bookmark (it was moved or renamed) or name: the choice the host now holds,
  /// with the same pick. The owner saves it; handing it back does not reload.
  var onMonitorLUTChoiceRefresh: (@Sendable (_ old: MonitorLUTChoice, _ new: MonitorLUTChoice) -> Void)? {
    get { lock.withLock { choiceRefresh } }
    set { lock.withLock { choiceRefresh = newValue } }
  }
  private var choiceRefresh: (@Sendable (MonitorLUTChoice, MonitorLUTChoice) -> Void)?
  private var mismatch: String?

  /// Render thread only.
  private var renderFeed: MonitorFeed?
  private var appliedLUTVersion: UInt64 = .max

  /// Why a LUT is not applied (made on another GPU than the monitor's); nil when
  /// they are. Set on the render thread, read anywhere.
  var lutMismatch: String? { lock.withLock { mismatch } }

  /// The file loader monitor-only LUTs go through: the interface makes their
  /// bookmarks with it (read-only, security-scoped), and hosts resolve them with it.
  static let monitorLUTLoader = LUTFileLoader()

  init(
    target: String, gpu: MonitorGPUContext?, lutLoader: LUTFileLoader = MonitorFeedHost.monitorLUTLoader,
    clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.target = target
    isProgram = target == Self.programTarget
    self.gpu = gpu
    self.lutLoader = lutLoader
    self.clock = clock
    owner = Self.counterLock.withLock {
      Self.nextOwner &+= 1
      return Self.nextOwner
    }
    geometries.reserveCapacity(Self.geometryCacheLimit)
  }

  // MARK: - Control (any thread)

  /// The surfaces that take this feed's frames. An empty list stops all per-frame work.
  func setConsumers(_ value: [any MonitorFeedConsumer]) {
    lock.withLock {
      if consumers.isEmpty != value.isEmpty { revision &+= 1 }
      consumers = value
    }
  }

  var hasConsumers: Bool { lock.withLock { !consumers.isEmpty } }

  /// How this camera's frames are read (log profile, code range). Ignored for Program.
  func setSignalDeclaration(_ value: MonitorSignalDeclaration?) {
    let value = isProgram ? nil : value
    lock.withLock {
      if declaration != value { revision &+= 1 }
      declaration = value
    }
  }

  /// The output stage's LUT: the same `MonitorLUT` the camera burns in
  /// (`CaptureController.burnInLUT`), so preview and output are identical. Always
  /// nil for Program, whose frames are already processed. Applied on the render thread.
  var burnInLUT: MonitorLUT? {
    get { lock.withLock { burnIn } }
    set {
      let value = isProgram ? nil : newValue
      lock.withLock {
        guard burnIn !== value else { return }
        burnIn = value
        lutVersion &+= 1
      }
    }
  }

  /// A monitor-only LUT, stacked on the burn-in LUT. Applied on the render thread.
  var monitorLUT: MonitorLUT? {
    get { lock.withLock { monitorOnly } }
    set {
      lock.withLock {
        guard monitorOnly !== newValue else { return }
        monitorOnly = newValue
        lutVersion &+= 1
      }
    }
  }

  /// Where the monitor-only LUT's file stands.
  enum MonitorLUTState: Equatable, Sendable {
    case none
    case loading
    /// Shown on the Monitor stage; the LUT's title.
    case loaded(String)
    /// Nothing is shown; why.
    case failed(String)
  }

  var monitorLUTState: MonitorLUTState { lock.withLock { monitorLUTPhase } }

  /// One line for the interface and diagnostics; nil when no monitor LUT is chosen.
  static func describe(_ state: MonitorLUTState) -> String? {
    switch state {
    case .none: return nil
    case .loading: return "Monitor LUT: loading…"
    case .loaded(let title): return title.isEmpty ? "Monitor LUT: loaded" : "Monitor LUT: \(title)"
    case .failed(let reason): return "Monitor LUT failed to load: \(reason)"
    }
  }

  /// The camera's monitor-only LUT file (`MonitorFeedPreferences.monitorLUT`).
  /// A new choice is resolved and read off the calling thread, inside its
  /// security scope, and built once as a tetrahedral `MonitorLUT` on the shared
  /// device; the LUT shown until then stays, and frames already encoded keep
  /// theirs (no wait). The same choice again does nothing while it is loading
  /// or shown, so this can be called on every preferences refresh; a choice
  /// whose file could not be read is tried again, no sooner than
  /// `monitorLUTRetryInterval` after it failed (the volume may be mounted by
  /// now). A new pick of the same file (`MonitorLUTChoice.pick`) reads it again.
  /// Nil clears it at once; a file that cannot be read clears it and is reported
  /// in `monitorLUTState`. Ignored for Program, whose frames are already processed.
  func setMonitorLUT(_ value: MonitorLUTChoice?) {
    let now = clock()
    let started: (load: UInt64, choice: MonitorLUTChoice)? = lock.withLock {
      var choice = isProgram ? nil : value
      if choice != nil, choice == monitorLUTRefreshedFrom { choice = monitorLUTChoice }
      if choice == monitorLUTChoice {
        guard let choice, case .failed = monitorLUTPhase else { return nil }
        guard now - (monitorLUTFailedAt ?? -.infinity) >= Self.monitorLUTRetryInterval else { return nil }
        monitorLUTLoad &+= 1
        monitorLUTFailedAt = nil
        monitorLUTPhase = .loading
        return (monitorLUTLoad, choice)
      }
      monitorLUTChoice = choice
      monitorLUTRefreshedFrom = nil
      monitorLUTLoad &+= 1
      monitorLUTFailedAt = nil
      guard let choice else {
        monitorLUTPhase = .none
        if monitorOnly != nil {
          monitorOnly = nil
          lutVersion &+= 1
        }
        return nil
      }
      monitorLUTPhase = .loading
      return (monitorLUTLoad, choice)
    }
    guard let (load, choice) = started else { return }
    let loader = lutLoader
    Task.detached { [weak self] in
      let result: Result<(MonitorLUT, LoadedLUT), any Error>
      do {
        let file = try await loader.restore(bookmark: choice.bookmark)
        result = .success((try LUTProcessor.makeLUT(file.cube), file))
      } catch {
        result = .failure(error)
      }
      self?.finishMonitorLUTLoad(load, choice, result)
    }
  }

  /// `setMonitorLUT` for a bare bookmark.
  func setMonitorLUTBookmark(_ value: Data?) {
    setMonitorLUT(value.map { MonitorLUTChoice(bookmark: $0, fileName: "") })
  }

  private func finishMonitorLUTLoad(
    _ load: UInt64, _ choice: MonitorLUTChoice, _ result: Result<(MonitorLUT, LoadedLUT), any Error>
  ) {
    let refresh: ((MonitorLUTChoice, MonitorLUTChoice) -> Void, MonitorLUTChoice)? = lock.withLock {
      guard load == monitorLUTLoad else { return nil }
      let lut: MonitorLUT?
      var refreshed: MonitorLUTChoice?
      switch result {
      case .success(let (value, file)):
        lut = value
        monitorLUTPhase = .loaded(value.cube.title)
        // A moved or renamed file: hold the refreshed choice first, so the owner
        // handing it back is the same choice and does not reload.
        if file.bookmark != choice.bookmark || (!file.fileName.isEmpty && file.fileName != choice.fileName) {
          var value = choice
          value.bookmark = file.bookmark
          if !file.fileName.isEmpty { value.fileName = file.fileName }
          monitorLUTRefreshedFrom = monitorLUTRefreshedFrom ?? choice
          monitorLUTChoice = value
          refreshed = value
        }
      case .failure(let error):
        lut = nil
        monitorLUTPhase = .failed(error.localizedDescription)
        monitorLUTFailedAt = clock()
      }
      if monitorOnly !== lut {
        monitorOnly = lut
        lutVersion &+= 1
      }
      guard let refreshed, let choiceRefresh else { return nil }
      return (choiceRefresh, refreshed)
    }
    if let (report, refreshed) = refresh { report(choice, refreshed) }
  }

  /// The camera frame rate measured from picture timestamps. Zero until two frames arrived.
  var observedSourceFrameHz: Double { lock.withLock { sourceFrameHz } }

  /// Frames offered to live consumers, and their rate over the last second.
  var offerStatistics: (frames: UInt64, fps: Double) {
    lock.withLock {
      let now = ProcessInfo.processInfo.systemUptime
      if now - rateWindow.start >= 1 {
        if rateWindow.start > 0 {
          offeredFPS = Double(offered - rateWindow.offered) / (now - rateWindow.start)
        }
        rateWindow = (now, offered)
      }
      return (offered, offeredFPS)
    }
  }

  // MARK: - Delivery (MonitorFrameSink)

  func invalidate(rejectingCaptureGeneration rejected: UInt64?) {
    lock.withLock {
      if let rejected {
        rejectedCaptureGeneration = max(rejectedCaptureGeneration ?? rejected, rejected)
      }
      if let captureGeneration {
        rejectedCaptureGeneration = max(rejectedCaptureGeneration ?? captureGeneration, captureGeneration)
      }
      captureGeneration = nil
      revision &+= 1
      geometries.removeAll(keepingCapacity: true)
    }
    // The stopped generation's frames are gone; so are their textures.
    gpu?.flushFrames(owner: owner)
  }

  func offer(_ image: CVPixelBuffer, pts: CMTime, captureGeneration: UInt64, sequence: UInt64, untouched: Bool) {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    defer { lock.unlock() }
    guard !consumers.isEmpty else { return }
    if let rejectedCaptureGeneration, captureGeneration <= rejectedCaptureGeneration { return }
    if self.captureGeneration != captureGeneration {
      generation = Self.counterLock.withLock {
        Self.nextGeneration &+= 1
        return Self.nextGeneration
      }
      self.captureGeneration = captureGeneration
      geometries.removeAll(keepingCapacity: true)
    }
    let format = CVPixelBufferGetPixelFormatType(image)
    let layout = MonitorFrame.layout(for: format)
    let signal = Self.interpret(
      image, format: format, range: layout?.range ?? .legal, declaration: declaration, processed: isProgram,
      untouched: untouched, cache: &interpretation)
    let geometry = cachedGeometry(image, format: format)
    let current = Identity(layout: layout?.layout, signal: signal, geometry: geometry)
    if identity != current {
      identity = current
      revision &+= 1
    }
    let stamp = Stamp(
      target: target, generation: generation, sequence: sequence, sourcePTS: pts.seconds, hostTime: now,
      revision: revision)
    guard stamp.follows(lastOfferedStamp) else { return }
    lastOfferedStamp = stamp
    noteSourceFrameRate(pts)
    offered &+= 1
    let frameID = Self.counterLock.withLock {
      Self.nextFrameID &+= 1
      return Self.nextFrameID
    }
    let delivery = Delivery(
      stamp: stamp,
      pixelBuffer: image, layout: layout?.layout, signal: signal, geometry: geometry, frameID: frameID,
      isProcessed: isProgram)
    // Under the lock, so a setConsumers that removes a surface cannot race a frame
    // into it. accept() only swaps a slot; it never calls back here.
    for consumer in consumers { consumer.accept(delivery) }
  }

  /// Records the camera interval from every offered frame's timestamp.
  private func noteSourceFrameRate(_ pts: CMTime) {
    guard pts.isNumeric, pts.epoch == 0 else { return }
    if let lastSourcePTS, lastSourcePTS.isNumeric {
      let delta = CMTimeSubtract(pts, lastSourcePTS).seconds
      if delta > 0, delta.isFinite { sourceFrameHz = 1 / delta }
    }
    lastSourcePTS = pts
  }

  /// Called with the lock held.
  private func cachedGeometry(_ image: CVPixelBuffer, format: OSType) -> MonitorFrameGeometry {
    guard let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else {
      return MonitorFrame.geometry(of: image)
    }
    let key = GeometryKey(
      surface: IOSurfaceGetID(surface), width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
      format: format)
    if let cached = geometries[key] { return cached }
    let value = MonitorFrame.geometry(of: image)
    if geometries.count >= Self.geometryCacheLimit { geometries.removeAll(keepingCapacity: true) }
    geometries[key] = value
    return value
  }

  /// A buffer's colour tags. Core Video returns these as interned constant strings:
  /// reading only retains them, and comparing is identity or CFEqual.
  private struct ColorTags {
    let matrix: CFTypeRef?
    let transfer: CFTypeRef?
    let primaries: CFTypeRef?
    let chromaLocation: CFTypeRef?
    init(_ image: CVPixelBuffer) {
      matrix = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil)
      transfer = CVBufferCopyAttachment(image, kCVImageBufferTransferFunctionKey, nil)
      primaries = CVBufferCopyAttachment(image, kCVImageBufferColorPrimariesKey, nil)
      chromaLocation = CVBufferCopyAttachment(image, kCVImageBufferChromaLocationTopFieldKey, nil)
    }
    func matches(_ other: ColorTags) -> Bool {
      Self.same(matrix, other.matrix) && Self.same(transfer, other.transfer)
        && Self.same(primaries, other.primaries) && Self.same(chromaLocation, other.chromaLocation)
    }
    private static func same(_ a: CFTypeRef?, _ b: CFTypeRef?) -> Bool {
      switch (a, b) {
      case (nil, nil): return true
      case let (a?, b?): return a === b || CFEqual(a, b)
      default: return false
      }
    }
  }

  private struct Interpretation {
    let tags: ColorTags
    let format: OSType
    let declaration: MonitorSignalDeclaration?
    let untouched: Bool
    let signal: SignalDescription
  }

  /// The cached signal while nothing it depends on changed; otherwise a fresh one
  /// (which may allocate), cached for the next frame. Primaries are read on their
  /// own, so HLG or PQ with BT.709 primaries keeps BT.709. `untouched`: the camera
  /// publishes the frame as captured, tags included, so the Output stage keeps
  /// the tagged matrix (SMPTE 240M too) where the burn-in would read BT.709.
  private static func interpret(
    _ image: CVPixelBuffer, format: OSType, range: CodeRange, declaration: MonitorSignalDeclaration?,
    processed: Bool, untouched: Bool, cache: inout Interpretation?
  ) -> SignalDescription {
    let tags = ColorTags(image)
    if let cached = cache, cached.format == format, cached.declaration == declaration,
      cached.untouched == untouched, cached.tags.matches(tags) {
      return cached.signal
    }
    let native = MonitorFrame.signal(of: image, range: range)
    var signal = native
    if !processed {
      signal = declaration?.applied(to: native) ?? native
      // The Output and Monitor stages read the frame as it is published: the
      // format's range, and the matrices LUTProcessor reads (an untouched frame
      // keeps its tag, as the passthrough copy does).
      let output = SignalReading(
        range: native.range, matrix: signal.matrix == .smpte240m && !untouched ? .bt709 : signal.matrix)
      signal.outputReading = output == signal.sourceReading ? nil : output
    }
    cache = Interpretation(tags: tags, format: format, declaration: declaration, untouched: untouched,
      signal: signal)
    return signal
  }

  /// `image` read as this host reads every offered frame (`Delivery.signal`, both
  /// readings); `untouched` as `offer` takes it (tests, tools).
  func signal(of image: CVPixelBuffer, untouched: Bool = false) -> SignalDescription {
    let format = CVPixelBufferGetPixelFormatType(image)
    var cache: Interpretation?
    return Self.interpret(
      image, format: format, range: MonitorFrame.layout(for: format)?.range ?? .legal,
      declaration: lock.withLock { declaration }, processed: isProgram, untouched: untouched, cache: &cache)
  }

  /// `image` as the Output and Monitor stages alone read it (`Delivery.outputSignal`).
  func outputSignal(of image: CVPixelBuffer, untouched: Bool = false) -> SignalDescription {
    signal(of: image, untouched: untouched).signal(for: .output)
  }

  // MARK: - Render thread

  /// The feed's `MonitorFeed`, made on first use, with the LUTs set since the last
  /// call. Render thread only (`MonitorFeed` is confined). A LUT made on another
  /// device than `engine`'s is not applied and is reported in `lutMismatch`.
  func feed(engine: MonitorEngine) -> MonitorFeed {
    let feed: MonitorFeed
    if let existing = renderFeed, existing.engine === engine {
      feed = existing
    } else {
      feed = engine.makeFeed()
      renderFeed = feed
      appliedLUTVersion = .max
    }
    let (version, burn, monitor) = lock.withLock { (lutVersion, burnIn, monitorOnly) }
    if version != appliedLUTVersion {
      appliedLUTVersion = version
      let device = engine.device
      let usable = { (lut: MonitorLUT?) -> MonitorLUT? in
        guard let lut else { return nil }
        return lut.texture.device === device ? lut : nil
      }
      feed.burnInLUT = usable(burn)
      feed.monitorLUT = usable(monitor)
      let reason =
        (burn != nil && feed.burnInLUT == nil) || (monitor != nil && feed.monitorLUT == nil)
        ? "The LUT was made on another GPU than the monitor's." : nil
      lock.withLock { mismatch = reason }
    }
    return feed
  }

  /// Lets go of the feed's render state once its camera is gone: the `MonitorFeed`
  /// (focus mask, LUT references, residency) is released on the render thread,
  /// and the feed's textures leave the shared cache. A surface still bound to the
  /// target makes a bare feed again if it draws.
  func releaseRenderState() {
    gpu?.renderThread.perform { [self] in
      renderFeed = nil
      appliedLUTVersion = .max
    }
    gpu?.flushFrames(owner: owner)
  }

  /// `delivery` as a `MonitorFrame` over the shared, resident texture cache, with the
  /// delivery's ID (so the feed analyses it once), signal and geometry: no attachment
  /// is read and nothing is allocated in steady state. Render thread only. The
  /// context keeps the pixel buffer alive until its submission completes.
  ///
  /// The submission is observed before the textures are looked up, so a sweep or
  /// flush that retires one of them at any later moment ties its release to this
  /// submission; a texture swept earlier is simply made (and made resident) again.
  ///
  /// Use the result only within `context`'s submission and never store it: it has
  /// no release tokens, so a later submission is not kept resident by it, and a
  /// stop's flush in between would leave it reading non-resident textures. Keep
  /// the `Delivery` instead (a pending scope tick, a Freeze source) and wrap it
  /// again at each encode.
  ///
  /// The frame carries `Delivery.signal`, both readings, whatever stage a pass
  /// measures: MonitorKit decodes each stage with its own (the picture's Source
  /// and Output tools, a scope, a focus analysis), so every pass draws the same
  /// frame. Relabelling a frame with one stage's reading would make the other
  /// stages' tools read the codes with it.
  func frame(
    _ delivery: Delivery, in context: MonitorGPUContext.EncodeContext, core: MonitorGPUContext.Core
  ) throws -> MonitorFrame {
    let buffer = delivery.pixelBuffer
    guard let layout = delivery.layout else {
      throw MonitorKitError.unsupportedPixelFormat(CVPixelBufferGetPixelFormatType(buffer))
    }
    guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
      throw MonitorKitError.invalidFrame("the pixel buffer is not IOSurface-backed")
    }
    core.engine.residency.observe(context.submission)
    let cache = core.frames
    let width = delivery.geometry.width, height = delivery.geometry.height
    var packed: MTLTexture?, luma: MTLTexture?, chroma: MTLTexture?
    // MonitorFrame's formats (MonitorTextureCache.frame lays planes out the same way).
    switch layout {
    case .v210:
      packed = try cache.makeTexture(
        iosurface: surface, plane: 0, format: .rgba32Uint, width: (width + 5) / 6, height: height, owner: owner)
    case .uyvy8, .yuyv8:
      packed = try cache.makeTexture(
        iosurface: surface, plane: 0, format: .rgba8Uint, width: (width + 1) / 2, height: height, owner: owner)
    case .biplanar(_, let depth):
      luma = try cache.makeTexture(
        iosurface: surface, plane: 0, format: depth == 8 ? .r8Unorm : .r16Unorm,
        width: CVPixelBufferGetWidthOfPlane(buffer, 0), height: CVPixelBufferGetHeightOfPlane(buffer, 0),
        owner: owner)
      chroma = try cache.makeTexture(
        iosurface: surface, plane: 1, format: depth == 8 ? .rg8Unorm : .rg16Unorm,
        width: CVPixelBufferGetWidthOfPlane(buffer, 1), height: CVPixelBufferGetHeightOfPlane(buffer, 1),
        owner: owner)
    case .rgb(let depth, let float):
      let format: MTLPixelFormat =
        float
        ? (depth == 16 ? .rgba16Float : .rgba32Float)
        : depth == 8
          ? (CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32RGBA ? .rgba8Unorm : .bgra8Unorm)
          : depth == 10 ? .bgr10a2Unorm : .rgba16Unorm
      luma = try cache.makeTexture(
        iosurface: surface, plane: 0, format: format, width: width, height: height, owner: owner)
    }
    var frame = try MonitorFrame(
      layout: layout, width: width, height: height, packed: packed, luma: luma, chroma: chroma,
      signal: delivery.signal, pixelAspectRatio: delivery.geometry.pixelAspectRatio,
      cleanAperture: delivery.geometry.cleanAperture)
    frame.id = delivery.frameID
    frame.isProcessed = delivery.isProcessed
    context.retain(buffer)
    return frame
  }
}
