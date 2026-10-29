#!/bin/bash
# Fast typecheck of every app source with the release build's strict settings
# (complete concurrency checking, warnings as errors). Reuses one incremental
# MonitorKit package build so repeated checks take seconds.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root="$(python3 "$task_root/scripts/work_paths.py" --path work_root)"
test_root="$external_root/agent-work/build/ultracam/ui-typecheck"
mkdir -p "$test_root/modules" "$test_root/tmp"
export TMPDIR="$test_root/tmp"
export MACOSX_DEPLOYMENT_TARGET=26.0
source "$task_root/scripts/monitor-kit-package.sh"
monitor_kit_package_build > "$test_root/package-build.log" 2>&1 || { cat "$test_root/package-build.log"; exit 1; }
source "$task_root/scripts/vendor-build.sh"
vendor_configure test "" "" app
xcrun swiftc -typecheck -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos26.0 -module-cache-path "$test_root/modules" "${monitor_kit_link_args[@]}" \
  ${vendor_swift_native_args[@]+"${vendor_swift_native_args[@]}"} \
  -import-objc-header "$vendor_bridge" \
  "$task_root"/Sources/Shared/*.swift "$task_root"/Sources/DeviceAPI/*.swift ${vendor_swift_sources[@]+"${vendor_swift_sources[@]}"} "$task_root"/Sources/Program/*.swift "$task_root"/Sources/Recording/*.swift "$task_root"/Sources/App/*.swift
echo "ui-typecheck: OK"
