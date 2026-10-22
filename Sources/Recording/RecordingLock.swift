import os

/// A short critical-section lock for the recording path. Unlike `NSLock`
/// (a pthread mutex), `os_unfair_lock` donates the waiter's priority to the
/// holder, so the capture thread is never stuck behind a preempted
/// lower-priority holder. Never hold it across encoder, GPU or file work.
final class RecordingLock: @unchecked Sendable {
  private let pointer: UnsafeMutablePointer<os_unfair_lock>

  init() {
    pointer = .allocate(capacity: 1)
    pointer.initialize(to: os_unfair_lock())
  }

  deinit {
    pointer.deinitialize(count: 1)
    pointer.deallocate()
  }

  func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
    os_unfair_lock_lock(pointer)
    defer { os_unfair_lock_unlock(pointer) }
    return try body()
  }
}
