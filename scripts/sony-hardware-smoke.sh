#!/bin/bash
# Optional real-camera discovery/readback. Does not change exposure or record.
set -euo pipefail
build_only=false
smoke_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) build_only=true; shift ;;
    --read-settings) smoke_args+=("$1"); shift ;;
    --rescan) smoke_args+=("$1"); shift ;;
    --expect-cameras)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]]; then echo '--expect-cameras requires a count.' >&2; exit 2; fi
      smoke_args+=("$1" "$2"); shift 2 ;;
    --direct)
      if [[ $# -lt 3 ]]; then echo '--direct requires IP and MAC address.' >&2; exit 2; fi
      smoke_args+=("$1" "$2" "$3"); shift 3 ;;
    *) echo 'Usage: sony-hardware-smoke.sh [--build-only] [--read-settings] [--rescan] [--expect-cameras COUNT] [--direct IP MAC]' >&2; exit 2 ;;
  esac
done
task_root="$(cd "$(dirname "$0")/.." && pwd)"
smoke_root="$(python3 "$task_root/scripts/work_paths.py" --path build_root)/sony-hardware-smoke"
smoke_app="$smoke_root/SonyHardwareCheck.app"
mkdir -p "$smoke_app/Contents/MacOS" "$smoke_app/Contents/Frameworks"
# Sony locates adapters using the main bundle's Contents/Frameworks/CrAdapter.
check_root="$smoke_root"
source "$task_root/scripts/vendor-build.sh"
vendor_configure test sony hardware
vendor_embed_into "$smoke_app/Contents/Frameworks"
python3 - "$smoke_app" <<'PY'
from pathlib import Path
import plistlib
import sys
root = Path(sys.argv[1])
(root / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'SonyHardwareCheck',
    'CFBundleIdentifier': 'org.ultracam.sony-hardware-check',
    'CFBundleName': 'Ultracam Sony Hardware Check',
    'CFBundlePackageType': 'APPL',
    'NSLocalNetworkUsageDescription': 'Discover and read Sony FX3 settings to verify Ultracam camera control.',
}))
PY
vendor_compile_native "$smoke_root/compile.log"
xcrun clang++ ${vendor_native_objects[@]+"${vendor_native_objects[@]}"} ${vendor_link_args[@]+"${vendor_link_args[@]}"} -framework AppKit \
  -Wl,-rpath,@executable_path/../Frameworks -o "$smoke_app/Contents/MacOS/SonyHardwareCheck"
if [[ "$build_only" == true ]]; then
  echo "Built Sony hardware check: $smoke_app"
else
  "$smoke_app/Contents/MacOS/SonyHardwareCheck" "${smoke_args[@]}"
fi
