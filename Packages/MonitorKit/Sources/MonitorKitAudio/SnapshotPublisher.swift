import Synchronization

/// A single-writer, multi-reader sequence lock over a bitwise-copyable value.
/// `Value` must accept any bit pattern (no Bool or enum fields): a rejected
/// torn copy is still written into the reader's variable before the retry.
///
/// The value lives in atomic 64-bit words, so a reader racing the writer is
/// never a data race: it may see a torn mix of words, but the sequence check
/// rejects that and it retries. The writer never waits (H.-J. Boehm, "Can
/// seqlocks get along with programming language memory models?", MSPC 2012).
final class SnapshotPublisher<Value: BitwiseCopyable>: @unchecked Sendable {
  // @unchecked: `words` is only touched through atomics; the raw pointer is
  // allocated in init and freed in deinit.
  private let sequence = Atomic<UInt64>(0)
  private let words: UnsafeMutablePointer<Atomic<UInt64>>
  private let wordCount: Int

  init(_ initial: Value) {
    wordCount = (MemoryLayout<Value>.size + 7) / 8
    words = .allocate(capacity: wordCount)
    for i in 0..<wordCount { (words + i).initialize(to: Atomic(0)) }
    var value = initial
    publish(&value)
  }

  deinit {
    words.deinitialize(count: wordCount)
    words.deallocate()
  }

  /// Producer only. Wait-free.
  func publish(_ value: inout Value) {
    let s = sequence.load(ordering: .relaxed)
    sequence.store(s &+ 1, ordering: .relaxed)
    // Orders the odd sequence before the payload stores.
    atomicMemoryFence(ordering: .releasing)
    withUnsafeBytes(of: &value) { bytes in
      let full = bytes.count / 8
      forEachIndex(full) { i in
        words[i].store(bytes.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self), ordering: .relaxed)
      }
      if full < wordCount {
        var tail: UInt64 = 0
        withUnsafeMutableBytes(of: &tail) { t in
          t.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[(full * 8)...]))
        }
        words[full].store(tail, ordering: .relaxed)
      }
    }
    sequence.store(s &+ 2, ordering: .releasing)
  }

  /// Any thread. Retries only while a publish overlaps the copy (a few hundred ns).
  func read(into value: inout Value) {
    while true {
      let s1 = sequence.load(ordering: .acquiring)
      if s1 & 1 == 0 {
        withUnsafeMutableBytes(of: &value) { bytes in
          let full = bytes.count / 8
          forEachIndex(full) { i in
            bytes.storeBytes(of: words[i].load(ordering: .relaxed), toByteOffset: i * 8, as: UInt64.self)
          }
          if full < wordCount {
            var tail = words[full].load(ordering: .relaxed)
            withUnsafeBytes(of: &tail) { t in
              UnsafeMutableRawBufferPointer(rebasing: bytes[(full * 8)...])
                .copyMemory(from: UnsafeRawBufferPointer(rebasing: t[..<(bytes.count - full * 8)]))
            }
          }
        }
        // Orders the payload loads before the confirming sequence load.
        atomicMemoryFence(ordering: .acquiring)
        if sequence.load(ordering: .relaxed) == s1 { return }
      }
    }
  }

  /// Publishes so far; the reader can skip work when this has not changed.
  var publishCount: UInt64 { sequence.load(ordering: .acquiring) / 2 }
}
