# Validation

## Capture discovery and Source overlay corrections — October 20, 2026

Signed host **14** is installed in `/Applications/Ultracam.app`; extension **4**
is unchanged (all 33 executable sections match). The host requires
`com.apple.security.cs.disable-library-validation` to load the installed
Blackmagic-signed DeckLink framework, following [Apple’s third-party framework
loading guidance](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation).
Before this correction, the signed host
rejected the framework because its signing team differs, then incorrectly
reported Desktop Video unavailable despite macOS detecting the UltraStudio.
Bundle validation now rejects a host missing this setting and rejects the same
exception in the camera extension. Hardware capture was restored in host 13:
3840×2160 v210 10-bit 59.94 input, 1920×1080 420v 29.97 output, live preview,
and 595 independently consumed virtual-camera frames in 20 seconds with zero
nonmonotonic timestamps. No frames were recorded or read back by that check.

Source picture overlays incorrectly reused the source-to-processed-output
mapping. Downscaling therefore displaced focus/false color and extended clamped
mask edges into lines. Source and fallback-to-source pictures now keep identity
mapping; Processed Output retains its declared transform. Three new GPU tests
first reproduced eight failing image comparisons, then passed. They cover BGRA
and native packed v210, half-scale and crop offsets, full-raster image equality,
expected source edge/color positions, and the processed-output control.
The complete strict-concurrency/warnings-as-errors package suite passes **115
checks**: 44 Core, 48 Metal and 23 UI. Capture/recording submission code is unchanged.
The installed host 14 independently delivers **599** physical-input virtual-camera
frames in 20 seconds, 1920×1080 420v, with zero nonmonotonic timestamps. Optional
window capture found the app background-occluded; alignment is qualified by the
GPU image comparisons, not a live visual comparison. No recording was started.
Temporary build/test copies are in recoverable Trash; evidence and user media
remain preserved, and the stable app link points to the installed copy.

Installed executable SHA-256:
`0ca8f6a9353b42f3c5730966cb10f9f64f5d805f29986e8f374023c9774b726f`.
Evidence: `/Volumes/8TB/cinesomatic-director-work/agent-work/ultracam/camera-fix13`
and `/Volumes/8TB/cinesomatic-director-work/agent-work/ultracam/source-geometry-fix14`.
The implementation and sustained results below describe their earlier frozen
snapshot; they are not new sustained measurements of this coordinate correction.

## Monitor tools implementation — October 20, 2026

The host includes per-feed Monitor Tools, Single/resizable Side by Side/Four Up
layouts, detached views and an independent tray choice. Guides, IRE zebras,
source-focus peaking, RGB parade and luma waveform are implemented. ARRI-style
false color now supports Sony S-Log3 in S-Gamut3.Cine and S-Gamut3 without an
ARRI camera. It decodes each Sony channel before source-gamut scene luminance
and LogC3 EI800 reference classification; its highlight/shadow bands do not
claim Sony sensor clipping or noise limits. Literal ARRI LogC3/LogC4 EI800
profiles remain available. Freeze/Clean remain local to each surface; source
and processed signals are independent settings. Recording receives untouched
source frames before processing admission. Tools-off selected main/tray preview
keeps its native path. Program source-focus/false color remain unavailable, and
EL Zone false color was removed on 2026-10-24 (a saved selection reads as off);
see [color evidence](docs/MONITOR_COLOR_REFERENCES.md).

The pre-correction frozen `bash scripts/test.sh` run passed **316 app tests, zero failures**,
34.681 seconds, and **112 package tests, zero failures** (44 Core including
11 color, 45 Metal including 6 Sony, 23 UI). The isolated actual AppModel/hosted-window suite also passes **11 integration
checks**, with complete strict concurrency and warnings as errors. A separate
strict-concurrency / warnings-as-errors package run passes without warnings. Regressions cover
all 1,024 native 10-bit Sony codes against the CPU reference, native/rescaled
transport, gamut differences, pre-LUT source analysis, existing Sony declarations
and atomic settings updates through a normalizing coordinator-style binding.

That frozen signed host build **12**, extension **4**, passed metadata,
host-only shader resources and strict deep code-signature verification.
Executable SHA-256:
`6ca14835ece9833f0f2f8783d690ecb83b030e0a08ec46070c0c2b176550992d`.
Receipt:
`/Volumes/8TB/cinesomatic-director-work/agent-work/monitor-final-verification/verification-sony-final.json`.
Earlier critical-feedback and pre-feedback receipts remain historical evidence.
The owner's disk recovery cleared the Instruments storage hold. Current paired
and sustained synthetic recording workloads pass. App-only lifecycle regressions
reproduced and fixed the detached empty chooser, stale removal projections, late
removed-feed updates and retained sink consumers. The fresh signed build is now
installed in `/Applications/Ultracam.app`. Native accessibility checks show the
monitor controls/layouts and idle recording state; opening/cancelling a menu
confirms responsiveness. No screenshots, physical capture or recording were
used for this installed-app check.

The production capture integration test paced 90 frames at 29.97 through the real
nonlinear LUT and 4K-v210-to-1080p-NV12 path, camera submission and recorder core,
with monitoring off then on. Each run delivered all 90 measured camera/recording
frames with exact source timing and no source mutation. Camera latency p95 was
5.437/5.401 ms and p99 6.534/9.176 ms (off/on). This is synthetic in-process camera
submission, not installed receiver or physical-device qualification. The test also
covers stalled monitor initialization, hiding, removal, Stop and retired results.
Blocked-consumer regressions also prove producer release before analysis
GPU commit or success/fallback/error delivery, bounded pending errors and
working-set reuse before consumer completion. Actual synthetic
NSWindow/NSHostingView checks cover resize, minimize, ancestor
hide, close and dual-window frozen clean/decorated/scope/configuration identity.
A separate actual 4K-v210-to-1080p-NV12 regression verifies an asymmetric source
aperture survives on the source while processing removes output aperture/display
attachments, and source-resolution red focus highlights remain at the expected
downscaled edge on the full-raster output picture.

Review and expanded tests caught and fixed an exact native-code ARRI boundary
error, capture-side resource retirement/reconfiguration hazards, and a planar
allocation bug: aggregate planar bytes-per-row was incorrectly used as alignment.
Real 4K and awkward/padded-stride copy fixtures now check active bytes and budget.
Additional fixes release producer storage before consumer callbacks while retaining
delivery-memory charges, validate frame order at final presentation storage, and
cancel a pending Freeze even if a background result arrived before UI publication.

