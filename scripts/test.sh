#!/bin/bash
set -euo pipefail
compile_only=false
if [[ ${1:-} == --app-compile-only ]]; then compile_only=true; shift; fi
if [[ $# -ne 0 ]]; then
  echo 'Usage: test.sh [--app-compile-only]' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root="$(python3 "$task_root/scripts/work_paths.py" --path work_root)"
export TMPDIR="$external_root/tmp"
# Match the deployment target used by the Xcode test binary and production app.
export MACOSX_DEPLOYMENT_TARGET="26.0"
artifact_root="$external_root/agent-work/ultracam"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
test_root="$external_root/agent-work/build/ultracam/tests/$run_id"
logs_root="$artifact_root/logs"
mkdir -p "$TMPDIR" "$test_root/modules" "$artifact_root" "$logs_root"
if [[ "$compile_only" == false ]]; then
python3 -m unittest discover -s "$task_root/Tests/BuildContracts" -v
python3 -m unittest discover -s "$task_root/Tests/DiagnosticContracts" -v
python3 -m unittest discover -s "$task_root/Tests/VendorSDK" -v
python3 -m unittest discover -s "$task_root/Tests/BundleContracts" -v
python3 -m unittest discover -s "$task_root/Tests/BoundaryContracts" -v
python3 -m unittest discover -s "$task_root/Tests/CIContracts" -v
python3 -m unittest discover -s "$task_root/Tests/CPUPixelContracts" -v
python3 "$task_root/scripts/check-vendor-boundaries.py"
python3 "$task_root/scripts/check-cpu-pixel-access.py"
python3 "$task_root/scripts/test-discovery-log-picker.py"
python3 "$task_root/scripts/test-settings-intent.py"
python3 "$task_root/scripts/test-source-ownership.py"
python3 "$task_root/scripts/test-app-source-integration.py"
python3 "$task_root/scripts/test-camera-standby-timing.py"
fi
package_log="$logs_root/monitor-package-$run_id.log"
source "$task_root/scripts/monitor-kit-package.sh"
monitor_kit_selftest_log="$logs_root/monitor-kit-selftest-$run_id.log"
/bin/bash "$task_root/scripts/monitor-kit-package.sh" selftest > "$monitor_kit_selftest_log" 2>&1 || {
  cat "$monitor_kit_selftest_log"; exit 1;
}
monitor_kit_package_build > "$package_log" 2>&1 || { cat "$package_log"; exit 1; }
monitor_kit_test_log="$logs_root/monitor-kit-package-tests-$run_id.log"
if [[ "$compile_only" == false ]]; then
  monitor_kit_package_test "$monitor_kit_test_log" || { monitor_kit_test_report "$monitor_kit_test_log"; exit 1; }
fi
python3 "$task_root/scripts/test-source-declarations.py"
rust_manifest="$task_root/Tools/auto-switcher/Cargo.toml"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$(python3 "$task_root/scripts/work_paths.py" --path build_root)/auto-switcher-target}"
rustc_path="$(rustup which --toolchain stable rustc)"
rustdoc_path="$(rustup which --toolchain stable rustdoc)"
RUSTC="$rustc_path" RUSTDOC="$rustdoc_path" rustup run stable cargo build \
  --manifest-path "$rust_manifest" --release --locked
if [[ "$compile_only" == false ]]; then
  RUSTC="$rustc_path" RUSTDOC="$rustdoc_path" rustup run stable cargo test \
    --manifest-path "$rust_manifest" --release --locked
fi
auto_switcher_lib="$CARGO_TARGET_DIR/release"
export ULTRACAM_SHADER="$task_root/Sources/App/LUTShaders.metal"
frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
compile_log="$logs_root/test-compile-$run_id.log"
test_log="$logs_root/tests-$run_id.log"
ln -sfn "logs/$(basename "$compile_log")" "$artifact_root/test-compile.log"
ln -sfn "logs/$(basename "$test_log")" "$artifact_root/tests.log"
source "$task_root/scripts/vendor-build.sh"
vendor_configure test
vendor_compile_native "$compile_log"
app_sources=()
for source_file in "$task_root"/Sources/App/*.swift; do
  if [[ "$source_file" != */UltracamApp.swift ]]; then app_sources+=("$source_file"); fi
done
shared_sources=()
for source_file in "$task_root"/Sources/Shared/*.swift; do
  if [[ "$source_file" != */ExtensionFormatCatalog.swift ]]; then shared_sources+=("$source_file"); fi
done
xcrun swiftc -O -swift-version 5 -strict-concurrency=complete -warnings-as-errors -D ULTRACAM_TEST_SUPPORT -target arm64-apple-macos26.0 -module-cache-path "$test_root/modules" \
  "${monitor_kit_link_args[@]}" \
  -D CAPTURE_LIFECYCLE_TESTS ${vendor_swift_native_args[@]+"${vendor_swift_native_args[@]}"} \
  -import-objc-header "$vendor_bridge" \
  -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
  -I "$libraries" -L "$libraries" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$libraries" \
  "${shared_sources[@]}" "$task_root/Sources/Shared/ExtensionFormatCatalog.swift" "$task_root"/Sources/DeviceAPI/*.swift ${vendor_swift_sources[@]+"${vendor_swift_sources[@]}"} \
  "$task_root"/Sources/Program/*.swift \
  "$task_root"/Sources/Recording/*.swift \
  "${app_sources[@]}" \
  "$task_root/Sources/CameraExtension/OutputFormatCatalog.swift" \
  "$task_root/Sources/CameraExtension/CameraProvider.swift" \
  "$task_root"/Sources/CameraProvider/*.swift \
  "$task_root"/Tests/*.swift "$task_root"/Tests/Recording/*.swift "$task_root"/Tests/CameraProvider/*.swift \
  "$task_root/Tests/MonitorKitHost/MonitorFeedHostChecks.swift" \
  ${vendor_native_objects[@]+"${vendor_native_objects[@]}"} ${vendor_link_args[@]+"${vendor_link_args[@]}"} -L "$auto_switcher_lib" -lauto_switcher \
  -framework Security -framework CoreFoundation -framework SystemConfiguration -lz -liconv -lc++ \
  -o "$test_root/lut-tests" >> "$compile_log" 2>&1 || {
  cat "$compile_log"
  exit 1
}
if [[ "$compile_only" == true ]]; then
  echo "App compile passed: $test_root/lut-tests (compile log: $compile_log)"
  exit 0
