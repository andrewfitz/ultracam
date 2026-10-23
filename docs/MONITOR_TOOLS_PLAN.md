# Monitor Tools implementation plan

> **Historical.** `Packages/MonitorTools` was retired in W4 (step 8, 2026-10-22): [MonitorKit](../Packages/MonitorKit/README.md) replaced it, as planned in [the integration map](MONITORKIT_INTEGRATION_MAP.md). The package, its tools and its `monitor-tools-*` scripts no longer exist; this plan is kept as the record of what it did and how it was qualified.

Status: implementation present with focused synthetic verification; release qualification
is incomplete. The historical milestones below remain the acceptance plan, not a
claim that every release gate has passed. Continuous EL Zone and physical receiver qualification remain explicit dependencies.
The named synthetic sustained workloads and signed installed delivery now pass.

Implementation status (2026-10-20):

Follow-up signed host 14 is installed. It restores physical DeckLink discovery
and corrects Source-picture focus/false-color coordinates with nonidentity
output transforms. All 115 package checks pass, and an independent physical-input
virtual-camera check receives 599 frames in 20 seconds with ordered timestamps.
The earlier implementation/sustained snapshot below retains its measured results;
see VALIDATION for the correction receipts.

The user clarified that the requested mode is ARRI-style false color on Sony
S-Log3, without requiring an ARRI camera. The correction and critical-pipeline
feedback snapshot passed 316 app tests, 112 package tests and 11 isolated app integration
checks, including strict concurrency
and warnings-as-errors. Signed host build 12 / extension 4 validates metadata,
resources and signature. Current paired and sustained synthetic workload checks
pass, as do app-only lifecycle regressions. The signed app is installed in
`/Applications/Ultracam.app` and responds to native menu input. Generated test
media/build caches and the old app copy are in recoverable Trash. See VALIDATION
for measured capacity, cleanup receipts and historical failures.

- Local `MonitorToolsCore`, `MonitorToolsMetal` and `MonitorToolsUI` products are
  linked into the host. Per-feed configuration, source interpretation, workspace
  bindings, generations/revisions and bounded retirement accounting are implemented.
  Unknown/future monitor preferences fail closed without discarding camera/LUT
  settings; explicitly cleared workspace bindings persist.
- Main/tray/workspace integration includes Single, Side by Side, Four Up and
  detached monitoring, shared feed analysis, surface-local Clean/Freeze and explicit
  Program capability limits. The existing native main/tray tools-off preview route
  is retained; additional surfaces use owned clean copies.
- Guides, IRE zebras, source-resolution focus peaking, spatial RGB parade and luma
  waveform have implementations and synthetic coverage. ARRI LogC3/LogC4 EI800
  profiles have published-table and synthetic GPU checks only. Continuous EL Zone
  remains unavailable: published palette/stop anchors are implemented, but authoritative
  intermediate boundaries and integration qualification remain unresolved. See
  [color reference receipt](MONITOR_COLOR_REFERENCES.md).
- The earlier full run passed 87 package tests and 313 app tests. Critical-pipeline
  feedback subsequently passed 96 package tests and 315 app tests with zero failures. The added production
  capture case uses a nonlinear LUT, paced 4K v210 input, 1080p NV12 camera output
  and the real recorder core with monitoring off/on; all 90 measured frames reach
  both consumers in each run. Actual synthetic-window tests cover visibility and
  local Freeze/Clean. Signed host build 12 passes resource and strict signature
  validation. Sustained, receiver-observed and installed-app gates remain separate.
- The runtime policy is three analysis jobs and four clean-copy jobs globally,
  at most one of each kind per target across retired generations, within a shared
  256 MiB owned-memory budget with 64 MiB reserved for clean presentation. The core
  ledger's reusable defaults remain two analysis jobs and one clean-copy slot; the
  runtime explicitly selects three and four. Clean slot and displayed-memory
  leases retire independently. Non-clean allocations are capped at 192 MiB;
  existing clean-presentation bytes satisfy the 64 MiB reserve within the
  256 MiB total. At most four idle working sets remain cached.
  Under repeated admission pressure, monitoring reduces composite height to 720p
  and scope sampling/cadence (default 15 Hz reduces to 12 Hz), preserving
  native-resolution focus. Recovery requires
  five healthy seconds. Per-target diagnostics show requested/delivered rates,
  skips, ages and quality; extra native surfaces reserve explicit compositor
  estimates and can report no capacity. Soft deadlines suppress late publication
  while committed GPU resources remain charged. This is the current bounded
  policy, not a sustained-performance claim.

See [audit findings and remaining dependencies](MONITOR_TOOLS_AUDIT.md).

This is the implementation plan for the agreed Monitor Tools module. The user
requires independent tools for multiple feeds and recording priority. Tasks
remain unchecked until implemented and verified. Proposed resource budgets below
are starting policies, not measured performance claims.

## Product decisions

Monitor Tools is a monitoring module for Ultracam, with independent state for
multiple feeds. It provides thirds guides, zebras, selectable EL Zone and ARRI
false color, colored focus peaking, RGB parade and luma waveform. It consumes
existing capture and processing frames; it does not open capture devices or
control recording.

Defaults:

- Tools off on existing and new feeds. Saved choices restore per stable feed ID.
- Monitor picture, zebras and scopes default to Processed Output, with Source
  available on individual feeds. Picture and scope stages are independent saved
  feed settings shared by that feed's surfaces. Always label the signal explicitly.
- EL Zone analyzes the original supported Log source before the viewing LUT.
  Its legend uses exposure stops relative to 18% gray, independently of picture
  LUT selection. It must not analyze an arbitrary post-LUT image as scene exposure.
- False Color selects EL Zone or ARRI independently per feed. Each mode has its
  own versioned classifier, calibration and legend; these are not palette swaps.
  ARRI compatibility and any non-ARRI camera adaptation must be labeled explicitly.
- Focus peaking analyzes full-resolution source luma and maps its mask to the
  picture geometry. Show `Focus: Source` when the picture shows processed output.
- Analysis/render results belong to one feed and stream generation. A feed switch
  never reuses the previous feed's scopes, thresholds or queued overlay result.
- Controls edit the selected monitor target. Starting/stopping another feed,
  changing Program, and choosing the app's settings feed are separate actions.
- Monitoring overlays appear on monitoring surfaces. Camera transport and
  recording consumers receive their existing image branches.
- Native Swift/Metal is the intended implementation; no external video package
  is currently required. EL Zone specification/integration availability must be
  resolved before claiming that mode complete.

## Scope and milestones

The first complete release includes all five requested tools, independent feeds,
luma waveform alongside RGB parade, main/tray integration, two-up/four-up and
detached monitoring, persistence, recording isolation and performance diagnostics.
Configured feed count has no artificial four-feed limit; workspace layouts and
qualification sizes use two/four feeds. Device ownership and resource admission
determine how many feeds can run.

Histogram, vectorscope, pixel picking, anamorphic de-squeeze, image export,
recording burn-in and autofocus are later extensions.

| Milestone | Deliverable | Depends on | Completion gate |
| --- | --- | --- | --- |
| M0 | Baselines and recording-isolation audit | None | Repeatable recording/capture baselines and admission tests |
| M1 | Package, contracts and build integration | M0 | Package tests and signed build; tools still off |
| M2 | Per-feed routing, surfaces and demand | M1 | Two feeds stay independent through switching, close and reconnect |
| M3 | Workspace shell and guides | M2 | Correct image geometry and native tools-off preview |
| M4a | Signal contracts, calibration harness and zebras | M3 | Range/packing/reference tests; explicit supported signal basis |
| M4b | EL Zone and ARRI false color | M4a | Each mode agrees with its own authoritative reference and qualified profiles |
| M5 | Source-resolution focus peaking | M4a | Edge/noise and alignment checks pass |
| M6 | RGB parade and luma waveform | M4a | Spatial scopes and bounded independent refresh pass |
| M7 | Full multi-view UX and resource governor | M5, M6 | Views share analysis; memory/load remains bounded |
| M8 | Recording qualification and signed delivery | M4b, M7 | Release gates pass; installed app verified while idle |

