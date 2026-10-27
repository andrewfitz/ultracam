# Sony Wi-Fi camera control

Open **Sony Camera** in an expanded camera strip, or **Inspector → Sony Wi-Fi
Control**. Enable Remote Shoot Function on each FX3 and put the Mac and cameras
on the same Wi-Fi network. For several cameras, use a shared access point;
joining one camera's Wi-Fi Direct network only reaches cameras on that network.
Camera menu names and authentication requirements depend on firmware.

Opening the pop-up automatically detects cameras and shows their friendly names,
such as **ILME-FX3:A** and **ILME-FX3:B**. Select the matching camera,
enter its camera access-authentication credentials if requested, and press
**Connect and Assign**. Verify that the selected physical camera matches the
HDMI picture. Network control cannot determine which HDMI cable it feeds.
Allow Ultracam's macOS local network access when prompted.

Press **Rescan** to detect newly powered cameras immediately. Recent successful
scan results are shared across camera pop-ups for 30 seconds. There is no
periodic scan. **Add FX3 by IP** remains a secondary recovery option if the
network blocks discovery; ordinary setup does not require typing IP or MAC
addresses. After the first successful connection, the camera login is stored in
macOS Keychain and used to reconnect its saved HDMI assignment on app launch.

One Sony camera belongs to one HDMI feed. The saved association uses its MAC
address, so DHCP address changes do not move the assignment. SSH fingerprints
are pinned after pairing; a changed fingerprint requires verifying the camera
and explicitly unassigning/pairing again. Credentials are never saved to defaults,
files or logs. Closing the settings sheet keeps the control connection.

## Saved camera sign-ins

Successful authenticated connections save their username/password in the local
macOS data-protection Keychain. The username is inside the encrypted payload,
not searchable item metadata. Items are non-synchronizing and accessible while
the user's Keychain is unlocked. An actor keeps Security calls off the main
thread; automatic loads never display an authentication prompt.

The stable service is `org.ultracam.sony-camera-control.credentials.v1`; the account
combines the normalized camera MAC with a hash of its pinned SSH fingerprint.
A replacement camera or changed fingerprint cannot receive the previous login.
The signed app explicitly selects its own private Keychain access group,
`$(AppIdentifierPrefix)org.ultracam.app`, authorized by its existing profile.
This prevents the app's shared file-container group from changing implicit
Keychain access-group resolution. No broad ACL, build-path whitelist, shared
credential group or unprotected fallback file is used.

One startup restore pass loads remembered logins for saved HDMI assignments,
shares one discovery, matches each camera by MAC and verifies its pinned
fingerprint before sending credentials. Each camera gets one connection attempt.
No saved assignment or login means no startup network scan. An offline camera,
locked/unavailable Keychain or authentication failure stays disconnected with a
message until **Reconnect** is pressed. Explicit Disconnect is respected for the
rest of the session. There is no repeating reconnect or polling loop.

**Reconnect** uses the saved sign-in. **Change camera sign-in** replaces it only
after successful authentication. **Forget Saved Sign-In** removes the exact
camera's Keychain record and disconnects its current session. Disconnect,
Unassign and resetting app settings retain Keychain records, so discovering and
assigning that same verified camera again can use **Connect Using Saved Sign-In**.

Same-user signed updates, installs at a different path and reinstalling Ultracam
preserve access when the Mac's Keychain items remain and the authorized signing
team/application identifier stay the same. Deleting Keychain items, changing
users/signing access groups, or ad-hoc builds can require a new sign-in. The
production signed app uses team `44XS8S26W2` and app ID `org.ultracam.app`.
There is no migration from the old session-only logins: enter them once in this
updated build; subsequent successful sessions use Keychain.

Supported properties are discovered from the connected camera, with the SDK's
current readable/writable flags and allowed values. The sheet includes ISO,
aperture, shutter speed/angle, exposure compensation/mode, white balance and
Kelvin, focus mode/area, subject-recognition AF, recognition target, AF transition
speed, subject-shift sensitivity, still-photo tracking sensitivity, remote control
priority, base ISO level and EI when available. Eye selection appears only if
returned by the camera; the SDK's FX3 support table does not promise it. Battery, current ISO, focus indication/absolute position and camera
recording state are cached readouts. Unsupported properties are omitted.
Modes such as Cine EI and lens capabilities can restrict which controls work.
Changing **Control priority → Remote control** may unlock dial-controlled
settings. Physical-camera recording state is separate from Ultracam recording.

**Show camera settings over this feed** adds a monitor-only cached readout.
It does not alter recordings, Program output, virtual-camera pixels or HDMI
capture. Clean View hides it. The preview shows only the optional settings
values, without update/progress/status text. It stays hidden until values are
available and hides on disconnect; cached values and connection/error status
remain in the Sony settings panel. No camera values are saved across launches.

