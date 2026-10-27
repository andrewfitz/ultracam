import Foundation

struct VendorDescriptor: Equatable, Sendable, Identifiable {
  let id: String
  let displayName: String
  let badgeText: String
  let signalHint: String?
  let sdkVersion: String?
  let sdkPresent: Bool
}