fi
"$test_root/lut-tests" > "$test_log" 2>&1 || {
  cat "$test_log"
  exit 1
}
python3 "$task_root/scripts/check-test-coverage.py" "$test_log"
# Verify every registered suite, including additions outside the historical contract list.
python3 - "$task_root" "$test_log" <<'PY_COVERAGE'
import importlib.util
import os
import re
import subprocess
import sys
from pathlib import Path
root, log = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("coverage", root / "scripts/check-test-coverage.py")
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)
registered = re.findall(r"forTestCaseClass: (\w+)\.self", (root / "Tests/main.swift").read_text())
if len(registered) != len(set(registered)):
    raise SystemExit("Duplicate XCTest suite registration")
sources = list((root / "Tests").glob("*.swift"))
sources += list((root / "Tests/Recording").glob("*.swift"))
sources += list((root / "Tests/CameraProvider").glob("*.swift"))
sources += [root / "Tests/MonitorKitHost/MonitorFeedHostChecks.swift"]
vendor_sources = subprocess.check_output(
    [sys.executable, str(root / "scripts/vendors.py"), "query", "--root", str(root),
     "--membership", "test", "--kind", "swift-sources"], text=True)
sources += [Path(path) for path in vendor_sources.splitlines() if path]
sources = list(dict.fromkeys(sources))
# This file runs separately with SOURCE_DECLARATION_CHECKS, before the app compile.
sources = [p for p in sources if p.name != "SourceDeclarationChecks.swift"]
expected = {}
for path in sources:
    source = path.read_text()
    for name in re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", source):
        if name not in registered:
            raise SystemExit(f"{path}: unregistered XCTest suite {name}")
        expected[name] = len(coverage.class_test_methods(source, name))
# Count each extension body separately, including several in the same file.
for path in sources:
    source = path.read_text()
    literals = r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/'
    source = re.sub(literals, lambda match: "\n" * match.group().count("\n"), source)
    for declaration in re.finditer(r"\bextension\s+(\w+)\s*\{", source):
        name = declaration.group(1)
        if name not in expected:
            continue
        depth, index = 1, declaration.end()
        while depth and index < len(source):
            depth += (source[index] == "{") - (source[index] == "}")
            index += 1
        body = source[declaration.end():index-1]
        expected[name] += len(re.findall(r"^\s*(?:@\w+(?:\([^\n]*\))?\s+)*func\s+(test\w+)\s*\(", body, re.MULTILINE))
coverage.verify_coverage(log.read_text(), expected)
print("All app suite discovery: " + ", ".join(f"{name}={count}" for name, count in expected.items()))
skipped = re.findall(r"Test Case '([^']+)' skipped[^\n]*", log.read_text())
if skipped:
    print(f"App runtime: {len(skipped)} skipped; coverage is incomplete:")
    for identity in skipped:
        print("  " + identity)
    if os.environ.get("ULTRACAM_REQUIRE_GPU_PROOFS") == "1":
        raise SystemExit("Required GPU proof lane refuses skipped app tests")
else:
    print("App runtime: no skipped tests")
PY_COVERAGE
python3 "$task_root/scripts/check-gpu-proof-skips.py" --app "$test_log"
python3 "$task_root/scripts/check-gpu-proof-skips.py" --package "$monitor_kit_test_log"
python3 "$task_root/scripts/vendors.py" run-tests
# MonitorKit's XCTest bundles, one "Executed" summary each after the run. A
# skipped case is a successful platform-qualified outcome, but it is not
# coverage; keep it visible instead of claiming that every case ran.
monitor_kit_tests="$(awk "/Test Suite 'All tests' (passed|failed)/ { getline; print }" "$monitor_kit_test_log" \
  | awk '{ tests += $2 } END { print tests + 0 }')"
monitor_kit_skipped="$(monitor_kit_skipped_cases "$monitor_kit_test_log" | awk 'NF { count++ } END { print count + 0 }')"
if [[ "$monitor_kit_skipped" -gt 0 ]]; then
  echo "MonitorKit package: $monitor_kit_tests tests completed, $monitor_kit_skipped skipped (platform-qualified; coverage is incomplete) ($monitor_kit_test_log)"
else
  echo "MonitorKit package: $monitor_kit_tests tests completed, none skipped ($monitor_kit_test_log)"
fi
# Timing budgets that passed only on their retry: report them, they are not silent.
if /usr/bin/grep -q '^FLAKY (passed on retry)' "$monitor_kit_test_log"; then
  echo 'WARNING: MonitorKit timing budgets missed on the first run, passed on retry:'
  /usr/bin/grep '^FLAKY (passed on retry)' "$monitor_kit_test_log"
fi
tail -5 "$test_log"
