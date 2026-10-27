import Foundation

struct DriverStatus: Equatable, Sendable {
  let installed: Bool
  let supported: Bool
  let version: String?
  let reason: String?
}
