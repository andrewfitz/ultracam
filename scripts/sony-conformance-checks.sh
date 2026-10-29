#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
export MACOSX_DEPLOYMENT_TARGET=26.0
check_root="$(python3 "$task_root/scripts/work_paths.py" --path build_root)/sony-conformance-checks"
mkdir -p "$check_root"
source "$task_root/scripts/vendor-build.sh"
vendor_configure test sony reusable-conformance
vendor_compile_native "$check_root/compile.log"
xcrun swiftc -parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors -D ULTRACAM_TEST_SUPPORT \
  -target arm64-apple-macos26.0 ${vendor_swift_native_args[@]+"${vendor_swift_native_args[@]}"} -import-objc-header "$vendor_bridge" \
  ${vendor_swift_sources[@]+"${vendor_swift_sources[@]}"} ${vendor_native_objects[@]+"${vendor_native_objects[@]}"} ${vendor_link_args[@]+"${vendor_link_args[@]}"} -lc++ -o "$check_root/checks"
"$check_root/checks"