## Activity and threading

- Opening Sony Camera starts one discovery when its cache is stale. Concurrent
  pop-ups share the same in-flight scan. Rescan requests a fresh scan. No scan
  runs on a repeating timer. Startup performs one shared scan only when saved
  assignments have remembered credentials (or do not require authentication).
- Discovery reads Sony's SSDP advertisements and camera descriptions, then uses
  the supported SDK camera-object factory. This handles FX3s omitted by Sony's
  built-in enumeration, discovers their Wi-Fi MAC/authentication automatically,
  and preserves connected camera objects during rescans.
- The UDP scan lasts 2.5 seconds with one retransmission, across active IPv4 LAN
  interfaces. At most 16 camera candidates proceed to description fetches,
  which run in parallel with 1.5-second request deadlines and a 4-second phase
  deadline. Replies must point to the responding local host; redirects and
  external XML entities are rejected, with header/body/parser size limits.
  SDK fingerprint calls run afterwards and use Sony's own timeout behavior.
- All SDK calls execute on one dedicated OS thread, away from capture and
  rendering. It sleeps on a condition variable when idle. SDK initialization
  and release share that thread, as Sony requires.
- Sony documents `GetDeviceProperties` as a copy of its internally maintained
  property list, without communicating with the camera. Property-change callbacks
  have no documented fixed default frequency; the SDK owns its transport activity.
- Settings are read on connection, after edits, and automatically when Sony reports
  a relevant property change, even with the sheet closed. The monitor overlay and
  controls share the same snapshot. Refresh remains an optional recovery action.
- Notifications schedule a one-shot 500 ms window per feed. Bursts share one read;
  sustained notifications produce at most two automatic reads per second per feed,
  without overlapping operations. A change during a read queues a trailing update.
  There are no periodic reads while idle. Read failures stop until another event
  or an explicit Refresh; disconnect/removal/shutdown cancel pending updates.
- Exposure settings, current ISO, battery and recording changes trigger updates.
  Code-specific focus-position/focus-indication telemetry is ignored to avoid
  continuous AF-driven reads. Generic Sony property callbacks also cause an update
  because they do not identify which property changed.
- Writes are validated again against the camera's currently allowed values.
  The SDK queues writes asynchronously; Ultracam waits for a notification (bounded
  to three seconds), reads back the camera, and confirms the requested value.
  A rejected/unconfirmed write leaves the last confirmed cache marked stale.
- `Setting_Key_EnableLiveView = CrDeviceSetting_Disable` explicitly disables
  Sony's default background live-view image acquisition after connection.
  No Sony image, monitoring, OSD, playback or media-transfer APIs are requested.
- SDK automatic reconnection is disabled. The app performs one bounded startup
  restore with Keychain, then waits for explicit Reconnect after failures. There
  are no application polling or retry loops; property notifications use one-shot
  coalescing tasks. The proprietary SDK may still maintain its own connection traffic.
- Removing a feed or resetting settings queues a disconnect even if connection
  work is still in flight; a late reply cannot recreate the removed assignment.
  Device handles and callbacks remain alive until Sony acknowledges disconnect.
- Normal Quit waits for one Sony shutdown alongside any recording drain, even
  if no recording is active. Concurrent Quit requests share that cleanup. A
  store that never used the SDK performs no native shutdown work, and queued
  discovery/connect replies cannot restart SDK work after shutdown begins.

## HDMI Face/Eye display

The video controls include **Sony HDMI display** when the connected FX3 reports
both supported properties. The toggle writes the camera's
`MonitoringOutputDisplayHDMI` and `FaceEyeFrameDisplay` settings together, so
the FX3 draws its own Face/Eye frames and camera display information into the
existing HDMI signal. Ultracam does not enable Sony Wi-Fi live-view acquisition,
request images or decode frames. The camera controls
the appearance and placement of these overlays; enabling them changes the HDMI
composition and should be checked against the capture format.

## HDMI output timing

The settings sheet also shows the FX3 HDMI output properties when the current camera
mode exposes them. **HDMI output resolution** selects the output size. On 4K output,
**HDMI 4K output timing** selects the HDMI frame rate together with 8-bit or 10-bit
output. RAW-capable modes expose **HDMI RAW frame rate** separately. These controls
are distinct from **Movie recording frame rate** and **S&Q recording frame rate**;
the camera may hide them while it is in a mode where HDMI output cannot be changed.

## Build and verification

```sh
python3 scripts/install-sony-sdk.py /path/to/CrSDK_v2.02.00_20260610a_Mac.zip
python3 scripts/generate_project.py
bash scripts/sony-control-checks.sh
bash scripts/sony-credential-checks.sh
bash scripts/ui-typecheck.sh
bash scripts/build.sh --debug
```

