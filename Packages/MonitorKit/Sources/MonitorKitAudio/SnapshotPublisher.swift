// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Synchronization

/// A single-writer, multi-reader publisher over a bitwise-copyable value.
/// `Value` must accept any bit pattern (no Bool or enum fields): a rejected
/// torn copy is still written into the reader's variable before the retry.
///
/// The writer alternates between two slots, and readers use the last committed
/// slot even if the writer is suspended. A reader racing a later reuse of its
/// slot can see a torn mix of atomic words; the sequence check rejects it.
/// The writer never waits.
final class SnapshotPublisher<Value: BitwiseCopyable>: @unchecked Sendable {
  // @unchecked: `words` is only touched through atomics; the raw pointer is
  // allocated in init and freed in deinit.
  private let sequence = Atomic<UInt64>(0)
  private let words: UnsafeMutablePointer<Atomic<UInt64>>
  private let wordCount: Int

  init(_ initial: Value) {
    wordCount = (MemoryLayout<Value>.size + 7) / 8
    words = .allocate(capacity: 2 * wordCount)
    for i in 0..<(2 * wordCount) { (words + i).initialize(to: Atomic(0)) }
    var value = initial
    publish(&value)
  }

  deinit {
    words.deinitialize(count: 2 * wordCount)
    words.deallocate()
  }

  /// Producer only. Wait-free with the default hook. Tests can hold a
  /// publication just before the commit to model a suspended producer.
  func publish(_ value: inout Value, beforeCommit: () -> Void = {}) {
    let next = sequence.load(ordering: .relaxed) &+ 1
    let slot = words + Int(next & 1) * wordCount
    // Orders the previous commit before the payload stores. A reader that
    // sees a reused slot must also see that its publication was superseded.
    atomicMemoryFence(ordering: .releasing)
    withUnsafeBytes(of: &value) { bytes in
      let full = bytes.count / 8
      forEachIndex(full) { i in
        slot[i].store(bytes.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self), ordering: .relaxed)
      }
      if full < wordCount {
        var tail: UInt64 = 0
        withUnsafeMutableBytes(of: &tail) { t in
          t.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[(full * 8)...]))
        }
        slot[full].store(tail, ordering: .relaxed)
      }
    }
    beforeCommit()
    sequence.store(next, ordering: .releasing)
  }

  /// Any thread. Retries only when a new publication commits during the copy.
  func read(into value: inout Value) {
    while true {
      let committed = sequence.load(ordering: .acquiring)
      let slot = words + Int(committed & 1) * wordCount
      withUnsafeMutableBytes(of: &value) { bytes in
        let full = bytes.count / 8
        forEachIndex(full) { i in
          bytes.storeBytes(of: slot[i].load(ordering: .relaxed), toByteOffset: i * 8, as: UInt64.self)
        }
        if full < wordCount {
          var tail = slot[full].load(ordering: .relaxed)
          withUnsafeBytes(of: &tail) { t in
            UnsafeMutableRawBufferPointer(rebasing: bytes[(full * 8)...])
              .copyMemory(from: UnsafeRawBufferPointer(rebasing: t[..<(bytes.count - full * 8)]))
          }
        }
      }
      // Orders the payload loads before the confirming sequence load.
      atomicMemoryFence(ordering: .acquiring)
      if sequence.load(ordering: .relaxed) == committed { return }
    }
  }

  /// Publishes so far; the reader can skip work when this has not changed.
  var publishCount: UInt64 { sequence.load(ordering: .acquiring) }
}
