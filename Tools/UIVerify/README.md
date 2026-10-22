# UI verification

Three layers check the new interface:

| Layer | Run | Covers |
|---|---|---|
| Unit | `bash scripts/test.sh` | `Tests/UIPresentationChecks.swift`: the audit rules in the pure presentation layer: tally, tile and strip states, record and cut controls, stop confirmations, status bar, menu bar icon, formatting, chips, wording (never consumer app names). |
| Offscreen | `bash scripts/ui-verify.sh` | This tool, described below. |
| In-app | `bash scripts/app-self-test.sh` | `Sources/App/UISelfTest.swift`, run inside the real app with `--ui-self-test <dir>`: the main menu (required menus, required shortcuts, no duplicates, dumped to `menus.tsv`); the main, Settings and Diagnostics windows; the inspector opened in the real window; the menu bar item; window renders in light and dark. Writes `report.json`. It never starts cameras. Windows appear briefly. `SKIP_BUILD=1` reuses the last Debug build. |

## What `ui-verify` does

The script compiles every app source except `UltracamApp.swift` with the release build's strict settings, plus `Tools/UIVerify/*.swift`, and runs the result.

1. **Renders.** Each screen is drawn in an offscreen window, in light and dark: the main window for every `UIFixtures` session at 1320×860 and 980×680, every layout, all strips collapsed, the camera column, every strip state (expanded and collapsed), sidebar, inspector, status bar, Program View, each Settings pane and Diagnostics (with a real `AppModel`), and the main window driven by the real model. Each PNG must not be blank. For main windows, the content area must draw too, not just the window chrome.
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
   - output mode, add, rename and remove
   - Auto, hold and strategy
5. **Menu bar.** `UIMenuBarController.buildItems` runs for each fixture:
   - required rows are present
   - cuts happen only on `Cut to …` rows with ⌃n, and never in Separate mode
   - no duplicate shortcuts and no app names
   - every icon state renders as a template image

## Output and options

Artifacts go to `/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam/ui-verify/<run>/` (with a `latest` link):
- `png/`
- `ui-verify.log`
- `accessibility-program-meeting.tsv`
- `menubar-*.txt`

`STRICT=0` reports view-dependent failures as pending instead of failing.

## Known limits

- **Inspector:** `.inspector` inside a bare `NSHostingView` throws during AppKit layout, so the whole-window inspector render runs in the app self-test. `RENDER_INSPECTOR=1` attempts it here anyway.
- **Vibrancy:** offscreen capture draws vibrant sidebar materials as a flat color.

## Speed

- `scripts/ui-verify.sh` skips the run when nothing it compiles has changed since its last passing run (a hash of the inputs is kept next to `latest`). `FORCE=1` reruns.
- Views settle until layout stops changing, in 16 ms slices; the old fixed waits are only the upper limit.
- A strict timer ends each slice on time (a process started from a background shell or agent gets coalesced timers, which stretched 16 ms to ~130 ms), and a closed window drops its content so it stops updating.
- The verifier is compiled unoptimized, and the MonitorTools package build is cached across runs.
- PNGs are encoded on one background thread.
- `UI_VERIFY_TIMING=1` prints each render's time and whether its layout settled or hit the limit.
