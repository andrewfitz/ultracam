// MonitorKitUI: the batteries-included tier.
//
// - `MonitorMetalView` (AppKit and UIKit): a CAMetalLayer view that draws a
//   `MonitorScene` (picture surfaces and scope overlays) at display rate, tags
//   its layer from `MonitorOutputColor` and tracks the EDR headroom.
// - `MonitorRenderer`: the view's drawable-free engine room, usable on its own
//   with any target texture and command buffer (classic or Metal 4). Per new
//   frame: one focus analysis per distinct analysis, one fused accumulation per
//   source's scope group (at each scope's `accumulationInterval`), then a single
//   render pass for every surface and scope; `encodePictures` + `encodeScopes`
//   take the accumulations out of the pictures' command buffer.
// - SwiftUI: `MonitorView`, `ScopeView`, `ScopeStackView` (several scopes of a
//   source in one renderer), `ClipReadout`, `AudioMeterView`,
//   `MonitorStatusOverlay` (host metadata: timecode, tally, format, LUT name,
//   labels; `MonitorOverlayModel` for video-rate values), legends (a list, or
//   the captioned monitor-chrome legend), the scope IRE scale
//   (`ScopeIREScaleView`), the tile toolbar (`MonitorTileToolbar`: tool
//   toggles and settings, false colour, magnify; scopes and Freeze through the
//   host's callbacks) and the control views, all editing `MonitorState`
//   through `normalized()`.
//
// This tier is the one exception to the zero-overhead contract's "host GPU
// objects" and "encode, never commit" rules: a view in convenience mode creates a
// command queue when the host gives it none, commits its own command buffers
// (pictures, then scopes; watching the last for completion) and an empty marker
// buffer, with one completion handler, when it goes idle.
// Nothing here creates a thread or a dispatch queue; the shared scope engine is
// compiled on a global queue.
import MonitorKit
import MonitorKitCore
