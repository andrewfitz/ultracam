import Foundation

enum PluginError: Error, LocalizedError, Equatable, Sendable {
  case unavailable(String), unsupported(String), busy(String), invalidState(String), failed(String)
  var errorDescription: String? {
    switch self {
    case .unavailable(let message), .unsupported(let message), .busy(let message), .invalidState(let message), .failed(let message): return message
    }
  }
}
