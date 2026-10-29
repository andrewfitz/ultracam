# Vendor plugins

Ultracam compiles vendor integrations into its host app from `Vendors/<Vendor>/`.
There are no dynamically discovered plugin bundles. The current integrations
are Blackmagic DeckLink capture (`decklink`) and Sony camera control (`sony`).
A camera-control connection is assigned to a feed independently of its capture
device; connecting to an FX3 does not identify its HDMI cable or supply video.

The current production capture path still requires 3840 × 2160 HDMI, 10-bit
4:2:2, at 29.97 or 59.94 fps, with 48 kHz signed 32-bit embedded audio. The
shared types can describe more formats, but that does not make the app support
them. [Part B](SOURCE_FORMAT_PLAN.md) tracks wider input formats, clocks,
colourimetry and pipeline support. Output resize/colour/rate controls do not
change this input restriction. UVC, AJA and other vendor integrations are not
implemented.

B1c's bounded retention work and B1d's settings migration remain preparatory;
their scratch reviews are not production acceptance gates. B2's size/aspect
catalog expansion, including 1080p and 720p input, is not active. Do not infer
new capture modes from shared value types or focused helper tests.

## Boundaries and registry

[Sources/DeviceAPI](../Sources/DeviceAPI/) contains the app-only protocols,
registry, typed settings and control UI context. [Sources/Shared](../Sources/Shared/)
contains source-format, timing and other value types shared with the camera
extension. The extension must not compile or link vendor implementations, SDKs
or MonitorKit. Native adapters share constants through `DeviceAPI.h`.

`VendorRegistry` registers capture and control implementations explicitly.
Capture enumeration preserves each plugin's driver status and enumeration error
independently; a failed plugin must not hide another plugin's devices. Capture
device IDs use `<plugin-id>:<vendor-owned-id>`; existing IDs must remain stable.
The registry resolves the prefix when a feed starts. Settings policy is seeded
before discovery, rather than written as a side effect of capture start.

The host uses `AppHardware`, `CaptureServicesBridge` and `CameraControlStore`.
Vendor SDK types must stay behind the adapter. This remains one app module:
folder placement and manifest membership provide organization, not Swift
compiler access isolation. `python3 scripts/check-vendor-boundaries.py` checks
source text, known plugin/SDK/core symbols and actual generated Xcode target
membership. It rejects vendor imports/wording in core code, reverse dependencies
from plugins into the app, vendor/package dependencies in the extension, and
shipping fake sources. The generated bridge must exactly match the validated
manifest rendering. This catches known coupling; lexical checks cannot prove
every dependency or provide compiler/security isolation.

Exceptions are exact tokens or phrases, never whole-file escapes: named Sony
false-color identifiers/profile IDs/display phrases and local evaluation names;
the fixed FX3 LUT filename and safe-area phrase; original preview fixture input
names; exact settings migration keys/plugin IDs; and exact plist privacy and
entitlement service/comment strings. `VendorRegistry` permits concrete no-arg
`*CapturePlugin`/`*ControlPlugin` constructors only inside its static registration
arrays. Shared `VideoContract` duration values remain allowed. The script's
`COLOR` and `EXACT` definitions are the authoritative narrow exception list;
adding an SDK call beside an allowed phrase still fails.

## Capture contract

`CaptureSourcePlugin` provides its descriptor, driver status, devices and
observations, expected format, diagnostics, typed settings and session factory.
Driver installation and SDK-file availability are separate conditions. A
`DeviceObservation` is a main-actor cancellation handle; retain it while observing.

`CaptureSession.start` with the same configuration is idempotent and retains the
original handlers. Starting with a different configuration, or after stop, throws.
Create a new session to restart. `stop` is idempotent and is a quiescence barrier:
when it returns, no new delivery may begin. Never call it synchronously from a
delivery callback. Serialize lifecycle work away from callback delivery; do not
hold state locks while invoking consumers or draining callbacks.