Follow these dependencies. M4b reference work must start during M0 so missing
specifications are discovered early. It does not block M5/M6 development after
M4a. Each milestone should be a focused, reviewable change. An explicitly scoped
interim release may contain qualified tools, with unavailable modes labeled;
it cannot be described as completion of the full requested module.

## Recording isolation is a release requirement

Recording has priority over monitoring. A recording must start, continue,
pause/resume and finalize independently of monitor initialization, settings,
window visibility, analysis errors or module shutdown.

Enforce these boundaries:

- Keep the existing direct source-to-recorder route. Monitor frames are optional
  read-only subscribers; recording never reads decorated monitor output.
- No monitor shader compilation, image conversion, GPU submission, file access,
  allocation-heavy work or waiting occurs on a capture/recording callback or the
  recorder's writer queue. Frame admission into monitoring is bounded and
  nonblocking; contention skips the monitor frame.
- Monitor output pools, working textures, queues and lifetime leases are separate
  from recording resources. Monitoring cannot reserve capacity in recording
  admission queues or change the recorder's queue limits.
- Bound borrowed source/output leases and release them promptly. Monitoring must
  not exhaust producer buffers while a slow GPU job or view retains a picture.
  New monitor views hold module-owned display results, not live capture leases.
  Preserve the existing native tools-off path and its baseline retention;
  additional surfaces must not multiply that allowance against producer pools.
- Count in-flight, display-held, frozen and retired-generation resources in
  admission. A timeout invalidates results but never releases memory the GPU may
  still access. Stop admitting work before those retained resources exceed budget.
- Recording callbacks, source pixel bytes, PTS/duration, audio and timecode are
  untouched by monitor configuration or analysis. No overlay is baked into a
  recording or virtual-camera frame.
- Recording demand is independent of monitor demand. Closing, hiding or freezing
  every monitor must not stop a feed that is recording. A monitor failure cannot
  call the recorder's Stop, drain its queues or reset its stream generation.
- Monitor initialization is lazy and asynchronous. Missing shaders, unavailable
  GPU resources, unsupported color metadata and analysis failure disable/report
  only the affected monitor tool; recording remains available.
- Use lower-priority CPU analysis and bounded GPU admission. Under pressure,
  lower scope refresh/sampling and suspend expensive monitoring before accepting
  more retained frames. Show monitoring degradation explicitly. Never silently
  lower recording quality, resolution, bitrate or cadence to keep scopes smooth.

Independent queues cannot eliminate contention for shared memory bandwidth or
hardware. Therefore release acceptance requires measured recording behavior,
not an architectural claim of zero performance cost.

Qualification compares monitoring off versus enabled for each supported codec
and source cadence, with two/four synthetic feeds where hardware capacity allows:

1. Check encoder-input pixel bytes, video PTS/duration and audio/timecode routing
   against the same synthetic reference. Do not demand binary-identical MOV
   files from separate encoding sessions.
   Compare active pixel samples/planes, not uninitialized row padding. For camera
   output compare the mapped cadence and relative timing separately from the
   per-run host-clock origin; recorder input retains original source time.
2. Verify recorded frame counts, timestamps and decodability, plus recording
   admission/encoder drops, queue depth and callback latency against baseline.
3. Inject stalled/failed monitor GPU work, rapid tool changes, feed switches,
   window closure and monitor teardown while recordings continue.
4. Verify pause/resume, asynchronous Stop/finalization, recovery journals and
   successful output publication with monitors active, hidden and failing.
5. Confirm monitoring memory/lease counts remain bounded and recover after tools
   close. Distinguish monitoring skips from source, camera and recording losses.
6. With feed cameras and Program camera clients active, compare delivered counts,
   cadence/mapped PTS, transport drops, queue depth and source-to-enqueue latency
   against tools-off baselines. Verify receiver-observed delivery in physical
   qualification where available; successful enqueue alone is not end-to-end proof.

Any additional recording losses or input/timing changes caused by monitoring
block release. Reduce monitoring work and requalify rather than weakening the
recording contract. Resource-admission settings must be justified by these tests.
Virtual-camera delivery has the same priority: attributable extra camera drops,
cadence gaps, timestamp changes or latency beyond a predeclared baseline tolerance
also block release. M0 fixes numerical p95/p99 latency tolerances before enabled
runs; do not move them afterward to excuse regressions. Recorder-first admission
does not isolate the existing synchronous camera processing path from contention.
This isolation covers app-controlled monitoring failures and sustainable load.
A process crash, OS/driver failure or device-wide GPU reset is a shared failure
domain; independent queues cannot guarantee continued encoding in those cases.
Exercise recording recovery separately instead of promising fault containment
that the hardware/process architecture cannot provide.

## User interface

A Monitor Tools toolbar lives directly below each preview. Its feed selector is
visible beside the picture title, so the control target is always apparent.
Buttons: Guides, Zebra, False Color, Focus, Scopes. A master `Monitor tools` switch
bypasses all tools while preserving settings. A press-and-hold `Clean view` action
hides picture overlays temporarily without changing saved choices.

The initial layout supports Single, Side by Side (two simultaneous feed previews),
Four Up (a 2×2 grid), and a detached monitor window. These are video-preview
layouts available even with all Monitor Tools off. Side by Side is a required
first-release feature, not only a development test view or alternating feed tabs.
The main window, menu bar preview and detached
windows use the same settings for the same feed. Surface layout, zoom and scope
visibility are view state, not global feed settings. Large, simultaneous views
of one feed share the same analysis results.

The workspace layout selector sits above the previews. Side by Side uses two
equal-width tiles initially, with a resizable divider and aspect-fit pictures.
Each tile has its own feed selector, feed name, live/stale status, tools and
optional scopes directly below its picture. Both feeds remain visible and update
concurrently; focusing a tile changes its control focus without hiding the other
feed, changing Program or changing the capture-settings selection. Show each
feed's own timestamps/age; simultaneous display does not imply camera frame sync.

Allow feeds to be swapped between tiles and a tile to expand temporarily to
Single, then return to the previous layout. Save layout, tile bindings and split
ratio as workspace state. A missing or stopped feed keeps its labeled placeholder
without silently substituting another camera. Switching layouts reuses sessions
and never restarts capture or recording. At narrow window sizes, retain the
chosen layout and expose compact controls; do not silently hide the second feed.

A tool's settings open in a popover, not in the capture configuration panels:

| Tool | Initial controls |
| --- | --- |
| Guides | Thirds, center cross, safe-area guides; contrast and opacity |
| Zebras | Threshold and width in IRE, above-threshold/band mode; stripe opacity |
| False Color | Off / EL Zone / ARRI; mode-specific legend, source profile, calibration and compatibility status; EL Zone stop scale with 18% gray at zero; ARRI camera/LogC/EI selection where applicable |
| Focus peaking | Red by default, optional alternate color; sensitivity, noise rejection and opacity |
| Scopes | RGB parade or luma waveform; gain, graticule, docked/expanded size; 10/15/30 Hz refresh |

The selected false-color mode replaces the picture's exposure rendering.
Only one false-color mode can be active per feed. False color and zebras are
mutually exclusive in v1 so their meanings remain readable. Guides and focus
peaking can coexist with either. Composition order is picture or false color,
then zebra (when applicable), then peaking, then guides/labels.
The active mode and its legend remain visible; each mode retains its own settings.
Tool settings remain independently saved when another tool temporarily hides it.
Picture stage and scope stage are separate feed settings. False color fixes its
own analysis to Source; selecting it does not silently move Output scopes to
Source. Label all three bases when they differ. Scope gain affects trace
brightness only, never measured level or axis scaling.

Each feed can copy its monitoring settings to selected feeds. This is an
explicit one-time copy, not a hidden permanent link. Named presets can be added
after the per-feed behavior is stable. There is no `apply to all` by default.

Scopes show feed name, signal, range/transfer interpretation and last update age.
No Signal, Starting, Unsupported Format, Paused/Hidden and Stale are explicit
states. Freeze is surface-local: hold a module-owned picture and its matching
available scope snapshot, including each timestamp/age. A slower scope can have
an older timestamp; do not claim exact simultaneity. Other live surfaces keep
updating. If the freeze allocation cannot be admitted, report that rather than
retaining a producer buffer. Frozen images are never persisted.

