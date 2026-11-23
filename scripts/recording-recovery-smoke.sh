#!/bin/bash
# Synthetic media only; kills child writers, never the installed app.
set -euo pipefail
if [[ $# -gt 1 || ( $# -eq 1 && "${1:-}" != --build-only ) ]]; then
  echo 'Usage: recording-recovery-smoke.sh [--build-only]' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$(python3 "$task_root/scripts/work_paths.py" --path build_root)"
TMPDIR="$(python3 "$task_root/scripts/work_paths.py" --path tmp_root)"
export TMPDIR
mkdir -p "$TMPDIR" "$build_root/recording-recovery"
smoke_root="$(mktemp -d "$build_root/recording-recovery/run.XXXXXXXX")"
mkdir "$smoke_root/modules"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  -module-cache-path "$smoke_root/modules" \
  "$task_root/Sources/Shared/SourceFormat.swift" "$task_root/Sources/Shared/SourceSize.swift" "$task_root/Sources/Shared/SourceAdmission.swift" "$task_root/Sources/Shared/VideoContract.swift" "$task_root/Sources/Shared/VideoOutputOptions.swift" \
  "$task_root/Sources/Shared/VideoBufferLayout.swift" \
  "$task_root/Sources/Shared/RecordingTimebase.swift" "$task_root/Sources/Shared/VariableFrameTimeline.swift" \
  "$task_root/Sources/Shared/AudioVideoClockMapping.swift" "$task_root/Sources/Shared/MediaRetention.swift" \
  "$task_root/Sources/Shared/RGBFormats.swift" "$task_root/Sources/Shared/Packed422Formats.swift" \
  "$task_root/Sources/Shared/LossLogLimiter.swift" \
  "$task_root/Sources/Shared/NDIPlanarLayout.swift" \
  "$task_root/Sources/Shared/GPUAllocationBudget.swift" \
  "$task_root/Sources/Shared/Packed422GPU.swift" "$task_root/Sources/Shared/Packed422GPU4.swift" \
  "$task_root"/Sources/Recording/*.swift \
  "$task_root/Tools/RecordingRecoverySmoke/main.swift" \
  -o "$smoke_root/recovery-smoke" > "$smoke_root/compile.log" 2>&1 || {
  cat "$smoke_root/compile.log"; exit 1
}
if [[ "${1:-}" == --build-only ]]; then
  echo "Recording recovery helper built: $smoke_root/recovery-smoke"
  exit 0
fi
{
  "$smoke_root/recovery-smoke" "$smoke_root/takes" &&
    python3 "$task_root/Tools/RecordingRecoverySmoke/verify_owner_exit.py" "$smoke_root/recovery-smoke" "$smoke_root"
} > "$smoke_root/run.log" 2>&1 || {
  cat "$smoke_root/run.log"; exit 1
}
cat "$smoke_root/run.log"