Installed: `/Applications/Ultracam.app` (host 12). The external stable app link
now points there. All 33 camera-extension Mach-O sections match installed
extension 4, so no activation request was made. The prior app copy, task-owned
build caches and 103.818 GiB of synthetic test media were moved to recoverable
Trash; Trash was not emptied. Compact receipts/logs, profiling evidence, project
source, preferences, bookmarks and user recordings were preserved. Delivery and
cleanup receipts are `installation-final.json` and `cleanup-final.json` under
`monitor-final-verification`. Old executable/media paths in historical receipts
identify tested artifacts that have since been Trashed; their hashes, manifests
and measured results remain preserved.

`bash scripts/recording-recovery-smoke.sh` passes all four synthetic interrupted
ProRes/HEVC cases, interrupted at 4 and 14 seconds. Readable recovered durations
are 1.0017 and 11.0117 seconds, with timecode present after the later fragment and
original interrupted files unchanged. Receipts are under
`/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam/recording-recovery/20261020T050417-98876`.

The final suite covers fair three-job admission, verified decrease-only lease
shrinking, pressure/recovery diagnostics, local scope visibility, zoom, soft
deadlines and budgeted native presentation. The shared reservation ledger caps
are 256 MiB total and 192 MiB non-clean, including retired resources; clean
presentation satisfies the 64 MiB reserve. Exact module-owned allocation charges
and estimated additional compositor allowances share that ledger. These are not
hard bounds on whole-process, OS or driver memory; borrowed producer storage and
the existing native preview baseline are separate. Source focus remains full resolution when pressure reduces
composite height and scope sampling/cadence. Reduced scope requests are now
12 Hz for the default 15 Hz setting; explicit user 10 Hz remains 10 Hz. The
previous reduced 10 Hz target measured 9.9859 Hz at 29.97 input in a 30-second
check, so the target was corrected while retaining the strict 10 Hz acceptance
minimum and phase-locked scheduling. Native surface tests cover explicit
no-capacity outcomes and admission recovery after teardown/resize.

Source-only priority feedback adds per-producer metadata handles independent of
monitor visibility. Queue age plus processing time exceeding one original input
frame interval pauses new analysis globally, retaining bounded owned clean
preview. Committed work remains charged. Fresh healthy samples spanning one
second permit reduced analysis; five further fresh healthy seconds restore
normal quality. Gaps exceeding two frame intervals restart that health span.
Stopped/removed producers cease contributing pressure, and stale generations or
replaced handles cannot revive or remove current state. This enforces the planned
priority contract; it does not establish the cause of earlier OS/driver tails.

Installed-extension synthetic loopback passes all six paired output profiles:
1080p NV12, 4K x422 and 4K v210 at 29.97/59.94. Each tools-off and tools-on
segment runs at least 30 seconds. All 12 segments deliver all **16,194**
frames with exact active pixels, PTS, duration and order, zero producer retries,
verified pre/post source policy, valid source cadence and useful monitoring.
Receiver p95/p99 stay within baseline +2/+5 ms. Both segments share one
connection and rational source grid; latency is timestamped by the SDK
queue-insertion callback, with later inspection delay reported separately.
All latency outliers remain in the histograms/log, including earlier failed
short-comparison receipts. The extension remains build 4. Final receipt:
`/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam-e2e/cmio-smoke/controlled-source-final-v5-cap12-20261020/receipt-30s.json`.
This qualifies synthetic IPC, not physical input or Program cuts.

Current Sony short workloads all pass with fixed rate, age, latency and media
gates. Four native 4K clean targets deliver 29.796–29.829 pictures/s per target,
13.6/24.8 ms p95/p99 age and zero retained ledger bytes after teardown. Corrected
single-feed Sony-Cine ProRes and HEVC comparisons preserve all 900 source,
processed and recording frames per segment, exact audio/timecode/timing, zero
capacity rejections and useful picture/scope rates. ProRes pipeline p95/p99 is
5.6/7.3→5.1/5.8 ms and HEVC 5.5/9.8→5.4/6.2 ms (off→on).
The second Sony gamut's ProRes comparison also passes. Two-feed Sony-Cine ProRes
passes with Source pictures on both, Source scopes on feed 0 and Processed Output
scopes on feed 1; picture rates are 29.962/29.397 Hz, scope rates 14.981/13.883 Hz,
p95 picture ages 7.9/14.9 ms and scope ages 8.0/15.4 ms. Every feed preserves all
900 processed/recorded frames on each side, with zero capacity rejections.

Current receipts under `monitor-final-verification`:
- `native-clean-sony-final-30s/receipt.json`
- `sony-cine-admission-corrected-pair-30s/takes/recording-receipt.json`
- `sony-sgamut3-secondary-pair-30s/takes/recording-receipt.json`
- `sony-two-feed-cine-pair-30s/takes/recording-receipt.json`

The first Sony ProRes baseline admitted only 899/900 processed frames while
preserving all recording media. Helper review found its statistics mutex used
`try()` for admission, unlike production's blocking metadata-only lock. A focused
RED/GREEN test proves the mismatch and the corrected helper preserves capacity
12, reports capacity/wait/high-water values and drains to zero. The particular
899-frame rejection had no reason telemetry, so its cause is not asserted. Its
failed receipt remains preserved; the new comparison has a new source manifest.

Thirty-minute native clean and two-feed ProRes sustained checks pass. Native
clean runs 1800.029 seconds with 215,482 observed 3840×2160 clean frames,
29.926–29.929 pictures/s per feed, p95/p99 ages 9.6/14.0 ms, source 29.960 Hz,
peak ledger 221,642,752 bytes and retained ledger zero after teardown. Source
policy setup/read/end-read/restore succeed and process activity is observed.

Two-feed Sony-Cine ProRes admits, processes and fully decodes all 53,947 frames
per feed (107,894 total), preserving exact source/timing/audio/timecode references
with zero recording, encoder or capacity drops. Pipeline p95 is 7.1 ms per feed
versus matching short-off 5.8/5.7 ms; p99 is 9.1/9.0 ms versus 8.2/7.1 ms. Fixed
+2/+5 ms limits pass. Pictures run 29.293/28.686 Hz, scopes 14.475/13.051 Hz;
p95 picture ages are 11.5/20.3 ms, scope ages 11.7/20.8 ms. Source is about
29.961 Hz, maximum pending is four of twelve, pending and ledger both drain to
zero. Full decoding takes 183.97 and 167.49 seconds.

