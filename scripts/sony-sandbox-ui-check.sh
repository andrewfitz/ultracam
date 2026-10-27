#!/bin/bash
# Builds, but does not launch, the production Sony UI in a separate sandbox app.
set -euo pipefail
export MACOSX_DEPLOYMENT_TARGET=26.0
task_root="$(cd "$(dirname "$0")/.." && pwd)"
check_root=/Volumes/8TB/cinesomatic-build/sony-sandbox-ui-check
check_app="$check_root/SonyCameraSoftwareCheck.app"
sdk_root="$task_root/ThirdParty/SonyCameraRemoteSDK"
[[ -f "$sdk_root/lib/libCr_Core.dylib" ]] || { echo 'Install the Sony SDK first.' >&2; exit 1; }
mkdir -p "$check_app/Contents/MacOS" "$check_app/Contents/Frameworks"
cp -R "$sdk_root/lib/" "$check_app/Contents/Frameworks/"
python3 - "$check_app" "$check_root" <<'PY'
from pathlib import Path
import plistlib
import sys
app, root = map(Path, sys.argv[1:])
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'SonyCameraSoftwareCheck',
    'CFBundleIdentifier': 'org.ultracam.sony-software-check',
    'CFBundleName': 'Sony Camera Software Check',
    'CFBundleVersion': '1',
    'CFBundlePackageType': 'APPL',
    'NSPrincipalClass': 'NSApplication',
    'NSLocalNetworkUsageDescription': 'Verify automatic Sony camera discovery for Ultracam.',
}))
(root / 'network.entitlements').write_bytes(plistlib.dumps({
    'com.apple.security.app-sandbox': True,
    'com.apple.security.network.client': True,
    'com.apple.security.network.server': True,
    'com.apple.security.cs.disable-library-validation': True,
}))
PY
xcrun clang++ -x objective-c++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror \
  -DULTRACAM_SONY_SDK=1 -I "$sdk_root/include" \
  -c "$task_root/Sources/DeckLinkBackend/SonyCameraControl.inc" -o "$check_root/sony.o"
xcrun swiftc -parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos26.0 \
  -import-objc-header "$task_root/Sources/DeckLinkBackend/SonyCameraControl.h" \
  "$task_root/Sources/App/SonyCameraCredentials.swift" "$task_root/Sources/App/SonyCameraStore.swift" "$task_root/Sources/App/UISonyCamera.swift" \
  "$task_root/Tools/SonyControlChecks/SandboxUI.swift" "$check_root/sony.o" \
  -L "$sdk_root/lib" -lCr_Core -lc++ -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -o "$check_app/Contents/MacOS/SonyCameraSoftwareCheck"
python3 - "$check_app" <<'PY'
from pathlib import Path
import subprocess
import sys
app = Path(sys.argv[1])
for library in sorted(app.rglob('*.dylib'), key=lambda p: -len(p.parts)):
    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(library)], check=True)
PY
codesign --force --sign - --timestamp=none --options runtime --entitlements "$check_root/network.entitlements" "$check_app"
codesign --verify --strict "$check_app"
echo "Built sandbox UI check: $check_app"
