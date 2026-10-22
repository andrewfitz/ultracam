#!/bin/bash
# Fast typecheck of every app source with the release build's strict settings
# (complete concurrency checking, warnings as errors). Reuses one incremental
# MonitorTools and MonitorKit package build so repeated checks take seconds.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root=/Volumes/8TB/cinesomatic-director-work
if ! mount | /usr/bin/grep -F ' on /Volumes/8TB ' >/dev/null; then
  echo 'External drive /Volumes/8TB is not mounted.' >&2
  exit 1
fi
test_root="$external_root/agent-work/build/ultracam/ui-typecheck"
mkdir -p "$test_root/modules" "$test_root/tmp"
export TMPDIR="$test_root/tmp"
export MACOSX_DEPLOYMENT_TARGET=26.0
source "$task_root/scripts/monitor-tools-package.sh"
source "$task_root/scripts/monitor-kit-package.sh"
monitor_package_build > "$test_root/package-build.log" 2>&1 || { cat "$test_root/package-build.log"; exit 1; }
monitor_kit_package_build >> "$test_root/package-build.log" 2>&1 || { cat "$test_root/package-build.log"; exit 1; }
sdk_dir="${DECKLINK_SDK_DIR:-$task_root/ThirdParty/DeckLinkSDK/include}"
[[ -d "$sdk_dir" ]] || bash "$task_root/scripts/fetch-decklink-sdk.sh" >/dev/null
xcrun swiftc -typecheck -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos26.0 -module-cache-path "$test_root/modules" "${monitor_link_args[@]}" "${monitor_kit_link_args[@]}" \
  -Xcc -DULTRACAM_BACKEND_TESTING -Xcc -I"$sdk_dir" \
  -import-objc-header "$task_root/Sources/DeckLinkBackend/BridgingHeader.h" \
  "$task_root"/Sources/Shared/*.swift "$task_root"/Sources/Recording/*.swift "$task_root"/Sources/App/*.swift
echo "ui-typecheck: OK"
