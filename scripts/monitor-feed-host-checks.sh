#!/bin/bash
# MonitorFeedHost and MonitorGPUContext checks (W4 step 5): every app source plus
# Tests/MonitorKitHost, built like monitor-app-integration.sh (strict concurrency,
# warnings as errors). Synthetic only: no AppModel, no camera, no CMIO.
# scripts/test.sh (gate U) runs the same suite in its test binary; this script
# is the standalone strict build.
set -euo pipefail
if [[ $# -ne 0 ]]; then
  echo 'Usage: monitor-feed-host-checks.sh' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root="$(python3 "$task_root/scripts/work_paths.py" --path work_root)"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
test_root="$external_root/monitor-feed-host-checks/$run_id"
mkdir -p "$test_root/modules" "$test_root/tmp"
export TMPDIR="$test_root/tmp"
export MACOSX_DEPLOYMENT_TARGET=26.0
export ULTRACAM_SHADER="$task_root/Sources/App/LUTShaders.metal"
source "$task_root/scripts/monitor-kit-package.sh"
monitor_kit_package_build > "$test_root/package-build.log" 2>&1 || {
  cat "$test_root/package-build.log"
  exit 1
}
rust_manifest="$task_root/Tools/auto-switcher/Cargo.toml"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$(python3 "$task_root/scripts/work_paths.py" --path build_root)/auto-switcher-target}"
rustc_path="$(rustup which --toolchain stable rustc)"
rustdoc_path="$(rustup which --toolchain stable rustdoc)"
RUSTC="$rustc_path" RUSTDOC="$rustdoc_path" rustup run stable cargo build \
  --manifest-path "$rust_manifest" --release --locked > "$test_root/rust-build.log" 2>&1
auto_switcher_lib="$CARGO_TARGET_DIR/release"
source "$task_root/scripts/vendor-build.sh"
vendor_configure test "" "" app
vendor_compile_native "$test_root/compile.log"
app_sources=()
while IFS= read -r source_file; do
  if [[ "$source_file" != */UltracamApp.swift ]]; then app_sources+=("$source_file"); fi
done < <(rg --files "$task_root/Sources/App" -g '*.swift' | sort)
frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -O -swift-version 5 -strict-concurrency=complete -warnings-as-errors -D ULTRACAM_TEST_SUPPORT \
  -target arm64-apple-macos26.0 \
  -module-cache-path "$test_root/modules" "${monitor_kit_link_args[@]}" \
  ${vendor_swift_native_args[@]+"${vendor_swift_native_args[@]}"} \
  -import-objc-header "$vendor_bridge" \
  -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
  -I "$libraries" -L "$libraries" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$libraries" \
  "$task_root"/Sources/Shared/*.swift "$task_root"/Sources/DeviceAPI/*.swift ${vendor_swift_sources[@]+"${vendor_swift_sources[@]}"} "$task_root"/Sources/Recording/*.swift \
  "${app_sources[@]}" "$task_root"/Tests/MonitorKitHost/*.swift \
  ${vendor_native_objects[@]+"${vendor_native_objects[@]}"} ${vendor_link_args[@]+"${vendor_link_args[@]}"} \
  -L "$auto_switcher_lib" -lauto_switcher \
  -framework Security -framework CoreFoundation -framework SystemConfiguration -lz -liconv -lc++ \
  -o "$test_root/monitor-feed-host-checks" >> "$test_root/compile.log" 2>&1 || {
  cat "$test_root/compile.log"
  exit 1
}
printf 'MonitorKit host check artifacts: %s\n' "$test_root"
"$test_root/monitor-feed-host-checks" > "$test_root/tests.log" 2>&1 || {
  cat "$test_root/tests.log"
  exit 1
}
tail -5 "$test_root/tests.log"
