#!/bin/bash
# Synthetic media only; kills child writers, never the installed app.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root=/Volumes/8TB/cinesomatic-director-work
if ! mount | /usr/bin/grep -F ' on /Volumes/8TB ' > /dev/null; then
  echo 'External drive /Volumes/8TB is not mounted.' >&2
  exit 1
fi
export TMPDIR="$external_root/tmp"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
smoke_root="$external_root/agent-work/build/ultracam/recording-recovery/$run_id"
mkdir -p "$TMPDIR" "$smoke_root/modules"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  -module-cache-path "$smoke_root/modules" \
  "$task_root/Sources/Shared/VideoContract.swift" \
  "$task_root/Sources/Shared/VideoBufferLayout.swift" \
  "$task_root"/Sources/Recording/*.swift \
  "$task_root/Tools/RecordingRecoverySmoke/main.swift" \
  -o "$smoke_root/recovery-smoke" > "$smoke_root/compile.log" 2>&1 || {
  cat "$smoke_root/compile.log"; exit 1
}
"$smoke_root/recovery-smoke" "$smoke_root/takes" > "$smoke_root/run.log" 2>&1 || {
  cat "$smoke_root/run.log"; exit 1
}
cat "$smoke_root/run.log"
