#!/bin/bash
set -euo pipefail
if [[ $# -ne 0 ]]; then
  echo 'Usage: monitor-app-integration.sh' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root=/Volumes/8TB/cinesomatic-build
if ! mount | /usr/bin/grep -F ' on /Volumes/8TB ' >/dev/null; then
  echo 'External drive /Volumes/8TB is not mounted.' >&2
  exit 1
fi
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
test_root="$external_root/monitor-app-integration/$run_id"
mkdir -p "$test_root/modules" "$test_root/tmp"
export TMPDIR="$test_root/tmp"
export MACOSX_DEPLOYMENT_TARGET=26.0
export ULTRACAM_SHADER="$task_root/Sources/App/LUTShaders.metal"
source "$task_root/scripts/monitor-tools-package.sh"
monitor_package_build > "$test_root/package-build.log" 2>&1 || {
  cat "$test_root/package-build.log"
  exit 1
}
bash "$task_root/scripts/fetch-decklink-sdk.sh"
sdk_dir="${DECKLINK_SDK_DIR:-$task_root/ThirdParty/DeckLinkSDK/include}"
rust_manifest="$task_root/Tools/auto-switcher/Cargo.toml"
rustc_path="$(rustup which --toolchain stable rustc)"
rustdoc_path="$(rustup which --toolchain stable rustdoc)"
RUSTC="$rustc_path" RUSTDOC="$rustdoc_path" rustup run stable cargo build \
  --manifest-path "$rust_manifest" --release --locked > "$test_root/rust-build.log" 2>&1
auto_switcher_lib="$task_root/Tools/auto-switcher/target/release"
xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror -DULTRACAM_BACKEND_TESTING \
  -fmodules-cache-path="$test_root/modules" -I "$sdk_dir" \
  -c "$task_root/Sources/DeckLinkBackend/UltracamBackend.mm" -o "$test_root/UltracamBackend.o" \
  > "$test_root/compile.log" 2>&1
xcrun clang++ -std=c++17 -I "$sdk_dir" -c "$sdk_dir/DeckLinkAPIDispatch.cpp" \
  -o "$test_root/DeckLinkAPIDispatch.o" >> "$test_root/compile.log" 2>&1
app_sources=()
while IFS= read -r source_file; do
  if [[ "$source_file" != */UltracamApp.swift ]]; then app_sources+=("$source_file"); fi
done < <(rg --files "$task_root/Sources/App" -g '*.swift' | sort)
frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -O -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos26.0 \
  -module-cache-path "$test_root/modules" "${monitor_link_args[@]}" \
  -Xcc -DULTRACAM_BACKEND_TESTING \
  -import-objc-header "$task_root/Sources/DeckLinkBackend/BridgingHeader.h" \
  -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
  -I "$libraries" -L "$libraries" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$libraries" \
  "$task_root"/Sources/Shared/*.swift "$task_root"/Sources/Recording/*.swift \
  "${app_sources[@]}" "$task_root/Tests/MonitorCoordinatorChecks.swift" \
  "$task_root/Tools/MonitorAppIntegration/main.swift" \
  "$test_root/UltracamBackend.o" "$test_root/DeckLinkAPIDispatch.o" \
  -L "$auto_switcher_lib" -lauto_switcher \
  -framework Security -framework CoreFoundation -framework SystemConfiguration -lz -liconv -lc++ \
  -o "$test_root/monitor-app-integration" >> "$test_root/compile.log" 2>&1 || {
  cat "$test_root/compile.log"
  exit 1
}
printf 'App monitor integration artifacts: %s\n' "$test_root"
"$test_root/monitor-app-integration" > "$test_root/tests.log" 2>&1 || {
  cat "$test_root/tests.log"
  exit 1
}
tail -5 "$test_root/tests.log"
