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
external_root=/Volumes/8TB/cinesomatic-director-work
if ! mount | /usr/bin/grep -F ' on /Volumes/8TB ' >/dev/null; then
  echo 'External drive /Volumes/8TB is not mounted.' >&2
  exit 1
fi
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
build_root="$external_root/agent-work/build/ultracam/ui-verify"
# Skip when nothing the verifier compiles has changed since its last passing run.
# FORCE=1 runs it anyway.
inputs_hash="$(cd "$task_root" && find Sources Tools/UIVerify Packages/MonitorTools/Sources Packages/MonitorKit/Sources Packages/MonitorKit/Package.swift \
  ThirdParty scripts/ui-verify.sh scripts/monitor-tools-package.sh scripts/monitor-kit-package.sh \
  -type f \( -name '*.swift' -o -name '*.metal' -o -name '*.msl' -o -name '*.mm' -o -name '*.h' -o -name '*.inc' -o -name '*.cpp' -o -name '*.txt' -o -name '*.sh' \) \
  -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)-strict${STRICT:-1}"
if [[ "${FORCE:-0}" != 1 && -f "$build_root/last-pass" && "$(cat "$build_root/last-pass")" == "$inputs_hash" ]]; then
  echo "UI verify: unchanged since the last passing run ($build_root/latest). FORCE=1 to rerun."
  exit 0
fi
test_root="$build_root/$run_id"
mkdir -p "$test_root/modules" "$test_root/tmp"
export TMPDIR="$test_root/tmp"
export MACOSX_DEPLOYMENT_TARGET=26.0
export ULTRACAM_SHADER="$task_root/Sources/App/LUTShaders.metal"
source "$task_root/scripts/monitor-tools-package.sh"
source "$task_root/scripts/monitor-kit-package.sh"
monitor_package_build > "$test_root/package-build.log" 2>&1 || {
  cat "$test_root/package-build.log"
  exit 1
}
monitor_kit_package_build >> "$test_root/package-build.log" 2>&1 || {
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
done < <(find "$task_root/Sources/App" -maxdepth 1 -name '*.swift' | sort)
# Unoptimized: the checks don't need optimized code, and -O doubles the compile.
xcrun swiftc -Onone -swift-version 5 -strict-concurrency=complete -warnings-as-errors -D UI_VERIFY \
  -target arm64-apple-macos26.0 \
  -module-cache-path "$test_root/modules" "${monitor_link_args[@]}" "${monitor_kit_link_args[@]}" \
  -Xcc -DULTRACAM_BACKEND_TESTING \
  -import-objc-header "$task_root/Sources/DeckLinkBackend/BridgingHeader.h" \
  "$task_root"/Sources/Shared/*.swift "$task_root"/Sources/Recording/*.swift \
  "${app_sources[@]}" "$task_root"/Tools/UIVerify/*.swift \
  "$test_root/UltracamBackend.o" "$test_root/DeckLinkAPIDispatch.o" \
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