Clean view is also surface-local. Provide keyboard/menu equivalents for Clean
and Freeze, readable legends that do not depend on color alone, and visible
stale/degraded labels. Compact tray UI must expose the selected mode and its
status without hiding the picture behind a full-size toolbar.
Clean on a frozen surface reveals an admitted clean counterpart of that same
frozen frame/configuration, never current live video. Reserve both images when
freezing a decorated picture. If that pair cannot be admitted, disable Clean on
that snapshot with a reason; do not unfreeze or reprocess a different frame.

## Packaging and responsibilities

Use a local Swift package at `Packages/MonitorTools`, linked into the host app.
It is not included in the camera extension. The project generator and test
scripts must explicitly integrate the package and its tests.

| Component | Owns | Must not own |
| --- | --- | --- |
| `MonitorToolsCore` | Configuration, signal/color contracts, frame stamps, geometry, analysis/result models and validation | AppModel, devices, recording, SwiftUI, mutable image storage |
| `MonitorToolsMetal` | Pixel-buffer texture mapping, tool kernels, scope accumulation, preview compositing, bounded pools and scheduling | Capture lifecycle, camera publication, app preferences |
| `MonitorToolsUI` | Toolbar, settings popovers, legends, scopes and monitor surface views | Capture callbacks and per-frame CPU image processing |
| App `MonitorCoordinator` adapter | Stable FeedID mapping, frame taps, surface subscriptions, persistence and capture-demand integration | Tool algorithms |

The package uses its own small source-key value type. The app adapter maps the
existing `FeedID` into it; display names never serve as identity. Public APIs
accept a lazily supplied shared Metal device, immutable configuration snapshots and frames with
explicit lifetime leases. GPU timing events feed the existing app resource meter
through an injected callback, without importing app-level global objects.

One `MonitorSession` exists per feed target. It owns settings version, stream
state, scheduled analysis, GPU buffers and diagnostics. Shared Metal context
owns compiled kernels and device resources. One `MonitorSurface` exists per
window/tile/tray preview; it selects a target and owns its display renderer.
Resolve live demand as the union of surface subscriptions. Scope visibility,
Freeze and Clean are surface-local; tool settings and analysis stages are shared
per feed. A stage change updates all live surfaces bound to that feed, with
separate explicit labels. A frozen snapshot keeps its original configuration
stamp and legend until unfrozen; it never adopts a new legend over old pixels.

Introduce lazy shared-device injection where necessary: `LUTProcessor` currently
creates a private default device and command queue. Share the device identity,
not its synchronous queue or mutable processing state. Tools-off and guides-only
paths must not require analysis/composition shader initialization. Retain the current Swift 5 mode
with complete concurrency checking; do not require a language-version migration.

`CleanPreviewService`, inside the presentation portion of `MonitorToolsMetal`,
has independent initialization, a bounded worker and module-owned native-display
buffers. It produces shared clean frames for added surfaces and fallback even
when analysis shaders fail or both analysis slots are occupied. Its CPU raw-copy
path must support admitted native pixel formats without a Metal command queue;
reserve independent clean-copy slots (four globally, one per target) and
64 MiB of clean-presentation memory before assigning
the remaining budget to analysis. Source buffers are borrowed only during that
admitted copy. Prefer shared clean results over another producer-buffer lease.
The existing stager's IOSurface passthrough is not an owned copy, and the current
synchronous GPU copier must not become the fallback's dependency.

Clean staging, frozen images and analysis share the total memory budget, but
analysis cannot consume the clean reserve. If clean capacity itself is exhausted,
skip that clean update, mark its age, then show an explicit unavailable placeholder
after the stale threshold; never allocate beyond budget or retain producer bytes
for display. Preserve the baseline native main/tray route independently. An OS/
device-wide failure may still prevent native display, as already qualified above.

Changing which surface is selected does not replace a feed's runtime session.
Removing a feed cancels its subscriptions and work before releasing resources.
Late GPU results are rejected using generation tokens.
Cancellation stops future admission immediately; retirement of committed work is
asynchronous. Keep one shared retirement ledger across removed/recreated sessions
so reconnects cannot reset the global job or memory limits. Session teardown must
not wait on the main actor, capture queue or recording finalization.

## Integration with the current app

Current `AppModel` constructs one main and one mini preview renderer, then passes
those same renderer instances to every `CaptureController` in `FeedCapturePool`.
This is a selected-preview implementation, not a safe basis for independent
simultaneous monitor surfaces. Refactor frame routing and presenter ownership
before adding tools. Do not put five new tool properties on the shared renderer.

Additional code constraints found during audit:

- `CaptureController.receive` submits recording only after shared capture
  admission. `LUTProcessor.process` waits for GPU completion on that serial path.
  The existing limiter therefore cannot establish recorder independence under
  preview stalls. M0 must resolve and test this prerequisite before tool load.
- `FeedCapturePool` lives in `Sources/App/CaptureController.swift`;
  `FeedSession`, `FeedCoordinator` and `ProgramOutputRoute` live in
  `Sources/Shared/FeedRuntime.swift`. These are the actual integration points.
- `onProcessedFrame` already serves Program through `LatestProcessedFrameHop`.
  Add a separate monitor offer, preserving that handler; do not route monitor
  pixels through a per-frame main-actor Task or reuse synchronous `FrameFanOut`
  queue operations on a capture callback.
- `ProcessedFrameMetadata` currently omits origin identity, source time after
  Program mapping, color and geometry. Build the monitoring envelope at the
  producer/accepted Program decision; a downstream bridge cannot reconstruct it.
- Extra Program feeds currently start with preview disabled and restore LUTs
  asynchronously. A monitor must subscribe to their real controller/configuration
  revisions without toggling their camera destinations or reloading effects.
- `VideoContract.outputBufferLimit` accounts for the existing preview/transport
  topology. Do not multiply native pending queues per new tile or raise that
  producer pool limit to accommodate monitors. Share admitted module-owned clean
  results between additional surfaces, with bounded per-surface presentation.

Introduce additive frame taps:

1. Source tap after input/timing validation, before effects or cadence reduction.
2. Processed Output tap after the normal effects/format/cadence pipeline.
3. Program tap after the switcher accepts a frame and maps its Program time.

These are subscribers to the existing frames. They do not invoke the LUT twice,
replace the raw recording callback, or publish decorated frames to CMIO.
Capture admission into the monitor is nonblocking.

Program is a distinct monitor target with its own settings, and follows the
actual switched output, not whichever feed is selected in the settings UI. V1
Program monitoring supports Program Output. Feed-source analysis is selected
through that feed's own monitor. On a Program cut, retain origin feed identity,
update the color contract, and reset scope accumulation/old-frame state.
Keep Program's calibrated false-color control unavailable with a clear source-Log
explanation until matching source provenance across cuts is implemented and qualified;
ordinary Program signal scopes remain available.
Program source-resolution peaking is also unavailable in v1 for that reason.
Do not substitute output-resolution edges under the `Focus: Source` label.
Program's capability row permits its Output picture, guides, output zebras and
signal scopes; both source false-color modes and source peaking remain disabled.

## Frame and result contracts

A `MonitorFrame` carries:

- Target/source ID, stream generation, sequence, source PTS and host arrival time.
- Duration, discontinuity/timing epoch and mapped presentation time separately
  from the original source PTS. Source sequence is the pairing key; PTS alone may
  repeat or reset. Use a single monotonic host clock for age/deadline measurements.
- Width, height, pixel format, clean aperture, pixel aspect ratio and orientation.
- Matrix coefficients, primaries, transfer function and video/full-range rules.
- Bit depth/bit alignment, per-plane stride/layout, chroma siting and progressive
  scan status. Preserve metadata provenance: captured, declared or unknown.
- Source/Processed/Program stage, processing configuration version and LUT identity.
- A lease to read-only pixel-buffer storage; never a borrowed unretained pointer.
- Paired bundles carry separate source/output geometry and an explicit processing
  correspondence mapping source pixel centers to output pixel centers. Aperture,
  crop, scaling, pixel aspect and orientation are not assumed to be identical
  normalized rectangles. Unknown correspondence disables source-derived overlays.

Peaking can use a source frame corresponding to the displayed processed frame.
Match by feed/generation/source sequence and verify PTS. If no matching source
frame is available, omit its mask for that displayed frame rather than reusing
an unrelated result.

