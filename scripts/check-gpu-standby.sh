#!/bin/bash
# Standalone Metal 4 proof only: no app launch, extension installation or capture.
set -euo pipefail
if [[ $# -gt 1 || ( $# -eq 1 && "${1:-}" != --build-only ) ]]; then
  echo 'Usage: check-gpu-standby.sh [--build-only]' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$(python3 "$task_root/scripts/work_paths.py" --path build_root)"
artifact_root="$(python3 "$task_root/scripts/work_paths.py" --path artifact_root)"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
build="$build_root/gpu-standby/$run_id"
artifacts="$artifact_root/gpu-standby/$run_id"
mkdir -p "$build/modules" "$build/tmp" "$artifacts"
export TMPDIR="$build/tmp"
export MACOSX_DEPLOYMENT_TARGET=26.0
xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos26.0 -module-cache-path "$build/modules" \
  "$task_root/Sources/Shared/GPUStandbyProducer.swift" \
  "$task_root/Sources/Shared/VideoContract.swift" \
  "$task_root/Sources/Shared/VideoBufferLayout.swift" \
  "$task_root/Sources/Shared/SourceFormat.swift" \
  "$task_root/Sources/Shared/ExtensionFormatCatalog.swift" \
  "$task_root/Sources/Shared/DerivedOutputAdmission.swift" \
  "$task_root/Sources/CameraExtension/OutputFormatCatalog.swift" \
  "$task_root/Tools/GPUStandbyChecks/main.swift" \
  -o "$build/gpu-standby-checks" > "$artifacts/compile.log" 2>&1 || {
    cat "$artifacts/compile.log" >&2
    exit 1
  }
if [[ "${1:-}" == --build-only ]]; then
  echo "GPU standby proof built: $build/gpu-standby-checks"
  exit 0
fi
evidence="$artifacts/evidence.json"
if "$build/gpu-standby-checks" --output "$evidence" > "$artifacts/proof.log" 2>&1; then
  echo "GPU standby evidence: $evidence"
else
  result=$?
  cat "$artifacts/proof.log" >&2
  echo "GPU standby proof failed or unsupported; evidence: $evidence" >&2
  exit "$result"
fi
