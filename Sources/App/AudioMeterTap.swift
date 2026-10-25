import Dispatch
import Foundation
import MonitorKitAudio
import OSLog
import Synchronization

/// Audio overs, logged by each capture's meter tap (rate-limited).
let audioLog = Logger(subsystem: "org.ultracam.app", category: "audio")

/// One capture's broadcast audio meters (MonitorKitAudio: sample and true peak,
/// EBU R 128 loudness and phase correlation), fed from the embedded audio the
/// DeckLink driver thread hands `CaptureController.receiveRawAudio`.
///
/// The meters run off the driver thread, on the tap's own serial queue. The
/// driver thread (`ingest`) only hands the packet over: it stores a reference
/// to the packet's `Data` (the backend's one `NSData` per packet, which
/// recording uses too; a retain, no copy) in a preallocated single-producer,
/// single-consumer ring, publishes it with a release store and signals the
/// queue through a user-data dispatch source. No heap allocation or release,
/// no lock, no Swift concurrency and no wait on the driver thread; atomics
/// only. By then recording and the video frame of the same DeckLink callback
/// have already been handed off (the backend reports a callback's audio after
/// its frame, and the controller hands the packet to recording before the
/// meters), so metering can never delay or drop either.
///
/// Backpressure: the meters take every packet. The default ring holds 4096
/// callbacks (68 s at 59.94p, 137 s at 29.97p), far longer than any stall of a
/// userInitiated queue whose work is a few microseconds a packet, so the
/// meters never lose audio to a busy queue in practice. Only a ring that is
/// still full (the meter queue `packetCapacity` packets behind) leaves a packet
/// out of the meters: never waiting and never allocating on the driver thread
/// leaves no other choice. That packet is counted in `Counters.coalesced`
/// (shown per capture in `CaptureUpdate.audioMeterCoalesced`), and the next
/// metered packet is marked as following a gap, so the meter primes its
/// true-peak interpolator and K-weighting there
/// (`AudioMeter.noteDiscontinuity()`) instead of interpolating across missing
/// audio. A stall holds its packets (a retain of each one's `Data`, at most
/// about 26 MB for a full ring of 2-channel 59.94p packets), never copies.
///
/// Demand driven: the meters run only while a view shows them (`attach` /
/// `detach`), so a feed nobody is metering pays one atomic load per packet.
/// Each time metering starts it starts on a new meter, allocated on the
/// attaching (main) thread, so the readings start over and integrated loudness
/// covers the time the meters have been shown. A new meter rather than
/// `AudioMeter.reset()`: a reset keeps the filters' signal memory (the
/// true-peak interpolator's history, the K-weighting), which is right for a
/// continuous stream but here would be the last audio metered before the
/// meters were hidden, possibly minutes earlier. Interpolating across that
/// jump latched a true-peak over that never happened into Max TP, and the
/// stale K-weighting put loudness into silence. Each packet carries the
/// session it was handed over in; the meter queue meters it into that
/// session's meter only (a packet still queued when its session ended goes to
/// that session's meter), and drops a packet of a session it has already moved
/// past (`Counters.stale`), so a new session never starts on old audio.
///
/// A take (`beginTake` / `endTake`) meters on a meter of its own, fed from the
/// same packets on the meter queue. A view's reset (clicking OVER, Reset
/// Loudness) never touches the take's numbers, and a paused take leaves the
/// paused audio out of its loudness, Max TP and overs.
///
/// The ring takes one producer at a time. The capture's generation guard
/// already rejects packets from a stopped stream; `producing` makes an overlap
/// of two driver threads (a restart racing the old stream's last packet) skip
/// that packet, counted, instead of corrupting the ring.
final class AudioMeterTap: @unchecked Sendable {
  // @unchecked: `slots` is shared through the ring's acquire/release protocol
  // (a slot belongs to the producer from `tail` to `head`, to the meter queue
  // from `head` back to `tail`), and `consumerMeter`/`consumerSession` are
  // confined to `meterQueue`. Everything else is atomic or under a Mutex.

