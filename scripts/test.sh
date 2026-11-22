#!/bin/bash
set -euo pipefail
compile_only=false
if [[ ${1:-} == --app-compile-only ]]; then compile_only=true; shift; fi
if [[ $# -ne 0 ]]; then
  echo 'Usage: test.sh [--app-compile-only]' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root="$(python3 "$task_root/scripts/work_paths.py" --path work_root)"
export TMPDIR="$external_root/tmp"
# Match the deployment target used by the Xcode test binary and production app.
export MACOSX_DEPLOYMENT_TARGET="26.0"
artifact_root="$external_root/agent-work/ultracam"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
test_root="$external_root/agent-work/build/ultracam/tests/$run_id"
logs_root="$artifact_root/logs"
mkdir -p "$TMPDIR" "$test_root/modules" "$artifact_root" "$logs_root"
if [[ "$compile_only" == false ]]; then
python3 -m unittest discover -s "$task_root/Tests/BuildContracts" -v
python3 -m unittest discover -s "$task_root/Tests/DiagnosticContracts" -v
python3 -m unittest discover -s "$task_root/Tests/VendorSDK" -v
python3 -m unittest discover -s "$task_root/Tests/BundleContracts" -v
python3 -m unittest discover -s "$task_root/Tests/BoundaryContracts" -v
python3 -m unittest discover -s "$task_root/Tests/CIContracts" -v
python3 -m unittest discover -s "$task_root/Tests/CPUPixelContracts" -v
python3 "$task_root/scripts/check-vendor-boundaries.py"
python3 "$task_root/scripts/check-cpu-pixel-access.py"
python3 "$task_root/scripts/test-discovery-log-picker.py"
python3 "$task_root/scripts/test-settings-intent.py"
python3 "$task_root/scripts/test-source-ownership.py"
python3 "$task_root/scripts/test-app-source-integration.py"
python3 "$task_root/scripts/test-camera-standby-timing.py"
fi
package_log="$logs_root/monitor-package-$run_id.log"
source "$task_root/scripts/monitor-kit-package.sh"
monitor_kit_selftest_log="$logs_root/monitor-kit-selftest-$run_id.log"
/bin/bash "$task_root/scripts/monitor-kit-package.sh" selftest > "$monitor_kit_selftest_log" 2>&1 || {
  cat "$monitor_kit_selftest_log"; exit 1;
}
monitor_kit_package_build > "$package_log" 2>&1 || { cat "$package_log"; exit 1; }
monitor_kit_test_log="$logs_root/monitor-kit-package-tests-$run_id.log"
if [[ "$compile_only" == false ]]; then
  monitor_kit_package_test "$monitor_kit_test_log" || { monitor_kit_test_report "$monitor_kit_test_log"; exit 1; }
fi
# In-repo Swift packages with their own tests (MonitorKit runs above).
package_test() {
  local log="$logs_root/package-$1-tests-$run_id.log"
  xcrun swift test --package-path "$task_root/Packages/$1" --scratch-path "$test_root/package-$1" > "$log" 2>&1 || {
    cat "$log"; echo "$1 package tests failed ($log)" >&2; exit 1;
  }
  echo "$1 package tests passed ($log)"
}
if [[ "$compile_only" == false ]]; then
  package_test HaishinKitRTMP
  package_test ProgramAV1
fi
auto_switcher_source="$(python3 "$task_root/scripts/auto_switcher_source.py")"
rust_manifest="$auto_switcher_source/Cargo.toml"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$(python3 "$task_root/scripts/work_paths.py" --path build_root)/auto-switcher-target}"
# rustup installs to ~/.cargo/bin, which non-login shells may not have on PATH.
command -v rustup >/dev/null || export PATH="$HOME/.cargo/bin:$PATH"
rustc_path="$(rustup which --toolchain stable rustc)"
rustdoc_path="$(rustup which --toolchain stable rustdoc)"
RUSTC="$rustc_path" RUSTDOC="$rustdoc_path" rustup run stable cargo build \
  --manifest-path "$rust_manifest" --release --locked
if [[ "$compile_only" == false ]]; then
  RUSTC="$rustc_path" RUSTDOC="$rustdoc_path" rustup run stable cargo test \
    --manifest-path "$rust_manifest" --release --locked
fi
auto_switcher_lib="$CARGO_TARGET_DIR/release"
export ULTRACAM_SHADER="$task_root/Sources/App/LUTShaders.metal"
frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
compile_log="$logs_root/test-compile-$run_id.log"
test_log="$logs_root/tests-$run_id.log"
ln -sfn "logs/$(basename "$compile_log")" "$artifact_root/test-compile.log"
source "$task_root/scripts/vendor-build.sh"
vendor_configure test
vendor_compile_native "$compile_log"
app_sources=()
for source_file in "$task_root"/Sources/App/*.swift; do
  if [[ "$source_file" != */UltracamApp.swift ]]; then app_sources+=("$source_file"); fi
