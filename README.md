# Ultracam

Ultracam uses fresh app and camera identities: `org.ultracam.app`,
`org.ultracam.app.camera` and the shared app group `group.org.ultracam.shared`.
Settings start fresh. Blackmagic UltraStudio refers to the input hardware.
The Xcode project is `Ultracam.xcodeproj`, with the `Ultracam` scheme.
The custom macOS icon and its reproducible asset catalog are documented in
[docs/ICON.md](docs/ICON.md).

A standalone native macOS app and Core Media I/O camera extension for a Sony
FX3 log feed through an UltraStudio Mini Recorder 12G. Select **Ultracam**
as the camera in Zoom or another macOS camera application.

## Processing

The four checkboxes are independent and ordered:

1. **Apply LUT:** decode source 10-bit Y′CbCr to floating-point log RGB and apply
   a `.cube` at the original 3840 × 2160 resolution. No implicit linearization
   or additional log-to-display transform is applied. The LUT must match
   S-Gamut3.Cine/S-Log3 or S-Gamut3/S-Log3 and output display Rec.709.
2. **Downscale:** use a separable Lanczos-3 filter with scale-adjusted support
   and normalized weights to reduce 4K to 1920 × 1080. Intermediate textures
   remain 32-bit float.
3. **Color format:** produce 4:2:0 8-bit video-range NV12. When disabled, produce
   4:2:2 10-bit video-range `x422`. Chroma sampling and integer quantization occur
   after LUT processing and spatial scaling.
4. **Frame rate:** reduce 59.94 to 29.97 by selecting every second source frame
   after pixel processing. This does not affect a 29.97 source.

Defaults: LUT off, downscale and color conversion enabled, frame-rate reduction
disabled. A LUT is optional; loading one enables its checkbox. Both source rates use their exact rational values, 30000/1001 and
60000/1001. DF is a timecode convention, not a pixel-processing operation.

With all pixel-processing switches disabled, the original input pixel buffer
is forwarded without color conversion. A bounded bit-exact IOSurface copy is
used only when camera transport or native display requires shareable memory. Frame-rate reduction
can still be enabled independently. A processed 10-bit output is high-precision
video, but the LUT intentionally changes its pixel values.

**Processing enabled** controls the whole pipeline independently of preview.
Turn it off for complete bypass: original resolution, color format, pixel values
and frame rate. The four saved effect selections remain available when it is
enabled again. **Video preview** controls rendering only; camera output continues
with the selected effects or bypass. Hidden or occluded previews submit no video
rendering work. With no connected camera output and no visible preview, capture
keeps detecting the source without processing unused frames.

Effects can change while capture runs. The producer stops and drains its camera
transport before negotiating a changed output format, then resumes delivery.
The camera publishes supported 4K/1080p, 10-bit 4:2:2/8-bit 4:2:0 modes; consumers
must accept the selected format. Installed-service format changes still need
qualification with a signed extension.

Settings and read-only scoped LUT bookmarks persist between launches. Capture
starts manually by default. Enable **Start with camera apps** for a camera (its
inspector, or the Camera menu) to let Zoom and other camera apps manage it:
opening the virtual camera starts capture with your saved effects, and closing
the last camera client stops capture, video processing and preview rendering.
This works with preview hidden and with the main window closed. Keep the app
running in the menu bar; this setting does not launch a fully quit app.
Zoom's camera settings preview also counts as camera use.

Automatic mode listens for source-stream activity without polling or opening
its own source stream. Waiting releases working video buffers, cancels capture
and processing timers, and submits no video GPU work. Normal macOS/app runtime
memory and event handling remain. A failed start is attempted once per camera
session, with an explicit Retry action rather than a background retry loop.
Turn automatic mode off to regain manual Start/Stop controls; an already live
feed continues under manual control.

The metadata panel also reports the detected RP188 video timecode when the HDMI
source carries one. It shows two embedded-audio meters from the UltraStudio's
48 kHz, 16-bit stereo input, with peak and RMS values for left and right. The
diagnostics disclosure includes audio channels, sample rate, packet/sample/byte
counts, estimated audio bitrate and audio gaps, plus video bitrate and separate
video drop counters. If the source carries no audio or timecode, the UI says so
instead of fabricating values.

A missing or invalid saved LUT leaves capture usable and keeps
the saved choice for recovery.

