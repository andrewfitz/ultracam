import SwiftUI

/// Vendor UI receives snapshots and generic actions only, never AppModel or a store.
@MainActor struct ControlViewContext {
    let feedID: String
    let pluginID: String
    let properties: [ControlProperty]
    let connected: Bool
    let busy: Bool
    let message: String?
    let prepare: @MainActor (String, ControlPreparationRequest) async -> ControlPreparationResult?
    let connect: @MainActor (ControlCamera, ControlCredentials?, Bool) async -> Void
    let set: @MainActor (ControlProperty, ControlValue) async -> Void
    let refresh: @MainActor () async -> Void
}
typealias ControlViewFactory = @MainActor (ControlViewContext) -> AnyView