The final single-feed Sony-Cine HEVC sustained run also passes: all 53,947
frames are admitted, processed and fully decoded, with exact source/media/audio/
timecode references and zero recording, encoder or capacity errors. Pipeline
p95/p99 is 5.9/7.6 ms versus matching short-off 5.5/9.8 ms. Pictures run 29.633 Hz,
scopes 14.776 Hz, p95 ages 13.3/13.6 ms; source is 29.952 Hz. Maximum pending is
four of twelve, and pending/ledger both drain to zero. Source policy readback /
restore succeed; process activity is observed. All three sustained stages pass,
fully decoding **161,841 recorded video frames**. The sequence lasts 98m39s,
including 90 minutes of capture plus full decode. Current run root:
`/Volumes/8TB/cinesomatic-director-work/agent-work/monitor-final-verification/sony-sustained-20261020T214037`.
Per-stage `sustained-gate-receipt.json` files retain exact baselines and measured
gates. `sequence-results.json` reports the completed passing sequence. The recording checks are enabled-only runs compared
to matching short off baselines, not 30-minute paired isolation. Final full-suite
and installed delivery checks pass after the app-only lifecycle corrections.
Physical input/receiver qualification remains
separate. Historical native-Source HEVC p99 failures (13.8→28.1 ms) and command
timing evidence remain in [the audit](docs/MONITOR_TOOLS_AUDIT.md); their OS/driver
cause is unresolved and passing current checks does not prove that cause fixed.

## Per-camera recording folders and PC timecode default — October 19, 2026

Each camera's recording row now offers a folder override, persisted by feed ID
with a read/write sandbox bookmark. Cameras without an override use the shared
default folder. A camera override also works without a shared default. Changing
folders affects the next take; active writers retain their directory access.
Recovery scans the default and camera folders and retains the corresponding
root for each recovery operation. PC time is the default recording timecode,
sampled at the first video frame; other timecode modes remain selectable.

`bash scripts/build.sh`: release build and camera bundle metadata validation
passed. `bash scripts/test.sh`: **292 tests, zero failures**, 27.630 seconds.
New checks cover per-camera routing, fallback and clearing, next-take changes,
bookmark restoration after rename/reorder, and recovery across selected folders.

## Recording statistics and app resource summary — October 19, 2026

Signed host build 11 adds independent feed status, elapsed time, actual output
file bytes, video frame losses, encoded FPS/bitrate and encoder details. Stats
are sampled off the main actor at 2 Hz during recording/finalization, retained
after Stop, and reset on a new take. Pause freezes elapsed time. Video losses
exclude intentional pause/stop callbacks and remain separate from audio packet
losses. Encoder details include hardware status, smoothed/peak callback latency,
queue occupancy and errors. A generation guard rejects late snapshots of an
older take after a new recording starts.

`bash scripts/test.sh`: **289 tests, zero failures**, 27.138 seconds. Added checks
cover independent per-feed rates/counters, pause/resume clocks, retained/reset
model statistics, invalid audio accounting and GPU interval union/clipping.
Six real 4K/59.94 synthetic native recordings (three per codec) each encoded all
60 frames with no drops or encoder errors. All reported hardware acceleration,
nonzero encoded byte counts, callback latency and empty queues after stop.

The shared resource summary samples whole-process user/system CPU time and
physical memory footprint. GPU video busy percentage is the union of completed
Metal intervals across all video-processing/copy queues over the previous
second; hardware encoders and the system compositor are excluded. The installed
app displayed live CPU roughly 17–20% and GPU video roughly 8–9% with the saved
4K-to-1080p processing pipeline. UI readings were checked through accessibility;
no camera screenshots or recordings were taken as tests.

The user's existing recording was left running until they stopped it and
explicitly authorized installation. The signed update is installed at
`/Applications/Ultracam.app`, with the capture directory and HEVC choice restored.
Strict signature and bundle checks pass. Camera extension build 4 is unchanged.

## Fragmented MOV and recovery — October 19, 2026

`bash scripts/test.sh`: **284 tests, zero failures**, 27.883 seconds. Recovery
checks include failed-stop retention, live-session exclusion, failed export
retry, bookmark restoration, concurrent launch scans, journal filename
reservations across managers, and cancellation preserving unowned files.
Strict signature and bundle metadata validation pass for the installed build.

The signed host build 10 adds QuickTime fragmentation for both ProRes 422 HQ
and HEVC Main10 4:2:2, with initial/regular intervals of 1/10 seconds. Failed
stops preserve media and a journal rather than publishing an unfinished file
or deleting it. Recovery re-muxes to a separate readable `_Recovered.mov` and
leaves the original unchanged. Journals are locked while a recording or
recovery owns them; directory traversal, symlinks and foreign partial files are
excluded. Folder access persists with a read/write sandbox bookmark.

`bash scripts/recording-recovery-smoke.sh` passed four synthetic 4K/59.94
SIGKILL tests: each codec recovered 1.001667 seconds from a take killed after
4 seconds and 11.011667 seconds from a take killed after 14 seconds. Audio
survived in all four; generated timecode survived in both longer takes. All
four recovered movies passed full FFmpeg video/audio decode and retained
`yuv422p10le`. Originals were compared byte-for-byte and remained unchanged;
active recordings were excluded and completed recoveries were not offered
again. The final smoke run repeated these cases after the launch-scan fix.

Six normal synthetic stops also passed (three per codec), with all 60 frames
encoded, no drops or encoder errors, and finalization between 11 and 26 ms.
The signed sandboxed app restored its chosen folder after restart, offered an
interrupted synthetic take on launch, and recovered it through the actual UI
with video, PCM audio and generated timecode present. Concurrent launch scans
are serialized to prevent a transient journal lock from hiding a take.

No physical-camera footage was recorded or exported for these tests. The
recording destination was restored to `/Volumes/8TB/capture`, HEVC was selected,
and automatic capture/preview were left enabled. The active camera extension
remains build 4; host-only recording changes require no extension replacement.
An interrupted unfinished fragment can still be lost. These tests cover
process interruption, not power loss or drive/filesystem failure.

## Ultracam fresh identity and flat icon — October 19, 2026

Source is in `/Users/andrew/Projects/ai/ultracam`, with the `Ultracam.xcodeproj`
project and `Ultracam` scheme. The app uses fresh identities `org.ultracam.app`
and `org.ultracam.app.camera`, the shared group `group.org.ultracam.shared`,
Ultracam camera/stream UIDs and `ultracam.*` preference keys. The native bridge
is `UltracamBackend`; development and test flags also use Ultracam names.
Settings start fresh, with no migration of the previous app's preferences.
Older entries below retain the names used for their historical checks.

