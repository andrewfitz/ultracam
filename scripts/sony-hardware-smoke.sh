#!/bin/bash
# Optional real-camera discovery/readback. Does not change exposure or record.
set -euo pipefail
smoke_args=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --read-settings) shift ;;
    --rescan) shift ;;
    --expect-cameras)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]]; then echo '--expect-cameras requires a count.' >&2; exit 2; fi
      shift 2 ;;
    --direct)
      if [[ $# -lt 3 ]]; then echo '--direct requires IP and MAC address.' >&2; exit 2; fi
      shift 3 ;;
    *) echo 'Usage: sony-hardware-smoke.sh [--read-settings] [--rescan] [--expect-cameras COUNT] [--direct IP MAC]' >&2; exit 2 ;;
  esac
done
task_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk_root="$task_root/ThirdParty/SonyCameraRemoteSDK"
if [[ ! -f "$sdk_root/lib/libCr_Core.dylib" ]]; then
  echo 'Install the Sony SDK with scripts/install-sony-sdk.py first.' >&2
  exit 1
fi
smoke_root=/Volumes/8TB/cinesomatic-build/sony-hardware-smoke
smoke_app="$smoke_root/SonyHardwareCheck.app"
mkdir -p "$smoke_app/Contents/MacOS" "$smoke_app/Contents/Frameworks"
# Sony locates adapters using the main bundle's Contents/Frameworks/CrAdapter.
cp -R "$sdk_root/lib/" "$smoke_app/Contents/Frameworks/"
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
xcrun clang++ -x objective-c++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror \
  -DULTRACAM_SONY_SDK=1 -I "$sdk_root/include" \
  "$task_root/Sources/DeckLinkBackend/SonyCameraControl.inc" "$task_root/Tools/SonyControlChecks/Hardware.mm" \
  -L "$sdk_root/lib" -lCr_Core -framework AppKit -Wl,-rpath,@executable_path/../Frameworks \
  -o "$smoke_app/Contents/MacOS/SonyHardwareCheck"
"$smoke_app/Contents/MacOS/SonyHardwareCheck" "${smoke_args[@]}"
