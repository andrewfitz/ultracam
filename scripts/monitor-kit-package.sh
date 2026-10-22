#!/bin/bash
# Source this helper after setting task_root and a run-specific external test_root.
# Compile the MonitorKit package once; consumers link its real products and use
# Bundle.module. Every name is monitor_kit_* so it can be sourced beside
# monitor-tools-package.sh while both packages are linked.
monitor_kit_package="$task_root/Packages/MonitorKit"
# A shared scratch and module cache keep package builds incremental across runs;
# SwiftPM locks its scratch directory, so concurrent runs wait rather than collide.
monitor_kit_cache_root="${MONITOR_KIT_PACKAGE_CACHE:-/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam/monitor-kit-package-cache}"
mkdir -p "$monitor_kit_cache_root/modules"
monitor_kit_scratch="$monitor_kit_cache_root/scratch"
# The package's own tests build with testable imports; a separate scratch keeps
# them from invalidating the linked products.
monitor_kit_test_scratch="$monitor_kit_cache_root/test-scratch"
# The module caches are set per command, not exported, so sourcing this beside
# monitor-tools-package.sh leaves that package's environment untouched.
monitor_kit_env=(env CLANG_MODULE_CACHE_PATH="$monitor_kit_cache_root/modules" SWIFTPM_MODULECACHE_OVERRIDE="$monitor_kit_cache_root/modules")
# Built dependencies first; linked in the reverse order (UI also uses Audio).
monitor_kit_products=(MonitorKitCore MonitorKit MonitorKitScopes MonitorKitAudio MonitorKitUI)
monitor_kit_package_build() {
  local product
  for product in "${monitor_kit_products[@]}"; do
    "${monitor_kit_env[@]}" xcrun swift build --package-path "$monitor_kit_package" --scratch-path "$monitor_kit_scratch" --cache-path "$test_root/package-cache" \
      --configuration release --arch arm64 --product "$product" || return $?
  done
  monitor_kit_bin="$("${monitor_kit_env[@]}" xcrun swift build --package-path "$monitor_kit_package" --scratch-path "$monitor_kit_scratch" --cache-path "$test_root/package-cache" \
    --configuration release --arch arm64 --show-bin-path)" || return $?
  monitor_kit_link_args=(-I "$monitor_kit_bin" -I "$monitor_kit_bin/Modules" -L "$monitor_kit_bin" \
    -lMonitorKitUI -lMonitorKitScopes -lMonitorKit -lMonitorKitAudio -lMonitorKitCore \
    -framework SwiftUI -framework Metal -framework QuartzCore -framework CoreVideo -framework IOSurface \
    -framework Accelerate)
  local bundle shader
  for bundle in MonitorKit_MonitorKit.bundle MonitorKit_MonitorKitScopes.bundle; do
    [[ -d "$monitor_kit_bin/$bundle" ]] || { echo "$bundle resource bundle missing from MonitorKit products." >&2; return 1; }
    cp -R "$monitor_kit_bin/$bundle" "$test_root/" || return $?
  done
  for shader in MonitorKit_MonitorKit.bundle:MKLUT.msl MonitorKit_MonitorKit.bundle:MKDecode.msl \
    MonitorKit_MonitorKit.bundle:MKMonitor.msl MonitorKit_MonitorKitScopes.bundle:MKScopes.msl; do
    [[ -n "$(find "$test_root/${shader%%:*}" -path "*/Shaders/${shader#*:}" -type f -print -quit)" ]] || {
      echo "MonitorKit shader Shaders/${shader#*:} missing from ${shader%%:*}." >&2; return 1;
    }
  done
}
# The package's swift test, on its own scratch, logged to $1. GPU tests skip without Metal.
# The package has CPU-timing benchmarks and stress tests that a loaded machine can
# push over budget, so failed cases run once more on their own; a case that fails
# again fails the run. Every retried case is listed as FLAKY in the log.
monitor_kit_package_test() {
  local log="$1" retry_log="$1.retry" failed filter
  local test_args=(--package-path "$monitor_kit_package" --scratch-path "$monitor_kit_test_scratch" --cache-path "$test_root/package-cache" --arch arm64)
  "${monitor_kit_env[@]}" xcrun swift test "${test_args[@]}" > "$log" 2>&1 && return 0
  failed="$(/usr/bin/grep -E "^Test Case '-\[[^ ]+ [^]]+\]' failed" "$log" | sed -E "s/^Test Case '-\[([^ ]+) ([^]]+)\]'.*/\1\/\2/" | sort -u)"
  # A build failure or crash leaves no failed case to retry.
  [[ -n "$failed" ]] || return 1
  filter="^($(printf '%s\n' "$failed" | paste -sd '|' -))$"
  printf 'FLAKY (retrying once): %s\n' $failed >> "$log"
  "${monitor_kit_env[@]}" xcrun swift test "${test_args[@]}" --skip-build --filter "$filter" > "$retry_log" 2>&1 || {
    cat "$retry_log" >> "$log"; return 1;
  }
  [[ "$(/usr/bin/grep -cE "^Test Case '-\[[^ ]+ [^]]+\]' passed" "$retry_log")" -eq "$(printf '%s\n' "$failed" | wc -l)" ]] || {
    cat "$retry_log" >> "$log"; echo 'MonitorKit retry did not rerun every failed case.' >> "$log"; return 1;
  }
  printf 'FLAKY (passed on retry): %s\n' $failed >> "$log"
}