Deliver events, frames, media and raw audio through one serialized stream.
`CaptureDelivery` carries a strictly increasing sequence, epoch ID, format
signature, clock bindings and mapping revision. Declare format and audio
presence/format before admitting dependent frames or audio. A source clock reset
or contract transition requires the appropriate ordered declaration and epoch;
a mapping refinement applies from its declared effective sequence. Preserve the
actual source timestamp rather than substituting callback arrival time. See
[SourceFormat.swift](../Sources/Shared/SourceFormat.swift) and the conformance
fixtures for the exact value definitions and validation.

Current clock mapping updates take effect on the immediately next delivery.
An event at sequence `N` retains the previous mapping revision in its envelope,
declares `effectiveSequence = N + 1`, and the next envelope must carry the new
revision. A sequence without a representable successor is refused. Later
future-effective updates and missing revision advances are refused before
media; the host does not accept them and overwrite a known pending estimate.
Mapping refinements change neither the source format signature nor its epoch;
replacing a clock instance requires a new epoch. Wider scheduled mapping
history belongs to the bounded clock work in Part B. Recording preserves genuine
clock IDs, revisions, effective sequences and supplied anchors as metadata;
this does not activate clock conversion or resampling.

`CapturedPixelBuffer` transfers immutable publication ownership of pixels and
attachments. Attach the SDK storage lease before publication. It must retain
storage independently of session stop, even when a consumer retains only the
raw pixel buffer; the lease must not retain that same buffer and create a cycle.
Consumers needing mutation allocate another output. `CaptureAudioPacket` owns
validated immutable PCM storage and its own timestamp; media carries optional
packet time and clock identity. Never invent audio timing from an adjacent video
frame when no packet timestamp exists.

A serialized callback contract does not promise unlimited lossless buffering.
Use bounded queues/pools, document overload admission, and distinguish device
loss from host drops. [The queue audit](PLUGIN_QUEUE_AUDIT.md) records the
current ownership and outstanding budget findings; it is not a claim that every
unbounded path has been closed. GPU work must retain its resources until Metal
completion, including stop/cancellation paths.

## Recording conversion and standby scope

**Allow CPU conversion (compatibility)** is a persisted, default-off Advanced
setting. A recording take snapshots `RecordingCompatibilityPolicy`; later UI
edits do not change that active take. With permission enabled, a missing native
route or GPU conversion failure may submit non-native input to VideoToolbox.
That system conversion may use CPU or GPU internally. The **Compatibility
conversion** badge and `systemCompatibilityFrames` counter deliberately describe
the observable route, not measured CPU execution. Diagnostics and take metadata
retain the sampled policy and conversion/failure/drop counters.

With compatibility disabled, admission refuses a missing required conversion
route. A subsequent GPU conversion failure drops that affected frame, records
the failure and continues the take. Compatibility permission does not remove
Metal 4 requirements, add B6 audio resampling, or activate wider capture formats.
Current recording audio remains resolved absence or paired 48 kHz interleaved
signed 32-bit stereo; arbitrary audio formats/clocks still need later routes.

`RecordingTakeSidecar.url(for:)` appends `ultracam.json` to the full movie name:
`Take.mov.ultracam.json`. Its append journal is
`Take.mov.ultracam.json.journal`. The recovery journal's `sidecarOwned` bit
authorizes metadata finalization, cleanup and copying to a recovered movie.
Recovery preserves the original pair and refuses occupied destination names;
it must never adopt or delete unrelated metadata merely because a filename
matches. Sidecar contract/clock records are not evidence that B6 resampling is
active.

The camera extension now uses `GPUStandbyProducer` through
`GPUStandbyLifecycle` in production. Preparation checks Metal 4 support and
pipeline creation before admitting a source consumer; completion precedes
immutable image publication. Allocation, plane mapping or execution failure is
reported, with no CPU fill or legacy Metal fallback. Focused proof on M4 Max
passed all 18 published format slots. Other GPU families remain unverified;
production activation on the available proof was explicitly approved without
claiming cross-device qualification.

`bash scripts/check-gpu-standby.sh` compiles and runs the standalone proof,
writing `compile.log`, `proof.log` and `evidence.json` under
`<artifact-root>/gpu-standby/<run-id>/`. `--build-only` compiles without running
GPU work. The helper uses the portable work-root resolver and does not install
or launch the app, activate an extension or open capture. Its focused receipt
does not substitute for pending broad strict/integration checks.

## Camera-control contract and UI

