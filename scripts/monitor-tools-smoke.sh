#!/bin/bash
# Synthetic pixel buffers only. Never opens devices or contacts the installed app.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root=/Volumes/8TB/cinesomatic-director-work
[[ -d /Volumes/8TB && "$(stat -f %d /Volumes/8TB)" != "$(stat -f %d /Volumes)" ]] || { echo 'External drive /Volumes/8TB is not mounted.' >&2; exit 1; }
export TMPDIR="$external_root/tmp"
export MACOSX_DEPLOYMENT_TARGET=26.0
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
test_root="$external_root/agent-work/build/ultracam/monitor-tools/$run_id"
mkdir -p "$TMPDIR" "$test_root/modules"
python3 "$task_root/scripts/monitor-tools-fingerprint.py" capture "$test_root/source-manifest.json"
source "$task_root/scripts/monitor-tools-package.sh"
monitor_package_build > "$test_root/compile.log" 2>&1 || { cat "$test_root/compile.log"; exit 1; }
xcrun swiftc -O -swift-version 5 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
  -module-cache-path "$test_root/modules" "${monitor_link_args[@]}" \
  "$task_root/Tools/MonitorToolsRecording/QualificationMetrics.swift" "$task_root/Tools/MonitorToolsRecording/MonitorGPUWorkload.swift" "$task_root/Tools/MonitorToolsSmoke/main.swift" -o "$test_root/monitor-tools-smoke" \
  >> "$test_root/compile.log" 2>&1 || { cat "$test_root/compile.log"; exit 1; }
python3 "$task_root/scripts/monitor-tools-fingerprint.py" verify "$test_root/source-manifest.json"
shasum -a 256 "$test_root/monitor-tools-smoke" > "$test_root/binary-sha256.txt"
if [[ "${MONITOR_BUILD_ONLY:-0}" == 1 ]]; then
  echo "Built qualification helper: $test_root"
  exit 0
fi
# Python owns only this child process group. Bounded watchdog never targets the app.
python3 - "$test_root" "$@" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1]); args = sys.argv[2:]
timeout = 120
for i, arg in enumerate(args):
    if arg == '--seconds' and i + 1 < len(args): timeout = max(timeout, float(args[i+1]) + 120)
try:
    print('Artifacts: ' + str(root), flush=True)
    with (root/'run.log').open('w') as log:
        child = subprocess.Popen([str(root/'monitor-tools-smoke'), *args], stdout=log, stderr=subprocess.STDOUT)
        try: child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            child.kill(); child.wait(); raise
    result = subprocess.CompletedProcess(child.args, child.returncode, (root/'run.log').read_text(), '')
    if result.returncode:
        (root/'failure-receipt.json').write_text(json.dumps({'status':'failed','exit_code':result.returncode,'reason':result.stdout[-4000:].strip()}))
    for line in result.stdout.splitlines():
        try:
            receipt = json.loads(line)
            if isinstance(receipt, dict) and 'workload' in receipt:
                receipt['source_manifest_sha256'] = hashlib.sha256((root/'source-manifest.json').read_bytes()).hexdigest()
                receipt['binary_sha256'] = hashlib.sha256((root/'monitor-tools-smoke').read_bytes()).hexdigest()
                (root/'receipt.json').write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
        except json.JSONDecodeError: pass
    print(result.stdout, end=''); print(result.stderr, end='', file=sys.stderr)
    print('Artifacts: ' + str(root))
    sys.exit(result.returncode)
except subprocess.TimeoutExpired as error:
    (root/'watchdog.json').write_text(json.dumps({'status':'failed','reason':'watchdog','timeout_seconds':timeout}))
    raise SystemExit('Monitor synthetic watchdog expired: ' + str(root))
PY
python3 "$task_root/scripts/monitor-tools-fingerprint.py" verify "$test_root/source-manifest.json"
