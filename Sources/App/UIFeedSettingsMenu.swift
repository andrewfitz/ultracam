import SwiftUI

/// The paired body's output timing (what it sends over HDMI), as rows of the inspector's
/// Camera Control section. They were the signal badge's menu on the strip; the badge is gone,
/// the signal's format is on the picture, and what is set once is in the inspector.
struct UICameraOutputTimingRows: View {
    let cameraID: String
    let store: CameraControlStore

    var body: some View {
        let state = store.state(for: cameraID)
        if store.assignment(for: cameraID) != nil, state.connected {
            ForEach(state.properties.filter { $0.role == .outputTiming }) { property in
                if property.writable {
                    LabeledContent(property.localizedLabel()) {
                        UIControlPropertyField(property: property, connected: true, busy: state.busy) { value in
                            Task { await store.set(property, value: value, feedID: cameraID) }
                        }
                    }
                } else {
                    LabeledContent(property.localizedLabel()) { Text(UIControlPresentation.value(property)) }
                }
            }
        }
    }
}
