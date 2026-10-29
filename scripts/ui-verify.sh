#!/bin/bash
# Offscreen verification of the new interface: renders every screen and state in
# light and dark, checks accessibility labels and control actions, exercises the
# real AppModel through UISessionBridge, and checks the menu bar item builder.
# STRICT=0 reports view-dependent failures as pending instead of failing.
set -euo pipefail
if [[ $# -ne 0 ]]; then
  echo 'Usage: ui-verify.sh' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root="$(python3 "$task_root/scripts/work_paths.py" --path work_root)"
# Before the inputs hash: it names the package's files, so a clone without the
# submodule stops on its message, not on find's.
source "$task_root/scripts/monitor-kit-package.sh"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
build_root="$external_root/agent-work/build/ultracam/ui-verify"
# Skip when nothing the verifier compiles has changed since its last passing run.
# FORCE=1 runs it anyway.
inputs_hash="$(cd "$task_root" && find Sources Tools/UIVerify Packages/MonitorKit/Sources Packages/MonitorKit/Package.swift \
  Vendors Config/Assets.xcassets scripts/ui-verify.sh scripts/monitor-kit-package.sh scripts/vendor-build.sh scripts/vendors.py \
  -type f \( -name '*.swift' -o -name '*.metal' -o -name '*.msl' -o -name '*.mm' -o -name '*.h' -o -name '*.inc' -o -name '*.cpp' -o -name '*.txt' -o -name '*.sh' -o -name '*.py' -o -name '*.json' -o -name '*.svg' -o -name '*.png' \) \
  -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)-strict${STRICT:-1}-vendors$(python3 "$task_root/scripts/vendors.py" digest)"
if [[ "${FORCE:-0}" != 1 && -f "$build_root/last-pass" && "$(cat "$build_root/last-pass")" == "$inputs_hash" ]]; then
  echo "UI verify: unchanged since the last passing run ($build_root/latest). FORCE=1 to rerun."
  exit 0
fi
test_root="$build_root/$run_id"
mkdir -p "$test_root/modules" "$test_root/tmp"
export TMPDIR="$test_root/tmp"
export MACOSX_DEPLOYMENT_TARGET=26.0
export ULTRACAM_SHADER="$task_root/Sources/App/LUTShaders.metal"
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
done < <(find "$task_root/Sources/App" -maxdepth 1 -name '*.swift' | sort)
# Unoptimized: the checks don't need optimized code, and -O doubles the compile.
xcrun swiftc -Onone -swift-version 5 -strict-concurrency=complete -warnings-as-errors -D ULTRACAM_TEST_SUPPORT -D UI_VERIFY \
  -target arm64-apple-macos26.0 \
  -module-cache-path "$test_root/modules" "${monitor_kit_link_args[@]}" \
  ${vendor_swift_native_args[@]+"${vendor_swift_native_args[@]}"} \
  -import-objc-header "$vendor_bridge" \
  "$task_root"/Sources/Shared/*.swift "$task_root"/Sources/DeviceAPI/*.swift ${vendor_swift_sources[@]+"${vendor_swift_sources[@]}"} "$task_root"/Sources/Recording/*.swift \
  "${app_sources[@]}" "$task_root"/Tools/UIVerify/*.swift \
  ${vendor_native_objects[@]+"${vendor_native_objects[@]}"} ${vendor_link_args[@]+"${vendor_link_args[@]}"} \
  -L "$auto_switcher_lib" -lauto_switcher \
  -framework Security -framework CoreFoundation -framework SystemConfiguration -lz -liconv -lc++ \
  -o "$test_root/ui-verify" >> "$test_root/compile.log" 2>&1 || {
  cat "$test_root/compile.log"
  exit 1
}
ln -sfn "$run_id" "$build_root/latest"
printf 'UI verify artifacts: %s\n' "$test_root"
status=0
"$test_root/ui-verify" "$test_root" > "$test_root/ui-verify.log" 2>&1 || status=$?
grep -E '^(FAIL|PENDING)' "$test_root/ui-verify.log" | head -80 || true
tail -4 "$test_root/ui-verify.log"
if [[ "$status" == 0 ]]; then printf '%s\n' "$inputs_hash" > "$build_root/last-pass"; fi
exit "$status"