The signed Release app is installed at `/Applications/Ultracam.app`. Strict
signature and bundle metadata checks pass for both the host and its embedded
camera extension, using team `44XS8S26W2`. The camera Mach service name now
starts with its entitled app group, correcting a category-validation failure
in the first signed build. Bundle validation checks this prefix for both
signed and unsigned builds before an installation request.

The final icon is flat blue/cyan vector artwork with no U-shaped holder or 3D
effects. `Assets/Ultracam-icon.svg` is the editable source; `generate_icon.sh`
renders the PNG master and all ten transparent macOS AppIcon sizes. The installed
`AppIcon.icns` and `Assets.car` match the final build. Concept prompt and asset
instructions are in `docs/ICON.md`.

The fresh app was launched with no LUT, automatic feed disabled, no recording
folder and capture stopped, confirming a clean settings store. The fresh-identity
synthetic XCTest suite passes **263 tests, zero failures**, in 26.802 seconds.
The renamed Rust helper package previously passed **15 integration tests**;
its Rust implementation was unchanged by the identity and icon updates.

The legacy virtual camera was deactivated through `systemextensionsctl`.
macOS retains its terminated versions pending removal on restart. Seventy-five
obsolete app/build/test paths were removed in the first cleanup. The approved
final cleanup removed 781 remaining build, test, cache and legacy-settings paths.
Strict signature verification still passes for `/Applications/Ultracam.app`.
The installed app is the only existing indexed app copy; no app copies remain
in the source or project build directories. Editable source, icon assets and
user media are preserved. The fresh camera extension is embedded in the app
but is not yet activated.

Development machine: M4 Max Mac Studio, 48 GB RAM, macOS 27.0.1, Xcode 27.0,
Blackmagic Desktop Video 16.4. Executed October 14, 2026.

## Automatic feed lifecycle — October 14

- `3987fba` adds persisted, opt-in **Start when camera is in use** in the window,
  menu bar panel and Feed menu. Old preferences retain their LUT bookmarks and
  manual default. Manual Start/Stop remains available when the option is off.
- Release local-development build passes strict concurrency, warnings as errors,
  bundle validation and signature verification. The installed host and camera
  extension were updated through the existing local development setup.
- `bash scripts/test.sh`: **113 tests, zero failures**, 25.315 seconds. New checks
  cover preference migration, deferred LUT readiness, demand cancellation, bounded
  start attempts/retry, independent producer/source demand, last-consumer stop,
  and authorized producer negotiation after a consumer takes device control.
- Installed native transport regression: **360/360 synthetic frames** across
  1080p NV12 and 4K x422/v210 at both NTSC rates; exact pixels/PTS, zero queue
  retries. This runs with automatic mode disabled to isolate the test producer.
- Real Zoom meeting video on starts the saved LUT pipeline automatically:
  detected 4K v210 59.94 input, 1080p NV12 59.94 output. Zoom's device-control
  lease initially prevented producer configuration; the authorized first sample
  now establishes the extension's supported output contract without taking
  Zoom's lease. Generic ingress and consumer property writes remain strict.
- With preview hidden, a second native camera client remained connected while
  Zoom video was turned off. Capture stayed live until that last client closed,
  then the host returned to **Automatic · idle**. The client received 1497 frames
  over 25 seconds with monotonic PTS; image pixels were never inspected or saved.
  A separate 8-second request verified automatic start with preview already off.
- Automatic mode and LUT restored after host relaunch, including with a source
  client already open. Enabling automatic mode during an unused manual feed
  stopped it; turning preview back on while idle did not start capture.
- Idle snapshots ten seconds apart showed 0.0% instantaneous CPU for host and
  extension, stable RSS (about 123 MiB and 12 MiB), unchanged extension CPU time,
  and 0.04 seconds additional host CPU time. This demonstrates near-idle runtime,
  not a promise of literally zero OS/app CPU. Capture timers/SDK input, queued
  previews and working GPU buffers are stopped/released; the activity monitor
  uses property notifications and schedules no polling or video GPU work.
- Final telemetry build `60c96f4` passed the full **114-test** suite and strict
  local-development bundle validation. A live source-only client produced
  detected 4K v210 59.94 input and 1080p NV12 59.94 output; the installed app
  displayed real embedded stereo levels (2 channels at 48.0 kHz, approximately
  -37 to -52 dB during this check), while timecode remained `—` because the
  current HDMI source did not carry RP188. Diagnostics exposed the live packet,
  sample, byte, bitrate and separate audio/video-drop fields. Closing the client
  returned the meters to **No signal**, cleared timecode and reset transient
  counters while automatic mode returned to idle.
- macOS 27 camera replacement hit one launchd registration race and retained a
  stale device list in an already-running host. Re-activation/reopening the host
  restored discovery. No security policy, permissions or certificate changes were
  made. Reopen camera apps after extension updates if discovery remains stale.
- Private text receipts are under the external workspace's
  `agent-work/ultrastudio-lut/logs/`: `tests-20261015T000453Z.log`, `auto-transport-full.log`,
  `auto-overlapping-client.log`, `auto-preview-hidden-start.log`, and
  `auto-idle-cpu.log`. No live-camera screenshots, recordings or image artifacts
  were created. Zoom transmission quality and remote A/V sync remain outside
  this lifecycle check. The host must remain running; automatic app launch is
  not implemented.

## Executed checks

- Unsigned arm64 app and embedded camera extension build successfully with
  `bash scripts/build.sh`, including strict Swift concurrency and warnings as errors.
- Direct DeckLink SDK discovers the UltraStudio Mini Recorder 12G and opens its
  native 3840 × 2160 v210 10-bit 4:2:2 modes at 29.97 and 59.94.
- Live 4K 59.94 input was received after the camera was powered on. The earlier
  preview refreshed only at 4 Hz; that implementation has been replaced and
  does not establish smoothness of the new native preview.
- The original integrated synthetic suite passed all **45 tests, zero failures**
  in 18.382 seconds (`bash scripts/test.sh`). Its paced controller test delivers
  all 180 packed-v210 source frames, yielding exactly 180 camera/preview samples
  at 59.94 or 90 with temporal reduction, with zero reported drops and identical
  camera/preview sample objects. Output timing follows the source cadence.
  Fast processing measured p95 4.324 ms, max 11.511 ms; queue wait p95 10.632 ms,
  max 17.026 ms. The producer still exhibited approximately 82 ms scheduling
  gaps and catch-up bursts; six-frame bounded admission handles this case.
  Assertions were not relaxed. Earlier three-frame failure receipts are retained.