The installer extracts only the SDK headers/libraries from Sony's `SimpleCli.zip`.
Those files are ignored by Git. The generated app target embeds/signs the core
and adapter libraries; the camera extension never links them. Builds without a
local SDK expose an explanation instead of attempting control. Existing CLI UI
verification harnesses use this unavailable backend; the focused Sony checks
exercise the store with a fake and compile native formats against the real SDK.

`scripts/prepare_local_build.py` signs nested libraries inside the staged copy
before signing the extension/host, including Sony libraries and Xcode Debug
dylibs. The downloaded SDK and original product are unchanged. An ad-hoc bundle
can still be rejected by macOS because the full app uses restricted extension
and app-group entitlements. The final full-app software build is signed with
the existing Apple Development identity/profile.

`bash scripts/sony-sandbox-ui-check.sh` builds a separate, sandboxed UI check
with the production Sony view, store and SDK. It has its own app identity and
preferences, network access only, and starts no HDMI capture or camera extension.
Its live pop-up was verified to list both FX3s with secure login fields. An
initial interface error was transient; diagnostics now report the failing
network stage without changing permissions or bypassing sandboxing.


`bash scripts/sony-credential-checks.sh --keychain /path/to/signed/Ultracam.app
"Apple Development: ..."` qualifies actual Keychain behavior using the reference
app's full entitlements and existing profile/signing identity. Only synthetic credentials and unique
test service names are used and cleaned up. The real signed check passed add,
update, read, delete, private/unlocked/non-sync policy, plus separate-process
persistence across different app paths and changed executable contents. The
full entitlement test reproduces OSStatus -34018 without the explicit private
Keychain group and passes with that group. A reduced helper omitting the app's
shared container entitlement was insufficient to qualify the production host.
Store
regressions inject memory vaults and never touch real user credentials.

Automated checks cover idle behavior, duplicate assignment, persistence without
credentials, coalesced automatic notification reads without idle polling, confirmed/rejected writes, DHCP and
fingerprint changes, disconnect labeling, feed removal during connection, reset,
light/dark sheet rendering, overlay accessibility, native numeric formatting,
signed/unsigned ranges, unaligned data, oversized/invalid ranges and event
coalescing. Focus checks cover demand-driven opt-in, fresh per-kind events,
generation isolation, frame aging, malformed packed data and geometry projection. Discovery tests also cover named cameras, cache expiry, coalesced
requests, explicit rescans and legacy saved names. They never contact a camera.

Further hardware qualification covers physical HDMI-pairing confirmation,
readback for every editable control, loss/recovery of Wi-Fi, and checking that
SDK live-view acquisition stays disabled while HDMI capture/recording run.
The user has authenticated both FX3s and reported that connections work; the
software regression checks do not access those credentials or alter that session.

Optional read-only hardware check: `bash scripts/sony-hardware-smoke.sh` performs
discovery in a correctly packaged app with the main run loop active. Add
`--read-settings` to connect unauthenticated cameras, read their settings,
refresh, then disconnect and release the SDK. Cameras requiring credentials
are listed and skipped; use the app's settings sheet to authenticate. This
script never changes exposure/focus settings or starts camera recording.
`--direct IP MAC` checks a known FX3's identity through the manual-IP SDK route.
`--expect-cameras 2 --rescan` verifies automatic discovery of both cameras and
stable identities across a second scan, without entering addresses.

Local hardware observation (2026-10-25): Sony's built-in enumeration returned
success with no cameras. SSDP and camera descriptions identify both cameras,
each running firmware **7.02**:

| Camera | IPv4 address | Wi-Fi MAC address |
|---|---|---|
| ILME-FX3:A | 192.168.1.160 | EC:5C:84:2B:E7:0A |
| ILME-FX3:B | 192.168.1.16 | A0:CD:F3:7E:31:02 |

The application's automatic discovery now detects both by friendly name,
prepares their SDK camera objects, and retrieves each camera's 44-byte SSH
fingerprint. A repeated scan returned the same stable identities and SDK
shutdown completed cleanly. Both require access authentication. The user subsequently authenticated both
cameras in the app and reported successful control. Automatic settings updates
replace the previous manual cache-invalidation behavior. Automated checks use
fakes rather than changing physical camera settings or reusing credentials.

References: the supplied Sony Camera Remote SDK 2.02 API reference, especially
Device Property, Device Setting and Callback Interface;
[Sony SDK support](https://support.d-imaging.sony.co.jp/app/sdk/en/),
[FX3 Remote Shoot Function guide](https://helpguide.sony.net/ilc/2210/v1/en/contents/TP1000884035.html).