For a Processed Output picture with source-based peaking/false color, offer an
atomic source/output bundle from the same `CapturedFrame` after output cadence
selection. Retain both only if monitor admission succeeds. Source-only picture
or scope jobs use the independent validated source offer. Both routes share the
same per-feed job slot; no unbounded PTS lookup cache or waiting for a future
matching frame. Demand selects which route supplies each job, so an always-busy
source path cannot starve paired Output pictures. The normal processing frame's
existing source reference is sufficient; do not retain every source speculatively.

Display a completed monitor picture with its matching overlay; never lay an old
mask over a newer native preview. Define the handoff between native and composed
renderers, flush the previous surface generation and suppress late results.
Missing results hold an age-labeled completed picture briefly, then fall back
to a clean native picture with an unavailable/stale tool badge. The initial
stale threshold is max(250 ms, three expected update periods), to be qualified.
Freeze is exempt from automatic fallback and always carries a frozen label.

Analysis results carry the same frame stamp and configuration version. Picture
overlays are composed against their matching image. Scopes refresh independently
and expose their age. A stopped/restarted stream, format change, LUT change,
analysis-stage change or Program cut invalidates incompatible results.

Geometry is defined in the active image rectangle. Guides and peaking account
for aspect fit, letterboxing, pixel aspect ratio, cropping, zoom and orientation;
window coordinates never substitute for source-image coordinates.
Compose source-derived masks through the producer's correspondence, then the
surface's image-to-view transform. A source-based false-color picture follows
the selected picture's geometry through that same correspondence; if unavailable,
require an explicit Source picture selection or report unsupported alignment.
Qualify actual full-frame 4K/1080p paths first. Test asymmetric clean aperture,
non-square pixels and orientation only where supported; unsupported transforms
must be labeled rather than implied by a generic geometry helper.

## Color and measurement rules

Correct signal interpretation is part of the module, not a display preference.
Zebras and signal scopes use documented signal levels, with IRE mapping based
on the actual pixel range. Preserve below-black and above-white values for
analysis; display clipping must not silently erase superwhite information.

Keep storage unpacking, transport scaling and Log-curve normalization separate.
The pixel-format range flag alone does not prove that camera Log code values
were rescaled by the HDMI/capture chain. Verify that chain with known patches;
avoid applying a legal/full conversion twice. Sony's S-Log3 reference anchors
are code 95 at black, 420 at 18% gray and 598 at 90% reflection in its native
10-bit convention. Test these before and after any declared transport scaling.
That Sony document covers other camera outputs; FX3 HDMI still needs its own
qualification. Do not confuse YCbCr matrix coefficients with RGB gamut primaries
or use Rec.709 linear-luminance coefficients for every source gamut.

For v1, calibrated display composition is SDR. PQ/HLG display conversion and
HDR/EDR monitor output are deferred, with explicit capability status. Numeric
signal scopes may still run when their packing/range contract is known; label
Log/code-level measurements as such. Unknown transfer must not disable guides
or every tool indiscriminately. Maintain a per-tool capability matrix.

The current LUT processor tags LUT output Rec.709, but an arbitrary `.cube`
does not establish its input/output transfer or gamut. Keep declared LUT/output
interpretation separate from those tags. Permit labeled signal-level inspection
without claiming calibrated scene exposure or silently changing camera pixels.

EL Zone and ARRI are the requested false-color modes and supersede the earlier
proposed generic `Ultracam IRE` palette. Source Log and processed Rec.709 are
distinct analysis contracts. The EL Zone basis is supported source Log decoded
to scene-referred exposure, with zero at 18% gray and zone labels in stops.
Exact colors, zone boundaries and interpretation must follow authoritative
EL Zone integration/reference material, not colors sampled from a screenshot.

For the initial FX3 workflow, support verified S-Log3 with the declared
S-Gamut3.Cine or S-Gamut3 primaries and actual input range/matrix. Decode the
source YCbCr, apply the correct inverse transfer and derive the exposure metric
using the validated system specification. A useful scalar reference model is
`EV = log2(sceneLinearY / 0.18)`; agreement with that formula alone does not prove
exact EL Zone compatibility. Verify the required luminance/channel interpretation,
zone boundaries, colors and any reference offset against authoritative material.

The EL Zone legend is stop-based, including its specified near-middle-gray
subdivisions and end zones. Keep IRE labels on zebras/waveforms. Do not call an
upper/lower display end zone actual sensor clipping without a separately verified
camera clipping reference. Handle zero/negative decoded values and invalid inputs
explicitly so logarithms cannot produce NaNs or misleading exposure colors.

Changing the viewing LUT must not change source EL Zone exposure. A source with
an already baked display LUT or unknown transfer is unsupported for calibrated
EL Zone; explain the source-profile/input requirement rather than guessing an
inverse of an arbitrary creative LUT. Program EL Zone is deferred until its
source-Log provenance can be paired with actual Program cuts and source PTS.

Per-feed camera EI/reference handling must be explicit. HDMI capture does not
automatically provide a trustworthy exposure-index/base-ISO contract. Record
whether any EI gain is already in the incoming signal, avoid applying it twice,
and validate supported reference-offset behavior. Do not infer this from the
viewing LUT's name or claim that HDMI frames supply camera settings they lack.

Before shipping the official EL Zone name/colors, obtain the authoritative
integration specification and confirm applicable implementation/branding terms.
The public sources below establish exposure behavior, not a published SDK license
for Ultracam. This is a planning dependency to resolve, not a claim that a
particular fee, agreement or prohibition has already been established. No third
party is contacted without a separate user instruction. Do not silently replace
the requested EL Zone system with an approximate palette under the same name.

ARRI False Color is a separate implementation based on ARRI's published LogC
specification. It uses an achromatic LogC signal, camera/encoding/EI-specific
bounds and categorical colors, leaving unclassified values grayscale. Match
legal/full-range normalization and the specified lower-inclusive/upper-exclusive
boundaries. Its legend identifies middle gray, one stop above gray, clipping
proximity, shadow detail and noise floor. Do not reuse EL Zone's classifier.

On supported ARRI inputs, select and verify the matching camera, LogC version
and EI. For the FX3 S-Log3 workflow, never apply LogC code-value tables directly.
The requested `ARRI-style — S-Log3` mode uses Sony's published inverse curve on
each channel, then the selected Sony gamut's scene-linear luminance. Encode that
luminance with the published LogC3 EI800 exposure curve and classify against the
LogC3 EI800 full-range reference table. This is a luminance-based adaptation,
not the ARRI camera's chromatic classification. Unclassified values retain the
original S-Log3 achromatic grayscale. Native and full-to-legal transport mappings
must reconstruct native S-Log3 values before decoding.

The legend identifies reference highlight and shadow bands, middle gray and
one stop above gray. It does not label Sony sensor clipping or noise floor.
Reference EI800 defines the chosen reference bands; it does not require the Sony
camera to use ISO/EI800. The source curve/gamut and transport declaration must
match the incoming source; camera-specific clipping/noise calibration remains a
separate future capability. No ARRI camera is required.

Represent both modes with separate profile IDs, specification versions,
classifiers, legends and validation fixtures behind one False Color interface.
Changing modes invalidates in-flight results through the configuration revision.
Tests must demonstrate that a change on one feed cannot affect another feed's
mode, profile, EI or legend. Both modes consume read-only source frames on the
monitor branch, before the viewing LUT, without changing recording or CMIO data.

RGB parade is a spatial scope: retain horizontal image position and accumulate
channel levels vertically. A three-channel histogram alone is not RGB parade.
For scope speed, reduce horizontal columns and sample source rows without
averaging away narrow highlight peaks. Validate the chosen sampling behavior;
call it sampled monitoring rather than a proof that no source pixel clipped.

Full-resolution peaking uses luma detail with noise suppression and adjustable
thresholding. It is a qualitative focus aid, not a distance or autofocus result.
False-color display and guide colors are composited in an explicit display color
space so ColorSync/transfer handling cannot silently alter exposure thresholds.

## Scheduling, threading and memory

- SwiftUI/main actor owns controls and subscription intent. Raw frames and Metal
  resources stay off the main actor and outside observable view state.
- A session applies immutable configuration revisions on its worker. GPU command
  completion publishes only matching results; it never mutates capture state.