- All 12 attached native preview format/rate combinations deliver their exact
  frame counts (30 at 59.94, 15 at 29.97), with zero native renderer drops or
  corruption. Cases include 1080p/4K NV12 and x422, and shareable/borrowed v210.
- Checks cover all 16 processing switch combinations at both source rates;
  cube parsing/order/domain/finite bounds; independent nonlinear color and
  Lanczos references; preserved 10-bit precision; metadata reuse; bounded pool
  pressure and recovery; camera stream negotiation, ownership, disconnects,
  cadence and recovery; SDK failure cleanup; optional LUT and lifecycle races.
- Standalone 300-frame GPU benchmark with a 33-cube LUT: 4K packed v210 → LUT →
  Lanczos → 1080p NV12, median 2.150 ms, p95 3.274 ms. This excludes UI, camera
  transport and Zoom and is not a sustained hardware qualification.

- A separate borrowed-v210 profile under host load compares bounded capture
  capacities of three and six. Three admitted 165/159 of 180 frames at the two
  output rates; six admitted all 180 at both, yielding exactly 180/90 output
  frames with zero drops/errors. For the six-frame fast case, total processing
  p95 was 6.076 ms, max 12.644 ms; actual GPU execution p95 2.755 ms, max 3.016 ms.
  No page-ins occurred. Most variation was scheduler/CPU resume delay, while
  callback gaps reached approximately 83 ms and then arrived in catch-up bursts.
  This is synthetic burst tolerance evidence, not physical display qualification.

The old Core Image pipeline failed the precision check and was replaced by
explicit float32 Metal processing. Core Image/CGImage readback has now also
been removed from preview. GPU resources warm before capture; the preview
receives the exact final buffer and timing sent to camera transport.

During the paced drop investigation, the host showed approximately 100% CPU
usage, load average above 47, approximately 24 GB of compressed memory, and
concurrent browser workers, virtual-machine, synchronization and native build
work. No unrelated processes were stopped. Source timestamp gaps, capture
admission, output-pool pressure, camera transport and native renderer loss are
counted separately. Intentional temporal reduction is not a drop.

## CPU/GPU optimization qualification

The earlier optimized Release build passed **55 tests, zero failures**, in 18.609 seconds
(`logs/tests-20261014T184250Z.log`). Added checks validate no-copy GPU memory
ownership through command completion, exactly-once release, alignment and
split-VM fallback, invalid packed strides, cached format identity and metadata
invalidation, and actual bit-exact GPU raw transport across every 4K word.
Synthetic camera/preview delivery remains exactly 180/180 or 90/90 with zero
drops. Metal API/GPU validation also passed the focused ten-test GPU suite.

Matched Release processor benchmarks alternate 360 frames per path. Thread
CPU median decreased from 0.512 to 0.190 ms/frame; aggregate CPU from 202.602 to
70.901 ms (approximately 65% less processor CPU). Wall median decreased from
2.324 to 2.000 ms. This compares copied versus eligible no-copy inputs and does
not measure driver, UI or native display CPU. Receipt:
`gpu-review/no-copy-profile/comparison.log`.

The owner subsequently ran the camera with a real 33-cube LUT, source 4K v210
59.94, Lanczos to 1080p NV12, and reduction to 29.97. On the same settings,
20-second whole-process CPU windows measured 30.448% of one core for the old
Debug app and 18.370% for the optimized Release app (approximately 40% lower).
These are observed live before/after windows, not a controlled host-load or
isolated attribution study. The changes combine no-copy input, GPU raw staging,
format caching, a smaller SwiftUI update subtree and Release optimization.
Private receipts: `cpu-preview/before-cpu.json` and `cpu-preview/after-cpu.json`.

Live diagnostics confirmed every packed input used the no-copy path and none
used the CPU fallback. Before/after stack samples confirm the hot packed-frame
memcpy disappeared; remaining work includes driver/framework and GPU submission
bookkeeping. No footage was recorded. Native renderer counters showed zero
preview losses during the observed run. Ten capture admission losses first
appeared at 13:48:34, inside the intrusive 1-ms stack sampling interval starting
13:48:32; the count did not increase after sampling. Earlier receipts retain
that result rather than silently removing it. A fresh ordinary four-minute run
without the sampler recorded zero source, capture, pool and preview loss counters;
camera transport was inactive. The user's LUT and four processing selections
are restored.

## Saved controls, menu bar and performance pass

The previous integrated suite passed **77 tests, zero failures**, in 23.11 seconds
(`logs/tests-20261014T205650Z.log`). All twelve native preview variants consumed
every paced sample with zero replacements, drops or corruption. Controlled
capture delivered 180/180 fast and 90/90 reduced camera/preview samples, with
exact timestamps and zero reported drops. Exact 64-buffer pressure and recovery
checks pass. The retained-consumer fixture observes actual send completion
rather than polling through a coalescible timer; its three-second deadline is
unchanged and the final run completed in 0.305 seconds.

An intermediate integrated suite passed **74 tests, zero failures**, in 25.65 seconds
(`logs/tests-20261014T200225Z.log`). Nine added controller tests cover complete
bypass without a LUT, hot effect restoration and cadence, preview-independent
camera delivery, automatic source timing, clock resets, invalid epochs,
no-consumer processing, bounded burst recovery and stopped-generation safety.

Capture admission is now bounded at twelve retained frames. The earlier
six-frame limit overflowed once under a measured 86-ms source gap plus 62-ms
queue delay. A deterministic held-queue test accepts exactly twelve, rejects
the thirteenth, and verifies slot recovery without restarting. For nominal
4K v210 rows, twelve retained source images represent about 264 MB of native
memory, without an additional app pixel copy.

Preview buffering is finite: 24 pending sample references per renderer plus its
current frame, with overflow replacing the oldest pending sample. The 400-ms
capacity at 59.94 accommodates a measured compound stall: about 197 ms elapsed
in raw staging followed by about 91 ms waiting for native display readiness.
The raw blit itself took about 0.08 ms of GPU execution. The earlier twelve-slot
preview overflowed under that load; its failure receipt is retained at
`logs/tests-20261014T203250Z.log`. Buffering adds no deliberate delay when the
renderer is ready and cannot guarantee lossless delivery through longer stalls.

