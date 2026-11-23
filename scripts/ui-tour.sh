#!/bin/bash
# Drives the real built app through its windows and states the way a person
# would (toolbar, menus, Settings tabs, menu bar item) and captures each step.
# Only this app process's own windows are captured, by window ID: never the
# screen. Every action targets the tour's own process, so an installed copy of
# Ultracam can keep running (and serving a meeting) during the tour.
# Needs Accessibility and Screen Recording permission for the terminal.
# Runs the Debug build with its own preferences and home directory.
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
xcrun swiftc -O "$task_root/Tools/UITour/escape.swift" -o "$out/escape" 2>>"$out/windows-build.log"

pid=""
finish() {
  [[ -n "$pid" ]] || return 0
  if kill -TERM "$pid" 2>/dev/null; then
    for _ in {1..10}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The main window, by title (its accessibility name adds the subtitle after an en dash).
main='(first window whose (name is "Ultracam" or name starts with "Ultracam –"))'
# Retries: the app can be busy for a few seconds (adding a camera, building the Program
# pipeline) and miss scripting requests meanwhile.
ui_once() {
  osascript -e 'with timeout of 5 seconds' \
    -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to $1" \
    -e 'end timeout' 2>>"$out/osascript.log"
}
ui() {
  local attempt
  for attempt in 1 2 3 4; do
    ui_once "$1" && return 0
    sleep "$attempt"
  done
  return 1
}
# A menu or modal confirmation can block its caller until dismissed.
click_without_wait() {
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

# A title selects matching tour windows. Menu captures also require a menu layer.
capture_windows() {
  local name="$1" title="${2:-}" mode="${3:-window}" n=0 menu_windows=0 windows
  local matched=() images=() id layer window_title suffix image
  sleep "${SETTLE:-1.2}" || return 1
  windows="$("$out/windows" "$pid")" || return 1
  while IFS=$'\t' read -r id layer window_title; do
    [[ -n "$id" ]] || continue
    if [[ -n "$title" && ( "$window_title" != *"$title"* || "$layer" != 0 ) ]]; then continue; fi
    if [[ "$layer" != 0 ]]; then menu_windows=$((menu_windows + 1)); fi
    matched+=("$id")
  done <<< "$windows"
  [[ ${#matched[@]} -gt 0 && ( "$mode" != menu || "$menu_windows" -gt 0 ) ]] || return 1

  for id in "${matched[@]}"; do
    n=$((n + 1))
    suffix=""; [[ $n -gt 1 ]] && suffix="-$n"
    image="$out/$name$suffix.png"
    images+=("$image")
    if ! screencapture -x -o -l "$id" "$image" || [[ ! -s "$image" ]]; then
      echo "could not capture window: $name ($id)" >&2
      rm -f -- "${images[@]}"
      return 1
    fi
  done
  printf '%s\n' "$name" >> "$out/steps.txt"
}
capture() {
  capture_windows "$@" || echo "missing window capture: $1" | tee -a "$out/missing.txt"
}
capture_menu() {
  local name="$1" item="$2" attempt
  for attempt in 1 2 3; do
    if [[ "$item" == *"of menu bar 1" && "$(ui_once 'get frontmost')" == false ]]; then
      echo "menu capture unavailable while Ultracam is in the background: $name" | tee -a "$out/missing.txt"
      return 0
    fi
    click_without_wait "$item"
    if capture_windows "$name" "" menu; then
      "$out/escape" "$pid"
      return 0
    fi
    "$out/escape" "$pid"
    sleep 0.3
  done
  echo "missing menu capture: $name" | tee -a "$out/missing.txt"
}

tour_args=(--ui-tour --ui-appearance "$appearance_arg")
if [[ "${LIVE:-0}" == 1 ]]; then tour_args+=(--live); fi
mkdir -p "$out/home/Library/Preferences"
CFFIXED_USER_HOME="$out/home" "$binary" "${tour_args[@]}" > "$out/app.log" 2>&1 &
pid=$!
deadline=$((SECONDS + 30))
until ui_once "get name of menu bar 1" >/dev/null; do
  if ! kill -0 "$pid" 2>/dev/null || (( SECONDS >= deadline )); then
    echo "Tour app's menu bar is unavailable. See $out/osascript.log and $out/app.log." >&2
    exit 1
  fi
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
capture_menu 15-program-menu 'menu bar item "Program" of menu bar 1'
menu View "Program View"
capture 15-program-view Ultracam
menu View "Side by Side"
click_without_wait '(first menu item of menu "Camera" of menu bar 1 whose name starts with "Remove")'
dialog=''
for _ in {1..10}; do
  if [[ "$(ui_once "exists sheet 1 of $main")" == true ]]; then
    dialog="(sheet 1 of $main)"
    capture 16-confirm-remove-camera Ultracam
    break
  elif [[ "$(ui_once 'exists (first window whose subrole is "AXDialog")')" == true ]]; then
    dialog='(first window whose subrole is "AXDialog")'
    capture 16-confirm-remove-camera
    break
  fi
  sleep 0.2
done
removed=false
if [[ -n "$dialog" ]]; then
  # The alert can close before Accessibility replies. Check the resulting layout availability.
  click_without_wait "(first button of $dialog whose name starts with \"Remove\" or description starts with \"Remove\")"
  for _ in {1..12}; do
    if [[ "$(ui_once "exists $dialog")" == false &&
          "$(ui_once 'get enabled of menu item "Program View" of menu "View" of menu bar 1')" == false ]]; then
      removed=true
      break
    fi
    sleep 0.3
  done
fi
if [[ "$removed" == false ]]; then
  echo "could not confirm camera removal" | tee -a "$out/missing.txt"
fi
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
  capture_menu "09-menu-$name" "menu bar item \"$name\" of menu bar 1"
done
SETTLE=2 capture_menu 10-menu-bar-extra 'menu bar item 1 of menu bar 2'

# Settings, every pane.
ui 'click menu item "Settings…" of menu "Ultracam" of menu bar 1' >/dev/null
sleep 1
for pane in General Hardware "Virtual Cameras" Recording Streaming Audio Switching Alerts Advanced; do
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
