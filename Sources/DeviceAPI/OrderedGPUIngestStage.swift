import Foundation

/// Bounded ordered capture boundary. All envelopes (including format, clock,
/// audio and discontinuity events) enter this stage; only one transform runs
/// at once, so asynchronous GPU completion cannot overtake later metadata.
/// Rejection is explicit backpressure: callers must report a capture error.
final class OrderedGPUIngestStage<Input: Sendable, Output: Sendable>: @unchecked Sendable {
  struct Weight: Sendable {
    let bytes: Int
    let duration: TimeInterval
  }
  typealias Transform = @Sendable (Input, @escaping @Sendable (Result<Output, Error>) -> Void) -> Void
  private let queue = DispatchQueue(label: "org.ultracam.ordered-gpu-ingest")
  private let key = DispatchSpecificKey<UInt8>()
  private let capacity: Int
  private let minimumSlots: Int
  private let maximumBytes: Int
  private let maximumDuration: TimeInterval
  private let weight: @Sendable (Input) -> Weight
  private var retainedBytes = 0
  private var retainedDuration: TimeInterval = 0
  private let transform: Transform
  private let emit: @Sendable (Result<Output, Error>) -> Void
  private var pending: [(input: Input, weight: Weight)] = []
  private var active: UUID?
  private var closed = false

  init(capacity: Int, minimumSlots: Int = 0, maximumBytes: Int = Int.max,
       maximumDuration: TimeInterval = .infinity,
       weight: @escaping @Sendable (Input) -> Weight = { _ in Weight(bytes: 0, duration: 0) },
       transform: @escaping Transform,
       emit: @escaping @Sendable (Result<Output, Error>) -> Void) {
    precondition(capacity > 0 && minimumSlots >= 0 && minimumSlots <= capacity && maximumBytes >= 0 && maximumDuration > 0)
    self.minimumSlots = minimumSlots
    self.maximumBytes = maximumBytes
    // Match the capture admission budget's tolerance for sums of fractional frame durations.
    self.maximumDuration = maximumDuration.isFinite ? maximumDuration + maximumDuration.ulp * 4 : .infinity
    self.weight = weight
    self.capacity = capacity; self.transform = transform; self.emit = emit
    queue.setSpecific(key: key, value: 1)
  }

  @discardableResult func enqueue(_ input: Input) -> Bool {
    sync {
      let slots = pending.count + (active == nil ? 0 : 1)
      guard !closed, slots < capacity else { return false }
      let value = weight(input)
      let bytes = retainedBytes.addingReportingOverflow(value.bytes)
      let duration = retainedDuration + value.duration
      guard value.bytes >= 0, value.duration >= 0, value.duration.isFinite,
        !bytes.overflow, bytes.partialValue <= maximumBytes,
        duration.isFinite, (value.duration == 0 || duration <= maximumDuration || slots < minimumSlots) else { return false }
      retainedBytes = bytes.partialValue; retainedDuration = duration
      pending.append((input, value))
      startNext()
      return true
    }
  }

  /// Explicit terminal transition: discards prior pending/publication work,
  /// emits one terminal envelope, and suppresses all later completions. GPU
  /// resource lifetime still belongs to the active completion callback.
  func terminate(with output: Output) {
    sync {
      guard !closed else { return }
      closed = true; pending.removeAll(); active = nil
      retainedBytes = 0; retainedDuration = 0
      emit(.success(output))
    }
  }

  /// Stops publication immediately. The active transform and its GPU-owned
  /// resources still survive through their completion callback.
  func cancel() {
    sync { closed = true; pending.removeAll(); active = nil; retainedBytes = 0; retainedDuration = 0 }
  }

  private func startNext() {
    guard !closed, active == nil, !pending.isEmpty else { return }
    let (input, weight) = pending.removeFirst()
    let token = UUID(); active = token
    transform(input) { [self] result in
      queue.async { [self] in
        guard !closed, active == token else { return }
        active = nil
        retainedBytes -= weight.bytes
        // Summing the bounded backlog preserves small pending durations that
        // may have rounded away while a much longer frame was active.
        retainedDuration = pending.reduce(0) { $0 + $1.weight.duration }
        emit(result)
        startNext()
      }
    }
  }

  private func sync<T>(_ body: () -> T) -> T {
    if DispatchQueue.getSpecific(key: key) != nil { return body() }
    return queue.sync(execute: body)
  }
}
