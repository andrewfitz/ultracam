# UI verification

The interface checks run at four levels.

| Layer | Run | Covers |
|---|---|---|
| Unit | `bash scripts/test.sh` | `Tests/UIPresentationChecks.swift`: the audit rules in the pure presentation layer: tally, tile and strip states, record and cut controls, stop confirmations, status bar, menu bar icon, formatting, chips, wording (never consumer app names). |
| Offscreen | `bash scripts/ui-verify.sh` | This tool, described below. |
| In-app | `bash scripts/app-self-test.sh` | `Sources/App/UISelfTest.swift`, run inside the real app with `--ui-self-test <dir>`: the main menu (required menus, required shortcuts, no duplicates, dumped to `menus.tsv`); the main, Settings and Diagnostics windows; the inspector opened in the real window; the menu bar item; window renders in light and dark. Writes `report.json`. The default run uses offline hardware. `LIVE=1` also checks starting and stopping the selected real camera. Windows appear briefly. `SKIP_BUILD=1` reuses the last Debug build. |
| UI tour | `bash scripts/ui-tour.sh` | Drives the unsigned Debug app with Accessibility and captures its windows and menus, including all nine Settings panes. Each run uses its own preferences and offline hardware. `APPEARANCE=Dark` selects dark appearance. `LIVE=1` selects real capture hardware. |

## What `ui-verify` does

The script compiles every app source except `UltracamApp.swift` with the release build's strict settings, plus `Tools/UIVerify/*.swift`, and runs the result.

1. **Renders.** Each screen is drawn in an offscreen window, in light and dark: the main window for every `UIFixtures` session at 1320×860 and 980×680, every layout, all strips collapsed, the camera column, every strip state (expanded and collapsed), inspector, status bar and its popovers, Program View, each Settings pane and Diagnostics (with a real `AppModel`), and the main window driven by the real model. Each PNG must not be blank. For main windows, the content area must draw too, not just the window chrome.
2. **Accessibility.** The tool walks the SwiftUI accessibility tree. Enhanced user interface mode is turned on at startup, because SwiftUI builds the tree only for an assistive client; no permission is needed. It checks key labels, and that no app names appear.
3. **Interactions.** Controls are pressed through accessibility, and the `UIAction` that each one sends is recorded:
   - a picture press selects and never cuts (D1)
   - record, Pause, Stop Camera, effect chips, Collapse
   - toolbar Cut and Stop All
   - a disabled LUT chip and a disabled Record send nothing
4. **Real model.** A real `AppModel` runs through `UISessionBridge` with injected `UserDefaults` and no hardware:
   - snapshot contents
   - select, layout and collapse
   - per-camera settings on a camera that isn't selected (persisted, selection unchanged)
   - stop on stopped cameras
   - add, rename and remove
   - Auto, hold and strategy
5. **Menu bar.** `UIMenuBarController.buildItems` runs for each fixture:
   - required rows are present
   - cuts happen only on `Cut to …` rows with ⌃n, and never with one camera
   - no duplicate shortcuts and no app names
   - every icon state renders as a template image

## Output and options

Artifacts go to `agent-work/build/ultracam/ui-verify/<run>/` under `ULTRACAM_WORK_ROOT`, which defaults to `.build` in the checkout. A `latest` link points to the last run.

- `png/`
- `ui-verify.log`
- `accessibility-program-meeting.tsv`
- `menubar-*.txt`

`STRICT=0` reports view-dependent failures as pending instead of failing.

`RENDER_INSPECTOR=1` adds an untitled 1600×900 inspector render. The default run renders the inspector in titled windows at 1320×860 and 980×680.

`UI_PERF_ONLY=1` runs only the live performance checks. The default cases cover two and four cameras with both live and fixed meters. `UI_PERF_CAMERAS` and `UI_PERF_METERS` select cases for a focused run. `UI_PERF_IDLE` sets the idle interval in seconds and `UI_PERF_PROFILE_INSPECTOR` adds inspector toggles before the measured interactions.

`UI_MAC_CAMERA_ONLY=1` runs the scripted Mac Camera and DeckLink scenario. It checks the Hardware permission action and mixed inventory, the inspector's input and Hardware link, per-device settings, the live effects route and the finalized source take. The fixture sends frames to an in-process sink. Screenshots and the fixture take are saved in the run directory.

## Known limits

- **Vibrancy:** offscreen capture draws vibrant materials (the inspector, bars) as a flat color.

## Speed

- `scripts/ui-verify.sh` reuses a passing run for unchanged inputs and default coverage. It reports the passing artifact directory even after an intervening focused or failed run. `FORCE=1` reruns.
- Views settle until layout stops changing, in 16 ms slices; the old fixed waits are only the upper limit.
- A strict timer ends each slice on time (a process started from a background shell or agent gets coalesced timers, which stretched 16 ms to ~130 ms), and a closed window drops its content so it stops updating.
- The verifier is compiled unoptimized, and the MonitorKit package build is cached across runs.
- PNGs are encoded on one background thread.
- `UI_VERIFY_TIMING=1` prints each render's time and whether its layout settled or hit the limit.