- No FIFO of analysis frames. Admit at most one borrowed analysis bundle per feed;
  while busy, skip incoming monitor work and admit a new frame when capacity is
  available. Release shared capture/output leases as soon as GPU reads finish.
- Surface presentation holds only bounded module-owned results. A slow window
  does not retain capture buffers or block other windows.
- Source input includes non-IOSurface packed v210. On a monitor worker, use a
  validated read-only buffer mapping where safe, otherwise a bounded compact-row
  staging copy. Planar texture mapping is not a universal decoder. Reserve
  staging/output capacity before touching borrowed storage; keep pixel buffers,
  locks and Metal wrappers alive until their last GPU read completes. Do not
  call the existing synchronous LUT processor to implement monitor work.
- Start with at most two monitor jobs in flight globally, one per feed. Schedule
  visible feeds fairly so a busy feed cannot monopolize analysis. Measure and
  tune these limits rather than increasing capture pool sizes preemptively.
  These are analysis slots; the runtime admits at most four independent clean
  copies globally, one per target. At most two analysis bundles plus four clean
  inputs are borrowed globally,
  including retiring work. All owned allocations still share one total budget.
- Exposure overlays/peaking target the displayed cadence. The original proposal called for
  15 Hz on the focused view and 10 Hz on other tiles. Current implementation uses
  a per-feed requested rate (default 15 Hz; selectable 10/15/30), shared target
  caching and bounded/fair admission; focus-based rate priority remains pending.
  Delivered rates must be measured. Hidden surfaces
  request no rendering. Scope-only views can request scope work independently.
- Reuse per-session buffers and pools. No per-frame texture allocation or full
  frame GPU-to-CPU image readback. Small histogram buffers may be read back only
  if required by the scope UI; prefer direct GPU rendering.
- The module has a memory admission budget across feeds. Degrade scope sampling
  or skip monitor updates before accumulating frame leases. Report degradation.
- Retain settings while hidden; release large idle working buffers after a short
  grace interval. Unsupported formats and shader errors affect that monitor only.
- Use asynchronous Metal completion handlers; never waitUntilCompleted or wait
  for a drawable on capture, recording or main queues. CPU QoS is not a GPU
  priority guarantee. Time out result publication and stop new submissions on a
  stalled device while retaining unsafe-to-release resources until completion.
  Do not create replacement queues/sessions repeatedly to evade a stuck job.
- Count source-only, paired-output, upload, analysis and presentation commands
  in the admission/resource model. Shared analysis does not make per-surface
  drawables free. Each surface has a bounded display slot and no display FIFO.

Monitoring and recording share physical CPU/GPU/memory bandwidth, so performance
is a measured acceptance condition, not a promise of zero cost. Instrument GPU
milliseconds, analysis FPS, skipped monitor work, retained frames, memory and
result age separately from recording/camera drops. Include monitor Metal work in
the existing total app GPU video meter; avoid double-counting shared commands.
That meter measures the union of instrumented Metal busy intervals, not total
hardware GPU utilization or VideoToolbox encoder utilization. Keep that limitation
in its label/help and report unavailable timing distinctly from zero activity.

## Capture demand

Automatic capture considers camera clients, Program source requirements, active
recordings, visible monitor pictures and visible scope-only surfaces as separate
demand reasons per feed.
Tool toggles alone do not start a hidden feed. Opening a monitor for Feed B can
request B without replacing Feed A's monitoring session or settings selection.
Closing the last B surface releases only B's monitor demand; any recording or
camera consumer keeps B running. A frozen surface no longer needs live analysis,
unless another live surface requests the same target. Distinguish presented
  from actually drawable/occluded: preserve existing automatic capture intent
while covered, but stop expensive hidden analysis. Respect preview disabled,
manual capture mode and explicit Stop/retry; demand changes must not restart
a deliberately stopped feed or create a retry loop. Existing demand and recording
behavior must be regression-tested when wiring the module into the coordinator.

## Persistence and compatibility

Persist a versioned `MonitorConfiguration` under each feed descriptor, with
`decodeIfPresent` defaults so existing settings still load. Store Program's
configuration separately. Persist tool choices, thresholds, false-color mode,
each mode's specification/profile version, per-feed Log/EI/reference settings,
colors, picture stage and scope stage. Calibration is keyed to device/format/
profile, invalidated on incompatible source reassignment, and never silently
copied between cameras by Copy Settings. Revalidate copied tool choices.
Keep transient queues, analysis results, frame images,
last-error state and temporary Clean/Freeze actions out of preferences.

View layout and surface bindings are workspace state. Closing one surface does
not delete feed settings. Selecting another feed does not copy settings unless
Copy Settings is explicitly requested. Unknown future settings must produce a
usable default configuration, without silently accepting invalid thresholds.

## Validation and delivery

Use synthetic patterns first: level ramps, color bars, channel-isolated patches,
superwhite/below-black samples, sharp/blurred edges, noise and letterboxed images.
Validate signal math on CPU as a reference, then compare Metal results. Compare
scope output with an independently configured established scope such as FFmpeg.

Required regression cases:

- Two/four feeds have visibly different independent settings and results.
- Main/tray/detached surfaces for one feed share analysis without duplicated work.
- Feed switching, device reconnect, format changes and Program cuts reject stale
  completions; deleting a feed releases its frame leases and buffers.
- Source/Output levels and peaking geometry stay correct across LUT changes,
  4K/1080p, supported pixel formats, 29.97/59.94, zoom and letterboxing.
- Monitoring off preserves the existing native preview path; camera/recording
  samples remain bit-identical with tools enabled and disabled.
- Slow GPU completions or scope rendering never block the capture callback or UI.
- Stress two/four synthetic feeds with recording and transport active; compare
  baseline vs tools for latency, dropped media, bounded memory and resource use.
- No-input, unsupported metadata and missing palette/profile cases have explicit,
  useful UI states. No real-camera imagery is saved as part of automated testing;
  synthetic fixtures and generated recording artifacts are allowed.

## Detailed implementation work

### M0 — Baselines and recording-isolation audit

- [ ] Inventory the recording, preview, Program and camera routes: capacities,
  ownership, source validation and capture-demand behavior.
- [ ] Audit `CaptureController.receive`: its recording video callback currently
  occurs after the capture admission limit accepts the frame. Monitoring must
  not add work or retained capacity to this shared limiter.
- [ ] Add a paced synthetic test that stalls preview/monitor processing while an
  independent recorder consumes video/audio. Inspect recording admission, frame
  counts and timestamps, not only successful file finalization.
- [ ] Resolve the existing shared limiter in a small prerequisite change with its
  own regression tests: validated recorder-first admission using the recorder's
  existing bounded queue, followed by independent preview/monitor admission.
  Preserve one recording submission per source frame,
  signal validation, original timing and shutdown ordering.
- [ ] Preserve recorder-side validation and invalid-signal behavior; do not
  simply move an unchecked callback above all validation.
- [ ] Start reference/profile qualification for M4b now; maintain a supported
  profile table with evidence, remaining gaps and exact release eligibility.
- [ ] Establish tools-off ProRes/HEVC baselines at 29.97/59.94 with one/two/four
  synthetic feeds, camera consumers, pause/resume and Stop. Record audio/timecode,
  source/recorder drops, callback latency, queues, encoder errors and memory.
- [ ] Establish feed/Program virtual-camera baseline delivery, timing, queue and
  latency receipts with active consumers. Set numeric p95/p99 latency regression
  tolerances before enabling monitoring.
- [ ] Define named Single, SideBySide and FourUp qualification workloads with
  input/output rates, preview size, codec/storage, camera consumers and tool mix.
  Commit numerical minimum sustained picture FPS per tile, scope update Hz and
  maximum age for each sustainable workload, measured over fixed windows after
  warmup. These are mandatory release thresholds set before M8, not rates that
  can be lowered indefinitely by the governor. Record any missing qualification.
- [ ] Use identical hardware, source patterns and workload for later comparisons.

Exit: a repeatable harness can identify additional losses caused by monitoring.
An already failing baseline is resolved or explicitly reported; it cannot serve
as evidence that recording isolation passed.

### M1 — Package, contracts and build integration

Planned structure:

