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
rust_manifest="$task_root/Tools/auto-switcher/Cargo.toml"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$(python3 "$task_root/scripts/work_paths.py" --path build_root)/auto-switcher-target}"
rustc_path="$(rustup which --toolchain stable rustc)"
rustdoc_path="$(rustup which --toolchain stable rustdoc)"
RUSTC="$rustc_path" RUSTDOC="$rustdoc_path" rustup run stable cargo build \
  --manifest-path "$rust_manifest" --release --locked
export AUTO_SWITCHER_LIB_DIR="$CARGO_TARGET_DIR/release"
python3 "$task_root/scripts/generate_project.py"
args=(-project "$task_root/Ultracam.xcodeproj" -scheme 'Ultracam' -configuration "$configuration" -derivedDataPath "$build_root" -jobs 4 ARCHS=arm64)
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
xcodebuild "${args[@]}" build > "$build_log" 2>&1 || {
  /usr/bin/grep -E 'error:|warning:|BUILD FAILED' "$build_log" || true
  exit 1
}
product="$build_root/Build/Products/$configuration/Ultracam.app"
validation_args=("$product")
if [[ "$signed" == true ]]; then validation_args+=(--signed); fi
if [[ "$official_release" == true ]]; then validation_args+=(--official-release); fi
if [[ -n "$release_evidence" ]]; then validation_args+=(--release-evidence "$release_evidence"); fi
python3 "$task_root/scripts/validate_bundle.py" "${validation_args[@]}"
stable_product="$artifact_root/Ultracam.app"
dsym="$build_root/Build/Products/$configuration/Ultracam.app.dSYM"
stable_dsym="$artifact_root/Ultracam.app.dSYM"
# Both checks before either link moves, so a refusal leaves the install link as it was.
if [[ -e "$stable_product" && ! -L "$stable_product" ]]; then
  echo "Refusing to replace existing non-symlink bundle: $stable_product" >&2
  exit 1
fi
if [[ -e "$stable_dsym" && ! -L "$stable_dsym" ]]; then
  echo "Refusing to replace existing non-symlink dSYM: $stable_dsym" >&2
  exit 1
fi
ln -sfn "$product" "$stable_product"
# Release keeps its symbols only in the dSYM beside the stripped product: link it
# beside the stable product, and keep a copy per build (the newest 20, found by
# UUID), so a crash report of an earlier build still symbolicates after its run
# directory is pruned. Best effort: the product is linked, so a failure only warns.
if [[ ! -d "$dsym" ]]; then
  # A Debug product carries its symbols; never leave another build's dSYM beside it.
  rm -f "$stable_dsym"
else
  ln -sfn "$dsym" "$stable_dsym"
  /bin/bash "$task_root/scripts/archive-dsym.sh" "$dsym" "$artifact_root/symbols" "$run_id" 20 ||
    echo "warning: the dSYM was not archived under $artifact_root/symbols" >&2
fi
if [[ "$local_development" == true ]]; then
  python3 "$task_root/scripts/prepare_local_build.py" "$product" \
    "$artifact_root/local-development/Ultracam.app"
else
  echo "Built: $stable_product"
fi
