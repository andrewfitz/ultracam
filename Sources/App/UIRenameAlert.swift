import SwiftUI

extension View {
  /// The one rename prompt. Every entry point (Camera menu, the strip's ⋯ menu,
  /// the inspector) sends `.beginRename(cameraID:)`; the main window applies this once.
  func uiRenameAlert(_ context: UIContext) -> some View {
    modifier(UIRenameAlert(context: context))
  }
}

private struct UIRenameAlert: ViewModifier {
  let context: UIContext
  @State private var nameDraft = ""

  private var camera: UICameraPresentation? { context.session.renamingCameraID.flatMap { context.camera($0) } }

  func body(content: Content) -> some View {
    content
      .alert("Rename \(camera?.name ?? "Camera")", isPresented: Binding(
        get: { camera != nil },
        set: { if !$0 && context.session.renamingCameraID != nil { context.send(.endRename) } })) {
        TextField("Name", text: $nameDraft)
        Button("Rename") {
          let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
          if let camera, !trimmed.isEmpty, trimmed != camera.name {
            context.send(.renameCamera(cameraID: camera.id, name: trimmed))
          } else {
            context.send(.endRename)
          }
        }
        Button("Cancel", role: .cancel) { context.send(.endRename) }
      } message: {
        // The camera extension keeps the device name it published until it restarts.
        Text("Meeting apps list the new name after Ultracam's camera restarts, for example after restarting your Mac.")
      }
      .onChange(of: context.session.renamingCameraID, initial: true) { _, id in
        nameDraft = id.flatMap { context.camera($0)?.name } ?? ""
      }
  }
}
