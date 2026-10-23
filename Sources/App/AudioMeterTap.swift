import Dispatch
import Foundation
import MonitorKitAudio
import Synchronization

/// One capture's broadcast audio meters (MonitorKitAudio: sample and true peak,
/// RMS, VU, PPM and EBU R 128 loudness), fed from the embedded audio the
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
/// Backpressure: a full ring (the meter queue `packetCapacity` packets
/// behind, about two seconds of 60p callbacks by default) leaves the packet out
/// of the meters, counted in `Counters.coalesced`, and the next metered packet
/// is marked as following a gap, so the meter primes its true-peak
/// interpolator and K-weighting there (`AudioMeter.noteDiscontinuity()`)
/// instead of interpolating across missing audio. The driver thread never
/// waits for the meters.
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
/// The ring takes one producer at a time. The capture's generation guard
/// already rejects packets from a stopped stream; `producing` makes an overlap
/// of two driver threads (a restart racing the old stream's last packet) skip
/// that packet, counted, instead of corrupting the ring.
final class AudioMeterTap: @unchecked Sendable {
  // @unchecked: `slots` is shared through the ring's acquire/release protocol
  // (a slot belongs to the producer from `tail` to `head`, to the meter queue
  // from `head` back to `tail`), and `consumerMeter`/`consumerSession` are
  // confined to `meterQueue`. Everything else is atomic or under `sessions`.

  /// The capture's fixed embedded-audio format: 48 kHz, 2 channels, Int32.
  static let configuration = AudioMeterConfiguration(
    sampleRate: EmbeddedAudioFormat.sampleRate, channelCount: EmbeddedAudioFormat.channelCount)

  /// Packets the hand-off holds before the meters coalesce: 128 DeckLink
  /// callbacks, 2.1 s at 59.94p and 4.3 s at 29.97p.
  static let defaultPacketCapacity = 128

  /// The meters' owner; `attach` and `detach`, and the meter queue when a
  /// packet of a new session arrives. Never the driver thread.
  private struct Sessions {
    /// The current session's meter; nil until the first attach.
    var live: AudioMeter?
    /// Starts at 0 (no session); each session start adds one.
    var number: UInt64 = 0
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
    while next != end {
      let slot = slots + (next & slotMask)
      let packetSession = slot.pointee.session
      // Sessions only move forward: an older packet is stale without a look at the sessions.
      if packetSession > consumerSession { adoptCurrentSession() }
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
      } else {
        stale.add(1, ordering: .relaxed)
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
    let current = sessions.withLock { ($0.live, $0.number) }
    consumerMeter = current.0
    consumerSession = current.1
  }

  /// Waits until the meter queue has metered every packet handed over before
  /// this call. For tests and verification; never from the driver thread.
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
    session.store(sessions.number, ordering: .releasing)
  }

  var isMetering: Bool { viewers.load(ordering: .relaxed) > 0 }

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
    /// never miss these; only the meters do, and they note the gap.
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