```text
Packages/MonitorTools/
  Package.swift
  Sources/
    MonitorToolsCore/       # configuration, frames, color, geometry, diagnostics
    MonitorToolsMetal/      # context, sessions, scheduling, rendering, scopes
      Resources/MonitorTools.metal.txt
    MonitorToolsUI/         # toolbar, popovers, picture/scopes, legends
  Tests/
    MonitorToolsCoreTests/
    MonitorToolsMetalTests/
    Fixtures/
```

- [x] Define immutable source keys, frame stamps, color/geometry contracts,
  configuration revisions, states, results and the read-only lease adapter.
- [ ] Define nonblocking `offer(frame)` admission. It must not spawn a Task per
  frame, await an actor on a capture callback, or create an unbounded mailbox.
  Busy admission rejects monitoring immediately. Use a try-acquire operation for
  global and per-feed slots before retaining the bundle; normal blocking locks
  or queue.sync calls do not satisfy this contract.
- [ ] Inject clock, completion driver and diagnostic sink for deterministic
  lifecycle, backpressure, failure and stale-result tests.
- [ ] Package shader resources and compile/load on a worker. Initialization and
  shader compilation cannot run on capture/recording queues. Share the device,
  compiled library and pipeline-state cache across sessions.
- [x] Add local package references/products to `scripts/generate_project.py` and
  regenerate `Ultracam.xcodeproj`. Link only the host; retain macOS 15 compatibility.
- [ ] Update build/test/smoke scripts to build and link package products. The
  current raw `swiftc` app test runner needs explicit package integration; do not
  compile divergent copies of package sources into separate test paths.
- [ ] Route package scratch/cache/build output to the external build directory.
  Validate host shader resources, unchanged extension dependencies and entitlements.

Exit: independent package tests, concurrency checks and a signed host build pass
with no installed preview or recording behavior change.

### M2 — Per-feed routing, lifecycle and demand

| Existing/app code | Planned change |
| --- | --- |
| `AppModel.swift` | Own monitoring adapter; keep monitor-target selection independent of capture settings selection |
| New `MonitorCoordinator.swift` | Map feeds/Program to sessions, subscriptions, preferences and diagnostics |
| `CaptureController.swift` | Validated source/output taps and bounded admission |
| `Sources/Shared/FeedRuntime.swift` / `FeedCapturePool` in `CaptureController.swift` | Feed lifecycle, per-feed demand and existing device exclusivity |
| `ProgramOutputRoute` in `FeedRuntime.swift` | Accepted switched frame envelope before provenance is lost; preserve `ProgramOutputBridge` camera consumer |
| `VideoPreview.swift` | Explicit surface/target renderer bindings and native tools-off path |
| `AppSettingsStore.swift` | Versioned per-feed settings and separate workspace persistence |
| `AutomaticFeedPolicy.swift` | Camera, recording, picture and scope demand reasons per feed |
| `AppResourceUsage.swift` | Receive monitor GPU intervals without counting shared work twice |

- [ ] Add subscribers without replacing raw recording callbacks or the Program
  consumer. Preserve source time separately from mapped Program time.
- [ ] Replace shared renderer ownership with explicit surface bindings. Each feed
  session analyzes once for all subscribed main/tray/detached views.
- [ ] Implement CleanPreviewService with shader-independent CPU owned-copy
  staging, reserved memory, four bounded runtime copy slots (one per target) and shared native presentation.
  Test IOSurface and packed inputs without passthrough producer retention.
- [ ] Add stream/configuration generations and invalidate incompatible work after
  reconnect, device/format/LUT/stage changes, Program cuts and feed removal.
- [ ] Centralize per-feed demand, preserving retry behavior. A recording keeps
  its source alive after every monitoring surface closes or freezes.
- [ ] Keep explicit manual Stop separate from monitor visibility. Visibility
  changes cannot use whole-feed Stop as a shortcut to releasing monitor demand.
- [ ] Admit only supported formats and known/declared signal interpretations;
  evaluate eligibility per tool so guides/native preview remain usable when
  calibrated analysis is unavailable.
- [ ] Include an explicit Program capability row: Output picture/guides/zebras/
  scopes available; source peaking and false color unavailable pending pairing.
- [ ] Implement atomic source/output bundle admission and source sequence IDs;
  test duplicate/reset PTS, cadence reduction and asynchronous LUT restoration.
- [x] Decode older settings with tools off; persist stable per-feed choices.
  Drain only affected subscriptions/resources when a feed is removed.

Exit: two synthetic feeds with different patterns/settings stay independent.
Stopping/removing one does not change the other's monitor or recording. Two
surfaces on one feed share analysis rather than doubling it.

### M3 — Workspace shell, geometry and guides

- [ ] Add a target-labeled toolbar under each picture and one reusable monitor
  tile. Deliver the user-facing Single / Side by Side selector and two simultaneous
  feed previews now, including tools-off operation; workspace polish completes in M7.
- [ ] Add master tools enable, Clean view, Freeze and signal/stale status badges.
  Temporary viewing actions do not change saved tool configuration.
- [ ] Implement separate source-to-output correspondence and image-to-view
  transforms for guides/compositing/peaking. Cover supported aperture, scale,
  orientation, pixel aspect, aspect fit and zoom without assuming equal rectangles.
- [x] Add thirds, center cross and safe-area overlays. Guides add no analysis
  kernels or staging buffers beyond the clean-preview path.
- [x] Retain native picture rendering when no pixel tool requires composition.
  Scope-only use does not instantiate an additional picture renderer.
- [ ] Verify tools-off Side by Side and clean fallback with missing
  analysis shaders and occupied analysis slots. Test clean-copy exhaustion/stale
  placeholders, and Clean while frozen without exposing a live frame.
- [ ] Implement surface visibility/occlusion handling while preserving recording
  and existing automatic-preview intent. Add feed-specific accessibility labels
  and keyboard actions; avoid per-frame accessibility announcements.

Exit: resizing/high-DPI/split views maintain alignment and correct demand while
camera/recording frames stay clean.

### M4a — Signal contracts, calibration harness and zebras

- [x] Write scalar reference math before Metal kernels. Specify matrix, range,
  primaries and transfer interpretation for each supported stage/format.
- [x] Distinguish reliable metadata from a user-declared camera/log profile.
  Label conflicts/unknowns and require a compatible contract for calibrated presets.
- [ ] Add ramps, below-black, above-white, isolated-channel and boundary fixtures
  for supported pixel formats/bit depths. Do not clamp away extended levels before analysis.
- [x] Implement above-threshold and band-mode zebras, IRE threshold/width and
  stable display-sized stripe appearance.
- [ ] Verify storage unpacking separately from transport and Log normalization,
  including S-Log3 reference anchors, chroma siting, padded rows and range overrides.
- [ ] Define tool capabilities for declared/unknown Log, SDR and HDR inputs;
  keep raw signal inspection distinct from calibrated exposure/display support.
- [ ] Publish scalar fixtures and an initial supported-profile table. Set
  explicit numeric tolerances: integer unpacking/code boundaries must match
  exactly; document float error and quantization at each supported curve/zone.

Exit: signal interpretation and nonblocking upload/composition paths have tested
contracts. M5/M6 may proceed while M4b reference qualification continues.

### M4b — EL Zone and ARRI false color

- [ ] Obtain authoritative EL Zone integration/zone-color material and resolve
  applicable implementation/branding terms; record sources and remaining gaps.
- [ ] Implement and verify S-Log3 decoding, source color interpretation, 18% gray
  reference and stop-based zone classification. Keep original Log as its input.
- [ ] Implement the specified EL Zone palette and stop legend, including near-gray
  subdivisions and end zones. Version its specification and test just below, at
  and above every boundary. Do not substitute the former generic IRE palette.
- [ ] Validate source exposure and supported EI/reference treatment against
  official Sony material and authoritative EL Zone behavior. Display unsupported
  source/profile/reference combinations explicitly.
- [x] Implement the separate ARRI classifier from the published specification;
  verify supported camera/LogC/EI profiles, range normalization, grayscale
  fallback, colors and every boundary against the official tables.
- [ ] Qualify and label the FX3 S-Log3 adaptation separately, including its sensor
  reference limitations. Keep unqualified combinations unavailable with a reason.
