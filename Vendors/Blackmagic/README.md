# Blackmagic capture plugin

The permanent plugin ID is `decklink`. The adapter currently captures HDMI
3840 × 2160 v210 at 29.97 or 59.94 fps through Desktop Video 16 or later.
Automatic timing follows those supported source modes; this relocation adds
no capture formats.

`Sources/DeckLinkBackend.h` exposes Objective-C `UCDeckLinkBackend` to Swift as
`DeckLinkBackend`. Native SDK callbacks enter the adapter as complete ordered
groups; published buffers retain their SDK frame independently of session stop.

`SDK/include` contains the committed DeckLink SDK 16.0 macOS interfaces and
dispatch implementation. Preserve every upstream license block. See
`SDK/README.md` for redistribution and update details. The Desktop Video driver
provides the implementation at runtime; no vendor runtime dylib is bundled.

`Tests/BackendTestSupport.inc` is included only by the native backend under
`ULTRACAM_BACKEND_TESTING`; it must not be compiled as another translation unit.
Existing `UltracamRun…SyntheticChecks` exports remain stable for test callers.
