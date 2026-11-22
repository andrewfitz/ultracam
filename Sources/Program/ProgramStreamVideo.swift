import CoreMedia
import CoreVideo
import Foundation

/// Bounded capture and converted queues surround one GPU submission. Both tracks follow
/// the same capture-host timeline, with a short playout window for rendering and input jitter.
/// The encoder consumes the selected cadence on the host clock regardless of UI or CMIO demand.
final class ProgramStreamVideo: ProgramStreamFrameSink, @unchecked Sendable {
  typealias Send = @Sendable (CMSampleBuffer, Bool) -> Void

  private struct SourceSlot: Sendable {
    let feedID: FeedID
    let generation: UInt64
    let start: CMTime
    let freshUntil: CMTime
    let expires: CMTime
  }

  private struct Input: @unchecked Sendable {
    let frame: ProcessedFrame<CVPixelBuffer>
    let retained: MediaRetentionLedger.Lease
    let slot: SourceSlot
  }
  private struct Picture: @unchecked Sendable {
    let image: CVPixelBuffer
    // A passthrough keeps the source's admission and producer lease until replacement.
    let passthrough: Input?
    let producer: FrameLease<CVPixelBuffer>?
    let slot: SourceSlot
  }

  private let lock = NSLock()
  private let worker = DispatchQueue(label: "org.ultracam.program-stream.video", qos: .userInitiated)
  private let normalizer: ProgramFrameNormalizing
  private let contract: ProgramOutputFormat
  private let black: CVPixelBuffer
  private let send: Send
  private let report: @Sendable (String) -> Void
  private let hostNow: @Sendable () -> CMTime
  private static let minimumPictureFreshness = CMTime(value: 3, timescale: 4)
  private let admission = MediaRetentionLedger(policy: ProgramOutputRoute.stagePolicy)
  private let samples = VideoSampleFactory()
  private let playout: CMTime
  private let capacity: Int
  private var pending: [Input] = []
  private var cuts: [(start: CMTime, generation: UInt64)] = []
  private var generation: UInt64 = 0
  private var oldestPictureGeneration: UInt64 = 0
  private var samplingOrigin: CMTime?
  private var lastInputSlot: Int64 = -1
  private var preparationScheduled = false
  private var feedID: FeedID?
  private var stopped = false
  private var drops: UInt64 = 0
  // Only the delivery worker accesses the fields below.
  private var timer: DispatchSourceTimer?
  private var busy = false
  private var ready: [Picture] = []
  private var picture: Picture?
  private var origin: CMTime?
  private var lastSlot: Int64 = -1
  private var lastIssue: String?

