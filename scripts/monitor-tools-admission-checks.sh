#!/bin/bash
# Focused metadata/capacity checks only; no GPU, recording or devices.
set -euo pipefail
[[ $# -eq 0 ]] || { echo 'Usage: monitor-tools-admission-checks.sh' >&2; exit 2; }
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root=/Volumes/8TB/cinesomatic-director-work
[[ -d /Volumes/8TB && "$(stat -f %d /Volumes/8TB)" != "$(stat -f %d /Volumes)" ]] || { echo 'External drive /Volumes/8TB is not mounted.' >&2; exit 1; }
export TMPDIR="$external_root/tmp" MACOSX_DEPLOYMENT_TARGET=26.0
test_root="$external_root/agent-work/build/ultracam/monitor-admission/$(date -u +%Y%m%dT%H%M%S)-$$"
mkdir -p "$TMPDIR" "$test_root/modules"
python3 "$task_root/scripts/monitor-tools-fingerprint.py" capture "$test_root/source-manifest.json"
xcrun swiftc -O -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos26.0 -module-cache-path "$test_root/modules" \
  "$task_root/Tools/MonitorToolsRecording/PipelineAdmission.swift" \
  "$task_root/Tools/MonitorToolsRecordingTests/main.swift" -o "$test_root/admission-checks" > "$test_root/compile.log" 2>&1 || { cat "$test_root/compile.log"; exit 1; }
shasum -a 256 "$test_root/admission-checks" > "$test_root/binary-sha256.txt"
"$test_root/admission-checks" | tee "$test_root/run.log"
python3 "$task_root/scripts/monitor-tools-fingerprint.py" verify "$test_root/source-manifest.json"
echo "Artifacts: $test_root"
