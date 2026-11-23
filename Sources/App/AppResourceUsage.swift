import Darwin
import Foundation

/// Completed Metal execution intervals from all Ultracam video command queues.
/// Overlap counts once, keeping the aggregate busy percentage within 0…100.
final class AppGPUActivity: @unchecked Sendable {
  static let shared = AppGPUActivity()
  private let lock = NSLock()
  private var intervals: [(Double, Double)] = []
  private var nextSlot = 0
  func record(start: Double, end: Double) {
    guard start.isFinite, end.isFinite, start > 0, end > start else { return }
    lock.withLock {
      if intervals.count < 2048 {
        intervals.append((start, end))
      } else {
        intervals[nextSlot] = (start, end)
        nextSlot = (nextSlot + 1) % intervals.count
      }
    }
  }
  func percent(now: Double, window: Double = 1) -> Double {
    let completed = lock.withLock { intervals }
    return Self.busyPercent(completed, from: now - window, to: now)
  }
  static func busyPercent(_ intervals: [(Double, Double)], from lower: Double, to upper: Double) -> Double {
    let duration = upper - lower
    guard duration.isFinite, duration > 0 else { return 0 }
    let clipped = intervals.compactMap { start, end -> (Double, Double)? in
      guard start.isFinite, end.isFinite else { return nil }
      let a = max(lower, start), b = min(upper, end)
      return b > a ? (a, b) : nil
    }.sorted { $0.0 < $1.0 }
    var lastEnd = lower, busy = 0.0
    for (start, end) in clipped {
      busy += max(0, end - max(start, lastEnd))
      lastEnd = max(lastEnd, end)
    }
    return min(100, max(0, busy / duration * 100))
  }
}

struct AppResourceUsage: Equatable, Sendable {
  var cpuPercent: Double?
  var gpuPercent: Double = 0
  var memoryBytes: UInt64?
}

struct AppResourceSampler {
  private var previousCPU: Double?
  private var previousTime: Double?
  mutating func sample() -> AppResourceUsage {
    var usage = rusage()
    let cpu: Double?
    if getrusage(RUSAGE_SELF, &usage) == 0 {
      cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    } else { cpu = nil }
    let now = ProcessInfo.processInfo.systemUptime
    var result = AppResourceUsage(gpuPercent: AppGPUActivity.shared.percent(now: now))
    if let cpu, let previousCPU, let previousTime, now > previousTime {
      result.cpuPercent = max(0, (cpu - previousCPU) / (now - previousTime) * 100)
    }
    previousCPU = cpu
    previousTime = now
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    if status == KERN_SUCCESS { result.memoryBytes = info.phys_footprint }
    return result
  }
}
