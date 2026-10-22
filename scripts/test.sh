#!/bin/bash
set -euo pipefail
if [[ $# -ne 0 ]]; then
  echo 'Usage: test.sh' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root=/Volumes/8TB/cinesomatic-director-work
if ! mount | /usr/bin/grep -F ' on /Volumes/8TB ' > /dev/null; then
  echo 'External drive /Volumes/8TB is not mounted.' >&2
  exit 1
fi
export TMPDIR="$external_root/tmp"
# Match the deployment target used by the Xcode test binary and production app.
export MACOSX_DEPLOYMENT_TARGET="26.0"
artifact_root="$external_root/agent-work/ultracam"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
test_root="$external_root/agent-work/build/ultracam/tests/$run_id"
logs_root="$artifact_root/logs"
mkdir -p "$TMPDIR" "$test_root/modules" "$artifact_root" "$logs_root"
source "$task_root/scripts/monitor-tools-package.sh"
package_log="$logs_root/monitor-package-$run_id.log"
monitor_package_build > "$package_log" 2>&1 || { cat "$package_log"; exit 1; }
xcrun swift test --package-path "$monitor_package" --scratch-path "$monitor_scratch" --cache-path "$test_root/package-cache" \
  --configuration release --arch arm64 > "$logs_root/monitor-package-tests-$run_id.log" 2>&1 || {
  cat "$logs_root/monitor-package-tests-$run_id.log"; exit 1;
}
source "$task_root/scripts/monitor-kit-package.sh"
monitor_kit_selftest_log="$logs_root/monitor-kit-selftest-$run_id.log"
/bin/bash "$task_root/scripts/monitor-kit-package.sh" selftest > "$monitor_kit_selftest_log" 2>&1 || {
  cat "$monitor_kit_selftest_log"; exit 1;
}
monitor_kit_package_build >> "$package_log" 2>&1 || { cat "$package_log"; exit 1; }
monitor_kit_test_log="$logs_root/monitor-kit-package-tests-$run_id.log"
monitor_kit_package_test "$monitor_kit_test_log" || { monitor_kit_test_report "$monitor_kit_test_log"; exit 1; }
bash "$task_root/scripts/fetch-decklink-sdk.sh"
rust_manifest="$task_root/Tools/auto-switcher/Cargo.toml"
rustc_path="$(rustup which --toolchain stable rustc)"
rustdoc_path="$(rustup which --toolchain stable rustdoc)"
RUSTC="$rustc_path" RUSTDOC="$rustdoc_path" rustup run stable cargo build \
  --manifest-path "$rust_manifest" --release --locked
auto_switcher_lib="$task_root/Tools/auto-switcher/target/release"
sdk_dir="${DECKLINK_SDK_DIR:-$task_root/ThirdParty/DeckLinkSDK/include}"
export ULTRACAM_SHADER="$task_root/Sources/App/LUTShaders.metal"
frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
compile_log="$logs_root/test-compile-$run_id.log"
test_log="$logs_root/tests-$run_id.log"
ln -sfn "logs/$(basename "$compile_log")" "$artifact_root/test-compile.log"
ln -sfn "logs/$(basename "$test_log")" "$artifact_root/tests.log"
xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror -DULTRACAM_BACKEND_TESTING \
  -fmodules-cache-path="$test_root/modules" -I "$sdk_dir" \
  -c "$task_root/Sources/DeckLinkBackend/UltracamBackend.mm" -o "$test_root/UltracamBackend.o" > "$compile_log" 2>&1 || {
  cat "$compile_log"; exit 1
}
xcrun clang++ -std=c++17 -I "$sdk_dir" -c "$sdk_dir/DeckLinkAPIDispatch.cpp" \
  -o "$test_root/DeckLinkAPIDispatch.o" >> "$compile_log" 2>&1 || {
  cat "$compile_log"; exit 1
}
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos26.0 -module-cache-path "$test_root/modules" \
  "${monitor_link_args[@]}" "${monitor_kit_link_args[@]}" \
  -D CAPTURE_LIFECYCLE_TESTS -Xcc -DULTRACAM_BACKEND_TESTING \
  -import-objc-header "$task_root/Sources/DeckLinkBackend/BridgingHeader.h" \
  -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
  -I "$libraries" -L "$libraries" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$libraries" \
  "$task_root"/Sources/Shared/*.swift "$task_root/Sources/App/LUTProcessor.swift" "$task_root/Sources/App/AppResourceUsage.swift" \
  "$task_root"/Sources/Recording/*.swift \
  "$task_root/Sources/App/MonitorCoordinator.swift" "$task_root/Sources/App/MonitorCaptureSink.swift" \
  "$task_root/Sources/App/CameraSink.swift" "$task_root/Sources/App/CaptureController.swift" \
  "$task_root/Sources/App/AutoSwitcherBridge.swift" \
  "$task_root/Sources/App/AutoSwitcherTimelineRecorder.swift" \
  "$task_root/Sources/App/ProgramOutputBridge.swift" \
  "$task_root/Sources/App/ProgramNormalizer.swift" \
  "$task_root/Sources/App/VideoPreview.swift" \
  "$task_root/Sources/App/AppSettingsStore.swift" \
  "$task_root/Sources/App/VirtualCameraRegistryPublishing.swift" \
  "$task_root/Sources/App/RecordingModel.swift" \
  "$task_root/Sources/App/AutomaticFeedPolicy.swift" \
  "$task_root/Sources/App/CameraDemandMonitor.swift" \
  "$task_root/Sources/App/ExtensionInstaller.swift" \
  "$task_root/Sources/App/UIPresentation.swift" "$task_root/Sources/App/UIAction.swift" \
  "$task_root/Sources/CameraExtension/CameraProvider.swift" \
  "$task_root"/Tests/*.swift "$task_root"/Tests/Recording/*.swift \
  "$test_root/UltracamBackend.o" "$test_root/DeckLinkAPIDispatch.o" -L "$auto_switcher_lib" -lauto_switcher \
  -framework Security -framework CoreFoundation -framework SystemConfiguration -lz -liconv -lc++ \
  -o "$test_root/lut-tests" >> "$compile_log" 2>&1 || {
  cat "$compile_log"
  exit 1
}
"$test_root/lut-tests" > "$test_log" 2>&1 || {
  cat "$test_log"
  exit 1
}
# MonitorKit's XCTest bundles, one "Executed" summary each after the run.
monitor_kit_tests="$(awk "/Test Suite 'All tests' (passed|failed)/ { getline; print }" "$monitor_kit_test_log" \
  | awk '{ tests += $2 } END { print tests + 0 }')"
echo "MonitorKit package: $monitor_kit_tests tests run, all passed ($monitor_kit_test_log)"
# Timing budgets that passed only on their retry: report them, they are not silent.
if /usr/bin/grep -q '^FLAKY (passed on retry)' "$monitor_kit_test_log"; then
  echo 'WARNING: MonitorKit timing budgets missed on the first run, passed on retry:'
  /usr/bin/grep '^FLAKY (passed on retry)' "$monitor_kit_test_log"
fi
tail -5 "$test_log"
