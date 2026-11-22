#!/bin/bash
# Drives the real built app through its windows and states the way a person
# would (toolbar, menus, Settings tabs, menu bar item) and captures each step.
# Only this app process's own windows are captured, by window ID: never the
# screen. Every action targets the tour's own process, so an installed copy of
# Ultracam can keep running (and serving a meeting) during the tour.
# Needs Accessibility and Screen Recording permission for the terminal.
# Saves the tour app's preferences first and restores them after the tour. The
# Debug build isn't sandboxed, so these are its own preferences, separate from
# the installed app's sandbox container.
# APPEARANCE=Dark runs the tour in dark mode. LIVE=1 also starts and stops the
# camera on the real UltraStudio input; it needs every other Ultracam quit.
set -euo pipefail
if [[ $# -ne 0 ]]; then
  echo 'Usage: ui-tour.sh' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root="$(python3 "$task_root/scripts/work_paths.py" --path work_root)"
app="${APP:-$external_root/agent-work/ultracam/Ultracam.app}"
binary="$app/Contents/MacOS/Ultracam"
[[ -x "$binary" ]] || { echo "Built app not found at $app" >&2; exit 1; }
if [[ "${LIVE:-0}" == 1 ]] && pgrep -x Ultracam >/dev/null; then
  echo 'LIVE=1 uses the UltraStudio: quit every running Ultracam first.' >&2
  exit 1
fi
if codesign -d --entitlements - "$app" 2>/dev/null | grep -q app-sandbox; then
  echo 'The tour needs the unsigned Debug build: a sandboxed build shares the installed app'"'"'s settings.' >&2
  exit 1
fi
# An explicit path: plain "org.ultracam.app" resolves to the installed app's sandbox container.
preferences="$HOME/Library/Preferences/org.ultracam.app"
appearance_arg="$(printf '%s' "${APPEARANCE:-Light}" | tr '[:upper:]' '[:lower:]')"
case "$appearance_arg" in
  light) appearance=Light ;;
  dark) appearance=Dark ;;
  *) echo 'APPEARANCE must be Light or Dark.' >&2; exit 2 ;;
esac
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
out_root="$external_root/agent-work/build/ultracam/ui-tour"
out="$out_root/$run_id-$appearance"
mkdir -p "$out"
ln -sfn "$run_id-$appearance" "$out_root/latest-$appearance"

xcrun swiftc -O "$task_root/Tools/UITour/windows.swift" -o "$out/windows" 2>"$out/windows-build.log"
xcrun swiftc -O "$task_root/Tools/UITour/scroll.swift" -o "$out/scroll" 2>>"$out/windows-build.log"
if [[ -f "$preferences.plist" ]] || defaults read "$preferences" >/dev/null 2>&1; then
  defaults export "$preferences" "$out/preferences-before.plist"
fi