`CameraControlPlugin` discovers cameras, prepares a typed camera or endpoint
request, connects, reads/writes typed properties, disconnects and shuts down.
`ControlCamera` carries plugin identity, stable camera identity, transport,
address, fingerprint and authentication mode. `ControlValue` distinguishes signed
and unsigned integers, finite decimals, text, Boolean and choice values. Preserve
unsigned SDK values without narrowing. Property ranges/options and writability
come from the plugin; unsupported controls must not be fabricated.

Serialize SDK commands per feed across suspension points. Every queued operation
checks its connection generation before touching SDK state. Disconnect permanently
retires that generation, is repeatable, and must not affect a replacement.
Late callbacks and late connection replies cannot recreate retired assignments.
Events are ordered per feed; asynchronous task completion is not event ordering.
Shutdown closes admission; pending cleanup retains callback owners and reports
`cleanupPending` rather than pretending native ownership has ended.

The host's **Camera Control** sheet provides discovery, assignment, sign-in and
a generic property grid. Optional `ControlViewFactory` UI receives a
`ControlViewContext` of snapshots and generic actions, never the app model or
store. The generic grid hides `hidden` and `cameraDisplay` roles; the camera strip
exposes a writable Boolean `cameraDisplay` property as its **HDMI display**
toggle, using the plugin-provided label and generic property write action.
Sony-specific discovery, native property IDs and formatting stay in its plugin;
see [Sony setup](SONY_CONTROL.md). The Sony Keychain service remains
`org.ultracam.sony-camera-control.credentials.v1`; moving files must preserve
service/account derivation and existing credentials. Credentials are deliberately
not Codable; only the Keychain owner may encode them.

## Manifests and generated inputs

Each vendor owns `vendor.json`, sources, tests, optional resources, SDK files and
a README. Start from [Blackmagic](../Vendors/Blackmagic/vendor.json) or
[Sony](../Vendors/Sony/vendor.json), not a second handwritten build source list.
Schema version 1 describes:

| Field | Purpose |
|---|---|
| `id`, `kinds` | Stable vendor identity; `capture`, `control`, or both |
| `sources`, `resources` | Manifest-relative paths with explicit `app`/`test` membership |
| `publicHeaders` | Native headers for the generated app bridge |
| Search paths, frameworks, libraries, defines | Structured build inputs; no arbitrary shell flags |
| `embedLibraries` | Runtime dylib paths and destination subfolders |
| `sdk` | Root, policy, version, required files, checksums, `archiveLayout`, declared `externalDrivers` and conditional `enabledBuild` inputs |
| `tests`, `testGroups`, `testBuild` | Focused entry points and group-specific source/SDK inputs |
| `capabilities` | Required entitlement and Info.plist keys |

Paths resolve relative to the manifest and must remain within permitted roots.
Unknown fields, invalid memberships and escaping paths fail validation. Vendor
membership is app/test only, never extension. The schema reader is
[scripts/vendors.py](../scripts/vendors.py); inspect it before extending fields.

```sh
python3 scripts/vendors.py validate
python3 scripts/vendors.py status
python3 scripts/vendors.py generate
python3 scripts/vendors.py check-generated
python3 scripts/generate_project.py
```

Canonical generation treats optional Sony SDK support as absent even if it is
installed locally. To generate a local SDK-enabled configuration, provide an
explicit inventory JSON file containing `{"sony": true}` via
`generate_project.py --sdk-inventory /path/to/inventory.json` (or
`ULTRACAM_SDK_INVENTORY`). Do not commit a locally enabled generated project as
the canonical SDK-absent project. Generated inputs include the native bridge;
Xcode prebuild checks reject stale generated inputs.

Adding a vendor also requires explicit registry wiring, typed adapter behavior,
SDK provenance/terms, capability declarations and conformance tests. A manifest
alone does not register a runtime plugin or widen supported capture formats.

## SDKs, local builds and official releases

Blackmagic's committed SDK 16.0 interfaces live in `Vendors/Blackmagic/SDK/`;
Desktop Video supplies the runtime externally. Sony SDK 2.2.0 headers/libraries
live locally in ignored `Vendors/Sony/SDK/`. Install Sony's downloaded archive
with `python3 scripts/vendor-sdk.py install sony /path/to/CrSDK_Mac.zip`, then generate
explicit SDK-enabled local inputs as above. Preserve adapter subfolders and
upstream license blocks when replacing an SDK; verify manifest versions and
checksums against the replacement.

