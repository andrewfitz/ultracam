import Foundation

enum PluginError: Error, Equatable, Sendable {
  case unavailable(String), unsupported(String), busy(String), invalidState(String), failed(String)
}
