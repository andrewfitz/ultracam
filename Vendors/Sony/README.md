# Sony camera control

`Sources/SonyControlPlugin.swift` adapts the native Camera Remote SDK bridge to
`CameraControlPlugin`. It owns the bridge on the main actor; the native bridge
serializes every SDK call on its dedicated worker thread. A unique native feed
key belongs to each connection generation. Retired generations cannot change or
disconnect replacement connections, and pending cleanup retains camera ownership
until acknowledgement. Native callback owners remain alive when cleanup times out.

The credential service remains
`org.ultracam.sony-camera-control.credentials.v1`. Accounts retain the normalized
MAC address followed by the SHA-256 digest of the exact pinned fingerprint, so
existing Keychain entries remain readable. Property values and choices remain
unsigned 64-bit values across JSON and the generic API.

`Sources/SonyCameraControl.mm` is a standalone translation unit. Compile it once
per executable. Native white-box tests include this implementation directly and
must not also link a second Sony bridge object. The native bridge supports an
SDK-absent build; the plugin reports SDK availability in its descriptor.

`Tests/SonyPluginChecks.swift` exercises the adapter with an injected native
bridge subclass and does not contact cameras. `Tests/main.swift` runs the live
generic store and UI through a native stub; its assertion audit is in
`Tests/PARITY.md`. The credential, native, hardware and sandbox entry points are
also explicit test source lists, never part of the production source list.
`Tests/SonyLayoutChecks.py` verifies vendor ownership.

The optional local SDK is installed in `SDK/`; headers and libraries remain
ignored by Git. `Resources/SonyAssets.xcassets` owns the `SonyLogo` image name.
The app consumes this catalog through the vendor manifest, while the camera
extension never receives vendor sources, SDK libraries or resources.
