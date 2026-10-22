#!/bin/bash
# Actual production writers with generated media; no devices or installed app.
set -euo pipefail
# Legacy positional duration remains accepted; all new workload options are forwarded.
if [[ $# -gt 0 && "$1" != --* ]]; then
  legacy_seconds="$1"; shift
  set -- --seconds "$legacy_seconds" "$@"
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root=/Volumes/8TB/cinesomatic-director-work
if ! mount | /usr/bin/grep -F ' on /Volumes/8TB ' > /dev/null; then
  echo 'External drive not mounted.' >&2; exit 1
fi
export TMPDIR="$external_root/tmp" MACOSX_DEPLOYMENT_TARGET=26.0
export ULTRACAM_SHADER="$task_root/Sources/App/LUTShaders.metal"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
test_root="$external_root/agent-work/build/ultracam/monitor-recording/$run_id"
mkdir -p "$TMPDIR" "$test_root/modules"
python3 "$task_root/scripts/monitor-tools-fingerprint.py" capture "$test_root/source-manifest.json"
source "$task_root/scripts/monitor-tools-package.sh"
monitor_package_build > "$test_root/compile.log" 2>&1 || { cat "$test_root/compile.log"; exit 1; }
xcrun swiftc -O -swift-version 5 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 -module-cache-path "$test_root/modules" \
  "${monitor_link_args[@]}" "$task_root/Sources/Shared/VideoContract.swift" \
  "$task_root/Sources/Shared/VideoBufferLayout.swift" "$task_root/Sources/Shared/CubeLUT.swift" \
  "$task_root/Sources/App/LUTProcessor.swift" \
  "$task_root/Sources/App/AppResourceUsage.swift" "$task_root"/Sources/Recording/*.swift \
  "$task_root/Tools/MonitorToolsRecording/QualificationMetrics.swift" "$task_root/Tools/MonitorToolsRecording/PipelineAdmission.swift" "$task_root/Tools/MonitorToolsRecording/MonitorGPUWorkload.swift" "$task_root/Tools/MonitorToolsRecording/main.swift" -o "$test_root/monitor-recording" \
  >> "$test_root/compile.log" 2>&1 || { cat "$test_root/compile.log"; exit 1; }
python3 "$task_root/scripts/monitor-tools-fingerprint.py" verify "$test_root/source-manifest.json"
shasum -a 256 "$test_root/monitor-recording" > "$test_root/binary-sha256.txt"
if [[ "${MONITOR_BUILD_ONLY:-0}" == 1 ]]; then
  echo "Built qualification helper: $test_root"
  exit 0
fi
python3 - "$test_root" "$@" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys, time
root=pathlib.Path(sys.argv[1]); args=sys.argv[2:]
seconds=5; codecs=2; modes=2
for i, arg in enumerate(args):
    if i+1 >= len(args): continue
    if arg=='--seconds': seconds=int(args[i+1])
    if arg=='--codec': codecs=2 if args[i+1].lower()=='both' else 1
    if arg=='--mode': modes=2 if args[i+1]=='compare' else 1
timeout=seconds*codecs*modes*4+600  # Includes bounded 4K decode/finalization allowance.
print('Artifacts: '+str(root),flush=True)
try:
    with (root/'run.log').open('w') as log:
        env=os.environ.copy()
        env['MONITOR_SOURCE_MANIFEST_SHA256']=hashlib.sha256((root/'source-manifest.json').read_bytes()).hexdigest()
        env['MONITOR_BINARY_SHA256']=hashlib.sha256((root/'monitor-recording').read_bytes()).hexdigest()
        child=subprocess.Popen([str(root/'monitor-recording'),str(root/'takes'),*args],stdout=log,stderr=subprocess.STDOUT,env=env)
        started=time.monotonic()
        while child.poll() is None:
            if time.monotonic()-started > timeout:
                child.kill(); child.wait()
                (root/'failure-receipt.json').write_text(json.dumps({'status':'failed','reason':'watchdog','timeout_seconds':timeout}))
                raise SystemExit('Recording qualification watchdog expired: '+str(root))
            time.sleep(1)
    output=(root/'run.log').read_text()
    print(output,end='')
    if child.returncode:
        (root/'failure-receipt.json').write_text(json.dumps({'status':'failed','exit_code':child.returncode,'reason':output[-4000:]}))
    sys.exit(child.returncode)
except KeyboardInterrupt:
    if 'child' in locals() and child.poll() is None: child.terminate(); child.wait()
    raise
PY
python3 "$task_root/scripts/monitor-tools-fingerprint.py" verify "$test_root/source-manifest.json"