- [ ] Add Off / EL Zone / ARRI selection, mode-specific legends and independent
  per-feed persistence. Verify mode switches discard stale GPU results and do
  not change another feed's settings or restart capture/recording.
- [ ] Compose on the monitor branch using an explicit display color space.
  Preserve original buffers/attachments and avoid a second LUT/transfer conversion.
- [ ] Test Source/Output and LUT changes during in-flight work; results must match
  the current frame stamp and interpretation/configuration revision. Changing a
  viewing LUT must leave source false-color classification unchanged.
- [ ] Test middle gray, each supported positive/negative exposure stop, boundary
  subdivisions, neutral and saturated patches, reference offsets, superwhites,
  invalid inputs and independent Log settings on simultaneous feeds.

Exit: CPU/Metal results agree with each mode's documented reference within
specified precision. Legends and source/reference/compatibility status are
accurate. EL Zone requires its integration/specification dependency resolved;
ARRI and any FX3 adaptation require their separate profile qualification.

### M5 — Full-resolution source focus peaking

- [ ] Derive source-resolution luma/detail without allocating a full-resolution
  float RGB image solely for peaking. Implement noise rejection and thresholding.
- [x] Add red default highlights with alternate color, sensitivity and opacity.
- [ ] Match masks by source/generation/sequence, verify PTS and map to displayed
  picture geometry. Do not introduce a pairing FIFO.
  Missing matches skip the mask instead of reusing unrelated highlights.
- [ ] Keep focus detail independent of output downscaling/sharpening. Label
  `Focus: Source` when the picture shows Processed Output.
- [ ] Validate sharp/blurred/diagonal edges, flat fields, chroma-only detail and
  synthetic noise across source/output geometry and cadence changes.
- [ ] Use an asymmetric clean-aperture fixture through actual 4K-to-1080p
  processing, verifying correspondence despite changed/removed output attachments.
  Test non-square pixels/orientation where supported and reject unsupported maps.

Exit: useful, aligned highlights without stale masks or noise-driven full-screen
red output; no claim of autofocus or a universal focus threshold.

### M6 — RGB parade and luma waveform

- [ ] Define scope axes, bin precision, extended-range display and signal labels.
- [ ] Specify per-update bin clearing, saturating counters and bounded optional
  trace persistence using monotonic time. Do not accumulate indefinitely or
  average level values. Verify horizontal position and intensity normalization
  across sampling-rate changes; any temporal decay resets on cuts/format changes.
- [x] Accumulate channel levels by horizontal position on the GPU. Build three
  adjacent RGB graphs and a luma waveform with graticule, intensity and gain.
- [ ] Use bounded point/stratified sampling to reduce work without averaging
  narrow peaks away. Expose effective sampling and its limitations.
- [ ] Keep scope and picture cadence independent. Use GPU textures or small
  bounded counters, without full-image CPU readback or SwiftUI pixel arrays.
- [ ] Validate channel order, spatial patches, bars/ramps, empty bins and clipping.
  Compare against independently configured FFmpeg scopes with matching signal assumptions.
- [ ] Add No Signal, Stale and Freeze behavior; clear incompatible accumulation
  after signal changes/Program cuts.

Exit: spatial positions and levels are reference-tested, and slow scopes cannot
build a source-frame backlog.

### M7 — Multi-view UX and resource governor

Initial budgets are conservative proposed policies. Revise them only with measured
qualification results and an explicit rationale.

| Resource | Starting policy |
| --- | --- |
| Borrowed input | At most three analysis bundles plus four independently admitted clean-copy inputs globally, one of each kind per target including retired jobs; no capture-frame FIFO |
| Monitor GPU work | One analysis job per target and three globally, including upload/composition and retired jobs; bounded presentation slots separately |
| Scope cadence | Current request: per-feed 15 Hz default, selectable 10/15/30; pressure reduces 15/30 to 12 Hz and preserves explicit 10 Hz. Shared target cache, three analysis slots and fairness determine delivery. Original focused-15/background-10 priority remains unimplemented |
| Composite size | Default at most 1080p; source-resolution peaking remains separate |
| Module-owned memory | 256 MiB including a 64 MiB reserve for clean staging/presentation, paired clean/decorated freeze results and retiring generations; analysis uses only unreserved capacity; borrowed bytes reported separately |
| UI diagnostics | Approximately 2 Hz; video presentation stays outside observable state |
| Hidden work | No analysis submissions without a live picture/scope subscription |
| Picture latency | Initial goal: p95 offer-to-ready within two picture periods at the requested rate; measure separately from native display latency |

- [ ] Implement fair feed-aware admission and shared result reuse. Focusing a
  feed may raise its refresh rate but cannot permanently starve another feed.
- [ ] Account for textures, display buffers, scope bins and retained results
  before allocation. Avoid per-window duplication and large float RGB intermediates.
- [ ] Include pixel-buffer row/plane padding, texture allocation sizes, pool
  reserves, frozen/clean pictures and per-surface drawables in estimates. Trace
  actual process footprint too; driver/native renderer allocations are not all
  exposed by a module ledger. Reject extra surfaces/freezes when admission fails.
- [ ] Under pressure, reduce background scope rate, sampling and composite size,
  then suspend costly tools. Keep recording/camera quality unchanged.
- [ ] Add hysteresis and a recovery grace period. Report requested/effective
  quality and why monitoring has degraded.
- [ ] Qualify useful picture cadence and latency, not only zero recording losses.
  A monitor that skips every frame is an isolation test, not a working tool.
  Report age and effective rates under load; lower requested cadence explicitly
  when the picture-latency goal cannot be sustained.
  Normal-operation rates must also satisfy the numerical M0 workload minimums;
  an explicit degraded/failure state does not establish nominal performance.
- [ ] Keep full-resolution peaking analysis when admitted, reducing its update
  cadence or suspending it under pressure. Never silently relabel a downsampled
  edge map as source-resolution peaking. Retired jobs retain their slots/budget
  until actual completion, even after feed removal or a soft timeout.
- [ ] Complete single/two-up/four-up and detached views with per-tile targets,
  focused controls and versioned workspace restoration. Finish compact tray UI.
- [ ] Finish Side by Side divider resizing, swap tiles, temporary expand/restore,
  compact controls and saved split ratio. Four Up uses a 2×2 video grid with
  independent tile feed bindings and scopes attached to the correct picture.
- [ ] Repeat M3's tools-off and missing-shader/occupied-analysis-slot clean
  fallback tests with Four Up, including bounded clean-copy exhaustion behavior.
- [ ] Verify two distinct moving synthetic feeds remain visible and update
  together with tools off/on. Changing, freezing or stopping one tile must leave
  the other live; layout changes must preserve recordings, Program selection and
  per-feed settings. Test resize, saved layout restoration and missing-feed placeholders.
- [ ] Add one-time Copy Settings and per-feed Reset, with understandable legends.
- [x] Retire cancelled resources only after GPU completion. Committed Metal work
  cannot be assumed cancellable; never reuse a buffer still referenced by GPU work.
- [ ] Report monitor timing, skips, memory and result age separately from recording
  losses, and contribute GPU intervals to the existing app total exactly once.

Exit: multiple views, reconnect and slow/delayed consumers remain bounded and
recording stays responsive with explicit monitoring degradation.

### M8 — Qualification, rollback and signed delivery

- [ ] Run existing app tests, package tests and deterministic multi-feed isolation
  and failure-injection harnesses. Decode synthetic recording outputs for verification.
- [ ] Test no-copy packed input and forced staging fallback, including allocation
  failure, padded/misaligned buffers and delayed completion during source removal.
- [ ] Test stalled work across repeated reconnects, mode changes and new windows;
  live plus retired resource totals must stay bounded. Test Freeze on only one
  of two surfaces, mixed source/output analysis and native/composed handoff.
- [ ] Verify math with independent published anchors/tables as well as CPU/Metal
  agreement. Sharing the same wrong normalization in both paths is not a pass.
- [ ] Exercise recording with tools toggling, changing views/feeds, window closure,
  memory admission, missing shaders/profiles, reconnect, Program cuts and Stop/Quit.
- [ ] Repeat virtual-camera baseline/enabled comparisons for feed and Program
  destinations with active consumers, simultaneous recording and layout/tool
  changes. Gate drops/cadence/timing and latency using the predeclared tolerances.
