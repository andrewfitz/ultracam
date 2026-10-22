import MonitorToolsCore
import SwiftUI

public struct MonitorDiagnosticsView: View {
  public let snapshot: MonitorDiagnostics
  public let surfaceScopeTiming: String
  public let presentationEstimate: String
  public init(
    snapshot: MonitorDiagnostics, surfaceScopeTiming: String, presentationEstimate: String
  ) {
    self.snapshot = snapshot
    self.surfaceScopeTiming = surfaceScopeTiming
    self.presentationEstimate = presentationEstimate
  }
  public var body: some View {
    DisclosureGroup("Monitoring diagnostics") {
      VStack(alignment: .leading, spacing: 3) {
        Text("Shared target live rates")
        Text(
          "Picture cap \(rate(snapshot.requestedPictureHz)) Hz · source offers \(rate(snapshot.offeredFPS)) fps · delivered \(rate(snapshot.pictureFPS)) fps"
        )
        Text(
          "Scopes requested \(snapshot.requestedScopeHz) Hz · effective cap \(snapshot.effectiveQuality.scopeRefreshHz) Hz · delivered \(rate(snapshot.scopeFPS)) fps"
        )
        Text(
          "\(snapshot.effectiveQuality.label) · picture ≤\(snapshot.effectiveQuality.pictureHeightLimit)p · scope sample stride \(snapshot.effectiveQuality.scopeSamplingStride)"
        )
        Text(availability)
        Text(
          "Offers \(snapshot.offeredFrames) · admitted \(snapshot.admittedFrames) · skipped \(snapshot.skippedFrames) · rejected \(snapshot.rejectedResults)"
        )
        Text(
          "Shared monitor budget: \(bytes(snapshot.retainedBytes)) retained, \(bytes(snapshot.retiredBytes)) retiring"
        )
        Text("Picture age deadline (250 ms): \(deadline)")
        Text("This surface: \(surfaceScopeTiming)")
        if !presentationEstimate.isEmpty {
          Text(presentationEstimate + " (estimate; existing native baseline excluded)")
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
    }.font(.caption2).foregroundStyle(.secondary)
  }
  private func rate(_ value: Double) -> String { String(format: "%.1f", value) }
  private func bytes(_ value: Int) -> String {
    String(format: "%.1f MiB", Double(value) / 1_048_576)
  }
  var deadline: String {
    switch snapshot.softDeadlineStatus {
    case .unavailable: return "unavailable"
    case .withinDeadline: return "within limit"
    case .exceeded: return "exceeded; last delivered picture is older than limit"
    }
  }
  private var availability: String {
    switch snapshot.availability {
    case .noSignal: return "No signal"
    case .starting: return "Starting"
    case .live: return "Live"
    case .paused: return "Paused / hidden"
    case .stale: return "Stale"
    case .unsupported(let reason), .degraded(let reason), .failed(let reason): return reason
    }
  }
}