Processor and raw-staging pools allocate three warm buffers and grow only on
actual retention, with a hard limit of 64 each. The budget allows two preview
FIFOs/current frames, native retention allowances, the three-slot camera queue
and producer/current images. Native retention has no public bound; pool limits
bound app allocation rather than promising universal losslessness. A fully
retained pool is approximately 2.12 GB for 4K x422, or 199 MB for 1080p NV12;
ordinary three-buffer warm allocation is unchanged. Effect, visibility and stop
flushes release pending references. Drain work belongs to a generation so an old
task cannot consume new frames ahead of its queued native flush.

The paced source fixture now uses a bounded Mach time-constraint policy only
on its dedicated producer thread, matching an independently timed hardware
source. Setup/readback/restoration and a 0.5-ms callback CPU budget are asserted.
The actual source spans were 2.986333/2.986325 seconds, with 16.67–16.70-ms
callback intervals. Production capture, processing and rendering queues retain
ordinary scheduling. All 180 fast or 90 reduced camera/preview samples delivered
with exact output timestamps and zero capture loss. Earlier ordinary-QoS
failures remain in `logs/tests-20261014T194315Z.log` and
`logs/tests-rerun-20261014T194525Z.log`; they include one real admission drop and
native preview replacement under concurrent VM/compiler load. This controlled
source result does not establish a universal zero-drop guarantee under load.

The updated unsigned Release app builds with strict concurrency and warnings
treated as errors. Settings tests cover preference round trips, malformed data,
bookmark restoration, missing files and failed-selection recovery. Capture now
detects actual frame duration and reports captured dimensions/format/rate;
native mocks cover mode changes, coalescing, signal recovery, cancellation and
driver failure cleanup. Permanent errors stop the controller; missing or
unsupported HDMI signals leave the detector armed.

The compact window and native menu bar popover share processing, complete
bypass and preview controls. Layout harnesses with synthetic 4K metadata and
long errors measured 850 × 583 / 1080 × 622 pt main content and 360 × 562 pt
tray content. Overflow scrolls; tray Open/Quit controls remain fixed. No camera
imagery was used in those checks.

Actual app accessibility checks verified the new controls and an exit/relaunch
cycle restored the owner's 33-cube LUT, all four effect selections, selected
device, gamut, complete-bypass selection and preview-off selection. Capture
remained stopped after launch. The saved file was restored through the actual
scoped-bookmark loader without choosing it again. The stopped main window was
visually inspected; no live-camera screenshot was taken.

The final unsigned Release build (`logs/build-20261014T205441Z.log`) was launched
after exiting the prior app. It restored the LUT and all four selections,
processing and preview. Start opened automatic UltraStudio detection and reported
no HDMI signal while remaining armed. Stop worked; the app was left stopped with
processing and preview enabled. Sustained hardware/display testing remains pending
at the owner's request. The automation surface did not expose the actual menu
bar item; the subsequent owner check and sizing correction are recorded below.

The owner reported that the tray showed only Open window and Quit. A native
hosting-controller probe reproduced a compact-size proposal shrinking the old
panel to 360 × 68 pt, despite its 360 × 562 pt ideal size. The earlier ideal-size
layout check therefore missed the collapsed scroll area. The panel now has a
defined 360 × 600 pt size, with overflow scrolling inside it; both ideal and
compact proposals return that size. The unsigned Release rebuild passed
(`logs/build-20261014T211553Z.log`) and was relaunched with the saved LUT/settings.
The owner confirmed that clicking the tray icon now shows the preview and
processing controls. Sizing receipt: `logs/tray-layout-sizing.log`. This UI-only
correction did not rerun the media-processing suite.

The final focused preview suite passes six tests, including actual native
renderer frame/drop/corruption metrics across 12 format/rate combinations.
All combinations delivered every 30/15 paced frame with zero replacements,
native renderer drops or corruption. The blocked-queue regression also proves a
new generation enqueues after native flush. Production capture stages borrowed
raw input once before fan-out, supplying shareable buffers to both previews.
The bare test executable required a test-only occlusion override for native
format acceptance; this override is absent from production. Visibility state
and independent renderers have separate tests. Receipt:
`logs/preview-generation-fifo24-20261014.log`.

Thirteen focused GPU checks pass with Metal API/GPU validation, including 64
retained 10-bit outputs, exact precision after idle release, rejection at the
65th allocation and recovery. Receipt: `gpu-review/shared-budget64-tests.log`.
Combining four compute encoders into one showed less than 0.5% CPU difference and no useful
GPU improvement, so it was discarded. Rejecting a full output pool before
mapping input reduced CPU over 1,000 rejected frames from 21.298 to 2.082 ms
(about 90% less rejection overhead; not a steady-stream speedup).

Measured float working textures use 233,963,520 bytes with scaling and
133,693,440 without scaling. Complete bypass/idle releases all working textures,
copied input staging and the processor output pool while retaining the LUT and
pipeline states. Tests retain published frames through release and verify
recovery. Capture releases these resources on Stop and when no camera output
or visible preview needs frames. Receipts:
`gpu-review/final-hotspot-tests.log`,
`gpu-review/encoder-profile/comparison.log`, and
`gpu-review/backpressure-profile/comparison.log`.

## UI refinement and independent code audit

The updated integrated suite passes **96 tests, zero failures**, in 26.408 seconds:
`logs/tests-20261014T213543Z.log`. All twelve native variants consumed every
30/15 frame with zero replacements, native drops or corruption. Controlled
capture delivered exactly 180/180 fast and 90/90 reduced samples with zero
reported loss and exact timestamp assertions. The suite includes 15 GPU,
eight preview, thirteen camera-contract, twenty-two capture-lifecycle and six
installer checks. Native focused checks also pass AddressSanitizer and
ThreadSanitizer. No signing or OS extension installation request was submitted
by tests.

The final unsigned Release app and embedded extension build also pass strict
concurrency and warnings as errors (`logs/build-20261014T213905Z.log`).

Independent audits fixed concrete issues in the native callback lifecycle,
capture/transport, preview, GPU buffer validation, LUT storage and installer:

- Backend last-reference release cannot deallocate/stop inside its own driver
  callback. Obsolete mode errors cannot stop a newer source, terminal errors
  cannot restart delivery, and failed rate queries do not fabricate cadence.
- Fatal capture updates survive queued UI changes. Forward source-clock jumps
  cannot schedule output seconds into the future; ordinary processing jitter
  preserves cadence. Final controller release tears down capture resources.
- Camera transport loss gets a finite, rate-limited recovery budget after a
  previous connection; initial unsigned absence stays quiet. A successful
  connection alone cannot renew retries when every subsequent send fails.
- Shared validation rejects malformed plane dimensions/count/stride before
  GPU mapping, untouched bypass, staging and extension ingress. The generated
  extension target explicitly includes that shared validator.