- [ ] Check every named sustainable workload against its M0 minimum preview/
  scope rates and age limits. Missing numeric thresholds are an incomplete gate.
- [ ] Inject delayed/failed completions with a controlled driver. Do not run
  deliberately nonterminating shaders on the user's GPU.
- [ ] Run a sustained 30-minute four-feed synthetic comparison at a sustainable
  qualified workload, plus sustained ProRes and HEVC recording runs. Track steady
  memory, callback latency, drop counts, effective monitor FPS and resource usage.
- [ ] Define sustainable capacity using tools-off baselines first; record machine,
  OS, codec settings, storage, thermal state, workload seed and repeated run order.
  Do not claim isolation from unpaced synthetic offers that bypass real producer
  admission/ownership. Alternate baseline/enabled runs to expose thermal drift.
- [ ] Mark unavailable physical multi-input/driver qualification pending. Synthetic
  routes do not establish real-device behavior or unlimited hardware capacity.
- [ ] Validate signed host resources and unchanged camera extension/entitlements.
  This module does not require replacing the installed camera extension.
- [ ] Install only when recording/finalization is idle; preserve preferences,
  recordings and the selected folder. Do not capture real-camera test footage or
  screenshots without an explicit test instruction.
- [ ] Verify the installed native/tools-off preview, main/tray monitor UI, recording
  controls and existing virtual-camera connection. Document receipts in `VALIDATION.md`.
- [ ] Move disposable synthetic media and build caches to Trash after reviewing
  results. Preserve source and user recordings.

Exit: every release gate passes. Failed qualification leaves the recording path
on known-good behavior and the incomplete monitoring path unavailable/off.

## Qualification matrix and release gates

| Dimension | Required coverage |
| --- | --- |
| Feeds | 1/2/4 synthetic; physical devices where available; no four-feed configuration cap |
| Source | Supported 4K 10-bit 4:2:2 layouts; 29.97/59.94; missing/malformed signal |
| Output | Bypass/processed; 4K/1080p; supported 10-bit/8-bit output; cadence reduction |
| Recording | ProRes/HEVC; embedded audio; source/record-start/wall-clock timecode modes |
| Virtual camera | Active feed and Program consumers; tools-off/enabled delivery counts, cadence, mapped timing, transport drops and latency |
| Tools | Off, each tool, valid overlay combinations, scopes only and multiple feeds |
| Surfaces | Main/tray/split/detached; hidden, occluded, closed and frozen |
| Lifecycle | Start, pause/resume, reconnect, LUT/format change, feed removal, cuts, Stop/Quit |
| Failures | Busy admission, slow consumer, delayed/failed completion, missing shader/profile, memory pressure |
| Recovery | Interrupted synthetic take still recoverable with monitoring active at interruption |

Use pairwise functional coverage followed by intended maximum-load combinations;
avoid an impractical Cartesian product without omitting high-load recording tests.

Hard release gates:

- Zero additional recording losses attributable to monitoring in qualified runs.
- Zero additional virtual-camera delivery losses/cadence regressions attributable
  to monitoring, with mapped timing preserved and p95/p99 latency within the
  predeclared baseline tolerances. Apply to feed and Program destinations.
- Encoder-input pixel bytes and timing match the synthetic reference. Separately
  encoded MOV files do not have to be binary-identical.
- No monitor waits or unbounded submissions on capture/recording callbacks.
- Tool failures and surface closure/teardown leave recording alive.
- Recording Stop/finalization and crash recovery remain correct.
- Memory and source leases reach a steady bound and recover after teardown.
- Independent feed state, measurement calibration and geometry tests pass.
- Named workloads meet their minimum sustained per-tile picture/scope rates and
  age limits. Shader-independent clean previews and their bounded fallback pass.
- Main-queue heartbeat remains responsive under injected delays, using bounded
  waits and host-appropriate timing tolerances.

Record baseline/enabled median/p95/p99 callback and recording-admission latency,
drops, effective monitoring FPS, CPU/GPU and memory. Repeat measurements to account
for scheduling noise; changed input or additional media losses never pass as noise.

## Repeatable validation tooling

Deliver a package test command with its scratch directory on the external build
root, and integrate it into `scripts/test.sh` alongside existing app checks.
Add two synthetic-only entry points:

- `scripts/monitor-tools-smoke.sh`: tap isolation, geometry/color fixtures,
  feed/Program identity, bounded overload and stale-result rejection.
- `scripts/monitor-tools-stress.sh`: sustained recording comparisons, lifecycle
  changes, resource pressure and controlled failure injection.

These scripts now exist, along with `monitor-tools-package.sh` and
`monitor-tools-recording.sh`. Their existence does not establish all planned
qualification runs have passed.
They need external artifact paths, bounded watchdogs, workload parameters and
concise machine-readable receipts. Their default must not open a physical camera.
Unavailable GPU tests are explicitly skipped/unqualified, never silently passed.
Core math tests must run independently of GPU availability.

Retain `scripts/recording-recovery-smoke.sh` as a container-recovery regression,
and use the existing signed `scripts/build.sh --signed` plus bundle validation
for the final host. Do not repeatedly run broad tests after passing checks unless
code changes, failures or unresolved qualification questions justify the repeat.

## Rollout and fallback

Existing/new feeds start with tools off unless saved configuration explicitly
enables them. Lazy initialization and a master tools disable leave native preview
and recording usable if analysis resources fail. Disabling tools releases their
analysis demand/resources without editing recorder or camera state. Visible clean
pictures retain presentation demand and bounded CleanPreviewService resources
until hidden/closed; committed GPU resources retire only after completion.

Do not introduce a Monitor Tools dependency into `SourceRecorderCore`,
`AVAssetSourceRecordingWriter`, `RecordingOutputManager` or recovery. Recording
integration is restricted to the M0 admission prerequisite, demand ownership and
tests proving isolation. Preserve codec/container/path/finalization contracts.

Version persisted configurations, palette definitions and shader/resource caches.
Migrate preferences additively. Global tools disable is the fallback for a
failed tool build while retaining per-feed choices for a later qualified build.
Completed recordings must never require migration or rollback for this feature.

## Technical reference sources

- [EL Zone System, official site](https://www.elzonesystem.com/): system identity
  and creator; public demonstrations over Log imagery.
- [Sony CineAlta Workflow Guide v1.2](https://pro.sony/s3/2024/11/25133734/Sony_CineAlta_WF_Guide_v1.2.pdf):
  exposure-stop interpretation, 18% gray reference, displayed stop scale and the
  distinction between EL Zone and conventional signal-level false color.
- [Sony Monitor & Control shooting-assist guide](https://helpguide.sony.net/promobile/mc/v1/en/contents/shooting_assist_functions.html):
  supported S-Log3/profile conditions and the distinction between source/EI-applied
  display behavior. Its Sony-app license statement does not establish Ultracam's
  integration terms.
- [EL Zone official contact](https://www.elzonesystem.com/contact): route for
  specification/integration questions if the user later authorizes outreach.
- [ARRI LogC False Color specification, 4 February 2025](https://www.arri.com/resource/blob/390448/871b733469a2f2c2099ca51b1516bcd1/arri-logc-false-color-specification-data.pdf):
  authoritative algorithms, categorical colors, camera/LogC/EI tables and range
  rules. This specifies ARRI input behavior, not an FX3 sensor calibration.
- [Sony S-Gamut3.Cine/S-Gamut3/S-Log3 technical summary](https://pro.sony/s3/cms-static-content/uploadfile/06/1237494271406.pdf):
  inverse curve, native code-value anchors and range conventions; not proof of
  the FX3 HDMI/capture-chain scaling.
- [Apple Metal completion handlers](https://developer.apple.com/documentation/metal/mtlcommandbuffer/addcompletedhandler(_:))
  and [blocking completion wait](https://developer.apple.com/documentation/metal/mtlcommandbuffer/waituntilcompleted()):
  asynchronous completion/status handling versus thread-blocking waits.

## Definition of done

Every requested tool works on independent feeds; main, tray, multi-view and
detached workflows are usable; measurements are calibrated/labeled; package and
host checks pass; recording isolation is qualified under sustained load and
controlled failures; and the signed app is verified installed with user settings
intact. No physical-hardware or capacity claim is complete without an executed
qualification receipt.
