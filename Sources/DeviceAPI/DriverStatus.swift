import Foundation

struct DriverStatus: Equatable, Sendable {
  let installed: Bool
  let supported: Bool
  let version: String?
  let reason: String?
  /// The driver as people know it, with its version ("Desktop Video 16.4"), from its plugin.
  var title: String? = nil
}