Source builds without Sony must explain that camera control is unavailable.
Local unsigned/debug workflows may omit it. Official releases require Sony,
valid signatures and recorded permission to redistribute every embedded runtime,
including adapter dependencies. The inspected installation lacks that license
evidence. [SDK_RELEASE_EVIDENCE.md](SDK_RELEASE_EVIDENCE.md) and
[THIRD_PARTY_LICENSES.md](../THIRD_PARTY_LICENSES.md) record the open gate.
Signing and SDK checks do not grant redistribution rights; notarization is a
separate distribution step after signing and submission. The consolidated SDK
CLI verifies manifest-pinned files and never downloads:

```sh
python3 scripts/vendor-sdk.py status
python3 scripts/vendor-sdk.py --json status sony
python3 scripts/vendor-sdk.py verify decklink
python3 scripts/vendor-sdk.py verify sony
python3 scripts/vendor-sdk.py install sony /path/to/CrSDK_Mac.zip
```

The vendor IDs are `decklink` and `sony`, not the folder names. `status` reports
availability and a reason, including optional missing SDKs; use `verify` when
a missing or mismatched SDK must fail the command. Installation accepts only
local-policy SDKs, so vendored DeckLink files are verified in place. It preserves
a fresh clone's README-only SDK directory, stages and verifies pinned payloads,
and refuses to replace an existing installed payload. The manifest's generic
`archiveLayout` maps nested archive paths into the SDK tree; Sony uses
`SimpleCli.zip`. Only pinned files are installed. Preserve downloaded upstream
terms/notices separately for release review, since payload installation does not
collect them automatically.

Artifact-specific validation and official-release evidence are documented in
[SDK_RELEASE_EVIDENCE.md](SDK_RELEASE_EVIDENCE.md). `validate_bundle.py APP`
checks vendor runtime layout/dependencies and extension exclusion even for
unsigned builds; `--inventory PATH` selects SDK inputs and `--signed` adds
signature checks. Official mode additionally requires `--official-release`,
Sony and artifact-bound `--release-evidence PATH`. This guide is not evidence
that an official release or hardware qualification has passed.

## Checks and work directories

```sh
bash scripts/test.sh
bash scripts/ui-typecheck.sh
bash scripts/ui-verify.sh
bash scripts/monitor-app-integration.sh
bash scripts/monitor-feed-host-checks.sh
bash scripts/sony-control-checks.sh
bash scripts/sony-credential-checks.sh
bash scripts/sony-plugin-checks.sh
python3 scripts/test-source-declarations.py
python3 scripts/check-vendor-boundaries.py
```

Run the applicable focused tests while developing, then the integrated build
paths affected by the change. Conformance checks cover delivery ordering,
epochs/clock declarations, retained buffers after stop, lifecycle races, partial
availability and control-generation behavior. Test sources/fakes are not
production capture vendors. `vendors.py run-tests --vendor sony` runs manifest
entry points. Hardware and signed Keychain checks have separate opt-in modes in
[SONY_CONTROL.md](SONY_CONTROL.md); ordinary software checks must not connect to
cameras or use real saved credentials. This guide lists commands and contracts,
not a receipt that every integration/hardware check has passed.

`test.sh` runs the boundary lint alongside BuildContracts, VendorSDK,
BundleContracts and BoundaryContracts checks. SDK sample provenance for the
packed v210 texture views is retained in the root [NOTICE](../NOTICE).

Outputs default to `<checkout>/.build/`. `ULTRACAM_WORK_ROOT` can select an
absolute or checkout-relative directory. Locations inside the checkout must
remain in its `.build/` subtree.
The path helper rejects unsafe overlap and escaping derived paths. Use
`python3 scripts/work_paths.py --path work_root` or `--path artifact_root` to
resolve actual locations. Stable app/log aliases live under
`<work-root>/agent-work/ultracam/`; unique build runs live under
`<work-root>/agent-work/build/ultracam/runs/`. No external volume is required.