  /// The capture's fixed embedded-audio format: 48 kHz, 2 channels, Int32.
  /// Only what the meters show runs: true peak (and the sample peak behind
  /// the clip count), R 128 loudness and phase correlation; no RMS, VU or PPM.
  static let configuration = AudioMeterConfiguration(
    sampleRate: EmbeddedAudioFormat.sampleRate, channelCount: EmbeddedAudioFormat.channelCount,
    meters: [.samplePeak, .truePeak, .loudness, .correlation])

  /// A take's own meter: what its summary reports (integrated loudness, Max
  /// TP) and its over watch needs (true peak, and the sample peak's clip count).
  static let takeConfiguration = AudioMeterConfiguration(
    sampleRate: EmbeddedAudioFormat.sampleRate, channelCount: EmbeddedAudioFormat.channelCount,
    meters: [.samplePeak, .truePeak, .loudness])

  private static let identities = Atomic<UInt64>(0)

  /// Unique to this tap for the life of the process. Views key on it: an
  /// `ObjectIdentifier` can come back for a new tap at a freed one's address
  /// (a camera removed and added again), which would keep a view attached to
  /// the old tap.
  let identity: UInt64 = AudioMeterTap.identities.add(1, ordering: .relaxed).newValue

  /// Packets the hand-off holds before the meters coalesce: 4096 DeckLink
  /// callbacks, 68 s at 59.94p and 137 s at 29.97p. The slots are
  /// preallocated (about 48 B each, 192 KB in all); a packet's samples are
  /// only retained while it waits.
  static let defaultPacketCapacity = 4096

  /// The meters' owner; `attach` and `detach`, and the meter queue when a
  /// packet of a new session arrives. Never the driver thread.
  private struct Sessions {
    /// The current session's meter; nil until the first attach.
    var live: AudioMeter?
    /// Starts at 0 (no session); each session start adds one.
    var number: UInt64 = 0
    /// Meters retained by session number until the meter queue first adopts them.
    var history: [UInt64: AudioMeter] = [:]
  }

  /// One handed-over packet. Producer-written from `tail` to `head`, read and
  /// cleared by the meter queue.
  private struct Slot {
    var samples: Data?
    var frames = 0
    var stride = 0
    var session: UInt64 = 0
    var followsGap = false
  }

  private let sessions = Mutex(Sessions())
  /// `sessions.number` for the driver thread; stored under `sessions`.
  private let session = Atomic<UInt64>(0)
  /// Changed only under `sessions`.
  private let viewers = Atomic<Int>(0)
  private let producing = Atomic<Bool>(false)

  // The hand-off ring. `head` and `tail` count packets from the start and
  // never wrap in practice (Int is 64-bit); a slot index is the count masked.
  private let slots: UnsafeMutablePointer<Slot>
  private let packetCapacity: Int
  private let slotMask: Int
  /// Next packet the producer writes; stored only by the producer.
  private let head = Atomic<Int>(0)
  /// Next packet the meter queue reads; stored only by the meter queue.
  private let tail = Atomic<Int>(0)
  /// A packet was left out (ring full, refused or overlapped): the next packet
  /// handed over follows a gap.
  private let gapPending = Atomic<Bool>(false)

  /// The meters' own serial queue, below the capture queues' QoS.
  let meterQueue = DispatchQueue(label: "org.ultracam.capture.audio-meter", qos: .userInitiated)
  private let wake: any DispatchSourceUserDataAdd

  // Meter queue only: the session being metered, held strongly here so a
  // session start on the main thread never releases a meter in use.
  private var consumerMeter: AudioMeter?
  private var consumerSession: UInt64 = 0

  /// Meter queue only: what the live meter's over watch saw last.
  private var overWatch = OverWatch()
  /// Meter queue only: the over log's rate limit.
  private var overLog = OverLogLimiter()
  /// Meter queue only: a flush of held-back overs is scheduled.
  private var overLogFlushScheduled = false
  /// Meter queue only: the take meter's over watch, and the last packet the take metered.
  private var takeWatch = OverWatch()
  private var lastTakePacket: Int?
  /// Overs since the tap was made (see `OverWatch`).
  private let overEvents = Atomic<UInt64>(0)
  /// The last over line logged (`lastOverReport`).
  private let lastReport = Mutex<String?>(nil)
  /// The camera the over log names (`setCameraName`).
  private let cameraName = Mutex<String?>(nil)
  /// The capture's latest source timecode, read when an over is logged.
  private let timecodeSource = Mutex<(@Sendable () -> String?)?>(nil)
  /// The take being measured, if any.
  private let take = Mutex<TakeState?>(nil)
  /// Numbers the takes, so the meter queue tells one take's meter from the next.
  private let takeNumbers = Atomic<UInt64>(0)

