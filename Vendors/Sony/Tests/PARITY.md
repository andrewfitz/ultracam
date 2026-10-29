# Sony software parity coverage

The software suite runs the live `CameraControlStore`, `SonyControlPlugin`,
`CameraControlKeychain`, and generic camera-control SwiftUI views. `NativeModels`
contains native JSON fixtures and argument adapters only. It contains no store,
SDK scheduling, credential storage, or UI implementation.

The original behavioral checks remain in `main.swift`: lazy discovery and its
30-second cache (including empty results), shared in-flight scans, manual-IP
candidate/friendly-name continuity, assignment persistence, secret exclusion,
exclusive assignment, invalidation during reads, supported and rejected writes,
disconnect/reconnect, fingerprint pinning, DHCP changes, removal races, credential
restoration, explicit reconnect/forget, Keychain failure handling, deletion/read
serialization, and shutdown admission/coalescing. Optional invisible snapshots
exercise the live generic settings and overlay in light/dark appearances.

Reviewed contract changes reflected in the port:

- Identity and fingerprint resolve before credentials are loaded. A missing or
  locked vault may follow a discovery, but must never cause a connection with
  empty credentials. A changed pin causes zero credential loads. Each saved
  camera is independently verified before releasing its credential.
- Native feed keys are generation-specific. Callback fixtures use the actual
  native key; callbacks with no live generation cannot invalidate discovery.
- A fresh connection no longer unconditionally disconnects an unrelated native
  feed key first. Removal/quit races hold identity preparation instead, asserting
  that late preparation cannot start an orphan connection. Removal during an
  already admitted connection separately verifies release of its late handle.
- Reset persists a valid empty generic assignment envelope, preserving the
  one-time migration marker rather than deleting the generic envelope.
- UI assertions use the production neutral control labels, retaining checks for
  name-only primary labels, explicit Rescan/manual preparation, cached values,
  overlay, accessible fields and settings actions.

`Credentials.swift` retains normalized identity, pin isolation, secret redaction,
round-trip/update/delete, and signed helper process modes. Actual Keychain access
requires explicit `--keychain`; it uses a random test service and additionally
seeds the legacy encrypted payload keys to verify continuity through the live
Keychain implementation. Automated checks never use the production Keychain.

`Native.mm` retains SDK value/formatting, network parser bounds, callback filtering,
coalescing and native lifetime checks. `SonyPluginChecks.swift` separately covers
UInt64.max, generation cleanup/retry, pending-cleanup exclusivity, SDK absence,
manual identity mismatch, metadata, and the combined camera-side HDMI toggle.
