#if ULTRACAM_TEST_SUPPORT
import Foundation

enum ControlPluginConformanceHarness {
  enum Failure: Error { case violation(String) }
  @MainActor static func run(make: () -> any CameraControlPlugin, camera: ControlCamera) async throws {
    let plugin = make()
    guard plugin.descriptor.id == camera.pluginID else { throw Failure.violation("Control identity mismatch") }
    try await plugin.connect(feedID: "conformance", generation: 1, camera: camera, credentials: nil)
    try await plugin.disconnect(feedID: "conformance", generation: 1)
    try await plugin.disconnect(feedID: "conformance", generation: 1)
    try await plugin.connect(feedID: "conformance", generation: 2, camera: camera, credentials: nil)
    try await plugin.disconnect(feedID: "conformance", generation: 1)
    let properties = try await plugin.properties(feedID: "conformance", generation: 2)
    var ids = Set<String>()
    for property in properties {
      guard ids.insert(property.id).inserted, property.value.isValid else {
        throw Failure.violation("Invalid or duplicate advertised property")
      }
      if property.writable {
        try await plugin.set(property.id, value: property.value, feedID: "conformance", generation: 2)
      }
    }
    try await plugin.shutdown()
    do { _ = try await plugin.discover() } catch { return }
    throw Failure.violation("Control discovery admitted after shutdown")
  }
}
#endif