- Retired native views cannot hide or resize their replacements, and obsolete
  in-flight errors cannot alter a new preview generation's diagnostics.
- LUT reads are bounded to 32 MB plus one detection byte even if the file grows
  after its size check. Restored basenames identify the look; persistent LUT
  errors cannot be overwritten by live status updates.
- Installer requests preflight the running signature and effective Boolean
  entitlement, reject unsupported builds before submission, guard duplicate
  requests and ignore old callbacks. The source entitlement was already
  declared; the owner's failure came from the unsigned executable lacking it.

The main window now groups capture, processing and camera status beside the
video, with a compact effect strip and filename-based LUT row. Common controls
fit the existing 1080 × 640 pt window without scrolling. Advanced diagnostics
and camera setup expand separately. The tray pins Start/Stop, Processing and
its footer; details scroll inside an explicitly sized panel. Its height adapts
to available screen space. Preview errors are visible with a preview-only retry
action, bypass selection is distinct from active output, and unavailable camera
output is visible in the tray.

A real-source native layout harness checked light/dark appearances, 850 × 590
and 1080 × 700 windows, long errors and synthetic input/output metadata. Native
preview bounds remain 16:9, including the mini preview; the base shape now owns
layout independently of native-view ideal sizing. The tray's compact-size
proposal remains a nonzero fixed panel. Receipt: `logs/ui-polish-layout.log`.
The final harness also covers preview errors and a remembered-but-missing
device. The shared Start eligibility guard prevents that missing-device action
from starting capture through the window, keyboard command or model. Capture
was never started by that harness.

Actual app checks restored the owner's filename, LUT and four selections;
verified Processing/Preview keyboard shortcuts and unsigned installation controls;
and visually checked the stopped window with all common controls visible. No
live video screenshot was taken. Capture remains stopped, with Processing and
Preview enabled. This does not qualify sustained hardware presentation or
signed extension IPC.

## Local camera extension installation — October 14, 2026

With SIP disabled by the owner, an explicitly compiled `UDL_LOCAL_DEVELOPMENT`
Release build was ad-hoc signed and installed in `/Applications/UltraStudio LUT.app`.
Both bundles contain the same local app group; the extension's Mach service
starts with that group. The host has the effective system-extension install
entitlement. The installer accepts local signatures only in the explicitly
compiled development mode; production behavior remains developer-signing-only.
Nine focused installer tests passed in each compile mode, including rejecting
missing entitlements/invalid signatures and accepting a valid entitled local
build. Environment variables cannot enable this policy in a production build.

The first real activation attempt identified a missing
`NSSystemExtensionUsageDescription` in the extension's own Info.plist. Adding it
fixed the activation error; having the description only in the host is
insufficient. Every build now checks the built extension's metadata before
finishing. A valid synthetic bundle passed; missing usage description and
unexpanded Mach service fixtures were rejected.

After the owner approved Camera Extensions in System Settings,
`systemextensionsctl list` reported `org.ultrastudiolut.app.camera` as
`[activated enabled]`, and the app received successful activation completion.
Global extension developer mode remains off; no signing identity, certificate
or keychain entry was created. Both ad-hoc signatures verify strictly on disk.
Receipt: `logs/local-activation-20261014T230200Z.log`.

Actual producer connection then exposed a second local-only issue: CMIO reports
the ad-hoc producer's signing ID as the literal `unknown`, causing the original
exact-ID guard to reject it with -4. A valid self signature alone did not qualify
this path. Ordinary process inspection and an attempted on-disk check also
returned EPERM inside the camera sandbox. The local build now uses the public
`kSecGuestAttributeDynamicCode` option to obtain the running process's signature
representation, then strictly validates it against the exact producer
identifier. Missing, terminated or differently signed processes fail closed.
Only nil/`unknown` CMIO identities are eligible for this local fallback.
Production builds retain their original CMIO signing-ID guard and one-producer
rule. The earlier disk/path fallback was removed.

A temporary file-read exception was tested and removed: macOS 27's
`cmioextension.sb` fails to compile its profile when that entitlement is present.
The extension retains its original sandbox entitlements. No system-wide
security setting is changed by these scripts.

The existing LUT bookmark needed reselecting once after the move to the signed
app. The authorized LUT, filename and all four selected effects were then
verified after quitting and relaunching the installed app. Capture remained
stopped throughout this installation check.

The integrated suite passed **99 tests, zero failures** in 26.334 seconds:
`logs/tests-20261014T225933Z.log`. The local development build, bundle validation
and both signature checks also passed.

The expanded audit exposed intermittent native sample creation errors (-12743)
in two 103-test runs (`tests-20261014T230859Z.log` and
`tests-20261014T231151Z.log`). A deterministic probe reproduced the same failure
when image metadata changed after a sample's original format was created. The
native writer was not directly observed. Preview now copies the existing sample
wrapper, preserving its original image/format/timing and separate sample
attachments without copying pixels. The source factory refreshes its description
once only for the exact InvalidMediaFormat error. Both deterministic regressions
pass, including nonempty source-attachment isolation. The complete final suite
passed **105 tests, zero failures** in 26.871 seconds:
`logs/tests-20261014T231506Z.log`. All 12 native preview cases received every
expected frame without replacement, native drops or corruption. Strict
concurrency/warnings-as-errors checks also passed at the actual macOS 15 target.

Installed transport testing uncovered an additional real ownership bug that the
old simulated consumer had encoded incorrectly. The sink queue-altered callback
released a sample whose enqueue retain already belonged to CMIO's native
consumer. Actual IPC crashed in CMIO's later release. ASAN and a zombie probe
reproduced it; an otherwise identical notification-only callback passed. The
production callback is now notification-only. Rejected and stopped/unconsumed
queue entries still release their owned retain, and the regression verifies
that a dequeued sample remains alive/readable until the native owner releases it.

The final production-source ASAN helper passed all six installed IPC cases:
1080p NV12, 4K bi-planar 10-bit x422, and 4K packed 10-bit v210, each at both
29.97 and 59.94 fps. Every case delivered **60 of 60 frames** (360 total), with
bit-exact active bytes including adjacent 10-bit codes, exact rational timestamps
and duration, correct order, zero send retries and successful stop/unregister.
No sanitizer error occurred. Receipt:
`/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultrastudio-lut-e2e/cmio-smoke/logs/run-production-asan-full.log`.
These inputs used synthetic shareable IOSurfaces; SDK borrowed-buffer staging
is covered separately by the integrated tests. The optimized reusable helper
also builds with strict concurrency and warnings as errors.

