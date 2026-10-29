#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
check_root="$(python3 "$task_root/scripts/work_paths.py" --path build_root)/sony-control-checks"
mkdir -p "$check_root"
source "$task_root/scripts/vendor-build.sh"
vendor_configure test sony control
vendor_compile_native "$check_root/control-compile.log"
xcrun swiftc -parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos26.0 ${vendor_swift_native_args[@]+"${vendor_swift_native_args[@]}"} -import-objc-header "$vendor_bridge" \
  ${vendor_swift_sources[@]+"${vendor_swift_sources[@]}"} ${vendor_native_objects[@]+"${vendor_native_objects[@]}"} ${vendor_link_args[@]+"${vendor_link_args[@]}"} -lc++ -o "$check_root/store-checks"
"$check_root/store-checks" "$check_root/png"
if python3 "$task_root/scripts/vendors.py" status --sdk-present sony >/dev/null 2>&1; then
  vendor_configure test sony native
  vendor_compile_native "$check_root/native-compile.log"
  xcrun clang++ ${vendor_native_objects[@]+"${vendor_native_objects[@]}"} ${vendor_link_args[@]+"${vendor_link_args[@]}"} \
    -Wl,-rpath,"${vendor_library_dirs[0]}" -o "$check_root/native-checks"
  "$check_root/native-checks"
else
  echo 'Sony native checks skipped: SDK inventory is unavailable.'
fi
