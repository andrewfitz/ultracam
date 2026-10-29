#!/bin/bash
# Synthetic media only; kills child writers, never the installed app.
set -euo pipefail
if [[ $# -gt 1 || ( $# -eq 1 && "${1:-}" != --build-only ) ]]; then
  echo 'Usage: recording-recovery-smoke.sh [--build-only]' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root="$(python3 "$task_root/scripts/work_paths.py" --path work_root)"
export TMPDIR="$external_root/tmp"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
smoke_root="$external_root/agent-work/build/ultracam/recording-recovery/$run_id"
mkdir -p "$TMPDIR" "$smoke_root/modules"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  -module-cache-path "$smoke_root/modules" \
  "$task_root/Sources/Shared/SourceFormat.swift" "$task_root/Sources/Shared/SourceAdmission.swift" "$task_root/Sources/Shared/VideoContract.swift" \
  "$task_root/Sources/Shared/VideoBufferLayout.swift" \
  "$task_root"/Sources/Recording/*.swift \
  "$task_root/Tools/RecordingRecoverySmoke/main.swift" \
  -o "$smoke_root/recovery-smoke" > "$smoke_root/compile.log" 2>&1 || {
  cat "$smoke_root/compile.log"; exit 1
}
if [[ "${1:-}" == --build-only ]]; then
  echo "Recording recovery helper built: $smoke_root/recovery-smoke"
  exit 0
fi
"$smoke_root/recovery-smoke" "$smoke_root/takes" > "$smoke_root/run.log" 2>&1 || {
  cat "$smoke_root/run.log"; exit 1
}
cat "$smoke_root/run.log"
