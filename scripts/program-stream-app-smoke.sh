#!/bin/bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo 'Usage: program-stream-app-smoke.sh PRODUCT_DIRECTORY [DURATION_SECONDS] [legacy|uhd60-hevc|720p2997-av1|all]' >&2
  exit 2
fi
profile="${3:-legacy}"
case "$profile" in
  legacy|uhd60-hevc|720p2997-av1|all) ;;
  *) echo "Unknown stream profile: $profile" >&2; exit 2 ;;
esac
pkg="$1"
task_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$task_root/scripts/program-stream-link.sh"
program_stream_link_args "$pkg"
build_root="$(python3 "$task_root/scripts/work_paths.py" --path build_root)"
mkdir -p "$build_root"
test_root="$(mktemp -d "$build_root/program-stream-app.XXXXXX")"
echo "Program stream app smoke artifacts: $test_root"
export TMPDIR="$test_root/tmp"
export MACOSX_DEPLOYMENT_TARGET=26.0
mkdir -p "$TMPDIR" "$test_root/modules"
source "$task_root/scripts/monitor-kit-package.sh"
monitor_kit_package_build >> "$test_root/monitor.log" 2>&1 || { cat "$test_root/monitor.log"; exit 1; }
source "$task_root/scripts/vendor-build.sh"
vendor_configure test "" "" app
vendor_compile_native "$test_root/native.log"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$build_root/auto-switcher-target}"
rustc_path="$(rustup which --toolchain stable rustc)"
RUSTC="$rustc_path" rustup run stable cargo build --release --locked --manifest-path "$task_root/Apps/AutoSwitcher/Cargo.toml"
# Compile and verify against the same fixture sources throughout the matrix.
cp -R "$task_root/Sources" "$test_root/Sources"
mkdir -p "$test_root/Tools/ProgramStreamSmoke" "$test_root/Tools/ProgramStreamAppSmoke"
cp "$task_root"/Tools/ProgramStreamSmoke/{FixturePublisher.swift,inspect_media.py,run_receiver.py} "$test_root/Tools/ProgramStreamSmoke/"
cp "$task_root"/Tools/ProgramStreamAppSmoke/{main.swift,verify.py} "$test_root/Tools/ProgramStreamAppSmoke/"
fixture_vendor_sources=()
for source in ${vendor_swift_sources[@]+"${vendor_swift_sources[@]}"}; do
  snapshot="$test_root/${source#"$task_root/"}"
  mkdir -p "$(dirname "$snapshot")"
  cp "$source" "$snapshot"
  fixture_vendor_sources+=("$snapshot")
done
export ULTRACAM_SHADER="$test_root/Sources/App/LUTShaders.metal"
git -C "$task_root" rev-parse HEAD >> "$test_root/revision"
find "$test_root/Sources" "$test_root/Tools" "$test_root/Vendors" -type f -exec shasum -a 256 {} + > "$test_root/source-sha256"
app_sources=()
for source in "$test_root"/Sources/App/*.swift; do
  if [[ "$source" != */UltracamApp.swift ]]; then app_sources+=("$source"); fi
done
xcrun swiftc -parse-as-library -O -whole-module-optimization -num-threads 4 \
  -swift-version 5 -strict-concurrency=complete -D ULTRACAM_TEST_SUPPORT -D ULTRACAM_STREAM_PUBLISHING \
  -target arm64-apple-macos26.0 -module-cache-path "$test_root/modules" "${monitor_kit_link_args[@]}" \
  "${stream_link_args[@]}" \
  ${vendor_swift_native_args[@]+"${vendor_swift_native_args[@]}"} -import-objc-header "$vendor_bridge" \
  "$test_root"/Sources/{Shared,DeviceAPI,Recording,Program}/*.swift ${fixture_vendor_sources[@]+"${fixture_vendor_sources[@]}"} \
  "${app_sources[@]}" "$test_root/Tools/ProgramStreamSmoke/FixturePublisher.swift" "$test_root/Tools/ProgramStreamAppSmoke/main.swift" \
  ${vendor_native_objects[@]+"${vendor_native_objects[@]}"} ${vendor_link_args[@]+"${vendor_link_args[@]}"} \
  -L "$CARGO_TARGET_DIR/release" -lauto_switcher -framework Security -framework CoreFoundation \
  -framework SystemConfiguration -lz -liconv -o "$test_root/app-smoke" >> "$test_root/compile.log" 2>&1 || { cat "$test_root/compile.log"; exit 1; }
if [[ "$profile" == all ]]; then
  status=0
  for candidate in legacy uhd60-hevc 720p2997-av1; do
    mkdir "$test_root/$candidate"
    python3 -B "$test_root/Tools/ProgramStreamAppSmoke/verify.py" "$test_root/app-smoke" \
      "$test_root/$candidate" "${2:-24}" "$candidate" || status=1
  done
  exit "$status"
fi
python3 -B "$test_root/Tools/ProgramStreamAppSmoke/verify.py" "$test_root/app-smoke" "$test_root" "${2:-24}" "$profile"