pid=""
finish() {
  if [[ -z "$pid" ]]; then return; fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [[ -f "$out/preferences-before.plist" ]]; then
    defaults import "$preferences" "$out/preferences-before.plist"
  elif defaults read "$preferences" >/dev/null 2>&1; then
    defaults delete "$preferences"
  fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The main window, by title (its accessibility name adds the subtitle after an en dash).
main='(first window whose (name is "Ultracam" or name starts with "Ultracam –"))'
# Retries: the app can be busy for a few seconds (adding a camera, building the Program
# pipeline) and miss scripting requests meanwhile.
ui() {
  local attempt
  for attempt in 1 2 3 4; do
    osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to $1" 2>>"$out/osascript.log" && return 0
    sleep "$attempt"
  done
  return 1
}
# Opening a menu blocks the scripting call until the menu closes, so don't wait for it.
open_menu() {
  osascript -e "ignoring application responses" \
    -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to click $1" \
    -e "end ignoring" >/dev/null 2>>"$out/osascript.log"
}
menu() { ui "click menu item \"$2\" of menu \"$1\" of menu bar 1" >/dev/null || echo "missing menu item: $1 › $2" | tee -a "$out/missing.txt"; }
toolbar() { ui "tell $main to click (first UI element of toolbar 1 whose description is \"$1\")" >/dev/null || echo "missing toolbar item: $1" | tee -a "$out/missing.txt"; }
# Closes the window with this title by its close button, never the main window by accident.
close_window() {
  ui "click (first button of (first window whose name contains \"$1\") whose subrole is \"AXCloseButton\")" >/dev/null ||
    echo "could not close window: $1" | tee -a "$out/missing.txt"
}

# capture NAME [TITLE]: the tour app's windows whose title contains TITLE, or every
# window and open menu when TITLE is empty.
capture() {
  local name="$1" title="${2:-}" n=0 menu_windows=0 windows
  sleep "${SETTLE:-1.2}"
  windows="$("$out/windows" "$pid")"
  while IFS=$'\t' read -r id layer window_title; do
    [[ -n "$id" ]] || continue
    # A named window: just that window. No name: every window, including open menus.
    if [[ -n "$title" && ( "$window_title" != *"$title"* || "$layer" != 0 ) ]]; then continue; fi
    if [[ "$layer" != 0 ]]; then menu_windows=$((menu_windows + 1)); fi
    n=$((n + 1))
    local suffix=""; [[ $n -gt 1 ]] && suffix="-$n"
    if ! screencapture -x -o -l "$id" "$out/$name$suffix.png" || [[ ! -s "$out/$name$suffix.png" ]]; then
      echo "could not capture window: $name ($id)" | tee -a "$out/missing.txt"
    fi
  done <<< "$windows"
  if [[ "$n" == 0 ]]; then
    echo "no matching window: $name" | tee -a "$out/missing.txt"
    return
  fi
  if [[ -z "$title" && "$menu_windows" == 0 ]]; then
    echo "no open menu window: $name" | tee -a "$out/missing.txt"
    return
  fi
  printf '%s\n' "$name" >> "$out/steps.txt"
}

"$binary" --ui-appearance "$appearance_arg" > "$out/app.log" 2>&1 &
pid=$!
for _ in $(seq 1 30); do
  ui "get name of menu bar 1" >/dev/null 2>&1 && break
  sleep 0.5
done
sleep 1
# macOS restores a closed main window as closed; open it the way a person would (⌘0).
if ! ui "get toolbar 1 of $main" >/dev/null 2>&1; then
  menu Window "Show Main Window"
  sleep 1
fi
ui "set position of $main to {80, 60}" >/dev/null
ui "set size of $main to {1440, 900}" >/dev/null

# Main window: without and with the inspector. There is no left pane.
ui "set frontmost to true" >/dev/null
capture 01-main Ultracam
toolbar Inspector
capture 02-main-inspector Ultracam
# At a smaller window the inspector scrolls: its sections pass under the toolbar and beside the scroller.
ui "set size of $main to {1345, 764}" >/dev/null
capture 02-main-inspector-small Ultracam
"$out/scroll" 1260 500 -12 "$pid"
capture 02-main-inspector-scrolled Ultracam
"$out/scroll" 1260 500 30 "$pid"
ui "set size of $main to {1440, 900}" >/dev/null
toolbar Inspector
menu View "Collapse All Strips"
capture 05-main-collapsed Ultracam
menu View "Expand All Strips"
# One camera has only the single layout (the others are shown with two cameras below).
capture 06-layout-Single Ultracam

# The smallest window with the inspector open: the pictures and their strips keep their room.
ui "set size of $main to {980, 680}" >/dev/null
toolbar Inspector
capture 07-main-minimum-size Ultracam
toolbar Inspector
ui "set size of $main to {1440, 900}" >/dev/null

# Two cameras: layouts, Program mode, and the Remove Camera confirmation.
menu Camera "Add Camera"
capture 14-two-cameras Ultracam
for layout in "Four Up" "Side by Side"; do
  menu View "$layout"
  capture "14-two-cameras-${layout// /-}" Ultracam
done
# Program exists whenever there are two or more cameras: nothing to switch on.
capture 15-program-mode Ultracam
open_menu "menu bar item \"Program\" of menu bar 1"
capture 15-program-menu
ui "key code 53" >/dev/null; ui "key code 53" >/dev/null
menu View "Program View"
capture 15-program-view Ultracam
menu View "Side by Side"
ui "click (first menu item of menu \"Camera\" of menu bar 1 whose name starts with \"Remove\")" >/dev/null ||
  echo "missing menu item: Camera › Remove…" | tee -a "$out/missing.txt"
capture 16-confirm-remove-camera Ultracam
# A sheet on the main window while Ultracam is active, otherwise a standalone alert.
ui "tell $main to click button \"Remove Camera\" of sheet 1" >/dev/null ||
  ui "tell $main to click (first button of sheet 1 whose description starts with \"Remove\")" >/dev/null ||
  ui "tell (first window whose subrole is \"AXDialog\") to click (first button whose name starts with \"Remove\")" >/dev/null ||
  echo "missing confirmation button: Remove Camera" | tee -a "$out/missing.txt"
capture 16-after-remove Ultracam

if [[ "${LIVE:-0}" == 1 ]]; then
  menu Camera "Start Capture"
  SETTLE=5 capture 08-live-started Ultracam
  toolbar Inspector
  capture 08-live-inspector Ultracam
  toolbar Inspector
  # "Stop Capture" with one camera, "Stop All Capture" with several.
  ui "click (first menu item of menu \"Camera\" of menu bar 1 whose name starts with \"Stop\" and name ends with \"Capture\")" >/dev/null ||
    echo "missing menu item: Camera › Stop Capture" | tee -a "$out/missing.txt"
  SETTLE=3 capture 08-live-stopped Ultracam
fi

# Menus from the menu bar.
for name in Camera Record Program View; do
  open_menu "menu bar item \"$name\" of menu bar 1"
  capture "09-menu-$name"
  ui "key code 53" >/dev/null; ui "key code 53" >/dev/null
done
open_menu "menu bar item 1 of menu bar 2"
SETTLE=2 capture 10-menu-bar-extra
ui "key code 53" >/dev/null

# Settings, every pane.
ui "keystroke \",\" using command down" >/dev/null
sleep 1
for pane in General Hardware "Virtual Cameras" Recording Audio Switching Alerts Advanced; do
  ui "click button \"$pane\" of toolbar 1 of window 1" >/dev/null || echo "missing settings pane: $pane" | tee -a "$out/missing.txt"
  capture "11-settings-$pane" "$pane"
done
close_window "Advanced"

menu Window Diagnostics
capture 12-diagnostics Diagnostics
close_window Diagnostics
menu Help "Ultracam Help"
capture 13-help Help
close_window "Ultracam Help"

shopt -s nullglob
images=("$out"/*.png)
printf 'UI tour (%s): %s images in %s\n' "$appearance" "${#images[@]}" "$out"
if [[ -s "$out/missing.txt" ]]; then
  echo "Incomplete UI tour. See $out/missing.txt." >&2
  exit 1
fi