  private let metered = Atomic<UInt64>(0)
  private let rejected = Atomic<UInt64>(0)
  private let overlapped = Atomic<UInt64>(0)
  private let coalesced = Atomic<UInt64>(0)
  private let stale = Atomic<UInt64>(0)
  private let maxQueued = Atomic<Int>(0)

  /// `packetCapacity` is rounded up to a power of two.
  init(packetCapacity: Int = AudioMeterTap.defaultPacketCapacity) {
    var capacity = 1
    while capacity < max(1, packetCapacity) { capacity <<= 1 }
    self.packetCapacity = capacity
    slotMask = capacity - 1
    slots = UnsafeMutablePointer<Slot>.allocate(capacity: capacity)
    slots.initialize(repeating: Slot(), count: capacity)
    wake = DispatchSource.makeUserDataAddSource(queue: meterQueue)
    wake.setEventHandler { [weak self] in self?.drainRing() }
    wake.activate()
  }

  deinit {
    // A running handler holds `self`, so none is running here; later events find it gone.
    wake.cancel()
    slots.deinitialize(count: packetCapacity)
    slots.deallocate()
  }

  // MARK: Driver thread

  /// Hands one packet to the meters, if a view is showing them. Driver thread only.
  func ingest(_ audio: CaptureRawAudio) {
    ingest(samples: audio.samples, sampleFrames: audio.sampleFrames, channels: audio.channels,
      bytesPerSample: audio.bytesPerSample)
  }

  func ingest(samples: Data?, sampleFrames: UInt64, channels: Int, bytesPerSample: Int) {
    // Acquiring: a viewer seen here implies its session in `session`.
    guard viewers.load(ordering: .acquiring) > 0, let samples else { return }
    let meterChannels = Self.configuration.channelCount
    guard bytesPerSample == EmbeddedAudioFormat.sourceBytesPerSample, channels >= meterChannels,
      sampleFrames > 0, sampleFrames <= UInt64(Int.max / (channels * bytesPerSample)),
      samples.count >= Int(sampleFrames) * channels * bytesPerSample
    else {
      rejected.add(1, ordering: .relaxed)
      gapPending.store(true, ordering: .relaxed)
      return
    }
    guard !producing.exchange(true, ordering: .acquiring) else {
      overlapped.add(1, ordering: .relaxed)
      gapPending.store(true, ordering: .relaxed)
      return
    }
    let next = head.load(ordering: .relaxed)
    // Acquiring: the meter queue released the slot (and its packet) before moving `tail` past it.
    let queued = next &- tail.load(ordering: .acquiring)
    if queued >= packetCapacity {
      coalesced.add(1, ordering: .relaxed)
      gapPending.store(true, ordering: .relaxed)
    } else {
      let slot = slots + (next & slotMask)
      // The slot is empty (the meter queue cleared it), so this only retains the packet.
      slot.pointee.samples = samples
      slot.pointee.frames = Int(sampleFrames)
      slot.pointee.stride = channels
      slot.pointee.session = session.load(ordering: .acquiring)
      slot.pointee.followsGap = gapPending.exchange(false, ordering: .relaxed)
      // Releasing: the slot's contents before the meter queue can see it.
      head.store(next &+ 1, ordering: .releasing)
      if queued + 1 > maxQueued.load(ordering: .relaxed) { maxQueued.store(queued + 1, ordering: .relaxed) }
      wake.add(data: 1)
    }
    producing.store(false, ordering: .releasing)
  }

  // MARK: Meter queue

