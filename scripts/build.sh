#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration=Release
signed=false
local_development=false
provisioning_updates=false
for option in "$@"; do
  case "$option" in
    --debug) configuration=Debug ;;
    --signed) signed=true ;;
    --provisioning-updates) provisioning_updates=true ;;
    --local-development) local_development=true ;;
    *) echo "Unknown build option: $option" >&2; exit 1 ;;
  esac
done
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
external_root=/Volumes/8TB/cinesomatic-director-work
if ! mount | /usr/bin/grep -F ' on /Volumes/8TB ' > /dev/null; then
  echo 'External drive /Volumes/8TB is not mounted.' >&2
  exit 1
fi
export TMPDIR="$external_root/tmp"
# Keep the Rust static library ABI-compatible with the app's deployment target.
# Without this, rustc can stamp the host SDK version (for example macOS 27)
# into dependencies even though Xcode links the application for macOS 26.
export MACOSX_DEPLOYMENT_TARGET="26.0"
artifact_root="$external_root/agent-work/ultracam"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
build_root="$external_root/agent-work/build/ultracam/runs/$run_id"
logs_root="$artifact_root/logs"
mkdir -p "$TMPDIR" "$artifact_root" "$logs_root"
bash "$task_root/scripts/fetch-decklink-sdk.sh"
rust_manifest="$task_root/Tools/auto-switcher/Cargo.toml"
rustc_path="$(rustup which --toolchain stable rustc)"
rustdoc_path="$(rustup which --toolchain stable rustdoc)"
RUSTC="$rustc_path" RUSTDOC="$rustdoc_path" rustup run stable cargo build \
  --manifest-path "$rust_manifest" --release --locked
export AUTO_SWITCHER_LIB_DIR="$task_root/Tools/auto-switcher/target/release"
python3 "$task_root/scripts/generate_project.py"
args=(-project "$task_root/Ultracam.xcodeproj" -scheme 'Ultracam' -configuration "$configuration" -derivedDataPath "$build_root" -jobs 4)
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
python3 "$task_root/scripts/validate_bundle.py" "$product"
stable_product="$artifact_root/Ultracam.app"
if [[ -e "$stable_product" && ! -L "$stable_product" ]]; then
  echo "Refusing to replace existing non-symlink bundle: $stable_product" >&2
  exit 1
fi
ln -sfn "$product" "$stable_product"
if [[ "$local_development" == true ]]; then
  python3 "$task_root/scripts/prepare_local_build.py" "$product" \
    "$artifact_root/local-development/Ultracam.app"
else
  echo "Built: $stable_product"
fi
