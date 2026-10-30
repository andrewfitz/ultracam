#!/bin/bash
# Contracts run without a Sony installation; SDK-present generation uses fixtures.
# --hardware additionally runs synthetic media/UI integration on a Metal 4 host.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:---contracts-only}"
[[ $# -le 1 && ( "$mode" == --contracts-only || "$mode" == --hardware ) ]] || {
  echo 'Usage: ci-vendor-checks.sh [--contracts-only | --hardware]' >&2; exit 2;
}
python3 "$task_root/scripts/vendors.py" validate
python3 "$task_root/scripts/vendor-sdk.py" verify decklink
for directory in BuildContracts VendorSDK BundleContracts BoundaryContracts CIContracts CPUPixelContracts; do
  python3 -m unittest discover -s "$task_root/Tests/$directory" -v
done
python3 "$task_root/scripts/check-canonical-generation.py"
python3 "$task_root/scripts/check-vendor-boundaries.py"
python3 "$task_root/scripts/check-cpu-pixel-access.py"
if [[ "$mode" == --hardware ]]; then
  export ULTRACAM_REQUIRE_GPU_PROOFS=1
  bash "$task_root/scripts/test.sh"
  bash "$task_root/scripts/ui-typecheck.sh"
  STRICT=1 bash "$task_root/scripts/ui-verify.sh"
  bash "$task_root/scripts/monitor-app-integration.sh"
  bash "$task_root/scripts/monitor-feed-host-checks.sh"
fi
