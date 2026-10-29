#!/bin/bash
# Builds, but does not launch, the production Sony UI in a separate sandbox app.
set -euo pipefail
export MACOSX_DEPLOYMENT_TARGET=26.0
task_root="$(cd "$(dirname "$0")/.." && pwd)"
check_root="$(python3 "$task_root/scripts/work_paths.py" --path build_root)/sony-sandbox-ui-check"
check_app="$check_root/SonyCameraSoftwareCheck.app"
mkdir -p "$check_app/Contents/MacOS" "$check_app/Contents/Frameworks"
source "$task_root/scripts/vendor-build.sh"
vendor_configure test sony sandbox
vendor_embed_into "$check_app/Contents/Frameworks"
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
vendor_compile_native "$check_root/compile.log"
xcrun swiftc -parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos26.0 ${vendor_swift_native_args[@]+"${vendor_swift_native_args[@]}"} \
  -import-objc-header "$vendor_bridge" ${vendor_swift_sources[@]+"${vendor_swift_sources[@]}"} ${vendor_native_objects[@]+"${vendor_native_objects[@]}"} \
  ${vendor_link_args[@]+"${vendor_link_args[@]}"} -lc++ -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
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
