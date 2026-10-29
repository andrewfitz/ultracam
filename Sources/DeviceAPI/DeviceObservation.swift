import Foundation

/// Main-actor delivery and cancellation share this token. Queued notifications
/// must call `deliver`, which checks cancellation immediately before invocation.
@MainActor final class DeviceObservation {
  private var handler: (@MainActor @Sendable (CaptureDeviceSnapshot) -> Void)?
  init(_ handler: @escaping @MainActor @Sendable (CaptureDeviceSnapshot) -> Void) { self.handler = handler }
  private var cleanup: (@MainActor @Sendable () -> Void)?
  func onCancel(_ cleanup: @escaping @MainActor @Sendable () -> Void) {
    guard handler != nil else { cleanup(); return }
    self.cleanup = cleanup
  }
  func cancel() {
    handler = nil
    let action = cleanup
    cleanup = nil
    action?()
  }
  deinit {
    let action = cleanup
    Task { @MainActor in action?() }
  }
  func deliver(_ snapshot: CaptureDeviceSnapshot) { handler?(snapshot) }
}
