#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration=Release
signed=false
local_development=false
provisioning_updates=false
official_release=false
release_evidence="${ULTRACAM_RELEASE_EVIDENCE:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) configuration=Debug; shift ;;
    --signed) signed=true; shift ;;
    --official-release) official_release=true; shift ;;
    --provisioning-updates) provisioning_updates=true; shift ;;
    --local-development) local_development=true; shift ;;
    --sdk-inventory)
      [[ $# -ge 2 ]] || { echo '--sdk-inventory requires a JSON path.' >&2; exit 2; }
      export ULTRACAM_SDK_INVENTORY="$2"; shift 2 ;;
    --release-evidence)
      [[ $# -ge 2 ]] || { echo '--release-evidence requires a JSON path.' >&2; exit 2; }
      release_evidence="$2"; shift 2 ;;
    *) echo "Unknown build option: $1" >&2; exit 1 ;;
  esac
done
if [[ "$official_release" == true && ( "$signed" != true || "$configuration" != Release || "$local_development" == true ) ]]; then
  echo '--official-release requires a signed Release build.' >&2
  exit 1
fi
if [[ "$provisioning_updates" == true && "$signed" != true ]]; then
  echo '--provisioning-updates requires --signed.' >&2
  exit 1
fi
if [[ "$signed" == true && "$local_development" == true ]]; then
  echo 'Choose either --signed or --local-development.' >&2
  exit 1
fi
if [[ "$signed" == true && -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo 'Set DEVELOPMENT_TEAM to your Apple Developer team ID when using --signed.' >&2
  exit 1
fi
# Plan decision 3 requires Sony for signed Release, including local builds.
# Redistribution evidence remains a separate explicit official-release gate.
if [[ "$signed" == true && "$configuration" == Release ]]; then
  python3 - "$task_root" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts'))
from vendors import read_inventory
try:
    _, inventory = read_inventory(Path(sys.argv[1]))
    if not inventory.get('sony', {}).get('available'):
        raise ValueError('Signed Release builds require the Sony SDK enabled in --sdk-inventory or ULTRACAM_SDK_INVENTORY; unsigned Release and signed Debug remain available without it.')
except (ValueError, OSError) as error:
    sys.exit(str(error))
PY
  python3 "$task_root/scripts/vendor-sdk.py" verify sony
fi
external_root="$(python3 "$task_root/scripts/work_paths.py" --path work_root)"
export TMPDIR="$external_root/tmp"
# Keep the Rust static library ABI-compatible with the app's deployment target.
# Without this, rustc can stamp the host SDK version (for example macOS 27)
# into dependencies even though Xcode links the application for macOS 26.
export MACOSX_DEPLOYMENT_TARGET="26.0"
artifact_root="$external_root/agent-work/ultracam"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
build_root="$(python3 "$task_root/scripts/work_paths.py" --derived-data "${ULTRACAM_DERIVED_DATA_PATH:-runs/$run_id}")"
logs_root="$artifact_root/logs"
mkdir -p "$TMPDIR" "$artifact_root" "$logs_root"
python3 "$task_root/scripts/vendor-sdk.py" status
python3 "$task_root/scripts/vendors.py" status
bash "$task_root/scripts/fetch-decklink-sdk.sh"
auto_switcher_source="$(python3 "$task_root/scripts/auto_switcher_source.py")"
rust_manifest="$auto_switcher_source/Cargo.toml"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$(python3 "$task_root/scripts/work_paths.py" --path build_root)/auto-switcher-target}"
# rustup installs to ~/.cargo/bin, which non-login shells may not have on PATH.
command -v rustup >/dev/null || export PATH="$HOME/.cargo/bin:$PATH"
rustc_path="$(rustup which --toolchain stable rustc)"
rustdoc_path="$(rustup which --toolchain stable rustdoc)"
RUSTC="$rustc_path" RUSTDOC="$rustdoc_path" rustup run stable cargo build \
  --manifest-path "$rust_manifest" --release --locked
export AUTO_SWITCHER_LIB_DIR="$CARGO_TARGET_DIR/release"
project="$build_root/Generated/$run_id/Ultracam.xcodeproj"
python3 "$task_root/scripts/generate_project.py" --build-project "$project"
args=(-project "$project" -scheme 'Ultracam' -configuration "$configuration" -derivedDataPath "$build_root"
  -onlyUsePackageVersionsFromResolvedFile -jobs 4 ARCHS=arm64)
if [[ "$signed" == true ]]; then
  args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
  if [[ "$provisioning_updates" == true ]]; then
    args+=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
  fi
else
  args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
fi
if [[ "$local_development" == true ]]; then
  args+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ULTRACAM_LOCAL_DEVELOPMENT')
fi
build_log="$logs_root/build-$run_id.log"
ln -sfn "logs/$(basename "$build_log")" "$artifact_root/build.log"
build_product="$build_root/Build/Products/$configuration/Ultracam.app"
product="$build_product"
if [[ -n "${ULTRACAM_DERIVED_DATA_PATH:-}" ]]; then
  # Keep validation and the published aliases on a private product even when
  # later builds reuse this build's Xcode intermediates and products directory.
  run_root="$(python3 "$task_root/scripts/work_paths.py" --derived-data "runs/$run_id")"
  product="$run_root/Build/Products/$configuration/Ultracam.app"
fi
run_build() {
  if [[ "$product" == "$build_product" ]]; then
    xcodebuild "${args[@]}" build
    return
  fi
  python3 - "$build_root" "$build_product" "$product" "${args[@]}" <<'PY'
import fcntl
import os
from pathlib import Path
import subprocess
import sys

build_root, source, product = map(Path, sys.argv[1:4])
directory = os.open(build_root, os.O_RDONLY)
try:
    fcntl.flock(directory, fcntl.LOCK_EX)
    subprocess.run(['xcodebuild', *sys.argv[4:], 'build'], check=True)
    product.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['/usr/bin/ditto', source, product], check=True)
    symbols = source.with_name(source.name + '.dSYM')
    if symbols.is_dir():
        subprocess.run(['/usr/bin/ditto', symbols, product.with_name(symbols.name)], check=True)
except (OSError, subprocess.CalledProcessError) as error:
    sys.exit(f'error: {error}')
finally:
    os.close(directory)
PY
}
run_build > "$build_log" 2>&1 || {
  /usr/bin/grep -E 'error:|warning:|BUILD FAILED' "$build_log" || true
  exit 1
}
validation_args=("$product")
if [[ "$signed" == true ]]; then validation_args+=(--signed); fi
if [[ "$official_release" == true ]]; then validation_args+=(--official-release); fi
if [[ -n "$release_evidence" ]]; then validation_args+=(--release-evidence "$release_evidence"); fi
python3 "$task_root/scripts/validate_bundle.py" "${validation_args[@]}"
dsym="$product.dSYM"
# Publish each validated app and its matching dSYM under one writer lock.
publish_args=("$product" "$artifact_root")
if [[ "$local_development" == true ]]; then publish_args+=(--local-development); fi
python3 "$task_root/scripts/publish_build.py" "${publish_args[@]}"
# Keep UUID-addressable Release symbols after the build directory is pruned.
if [[ -d "$dsym" ]]; then
  /bin/bash "$task_root/scripts/archive-dsym.sh" "$dsym" "$artifact_root/symbols" "$run_id" 20 ||
    echo "warning: the dSYM was not archived under $artifact_root/symbols" >&2
fi
