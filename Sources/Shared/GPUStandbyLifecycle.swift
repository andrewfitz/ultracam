import CoreMedia
import CoreVideo
import Foundation

/// Queue-confined asynchronous standby cache. GPU resources belong to submitter;
/// callbacks retain only this cache weakly and return to its owning queue.
final class GPUStandbyLifecycle: @unchecked Sendable {
  typealias Submitter = (CMVideoFormatDescription, @escaping @Sendable (Result<GPUStandbyImage, Error>) -> Void) throws -> Void
  private let queue: DispatchQueue
  private let submit: Submitter
  private let ready: () -> Void
  private let failure: (String) -> Void
  private var generation = UUID()
  private var activeSubmission: UUID?
  private var desiredFormat: CMVideoFormatDescription?
  private var image: CVPixelBuffer?
  private(set) var failureCount: UInt64 = 0
  private(set) var lastError: String?

  init(queue: DispatchQueue, submit: @escaping Submitter, failure: @escaping (String) -> Void = { _ in }, ready: @escaping () -> Void) {
    self.queue = queue; self.submit = submit; self.failure = failure; self.ready = ready
  }

  func invalidate() {
    dispatchPrecondition(condition: .onQueue(queue))
    generation = UUID()
    desiredFormat = nil; image = nil; lastError = nil
  }

  func image(for format: CMVideoFormatDescription) -> CVPixelBuffer? {
    dispatchPrecondition(condition: .onQueue(queue))
    if let image { return image }
    // Invalidation retires a generation, not its Metal submission. Until that
    // submission completes, retain only the newest desired format; allocating
    // another image for each format change would retain unbounded IOSurfaces.
    desiredFormat = format
    guard activeSubmission == nil, lastError == nil else { return nil }
    let submission = UUID()
    activeSubmission = submission
    let token = generation
    do {
      try submit(format) { [weak self] result in
        guard let self else { return }
        self.queue.async { [weak self] in self?.complete(result, generation: token, submission: submission) }
      }
    } catch { activeSubmission = nil; fail(error) }
    return nil
  }

  private func complete(_ result: Result<GPUStandbyImage, Error>, generation token: UUID, submission: UUID) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard activeSubmission == submission else { return }
    activeSubmission = nil
    guard token == generation else {
      // A stopped runtime has no desired image. A restarted/renegotiated one
      // submits only its latest request after the prior GPU work has finished.
      if let desiredFormat { _ = image(for: desiredFormat) }
      return
    }
    switch result {
    case .success(let completed): image = completed.pixelBuffer; ready()
    case .failure(let error): fail(error)
    }
  }

  private func fail(_ error: Error) {
    failureCount &+= 1; lastError = String(describing: error)
    failure(lastError!)
  }
}
