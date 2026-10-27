#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
check_root=/Volumes/8TB/cinesomatic-build/sony-control-checks
mkdir -p "$check_root"
sdk_root="$task_root/ThirdParty/SonyCameraRemoteSDK"
# The Swift store uses an injected fake; no physical camera is contacted.
xcrun clang++ -x objective-c++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror \
  -c "$task_root/Sources/DeckLinkBackend/SonyCameraControl.inc" -o "$check_root/bridge.o"
xcrun swiftc -parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -import-objc-header "$task_root/Sources/DeckLinkBackend/SonyCameraControl.h" \
  "$task_root/Sources/App/SonyCameraCredentials.swift" "$task_root/Sources/App/SonyCameraStore.swift" "$task_root/Sources/App/UISonyCamera.swift" \
  "$task_root/Tools/SonyControlChecks/Snapshot.swift" "$task_root/Tools/SonyControlChecks/main.swift" \
  "$check_root/bridge.o" -lc++ -o "$check_root/store-checks"
"$check_root/store-checks" "$check_root/png"
if [[ -f "$sdk_root/lib/libCr_Core.dylib" ]]; then
  xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror \
    -I "$sdk_root/include" "$task_root/Tools/SonyControlChecks/Native.mm" \
    -L "$sdk_root/lib" -lCr_Core -framework Foundation -Wl,-rpath,"$sdk_root/lib" \
    -o "$check_root/native-checks"
  "$check_root/native-checks"
else
  echo 'Sony native checks skipped: install the SDK to test its value formats.'
fi