done
shared_sources=()
for source_file in "$task_root"/Sources/Shared/*.swift; do
  if [[ "$source_file" != */ExtensionFormatCatalog.swift ]]; then shared_sources+=("$source_file"); fi
done
# Match the release compilation mode and bound code generation concurrency.
xcrun swiftc -O -whole-module-optimization -num-threads 4 \
  -swift-version 5 -strict-concurrency=complete -warnings-as-errors -D ULTRACAM_TEST_SUPPORT -target arm64-apple-macos26.0 -module-cache-path "$test_root/modules" \
  "${monitor_kit_link_args[@]}" \
  -D CAPTURE_LIFECYCLE_TESTS ${vendor_swift_native_args[@]+"${vendor_swift_native_args[@]}"} \
  -import-objc-header "$vendor_bridge" \
  -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
  -I "$libraries" -L "$libraries" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$libraries" \
  "${shared_sources[@]}" "$task_root/Sources/Shared/ExtensionFormatCatalog.swift" "$task_root"/Sources/DeviceAPI/*.swift ${vendor_swift_sources[@]+"${vendor_swift_sources[@]}"} \
  "$task_root"/Sources/Program/*.swift \
  "$task_root"/Sources/Recording/*.swift \
  "${app_sources[@]}" \
  "$task_root/Sources/CameraExtension/OutputFormatCatalog.swift" \
  "$task_root/Sources/CameraExtension/CameraProvider.swift" \
  "$task_root"/Sources/CameraProvider/*.swift \
  "$task_root"/Tests/*.swift "$task_root"/Tests/Recording/*.swift "$task_root"/Tests/CameraProvider/*.swift \
  "$task_root/Tests/MonitorKitHost/MonitorFeedHostChecks.swift" \
  ${vendor_native_objects[@]+"${vendor_native_objects[@]}"} ${vendor_link_args[@]+"${vendor_link_args[@]}"} -L "$auto_switcher_lib" -lauto_switcher \
  -framework Security -framework CoreFoundation -framework SystemConfiguration -lz -liconv -lc++ \
  -o "$test_root/lut-tests" >> "$compile_log" 2>&1 || {
  cat "$compile_log"
  exit 1
}
if [[ "$compile_only" == true ]]; then
  echo "App compile passed: $test_root/lut-tests (compile log: $compile_log)"
  exit 0
fi
: > "$test_log"
ln -sfn "logs/$(basename "$test_log")" "$artifact_root/tests.log"
"$test_root/lut-tests" > "$test_log" 2>&1 || {
  cat "$test_log"
  exit 1
}
python3 "$task_root/scripts/check-test-coverage.py" "$test_log"
python3 "$task_root/scripts/check-gpu-proof-skips.py" --app "$test_log"
python3 "$task_root/scripts/check-gpu-proof-skips.py" --package "$monitor_kit_test_log"
python3 "$task_root/scripts/vendors.py" run-tests
# MonitorKit's XCTest bundles, one "Executed" summary each after the run. A
# skipped case is a successful platform-qualified outcome, but it is not
# coverage; keep it visible instead of claiming that every case ran.
monitor_kit_tests="$(awk "/Test Suite 'All tests' (passed|failed)/ { getline; print }" "$monitor_kit_test_log" \
  | awk '{ tests += $2 } END { print tests + 0 }')"
monitor_kit_skipped="$(monitor_kit_skipped_cases "$monitor_kit_test_log" | awk 'NF { count++ } END { print count + 0 }')"
if [[ "$monitor_kit_skipped" -gt 0 ]]; then
  echo "MonitorKit package: $monitor_kit_tests tests completed, $monitor_kit_skipped skipped (platform-qualified; coverage is incomplete) ($monitor_kit_test_log)"
else
  echo "MonitorKit package: $monitor_kit_tests tests completed, none skipped ($monitor_kit_test_log)"
fi
# Timing budgets that passed only on their retry: report them, they are not silent.
if /usr/bin/grep -q '^FLAKY (passed on retry)' "$monitor_kit_test_log"; then
  echo 'WARNING: MonitorKit timing budgets missed on the first run, passed on retry:'
  /usr/bin/grep '^FLAKY (passed on retry)' "$monitor_kit_test_log"
fi
tail -5 "$test_log"