  init(contract: ProgramOutputFormat, normalizer: ProgramFrameNormalizing,
       black: CVPixelBuffer, playoutFrames: Int32 = 4, send: @escaping Send, report: @escaping @Sendable (String) -> Void = { _ in },
       hostNow: @escaping @Sendable () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }) {
    self.playout = CMTimeMultiply(contract.duration, multiplier: max(0, playoutFrames))
    self.capacity = Int(max(0, playoutFrames)) + 4
    self.contract = contract
    self.normalizer = normalizer
    self.black = black
    self.send = send
    self.report = report
    self.hostNow = hostNow
  }

  var droppedFrames: UInt64 { lock.withLock { drops } }

  func start() {
    worker.async { [self] in
      guard !lock.withLock({ stopped }), timer == nil else { return }
      // A regular dispatch timer can be coalesced to 100 ms while the app is in the
      // background, even with submillisecond leeway. Every wake is a media deadline.
      let timer = DispatchSource.makeTimerSource(flags: .strict, queue: worker)
      self.timer = timer
      timer.setEventHandler { [weak self] in self?.tick() }
      timer.schedule(deadline: .now(), leeway: .microseconds(100))
      timer.resume()
    }
  }

  func stop() {
    lock.withLock { stopped = true; pending.removeAll(); cuts.removeAll(); generation &+= 1 }
    worker.sync {
      timer?.cancel()
      timer = nil
      ready.removeAll()
      picture = nil
      normalizer.releaseIdleResources()
    }
  }

  func discardPicture() {
    lock.withLock {
      generation &+= 1
      oldestPictureGeneration = generation
      pending.removeAll()
      cuts.removeAll()
      feedID = nil
      samplingOrigin = nil
    }
  }

  func offer(_ frame: ProcessedFrame<CVPixelBuffer>, feedID: FeedID, programTime: CMTime,
             repeatWindow: Duration) {
    let components = repeatWindow.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) * 1e-18
    let content = frame.metadata.captureHostTime ?? hostNow()
    guard content.isNumeric, content.epoch == 0, content >= .zero else { return }
    let schedule = lock.withLock { () -> Bool in
      guard !stopped else { return false }
      if self.feedID != feedID || samplingOrigin == nil {
        self.feedID = feedID
        generation &+= 1
        let cutTime = cuts.last.map { CMTimeMaximum(content, $0.start) } ?? content
        cuts.append((cutTime, generation))
        if cuts.count > capacity { cuts.removeFirst() }
        samplingOrigin = programTime
        lastInputSlot = -1
      }
      guard let samplingOrigin else { return false }
      let elapsed = CMTimeSubtract(programTime, samplingOrigin)
      let slot = CMTimeConvertScale(elapsed, timescale: contract.duration.timescale, method: .roundTowardZero).value / contract.duration.value
      guard slot > lastInputSlot else { return false }
      lastInputSlot = slot
      // Cut selection and sampling happen on the Program clock. Camera frames faster than
      // the stream cadence are naturally skipped. Replacing an admitted slot means pressure.
      if pending.count == capacity { pending.removeFirst(); drops &+= 1 }
      do {
        let bytes = try ProgramOutputRoute.storageBytes(frame.payload)
        let retained = try admission.admit(bytes: bytes, duration: min(contract.duration.seconds, frame.metadata.duration.seconds))
        let repeatDuration = CMTime(seconds: max(contract.duration.seconds, seconds), preferredTimescale: 240_000)
        let expires = CMTimeAdd(content, repeatDuration)
        // A low-rate source owns its full declared span. One stream slot of
        // tolerance covers a cadence boundary before that source updates.
        let nominal = CMTimeAdd(frame.metadata.duration, contract.duration)
        let freshness = CMTimeMinimum(repeatDuration, CMTimeMaximum(nominal, Self.minimumPictureFreshness))
        let position = SourceSlot(feedID: feedID, generation: generation, start: content,
          freshUntil: CMTimeAdd(content, freshness), expires: expires)
        pending.append(Input(frame: frame, retained: retained, slot: position))
      } catch { drops &+= 1; return false }
      guard !preparationScheduled else { return false }
      preparationScheduled = true
      return true
    }
    if schedule { worker.async { [weak self] in self?.preparePending() } }
  }

  /// Begin conversion as soon as an output slot has a source. Waiting until its send
  /// deadline would add a full frame of audio/video skew for every non-native input.
  private func preparePending() {
    while !busy {
      let next = lock.withLock { () -> Input? in
        guard !stopped, !pending.isEmpty else { preparationScheduled = false; return nil }
        if let origin, lastSlot >= 0 { retirePending(through: contentTime(origin: origin, slot: lastSlot)) }
        guard !pending.isEmpty else { preparationScheduled = false; return nil }
        return pending.removeFirst()
      }
      guard let next else { break }
      if CMTimeSubtract(hostNow(), playout) <= next.slot.expires {
        prepare(next)
      } else {
        lock.withLock { drops &+= 1 }
      }
    }
  }

  /// The delivery worker holds the input lock. Retire cuts whose last slot has
  /// already passed, then coalesce only superseded slots within the remaining cut.
  private func retirePending(through sentThrough: CMTime) {
    var skipped = 0
    if let active = cuts.last(where: { $0.start <= sentThrough }) {
      skipped = pending.prefix(while: { $0.slot.generation < active.generation }).count
    }
    if picture != nil || !ready.isEmpty {
      for index in pending.indices.dropFirst(skipped + 1) {
        let prior = pending[index - 1].slot
        let later = pending[index].slot
        guard later.generation == prior.generation, later.start >= prior.start,
          later.start <= sentThrough, sentThrough <= later.expires else { break }
        skipped = index
      }
    }
    if skipped > 0 {
      pending.removeFirst(skipped)
      drops &+= UInt64(skipped)
    }
  }

  private func contentTime(origin: CMTime, slot: Int64) -> CMTime {
    let grid = CMTime(value: slot * contract.duration.value, timescale: contract.duration.timescale)
    return CMTimeAdd(origin, CMTimeSubtract(grid, playout))
  }

  private func tick() {
    let now = hostNow()
    if origin == nil { origin = now }
    guard let origin else { return }
    // Use only elapsed slots. A 19 ms late 30 fps wake still belongs to its original
    // deadline; assigning it the next slot would also discard the next on-time wake.
    let elapsed = CMTimeSubtract(now, origin)
    let slot = CMTimeConvertScale(elapsed, timescale: contract.duration.timescale,
      method: .roundTowardNegativeInfinity).value / contract.duration.value
    if let timer {
      // Arm the exact next grid boundary before doing media work. Recheck an early wake
      // at that same boundary, and skip straight to the current slot after a long stall.
      let next = CMTime(value: (max(lastSlot, slot) + 1) * contract.duration.value, timescale: contract.duration.timescale)
      let delay = CMTimeConvertScale(CMTimeSubtract(next, elapsed), timescale: 1_000_000_000,
        method: .roundTowardPositiveInfinity)
      timer.schedule(deadline: .now() + .nanoseconds(max(1, Int(delay.value))), leeway: .microseconds(100))
    }
    guard slot > lastSlot else { return }
    let skipped = slot - lastSlot - 1
    lastSlot = slot
    let time = contentTime(origin: origin, slot: slot)
    let (active, current, oldest) = lock.withLock {
      drops &+= UInt64(skipped)
      while cuts.count > 1 && cuts[1].start <= time { cuts.removeFirst() }
      let current = cuts.first.flatMap { $0.start <= time ? $0.generation : nil }
      return (!stopped, current, oldestPictureGeneration)
    }
    guard active else { return }
    // Slots are stamped with the capture time they represent. Consume only pictures due on
    // that grid, including cuts: an early completion from another source cannot play early.
    ready.removeAll { next in
      if next.slot.generation < oldest || next.slot.expires < time { return true }
      guard next.slot.start <= time, let current else { return false }
      if next.slot.generation < current { return true }
      guard next.slot.generation == current else { return false }
      if let previous = picture, previous.slot.generation == current, previous.slot.start > next.slot.start { return true }
      picture = next
      return true
    }
    if let previous = picture, previous.slot.generation < oldest || time > previous.slot.expires {
      picture = nil
    }
    do {
      let sample = try samples.sample(picture?.image ?? black, at: time, duration: contract.duration)
      if let picture {
        if let producer = picture.producer { sample.retainImageFrame(producer) }
        CMSetAttachment(sample, key: "org.ultracam.program-stream.feed-id" as CFString,
          value: picture.slot.feedID.rawValue as CFString, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
      }
      let fresh = picture.map { $0.slot.generation == current && time < $0.slot.freshUntil } ?? false
      send(sample, fresh)
    } catch { failed(error) }
  }

  private func prepare(_ input: Input) {
    let frame = input.frame
    if contract.matches(frame.metadata), contract.matchesColourAndAspect(frame.payload) {
      store(Picture(image: frame.payload, passthrough: input, producer: frame.retainProducerLease(), slot: input.slot))
      lastIssue = nil
      return
    }
    do {
      guard normalizer.canNormalize(frame.metadata, to: contract) else {
        throw VideoError.message("Unsupported Program stream video format.")
      }
      busy = true
      try normalizer.normalize(frame.payload, to: contract) { [weak self, input] result in
        guard let self else { return }
        switch result {
        case .success(let image):
          let completed = Picture(image: image, passthrough: nil, producer: nil, slot: input.slot)
          self.worker.async {
            self.busy = false
            defer { self.preparePending() }
            guard self.lock.withLock({ !self.stopped && self.oldestPictureGeneration <= completed.slot.generation }) else { return }
            self.store(completed)
            self.lastIssue = nil
          }
        case .failure(let error):
          self.worker.async {
            self.busy = false
            if self.lock.withLock({ !self.stopped && self.generation == input.slot.generation }) { self.failed(error) }
            self.preparePending()
          }
        }
      }
    } catch {
      busy = false
      failed(error)
    }
  }

  private func store(_ next: Picture) {
    if ready.count == capacity {
      ready.removeFirst()
      lock.withLock { drops &+= 1 }
    }
    ready.append(next)
  }

  private func failed(_ error: Error) {
    lock.withLock { drops &+= 1 }
    let issue = error.localizedDescription
    if lastIssue != issue { lastIssue = issue; report(issue) }
  }

#if CAPTURE_LIFECYCLE_TESTS
  func tickForTesting() { worker.sync { tick() } }
#endif
}
