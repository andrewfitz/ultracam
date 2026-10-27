import Foundation

/// Main-actor delivery and cancellation share this token. Queued notifications
/// must call `deliver`, which checks cancellation immediately before invocation.
@MainActor final class DeviceObservation {
  private var handler: (@MainActor @Sendable (CaptureDeviceSnapshot) -> Void)?
  init(_ handler: @escaping @MainActor @Sendable (CaptureDeviceSnapshot) -> Void) { self.handler = handler }
  func cancel() { handler = nil }
  func deliver(_ snapshot: CaptureDeviceSnapshot) { handler?(snapshot) }
}
