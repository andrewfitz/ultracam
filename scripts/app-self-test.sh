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
timeout=${SELF_TEST_TIMEOUT:-90}
if [[ ! "$timeout" =~ ^[1-9][0-9]*$ ]] || ! [ "$timeout" -gt 0 ] 2>/dev/null; then
  echo 'SELF_TEST_TIMEOUT must be a positive number of seconds.' >&2
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
if [[ "${LIVE:-0}" == 1 ]]; then
  live_args=(--live)
else
  # Keep home-relative files in this run. The app also creates a dedicated defaults suite.
  export CFFIXED_USER_HOME="$out/home"
  mkdir -p "$CFFIXED_USER_HOME/Library/Preferences"
fi
pid=''
cleanup() {
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
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$binary" --ui-self-test "$out" ${live_args[@]+"${live_args[@]}"} > "$out/app.log" 2>&1 &
pid=$!
started_at=$SECONDS
while kill -0 "$pid" 2>/dev/null; do
  if (( SECONDS - started_at >= timeout )); then
    echo "Self-test timed out; app log: $out/app.log" >&2
    exit 1
  fi
  sleep 1
done
app_status=0
wait "$pid" || app_status=$?
pid=''
if [[ "$app_status" -ne 0 ]]; then
  echo "Self-test app exited with status $app_status; app log: $out/app.log" >&2
  tail -20 "$out/app.log" >&2 || true
  exit "$app_status"
fi
report="$out/report.json"
if [[ ! -f "$report" ]]; then
  echo "No report written (the app may have crashed); app log: $out/app.log" >&2
  tail -20 "$out/app.log" >&2 || true
  exit 1
fi
printf 'App self-test artifacts: %s\n' "$out"
/usr/bin/python3 -I - "$report" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as report_file:
        report = json.load(report_file)
except (OSError, ValueError) as error:
    sys.exit(f"Cannot read app self-test report: {error}")
checks = report.get("checks") if isinstance(report, dict) else None
if not isinstance(checks, list) or not checks or any(
    not isinstance(check, dict)
    or type(check.get("pass")) is not bool
    or not isinstance(check.get("name"), str)
    or not isinstance(check.get("detail"), str)
    for check in checks
):
    sys.exit("App self-test report has invalid check results")
passed = sum(check["pass"] for check in checks)
failed = len(checks) - passed
if (
    type(report.get("passed")) is not int
    or type(report.get("failed")) is not int
    or report["passed"] != passed
    or report["failed"] != failed
    or report.get("pass") is not (failed == 0)
):
    sys.exit("App self-test report summary disagrees with its check results")
for check in checks:
    if not check["pass"]:
        print(f"FAIL {check['name']}: {check['detail']}")
print(f"App self-test: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