## Interface

The main window is a native macOS window in light or dark appearance:

- **Sidebar:** the session panel. It shows the published output, the Program
  summary and shot timer, recording drives with time left, recent takes,
  interrupted takes (Recover) and automation.
- **Camera columns:** each camera has its picture, then its channel strip.
  - The strip holds that camera's own recording (record, pause, folder, time left)
    and output (cut, effects, Processing, audio).
  - Each strip collapses to one line; collapse all with ⌥⌘S.
- **Selection:** clicking a picture selects that camera (blue ring); it never cuts.
- **Program mode tally:** the camera on Program shows a red ON AIR ring once a
  meeting app is using "Ultracam · Program" (PROGRAM before that), and NEXT while
  a cut is pending.
- **Inspector (⌥⌘I):** deeper per-camera settings, opened on demand.
- **Status bar:** output, Program, recording, audio and resources.
- **Settings (⌘,):** General, Recording, Camera, Switcher, Monitor and Advanced.
- **Diagnostics:** engineering detail lives in its own window.

The menu bar item is a native menu. Its live preview row shows what is
published, followed by the camera, recording and Program commands. Closing the
window does not stop capture.

Shortcuts:

| Shortcut | Command |
|---|---|
| ⌘↩ | Start or stop the cameras |
| ⇧⌘B | Processing (selected camera) |
| ⇧⌘P | Video preview |
| ⌘R / ⌥⌘R | Record or stop the selected camera / all cameras |
| ⇧⌘R | Pause or resume the selected camera's recording |
| ⌃1–⌃4 | Cut Program to a camera (also Mission Control's desktop shortcuts if those are on) |
| ⌃⌥A | Automatic switching |
| ⌘1–⌘4 | Select a camera |
| ⌥⌘1–⌥⌘4 | Layout |
| ⌃⌘S | Sidebar |
| ⌥⌘S | Collapse all strips |
| ⌥⌘K | Scopes |
| ⌥⌘I | Inspector |
| ⌃⌥F / ⌃⌥C | Freeze / Clean view (selected picture) |
| ⌘0 | Show main window |

Stopping a camera that is recording or on air asks first. Changing Downscale,
Color, Frame rate or Processing while a meeting app is connected renegotiates
the camera format, so its video updates briefly; the LUT doesn't change the
format. Preview errors offer Retry Preview, which leaves camera output running.

Verification: `bash scripts/ui-verify.sh` renders every screen and state
offscreen in light and dark, and checks accessibility, interactions and the
real model. `bash scripts/app-self-test.sh` runs checks inside the real app;
`LIVE=1` also starts and stops the selected camera on the real input. See
[Tools/UIVerify/README.md](Tools/UIVerify/README.md).

## Monitor tools

The main window offers **Single**, **Side by Side**, **Four Up** and, in Program
mode, **Program View** layouts. Expand a picture from its context menu, swap the
first two, or detach a camera into its own window. Tools are off by default, and
each camera retains its own settings. Each tool is a split button on the picture:
click it to toggle the tool, or use its chevron for settings.

Monitor tools are drawn by [MonitorKit](Packages/MonitorKit/README.md) on the GPU,
for every camera frame, with no CPU pixel copies: thirds, center and safe-area
guides, IRE zebras, focus peaking, false color, and RGB parade, luma waveform,
vectorscope and histogram scopes. The **Picture** menu chooses what a view shows:
Source (camera signal), Output (LUT), which is the source with the burn-in LUT applied
in the shader exactly as the published output applies it, or Monitor, which adds the
camera's optional Monitor LUT. **Freeze** and **Clean**, scope visibility and zoom
affect only their own view. Hidden or covered views do no monitor work, and only a
scope may skip an update while the GPU is still drawing earlier scopes; recording
and virtual-camera output keep their own image branches. The diagnostics show the
source and presented rates, scope skips and GPU time.

**Sony S-Log3** false color uses Sony Monitor & Control's published source IRE
bands with Ultracam display colors. It supports S-Gamut3.Cine and S-Gamut3;
camera EI does not shift these bands, and they do not claim Sony sensor
clipping/noise limits. The exposure offset of custom stop bands adds stops; it
does not infer camera EI. A saved EL Zone selection from an earlier build reads
as false color off, with every other setting kept. Historical Sony ARRI-style
settings migrate to Sony S-Log3; legacy literal
ARRI data remains readable as an unsupported saved choice. Select the matching source
profile, input range and Log transport mapping; these declarations do not
calibrate the capture device. Source Log pictures without a LUT are labeled as
code-value views. While false color draws, zebras are suppressed. Program supports
guides, zebras and scopes; focus peaking and Log false color need the camera's own
signal and stay off on Program. PQ and HLG pictures are shown on an EDR layer in
their own primaries, with overlays at BT.2408 graphics white.

Peaking uses a noise-rejecting Scharr mask computed from the camera signal at
source resolution. Scopes count every pixel of the frame into GPU bins; nothing
is read back to the CPU.

Both false-color references, including EL's explicit interval convention, are
documented in [the color reference receipt](docs/MONITOR_COLOR_REFERENCES.md).
See [the Sony quality execution plan](docs/MONITOR_SONY_QUALITY_PLAN.md) for the
current change and measurement gates.
MonitorKit replaced the earlier in-app MonitorTools package (retired in W4; see
[the integration map](docs/MONITORKIT_INTEGRATION_MAP.md)). [The MonitorTools
plan](docs/MONITOR_TOOLS_PLAN.md) and [audit](docs/MONITOR_TOOLS_AUDIT.md) are kept
as historical records.

## Recording and interrupted takes

Choose a default output folder in **Recording**, or choose a separate folder in
each camera feed's recording row. **Use default** clears that camera's override.
Each camera can record with its own folder even if no default is selected.
Folder changes apply to the next take. **PC time** is the default timecode mode;
it writes the computer's clock into the file, aligned to the first video frame.
ProRes 422 10-bit and HEVC Main10 4:2:2 use fragmented QuickTime MOV containers,
with a one-second initial fragment and ten-second subsequent fragment intervals.
Normal Stop drains the encoder and finalizes the whole take on a worker, while
**Finishing…** keeps duplicate recording actions disabled. Quitting waits for
active recordings to finish.

Each feed shows its own status, elapsed recording time, current file size and
video-frame drop count. While a take is active, its counters refresh twice a
second; FPS and video bitrate reflect encoded output. **Encoder details** shows
hardware acceleration, smoothed/peak submission-to-callback latency, writer and
encoder queues, audio packet drops, and encoder/writer errors. Paused time and
intentionally ignored paused/stopped callbacks do not increase elapsed time or
video-frame losses. Final take statistics remain visible until the next take.

**Ultracam total**, above Recording and in the menu bar panel, reports app CPU,
combined GPU video-processing busy time and memory footprint. CPU uses all
Ultracam process threads (100% means one core). GPU busy time unions completed
Metal processing/copy intervals from all feeds so overlapping work counts once;
it excludes the hardware media encoder and system display compositor. This is
not a whole-machine GPU utilization reading or a per-encoder utilization claim.

Completed takes use readable feed names and local timestamps, for example
`Feed 1/Feed 1_2026-10-19_21-13-55_003.mov`. During recording, a hidden `.partial`
file and an Ultracam recovery journal remain beside the final destination.
The default and per-camera folders' read/write sandbox bookmarks persist across
launches. Camera folder choices follow the feed when it is renamed or reordered.

After an interruption, launch Ultracam with the recording drive connected. The
Recording controls offer **Recover** for interrupted takes in the saved folders;
choosing another recording folder also checks it. Recovery copies complete
fragments into a separate `_Recovered.mov` without re-encoding and keeps the
interrupted original unchanged. A recovered take is not offered again while its
recovered movie exists. The hidden original still occupies space; keep it until
you have verified the recovered movie.

An interruption can lose the last unfinished fragment, and a take interrupted
before its first fragment may have no recoverable video. Fragmentation cannot
guarantee recovery from drive failure, filesystem damage or unflushed writes
following a power loss. Existing non-fragmented recordings are not upgraded.

Run `bash scripts/recording-recovery-smoke.sh` to SIGKILL synthetic 4K writers
before normal finalization and verify recovery for both codecs, with embedded
audio and generated timecode. This helper never opens a capture device.

## Build and synthetic checks

Requirements: Apple silicon, Xcode, macOS 15 or later, Blackmagic Desktop Video
with its camera extension enabled. The development target is macOS 27.0.1.

```sh
git clone --recurse-submodules https://github.com/andrewfitz/blackmagic-lut-webcam.git
# or, in an existing clone:
git submodule update --init
bash scripts/build.sh
bash scripts/test.sh
```

MonitorKit (`Packages/MonitorKit`) is a git submodule pinned to a tagged release
of [github.com/andrewfitz/MonitorKit](https://github.com/andrewfitz/MonitorKit);
run `git submodule update --init` after cloning or after a pull that moves it.
Its development log is [docs/monitorkit/PROGRESS.md](docs/monitorkit/PROGRESS.md).

These commands require the mounted `/Volumes/8TB` drive and keep all build
products, test binaries, module caches and temporary files under
`/Volumes/8TB/cinesomatic-director-work/`. The generated Xcode project and shared
scheme are checked in; `scripts/generate_project.py` regenerates them without
third-party tools. Metal shader source is bundled and compiled through Metal at
runtime, so the separate downloadable Xcode Metal toolchain is not required.

The app is built unsigned with Release optimization by default. Use
`bash scripts/build.sh --debug` for a debugger build. The stable app-bundle
alias, overwritten on every build, is at:

```text
/Volumes/8TB/cinesomatic-director-work/agent-work/ultracam/Ultracam.app
```

Xcode derived data and test objects use a unique UTC timestamp/PID directory
under `/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam/`
so overlapping builds and test runs cannot overwrite one another. The stable
`build.log`, `test-compile.log`, and `tests.log` aliases point to the latest
run; timestamped logs remain in the `logs/` directory.

## Install the camera

An unsigned build is for compilation/UI review and cannot activate a camera
system extension. Use an Apple Developer signing identity and configure the
same team for the app and extension, including their shared app group.
The app checks its running signature and effective install entitlement before
offering installation. Unsupported builds explain the signing requirement and
keep Install/Remove disabled; capture and preview remain available.

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID bash scripts/build.sh --signed
```

For first-time setup with your developer account signed in to Xcode, allow Xcode
to register identifiers and this Mac, and create or download provisioning profiles:

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID bash scripts/build.sh --signed --provisioning-updates
```

Without `--provisioning-updates`, the script uses existing signing assets only.
The script does not change system-extension developer mode, install certificates,
or install the app.
In Xcode, configure Signing & Capabilities for both targets if signing needs
setup. Keep bundle IDs synchronized with `VideoContract.extensionID` and the
producer signing ID in `CameraStream.authorizedToStartStream`.

After signing, place the app in `/Applications`, launch it and click **Install
camera**. Approve the camera extension in System Settings when macOS asks.
**Remove camera** requests deactivation of this app's extension.

For local testing on a Mac already configured to permit unsigned system
extensions (including SIP disabled), build an explicitly marked development
package without an Apple Developer identity:

```sh
bash scripts/build.sh --local-development
```

The ad-hoc signed package is staged at
`/Volumes/8TB/cinesomatic-director-work/agent-work/ultracam/local-development/Ultracam.app`.
Quit the previous app, copy this package into `/Applications`, launch it there,
then request **Install camera** and approve **Ultracam Camera** in
System Settings → General → Login Items & Extensions → Camera Extensions.
This mode embeds the actual install entitlement and matching local app groups;
its compile-time policy accepts a valid local signature. Production builds
still require developer signing. The script never changes SIP, extension
developer mode, certificates or other macOS security settings, and never
installs the package. macOS retains control over activation and approval.
Both build modes validate the built bundle metadata before finishing.

With the local development extension installed and approved, stop the app's feed
and run
`bash scripts/camera-smoke.sh --run` to check actual camera transport with
synthetic numbered frames. The helper checks received pixels, frame counts and
timestamps in memory; it never opens the physical capture device, records video
or submits an installation request. Running the script without `--run` only
builds the helper. Use `--full` instead of `--run` to include 4K 10-bit x422 and
packed v210 at both rates. Build products and receipts stay on the external drive.
Use `bash scripts/camera-smoke.sh --consumer` for a bounded 20-second source-only
client request to test automatic start/stop. That mode may start physical capture
through the running host app; it inspects frame metadata only and never reads,
displays or records image pixels.
`bash scripts/camera-smoke.sh --monitor-gpu-check` (or `--monitor-gpu-check-full`
for the 4K profiles) runs the `--monitor` load, the app's Metal 4 monitor path, over
the same synthetic frames without CMIO; it never touches the installed extension.

Configure the FX3 for clean 4K 10-bit 4:2:2 HDMI log output, with RAW output off
and any HDMI display LUT disabled. Optionally load the matching LUT here. Select the
processing checkboxes and start the
feed. In Zoom, choose **Ultracam**. Zoom determines transmitted quality
and frame rate from its own supported features, settings, and meeting conditions.

## Natural talking-head auto-switcher

Program mode includes a **Natural talking head** strategy. When enabled, the
app feeds live audio cues to the Rust director in `Tools/auto-switcher`, queues
decisions at Program frame boundaries, and acknowledges them only after the
target frame is applied. The hard shot maximum forces a bounded cut, preferring
the nearest speech gap and using the configured grace period only when no safe
gap arrives. The standalone package also accepts realtime JSONL or PCM16LE and
can analyze complete audio/video files offline; see
[Tools/auto-switcher/README.md](Tools/auto-switcher/README.md).
Recorded source movies use the readable feed name and a local datetime in
their filenames. Each switcher session writes a datetime JSON sidecar in the
recording folder.

## Qualification status and boundaries

See [VALIDATION.md](VALIDATION.md) for executed checks and outstanding live tests.
Capture uses the native DeckLink SDK directly and validates every received frame
as 3840 × 2160 10-bit 4:2:2. It detects 29.97/59.94 input automatically and reports
the actual captured dimensions, format and rate. Unsupported HDMI modes are
reported while the detector waits for a supported signal. The build
fetches checksum-pinned, permissively licensed Blackmagic headers and dispatch
source from official OBS upstream; Blackmagic Desktop Video supplies the runtime.

With Monitor Tools off, the selected camera's processed preview receives the
same final pixel buffer and timing as camera output. AVSampleBufferDisplayLayer
renders it through native video hardware without CGImage readback or per-frame
SwiftUI state. Preview sample attachments are independent from camera transport;
native fitting and display color conversion apply. Monitor surfaces can instead
select Source, retain a frozen frame, or display an owned, size-limited picture
with overlays. These monitor-only operations leave camera output unchanged.
Capture can run in preview mode before the camera extension is signed and installed.

On Apple silicon, eligible packed capture memory is read directly by Metal.
The allocation is retained and locked through GPU completion; page alignment,
VM-region bounds and layout are checked before using it. Incompatible buffers
use a bounded CPU upload fallback. Raw transport staging uses a bit-exact GPU
blit when eligible, and preview/camera share the same staged IOSurface. No color
or precision change is introduced by these optimizations. Frame descriptions
are cached only while Core Media confirms their metadata and layout still match.

GPU resources and three output buffers are warmed before capture when needed.
Capture retains at most twelve source frames to absorb callback bursts. Each
preview has a bounded 24-sample FIFO; it drains immediately when native display
is ready and discards the oldest pending sample on overflow. Output pools grow
only on demand, up to 64 images shared across their consumers. Idle/bypass
releases unused processing textures and pools. Camera transport is also bounded.
The UI shows
source timestamp gaps, capture admission drops, pool pressure, transport drops
and native preview delivery separately. Intentional frame-rate reduction does
not count as a dropped frame.
Footage is written only when recording is started; monitoring does not save
frames. The virtual camera supplies video without an audio device or SMPTE/DF
timecode transport. Select your existing microphone or
Blackmagic audio input separately in Zoom and qualify A/V synchronization.
Signal loss leaves automatic HDMI detection armed; the extension clears its latest image and emits black
after 0.5 seconds without a producer frame. Queue depth and pixel-buffer
allocation are bounded; late frames are discarded instead of building latency.

## References

- [UltraStudio Mini Recorder 12G specifications](https://www.blackmagicdesign.com/products/ultrastudiomini/techspecs/W-DLUS-15)
- [Apple camera extension architecture](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o)
- [Sony FX3 help guide](https://helpguide.sony.net/ilc/2210/v1/en/print.pdf)
- [Zoom camera/system requirements](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060748)

GPU buffer contract: [Apple Metal no-copy memory API](https://developer.apple.com/documentation/metal/mtldevice/makebuffer%28bytesnocopy%3Alength%3Aoptions%3Adeallocator%3A%29).
