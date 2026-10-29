#!/bin/bash
# Builds the Debug app and launches it with --ui-self-test. The app checks its
# real main menu (required menus and shortcuts, no duplicates), opens the main,
# Settings and Diagnostics windows and the inspector, renders every window in
# light and dark, checks the menu bar item, writes report.json and quits.
# It never starts cameras. Windows appear briefly on screen while it runs.
# SKIP_BUILD=1 reuses the last build. LIVE=1 adds the real-camera start/stop check.
set -euo pipefail
if [[ $# -ne 0 ]]; then
  echo 'Usage: app-self-test.sh' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root="$(python3 "$task_root/scripts/work_paths.py" --path work_root)"
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  bash "$task_root/scripts/build.sh" --debug
fi
app="$external_root/agent-work/ultracam/Ultracam.app"
binary="$app/Contents/MacOS/Ultracam"
[[ -x "$binary" ]] || { echo "Built app not found at $app" >&2; exit 1; }
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
out_root="$external_root/agent-work/build/ultracam/app-self-test"
out="$out_root/$run_id"
mkdir -p "$out"
ln -sfn "$run_id" "$out_root/latest"
live_args=()
# LIVE=1 also starts and stops the selected camera on the real UltraStudio input (HDMI read only, no recording).
if [[ "${LIVE:-0}" == 1 ]]; then live_args=(--live); fi
"$binary" --ui-self-test "$out" ${live_args[@]+"${live_args[@]}"} > "$out/app.log" 2>&1 &
pid=$!
deadline=$((SECONDS + ${SELF_TEST_TIMEOUT:-90}))
while kill -0 "$pid" 2>/dev/null; do
  if (( SECONDS >= deadline )); then
    kill "$pid" 2>/dev/null || true
    echo "Self-test timed out; app log: $out/app.log" >&2
    exit 1
  fi
  sleep 1
done
wait "$pid" || true
report="$out/report.json"
if [[ ! -f "$report" ]]; then
  echo "No report written (the app may have crashed); app log: $out/app.log" >&2
  tail -20 "$out/app.log" >&2 || true
  exit 1
fi
printf 'App self-test artifacts: %s\n' "$out"
/usr/bin/python3 -I - "$report" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
for check in report["checks"]:
    if not check["pass"]:
        print(f"FAIL {check['name']}: {check['detail']}")
print(f"App self-test: {report['passed']} passed, {report['failed']} failed")
sys.exit(0 if report["pass"] else 1)
PY