  /// Meters every packet handed over so far. Meter queue only; the wake-up
  /// events coalesce, so one call may meter several packets.
  private func drainRing() {
    var next = tail.load(ordering: .relaxed)
    // Acquiring: the producer's slot contents up to `end`.
    let end = head.load(ordering: .acquiring)
    guard next != end else { return }
    // Once per drain, not per packet: the take, if one is running and not paused.
    let currentTake = take.withLock { state in
      state.flatMap { $0.paused ? nil : (meter: $0.meter, number: $0.number, start: $0.startPacket) }
    }
    while next != end {
      let slot = slots + (next & slotMask)
      let packetSession = slot.pointee.session
      // Sessions only move forward: an older packet is stale without a look at the sessions.
      if packetSession > consumerSession {
        // If this is the first packet drained after a rapid attach/detach cycle,
        // adopt the packet's own session. Once the consumer has advanced, use
        // the current session so packets from sessions it passed are stale.
        if consumerSession == 0, let meter = sessions.withLock({
          let meter = $0.history[packetSession]
          // The first drain establishes the consumer's session. Older meters
          // are no longer reachable by queued packets after this point.
          $0.history.removeAll(keepingCapacity: true)
          return meter
        }) {
          consumerMeter = meter
          consumerSession = packetSession
        } else {
          adoptCurrentSession()
        }
      }
      if packetSession == consumerSession, let meter = consumerMeter, let samples = slot.pointee.samples {
        if slot.pointee.followsGap { meter.noteDiscontinuity() }
        let frames = slot.pointee.frames
        let stride = slot.pointee.stride
        samples.withUnsafeBytes { raw in
          guard let base = raw.baseAddress else { return }
          meter.process(interleaved: base.assumingMemoryBound(to: Int32.self), frameCount: frames,
            frameStride: stride)
        }
        metered.add(1, ordering: .relaxed)
        watchForOvers(meter)
      } else {
        stale.add(1, ordering: .relaxed)
      }
      // The take's own meter, from the packet the take started at.
      if let currentTake, next >= currentTake.start, let samples = slot.pointee.samples {
        let takeMeter = currentTake.meter
        // A gap in the stream, or audio left out while the take was paused.
        if slot.pointee.followsGap || (lastTakePacket.map { $0 != next &- 1 } ?? false) { takeMeter.noteDiscontinuity() }
        let frames = slot.pointee.frames
        let stride = slot.pointee.stride
        samples.withUnsafeBytes { raw in
          guard let base = raw.baseAddress else { return }
          takeMeter.process(interleaved: base.assumingMemoryBound(to: Int32.self), frameCount: frames,
            frameStride: stride)
        }
        lastTakePacket = next
        if takeWatch.observe(takeMeter.snapshot(), source: currentTake.number) != nil {
          take.withLock { state in
            if state?.number == currentTake.number { state?.overs += 1 }
          }
        }
      }
      // The packet is released here, never on the driver thread.
      slot.pointee.samples = nil
      next &+= 1
      // Releasing: the slot is clear before the producer can reuse it.
      tail.store(next, ordering: .releasing)
    }
  }

  /// Takes the current session's meter for the packets of that session; any
  /// packet of an earlier one is stale. Meter queue only; at most once per
  /// session start.
  private func adoptCurrentSession() {
    let current = sessions.withLock { sessions in
      let current = (sessions.live, sessions.number)
      // Once the consumer advances, queued packets from earlier sessions are
      // intentionally stale; release their retained meters promptly.
      sessions.history.removeAll(keepingCapacity: true)
      return current
    }
    consumerMeter = current.0
    consumerSession = current.1
  }

  /// Looks for a new over after each packet (`OverWatch.observe`): a sample
  /// clipped, the true-peak maximum rose to −1 dBTP or above, or the true-peak
  /// bar is there. Overs on a channel less than a second (of audio) apart are
  /// one over. Each new one counts in `overCount` and is logged, at most one
  /// line a second; overs held back are counted in the next line, or in a line
  /// of their own a second after the last if no other over follows. Meter queue only.
  private func watchForOvers(_ meter: AudioMeter) {
    let snapshot = meter.snapshot()
    guard let event = overWatch.observe(snapshot, source: consumerSession) else { return }
    overEvents.add(1, ordering: .relaxed)
    let now = DispatchTime.now().uptimeNanoseconds
    let timecode = timecodeSource.withLock { $0 }?()
    guard let suppressed = overLog.offer(now: now, timecode: timecode) else {
      scheduleOverLogFlush(now: now)
      return
    }
    let message = Self.overMessage(
      camera: cameraName.withLock { $0 }, channel: event.channel, channels: min(snapshot.channelCount, OverWatch.channels),
      level: Double(event.level), clips: event.clips, timecode: timecode, suppressed: suppressed)
    audioLog.notice("\(message, privacy: .public)")
    lastReport.withLock { $0 = message }
  }