After the production ownership fix, the complete suite again passed **105
tests, zero failures** in 29.049 seconds (`logs/tests-20261014T232510Z.log`).

The installed app then captured actual FX3 3840 × 2160 v210 4:2:2 10-bit at
59.94 fps and delivered the selected LUT/Lanczos/NV12 output at 1920 × 1080,
29.97 fps. Camera output connected successfully. Approximately one minute of
steady capture added no source gaps, admission drops, pool drops, camera drops
or preview drops; three admission drops had occurred during the cold start.
Packed input used the direct Metal path with no upload fallbacks. Accessibility
metadata now exposes separate live Input/Output values instead of a stale
combined selectable-text label. Zoom 7.2.2 was restarted to refresh its cached
camera list and showed **UltraStudio LUT** selected in local video settings.
No meeting was started. The HDMI signal later became unavailable; local camera
selection alone does not qualify Zoom's remote transmission.

The startup admission drops identified another cold path: automatic capture
previously deferred both CMIO connection and, with preview hidden, GPU warming
until its first queued frame. Known backend storage now permits provisional
camera connection and resource warming before native capture begins. The first
validated real frame still negotiates the detected rate/layout, and only real
frames populate source metadata. No-camera/no-preview starts continue to skip
pixel preparation. Focused lifecycle checks passed **24 tests**, including cold
connection ordering and processing preparation with preview off; the fixture
also verifies that preparation cannot publish synthetic source frames.

The final integrated suite passed **107 tests, zero failures** in 28.925
seconds: `logs/startup-perf-full-20261014T233554Z.log`. The updated Release app
build and both local signatures passed (`logs/build-20261014T233147Z.log`).
The installed app's embedded extension and the currently active extension have
the same compiled Mach-O build UUID; the last update changed host startup code.

Final actual hardware verification recovered the 59.94 FX3 signal after capture
restart. From the first delivered frame through more than two minutes, all five
UI counters stayed at zero: source gaps, capture admission, output pool, camera
transport and preview. Preview off continued delivering LUT-applied 1080p NV12
at 29.97. Complete bypass with preview off switched output to original 4K v210
10-bit 4:2:2 at 59.94; returning to enabled processing and preview restored the
selected LUT/Lanczos/NV12/29.97 settings without adding drops. Input/output
metadata reflected these actual changes. Receipt: `logs/live-final-startup.log`.
The app is left **Live**, Processing and Preview on, with the owner's LUT and
all four processing selections preserved. This is a bounded observed run, not
a universal no-drop claim under every future workload.

All owned source changes were committed in coherent checkpoints, including
`722b9cb`, `a384e58`, `22be60d`, `fa88851`, `1a66d4d`, `ca14566` and `b02ffce`.
Finished diagnostic cleanup recovered 14,376,960 allocated bytes. Automatic
cleanup review rejected embedded `os.unlink` and recursive `shutil.rmtree`
deletion patterns; an obsolete 20,480-byte allocated Apple HTML download and
156,315,648 bytes of reusable startup-test module cache remain externally.
No cleanup bypass or process termination was used. Other retained binaries,
module caches and useful failure/success receipts are current reusable lanes.

## Remaining qualification

- Broaden sustained hardware/display qualification to other output modes,
  actual 29.97 source input, and controlled host workloads. The observed live
  59.94-source/29.97-output run and counters do not establish all hardware modes
  or a universal zero-drop guarantee.
- Qualify actual Zoom consumption/transmission in a meeting. Installed-service
  frame IPC now passes the six synthetic cases above with SIP disabled; this
  does not qualify production signing or operation with SIP enabled.
- Qualify the actual Sony LUT, gamut, levels and chroma siting against a trusted
  reference chart; measure hardware latency and A/V synchronization.
- Verify actual remote Zoom quality at both rates and 4K 10-bit consumption in
  another compatible application. The app does not supply an audio device.

No footage has been recorded or retained. Live UI checks use accessibility
text without screenshots of camera imagery. Private raw build/test/profiling
logs remain under
`/Volumes/8TB/cinesomatic-director-work/agent-work/ultrastudio-lut/`.

Original passing test receipt: `logs/tests-20261014T064354Z.log`.
Current passing test receipt: `logs/startup-perf-full-20261014T233554Z.log`.


## Sony monitoring update — 2026-10-20

Installed signed host build **15** in `/Applications/Ultracam.app`; camera extension
build **4** retains identical compiled Mach-O sections. Sony S-Log3 false color
now uses published Sony Pattern 2 native IRE bands. EL Zone is enabled with an
explicit versioned public-chart mapping, source-gamut scene-linear luminance and
additive manual stop offset. Exact Sony Monitor & Control EL matching is not
claimed; the iPhone reference test was skipped at the user's request.

The six quality/performance areas in `docs/MONITOR_SONY_QUALITY_PLAN.md` are
implemented and tested. Final strict release package checks passed **184 tests**
(Core 63, Metal 93, UI 28); final application checks passed **317 tests**, zero
failures. Application integration passed **12 tests** before final shader-only
tuning. The final tiled focus/scalar scope images match frozen scalar references
in 432 full-image comparisons across formats, ranges, sizes and threadgroups.

All three fixed actual-pipeline synthetic recording comparisons passed once:
one-feed ProRes, two-feed ProRes and one-feed HEVC, 30 seconds tools off and
30 seconds enabled each. All **7,200 decoded frames**, audio/timecode references,
source integrity, recording equivalence and unchanged latency gates passed;
no recording losses occurred and tracked monitoring memory returned to zero.
All six isolated microbenchmark cases passed. Focus GPU p95 was 0.954 ms versus
1.779 ms in the frozen baseline. Higher-quality preview filtering and scope tail
costs increased; these are not six independent speedups. Two-feed picture cadence
passed at 20.90/21.54 Hz, with a narrow margin over the 20 Hz gate and mixed adaptive
quality. This is a short synthetic qualification, not a sustained guarantee.
Baseline failures and the rejected scope cache candidate remain in the evidence.

Installed UI mode/legend/layout checks passed with original operational selections
restored. A 20-second installed virtual-source consumer passed with **593 frames**,
1080p 420v and zero nonmonotonic timestamps. The capture device currently reports
**No HDMI video signal**, so this does not qualify a live physical Sony picture.
No real recording was started, and existing user recordings were not modified.

Detailed measurements, limitations, signing/installation receipts and cleanup:
`/Volumes/8TB/cinesomatic-build/ultracam-monitor-upgrade-20261021/FINAL_VERIFICATION.md`.
