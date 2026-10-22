import MonitorToolsCore
import SwiftUI

public struct MonitorDiagnosticsView: View {
  public let snapshot: MonitorDiagnostics
  public let surfaceScopeTiming: String
  public init(snapshot: MonitorDiagnostics, surfaceScopeTiming: String) {
    self.snapshot = snapshot
    self.surfaceScopeTiming = surfaceScopeTiming
  }
  public var body: some View {
    DisclosureGroup("Monitoring diagnostics") {
      VStack(alignment: .leading, spacing: 3) {
        Text(
          "Camera \(rate(snapshot.requestedPictureHz)) Hz · offered \(rate(snapshot.offeredFPS)) fps · presented \(rate(snapshot.pictureFPS)) fps"
        )
        Text(
          "Scopes requested \(snapshot.requestedScopeHz) Hz · drawn \(rate(snapshot.scopeFPS)) fps · every pixel"
        )
        Text(
          "Scopes skipped: GPU busy \(snapshot.scopeSkippedBusy) · no drawable \(snapshot.scopeSkippedNoDrawable)"
        )
        Text("GPU per picture \(milliseconds(snapshot.gpuMilliseconds)) · per scope \(milliseconds(snapshot.scopeGPUMilliseconds))")
        Text(availability)
        Text(
          "Offered \(snapshot.offeredFrames) · presented \(snapshot.presentedFrames) · replaced before a refresh \(snapshot.supersededFrames) · failures \(snapshot.failures)"
        )
        Text("This surface: \(surfaceScopeTiming)")
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
    }.font(.caption2).foregroundStyle(.secondary)
  }
  private func rate(_ value: Double) -> String { String(format: "%.1f", value) }
  private func milliseconds(_ value: Double?) -> String {
    value.map { String(format: "%.2f ms", $0) } ?? "—"
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