  /// Logs the overs the rate limit held back once their second is up, so a
  /// burst's last overs reach the log even when no over follows them, or the
  /// metering stops. Meter queue only.
  private func scheduleOverLogFlush(now: UInt64) {
    guard !overLogFlushScheduled else { return }
    overLogFlushScheduled = true
    let wait = overLog.nanosecondsUntilFlush(now: now)
    meterQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: wait))) { [weak self] in
      self?.flushOverLog()
    }
  }

  private func flushOverLog() {
    overLogFlushScheduled = false
    let now = DispatchTime.now().uptimeNanoseconds
    if let held = overLog.flush(now: now) {
      let message = Self.heldOversMessage(camera: cameraName.withLock { $0 }, count: held.count, lastTimecode: held.timecode)
      audioLog.notice("\(message, privacy: .public)")
      lastReport.withLock { $0 = message }
    } else if overLog.suppressed > 0 {
      scheduleOverLogFlush(now: now)
    }
  }

  /// Waits until the meter queue has metered every packet handed over before
  /// this call. For tests, verification and the end of a take; never from the
  /// driver thread.
  func waitUntilMetered() {
    meterQueue.sync { drainRing() }
  }

  // MARK: Any thread

  /// A view starts showing the meters, and gets the meter to show. The first
  /// viewer starts a new session on a new meter; later ones share it.
  @discardableResult func attach() -> AudioMeter {
    sessions.withLock { sessions in
      if viewers.load(ordering: .relaxed) == 0 { startSession(&sessions) }
      viewers.add(1, ordering: .releasing)
      guard let live = sessions.live else { preconditionFailure("A metering session has no meter") }
      return live
    }
  }

  /// A view stopped showing the meters; the last one stops the metering.
  /// Never goes below zero, so an unpaired call cannot stop another view's meters.
  func detach() {
    sessions.withLock { _ in
      if viewers.load(ordering: .relaxed) > 0 { viewers.subtract(1, ordering: .relaxed) }
    }
  }

  /// Installs a new meter and session number. The meter queue picks it up at
  /// the first packet of the session and keeps the meter it was using alive
  /// until then.
  private func startSession(_ sessions: inout Sessions) {
    let meter: AudioMeter
    do {
      meter = try AudioMeter(configuration: Self.configuration)
    } catch {
      preconditionFailure("The embedded-audio meter configuration is invalid: \(error)")
    }
    sessions.live = meter
    sessions.number &+= 1
    sessions.history[sessions.number] = meter
    session.store(sessions.number, ordering: .releasing)
  }

  var isMetering: Bool { viewers.load(ordering: .relaxed) > 0 }

  /// Views (and a take) holding the meters; for checks that views pair attach and detach.
  var viewerCount: Int { viewers.load(ordering: .relaxed) }

  /// Overs seen since the tap was made, while metering (a second apart per channel).
  var overCount: UInt64 { overEvents.load(ordering: .relaxed) }

  /// The last line the over log wrote; nil before the first over. Any thread.
  var lastOverReport: String? { lastReport.withLock { $0 } }

  /// The camera the over log names. Any thread; cheap when unchanged.
  func setCameraName(_ name: String?) {
    cameraName.withLock { if $0 != name { $0 = name } }
  }

  /// Where the over log reads the source timecode: the capture's latest
  /// RP188 label, read on the meter queue when an over is logged (never on
  /// the driver thread). Set once by the capture.
  func setTimecodeSource(_ source: @escaping @Sendable () -> String?) {
    timecodeSource.withLock { $0 = source }
  }

  /// The audio the next packet brings does not follow the last one (the
  /// capture restarted): the meters prime their filters there instead of
  /// interpolating across the gap. Any thread.
  func noteGap() {
    gapPending.store(true, ordering: .relaxed)
  }

  // MARK: Takes

  /// A take started. It meters on a meter of its own from the next packet
  /// handed over, whether or not a view shows the meters, so its loudness,
  /// Max TP and overs are its own: no view's reset changes them. The views'
  /// meters start their peaks, over latch and loudness over too, so what they
  /// show from here is the take. Main thread. A second call during a take
  /// starts it over.
  func beginTake() {
    let meter: AudioMeter
    do {
      meter = try AudioMeter(configuration: Self.takeConfiguration)
    } catch {
      preconditionFailure("The take meter configuration is invalid: \(error)")
    }
    let start = head.load(ordering: .acquiring)
    let number = takeNumbers.add(1, ordering: .relaxed).newValue
    let restarted = take.withLock { state -> Bool in
      let running = state != nil
      state = TakeState(meter: meter, number: number, startPacket: start)
      return running
    }
    // The take keeps the stream metered; a restart already holds its viewer.
    let live = restarted ? self.meter : attach()
    live?.resetPeaks()
    live?.resetLoudness()
  }

  /// Leaves the audio out of the take while it is paused (`true`) and takes it
  /// in again on resume. Main thread; a no-op without a take.
  func pauseTake(_ paused: Bool) {
    take.withLock { $0?.paused = paused }
  }

  /// The running take's numbers so far; nil without a take. Any thread.
  func takeSummarySoFar() -> AudioTakeSummary? {
    take.withLock { $0 }.map(Self.summary)
  }

  /// The take ended: its integrated loudness, maximum true peak and overs,
  /// after the audio already handed over is metered. The metering it held
  /// stops. Nil when no take was running. Main thread.
  func endTake() -> AudioTakeSummary? {
    guard take.withLock({ $0 != nil }) else { return nil }
    // Normally the ring is empty and this is a few microseconds. `flush`
    // publishes the take meter's last few milliseconds; producer (meter queue) only.
    meterQueue.sync {
      drainRing()
      take.withLock { $0?.meter }?.flush()
    }
    guard let state = take.withLock({ state -> TakeState? in
      defer { state = nil }
      return state
    }) else { return nil }
    detach()
    return Self.summary(state)
  }

  private static func summary(_ state: TakeState) -> AudioTakeSummary {
    let snapshot = state.meter.snapshot()
    return AudioTakeSummary(
      integrated: Double(snapshot.loudness.integrated), maximumTruePeak: Double(snapshot.programmeMaximumTruePeak),
      overs: state.overs, duration: snapshot.loudness.duration)
  }

  /// The current (or last) session's meter; nil before the first attach.
  var meter: AudioMeter? { sessions.withLock { $0.live } }

  /// Packets handed over and not yet metered.
  var queuedPackets: Int { max(0, head.load(ordering: .acquiring) &- tail.load(ordering: .acquiring)) }

  struct Counters: Sendable, Equatable {
    /// Packets the meter processed.
    var metered: UInt64
    /// Packets refused for their format (not 32-bit, fewer than 2 channels, short data).
    var rejected: UInt64
    /// Packets skipped because another driver thread was handing one over at the same time.
    var overlapped: UInt64
    /// Packets left out of the meters because the hand-off ring was full (the
    /// meter queue was `packetCapacity` packets behind). Recording and video
    /// never miss these; only the meters do, and they note the gap. Counts
    /// over the tap's whole life; the capture publishes its own share.
    var coalesced: UInt64
    /// Packets of a session the meter queue had already moved past, dropped.
    var stale: UInt64
    /// The most packets the ring has held at once.
    var maxQueued: Int
  }

  var counters: Counters {
    Counters(metered: metered.load(ordering: .relaxed), rejected: rejected.load(ordering: .relaxed),
      overlapped: overlapped.load(ordering: .relaxed), coalesced: coalesced.load(ordering: .relaxed),
      stale: stale.load(ordering: .relaxed), maxQueued: maxQueued.load(ordering: .relaxed))
  }
}
