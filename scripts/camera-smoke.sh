#!/bin/bash
# Build by default. --run explicitly exercises an already approved extension;
# --full additionally checks 4K ten-bit x422/v210 at both rates. Ad-hoc producer
# authorization requires the explicit local development extension build.
# --consumer requests only the virtual source for 20 seconds; the running host
# may start physical capture automatically. It inspects metadata, never pixels.
# --monitor-gpu-check[-full] runs the monitor load (the app's Metal 4 monitor
# path) over synthetic frames without CMIO; it never touches the extension.
# This script never installs or activates extensions.
set -euo pipefail
usage() { echo 'Usage: camera-smoke.sh [--run | --full | --consumer | --registry-check | --monitor | --monitor-full | --monitor-gpu-check | --monitor-gpu-check-full] [--segment-seconds 1..60 (monitor only)]' >&2; exit 2; }
if [[ $# -gt 0 ]]; then
  case "$1" in --run|--full|--consumer|--registry-check|--monitor|--monitor-full|--monitor-gpu-check|--monitor-gpu-check-full) ;; *) usage ;; esac
fi
if [[ $# -gt 1 ]]; then
  [[ $# -eq 3 && ( "$1" == --monitor || "$1" == --monitor-full ) && "$2" == --segment-seconds && "$3" =~ ^[0-9]+([.][0-9]+)?$ ]] || usage
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root="$(python3 "$task_root/scripts/work_paths.py" --path work_root)"
export TMPDIR="$external_root/tmp"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
smoke_root="$external_root/agent-work/build/ultracam-e2e/cmio-smoke/$run_id"
mkdir -p "$TMPDIR" "$smoke_root/modules"
compile_log="$smoke_root/compile.log"
export MACOSX_DEPLOYMENT_TARGET=26.0
test_root="$smoke_root"
source "$task_root/scripts/monitor-kit-package.sh"
monitor_kit_package_build >> "$compile_log" 2>&1 || { cat "$compile_log"; exit 1; }
# PipelineConfiguration's production settings declarations depend on the recording
# model. Use the same complete app source set as the standalone UI verifier.
rust_manifest="$task_root/Tools/auto-switcher/Cargo.toml"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$(python3 "$task_root/scripts/work_paths.py" --path build_root)/auto-switcher-target}"
rustc_path="$(rustup which --toolchain stable rustc)"
rustdoc_path="$(rustup which --toolchain stable rustdoc)"
RUSTC="$rustc_path" RUSTDOC="$rustdoc_path" rustup run stable cargo build \
  --manifest-path "$rust_manifest" --release --locked >> "$compile_log" 2>&1
source "$task_root/scripts/vendor-build.sh"
vendor_configure test "" "" app
vendor_compile_native "$smoke_root/native-compile.log"
app_sources=()
for source_file in "$task_root"/Sources/App/*.swift; do
  if [[ "$source_file" != */UltracamApp.swift ]]; then app_sources+=("$source_file"); fi
done
xcrun swiftc -O -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos26.0 -module-cache-path "$smoke_root/modules" "${monitor_kit_link_args[@]}" \
  ${vendor_swift_native_args[@]+"${vendor_swift_native_args[@]}"} \
  -import-objc-header "$vendor_bridge" \
  "$task_root"/Sources/Shared/*.swift "$task_root"/Sources/DeviceAPI/*.swift \
  ${vendor_swift_sources[@]+"${vendor_swift_sources[@]}"} \
  "$task_root"/Sources/Recording/*.swift "$task_root"/Sources/Program/*.swift \
  "${app_sources[@]}" "$task_root/Tools/CameraSmoke/main.swift" \
  ${vendor_native_objects[@]+"${vendor_native_objects[@]}"} ${vendor_link_args[@]+"${vendor_link_args[@]}"} \
  -L "$CARGO_TARGET_DIR/release" -lauto_switcher \
  -framework Security -framework CoreFoundation -framework SystemConfiguration -lz -liconv -lc++ \
  -o "$smoke_root/camera-smoke" >> "$compile_log" 2>&1 || { cat "$compile_log"; exit 1; }
if ! codesign --force --sign "${SIGNING_IDENTITY:--}" --identifier org.ultracam.app "$smoke_root/camera-smoke" >> "$compile_log" 2>&1; then
  cat "$compile_log" >&2
  exit 1
fi
if ! codesign --verify --strict "$smoke_root/camera-smoke" >> "$compile_log" 2>&1; then
  cat "$compile_log" >&2
  exit 1
fi
echo "Synthetic camera helper built: $smoke_root/camera-smoke"
if [[ -n "${1:-}" ]]; then
  run_log="$smoke_root/run.log"
  arguments=(--run)
  if [[ "$1" == --full ]]; then arguments+=(--full); fi
  if [[ "$1" == --monitor ]]; then arguments+=(--monitor); fi
  if [[ "$1" == --monitor-full ]]; then arguments+=(--monitor --full); fi
  if [[ "$1" == --consumer ]]; then arguments=(--consumer 20); fi
  if [[ "$1" == --registry-check ]]; then arguments=(--registry-check); fi
  if [[ "$1" == --monitor-gpu-check ]]; then arguments=(--monitor-gpu-check); fi
  if [[ "$1" == --monitor-gpu-check-full ]]; then arguments=(--monitor-gpu-check --full); fi
  if [[ $# -eq 3 ]]; then arguments+=(--segment-seconds "$3"); fi
  "$smoke_root/camera-smoke" "${arguments[@]}" > "$run_log" 2>&1 || { cat "$run_log"; exit 1; }
  cat "$run_log"
fi
