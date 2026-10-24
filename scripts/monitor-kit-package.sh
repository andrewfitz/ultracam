#!/bin/bash
# Source this helper after setting task_root; set a run-specific external test_root
# before calling its functions.
# Compile the MonitorKit package; consumers link a per-run copy of its real products and
# use Bundle.module. Every name is monitor_kit_*, so it leaves a sourcing script's own
# names alone.
# Run directly, `monitor-kit-package.sh selftest` checks the test-log analysis and the
# retry policy against fixture logs and a stub xcrun.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then task_root="$(cd "$(dirname "$0")/.." && pwd)"; fi
monitor_kit_package="$task_root/Packages/MonitorKit"
if [[ ! -f "$monitor_kit_package/Package.swift" ]]; then
  echo "Packages/MonitorKit/Package.swift is missing: MonitorKit is a git submodule; run git submodule update --init" >&2
  exit 1
fi
# The release products build incrementally in one shared scratch. Each run copies them out
# while it still holds the cache lock, so it compiles and links against exactly what it
# built, whatever another run rebuilds afterwards.
monitor_kit_cache_root="${MONITOR_KIT_PACKAGE_CACHE:-/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam/monitor-kit-package-cache}"
mkdir -p "$monitor_kit_cache_root/modules"
monitor_kit_scratch="$monitor_kit_cache_root/scratch"
monitor_kit_build_lock="$monitor_kit_cache_root/build.lock"
# The module caches are set per command, not exported, so sourcing this leaves the
# caller's environment untouched.
monitor_kit_env=(env CLANG_MODULE_CACHE_PATH="$monitor_kit_cache_root/modules" SWIFTPM_MODULECACHE_OVERRIDE="$monitor_kit_cache_root/modules")
monitor_kit_products=(MonitorKitCore MonitorKit MonitorKitScopes MonitorKitAudio MonitorKitUI)
# One XCTest bundle per test target; a complete run finishes every one of them.
monitor_kit_test_bundles="$(cd "$monitor_kit_package/Tests" 2>/dev/null && ls -d */ | tr -d / | tr '\n' ' ')"
# The only failures a run may retry: CPU and GPU timing budgets that a loaded machine can
# miss. Correctness, race and order checks fail on their first failure, so a retry needs
# both the case and every assertion it failed to be allowed. The list holds pairs: a regex
# for Module.Class/test, then one that each of that case's failure messages (the text after
# "error: -[Module.Class test] : ") must match whole. A benchmark's pixel, pipeline, fusion
# and command-buffer checks are XCTAssertEqual, True or Nil, so they never match; only a
# numeric less-than is a budget (a GreaterThan is a throughput or sanity floor).
monitor_kit_budget='XCTAssertLessThan(OrEqual)? failed: \("[-+0-9.einfa]+"\) is (not less than|greater than) \("[-+0-9.einfa]+"\)'
monitor_kit_retry_allowlist=(
  'MonitorKitTests\.Benchmarks/.*' "$monitor_kit_budget( - .*)?"
  'MonitorKitTests\.Metal4Benchmarks/.*' "$monitor_kit_budget( - .*)?"
  # The GPU-time budget only; its pixel-identity and pipeline checks are never retried.
  'MonitorKitTests\.ContractTests/testLibraryMatchesAHostsInlineShaderInPixelsAndGPUTime'
  "$monitor_kit_budget - [^ ]+: the library costs more than inline code"
  'MonitorKitScopesTests\.ScopeBenchmarkTests/.*' "$monitor_kit_budget( - .*)?"
  'MonitorKitScopesTests\.ScopeMetal4Benchmarks/.*' "$monitor_kit_budget( - .*)?"
  'MonitorKitScopesTests\.ScopeContractTests/testEncodeCPUCost' "$monitor_kit_budget"
  'MonitorKitUITests\.GPUBenchmarks/.*' "$monitor_kit_budget( - .*)?"
  'MonitorKitUITests\.TickBenchmarks/.*' "$monitor_kit_budget( - .*)?"
  # The submit latency budgets only; its deadlock, latest-frame and throughput checks and
  # its retired-frame bound (a less-than with no message) are never retried.
  'MonitorKitUITests\.HandoffTests/testHandoffUnderStressNeverBlocksEitherSide'
  "$monitor_kit_budget - (a submit waited|submits waited)"
  'MonitorKitAudioTests\.RealtimeTests/testBenchmarkSixteenChannels' "$monitor_kit_budget - .*"
)

# Runs under the cache lock (see monitor_kit_package_build): build every product, check
# each one, and clone the products directory into the empty directory $1.
monitor_kit_build_snapshot() {
  local snapshot="$1" bin product
  "${monitor_kit_env[@]}" xcrun swift build --package-path "$monitor_kit_package" --scratch-path "$monitor_kit_scratch" \
    --cache-path "$test_root/package-cache" --configuration release --arch arm64 || return $?
  bin="$("${monitor_kit_env[@]}" xcrun swift build --package-path "$monitor_kit_package" --scratch-path "$monitor_kit_scratch" \
    --cache-path "$test_root/package-cache" --configuration release --arch arm64 --show-bin-path)" || return $?
  for product in "${monitor_kit_products[@]}"; do
    [[ -f "$bin/lib$product.a" && -d "$bin/$product.swiftmodule" ]] || { echo "MonitorKit product $product missing from $bin." >&2; return 1; }
  done
  [[ -d "$snapshot" && -z "$(ls -A "$snapshot")" ]] || { echo "$snapshot is not an empty directory." >&2; return 1; }
  # Clones on APFS, so the copy costs no space or time.
  cp -cR "$bin/." "$snapshot/" 2> /dev/null || cp -R "$bin/." "$snapshot/" || return $?
}
monitor_kit_package_build() {
  local snapshot
  # Some gates (ui-typecheck) reuse one root across runs, so every run takes a directory
  # of its own and clears the ones no gate can still be using.
  find "$test_root" -maxdepth 1 -type d -name 'monitor-kit-products.*' -mmin +180 -exec rm -rf {} + 2> /dev/null || true
  snapshot="$(mktemp -d "$test_root/monitor-kit-products.XXXXXX")" || return $?
  /usr/bin/lockf -k "$monitor_kit_build_lock" /bin/bash "$task_root/scripts/monitor-kit-package.sh" snapshot "$test_root" "$snapshot" || return $?
  monitor_kit_bin="$snapshot"
  # MonitorKitUI also uses MonitorKitAudio, so Audio links after UI.
  monitor_kit_link_args=(-I "$monitor_kit_bin" -L "$monitor_kit_bin" \
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

# Prints, one per line, why a swift test log does not account for every test: a SwiftPM or
# runtime error, a crash, a case that started and never finished, or an expected bundle
# that never finished. Prints nothing for a complete log. $2 overrides the bundle list.
monitor_kit_log_problems() {
  LC_ALL=C awk -v bundles="${2:-$monitor_kit_test_bundles}" '
    /^Test Case .-\[[^ ]+ [^]]+\]. started/ { started++ }
    /^Test Case .-\[[^ ]+ [^]]+\]. (passed|failed|skipped)/ { ended++ }
    /^Test Suite .[^ ]+\.xctest. started/ { suites++ }
    /^Test Suite .[^ ]+\.xctest. (passed|failed)/ {
      name = $3; gsub(/\047|\.xctest/, "", name); finished[name] = 1; done++
    }
    /^error: |Exited with|unexpected signal|Fatal error|fatal error:|Restarting after unexpected exit|^\342\234\230 / {
      if (errors++ < 3) print "error line: " substr($0, 1, 300)
    }
    END {
      if (started != ended) print started - ended " test case(s) started and never finished"
      if (suites != done) print suites - done " test bundle(s) started and never finished"
      n = split(bundles, expected, " ")
      for (i = 1; i <= n; i++) if (!(expected[i] in finished)) print "test bundle " expected[i] " never finished"
    }' "$1"
}
# Prints the failed cases of a log as Module.Class/test, sorted.
monitor_kit_failed_cases() {
  { LC_ALL=C grep -aE "^Test Case '-\[[^ ]+ [^]]+\]' failed" "$1" || true; } \
    | sed -E "s/^Test Case '-\[([^ ]+) ([^]]+)\]'.*/\1\/\2/" | sort -u
}
# Prints the failure messages the case $2 (Module.Class/test) logged in $1, one per line,
# each cut short: a pixel array's message can be hundreds of megabytes.
monitor_kit_case_failures() {
  LC_ALL=C awk -v prefix=": error: -[${2%%/*} ${2#*/}] : " \
    '{ i = index($0, prefix); if (!i) next; m = substr($0, i + length(prefix))
       print (length(m) > 2000 ? substr(m, 1, 2000) " [cut]" : m) }' "$1"
}
# Prints the cases a failed run may retry, one per line. Returns 1, printing why, unless the
# log accounts for every test and every failed case is an allowlisted case that failed only
# its timing budgets.
monitor_kit_retry_plan() {
  local log="$1" problems failed case i rule count other
  problems="$(monitor_kit_log_problems "$log" "${2:-}")"
  [[ -z "$problems" ]] || { printf 'not retried, the run is incomplete: %s\n' "$problems"; return 1; }
  failed="$(monitor_kit_failed_cases "$log")"
  [[ -n "$failed" ]] || { echo 'not retried: the run failed with no failed test case'; return 1; }
  for case in $failed; do
    rule=''
    for ((i = 0; i < ${#monitor_kit_retry_allowlist[@]}; i += 2)); do
      if [[ "$case" =~ ^(${monitor_kit_retry_allowlist[i]})$ ]]; then rule="${monitor_kit_retry_allowlist[i + 1]}"; break; fi
    done
    [[ -n "$rule" ]] || { printf 'not retried, not a timing budget: %s\n' "$case"; return 1; }
    count="$(monitor_kit_case_failures "$log" "$case" | wc -l | tr -d ' ')"
    [[ "$count" -gt 0 ]] || { printf 'not retried, no assertion failure logged: %s\n' "$case"; return 1; }
    other="$(monitor_kit_case_failures "$log" "$case" | { LC_ALL=C grep -vE "^($rule)$" || true; } | head -1 | cut -c1-300)" || true
    [[ -z "$other" ]] || { printf 'not retried, not a timing budget: %s: %s\n' "$case" "$other"; return 1; }
  done
  printf '%s\n' "$failed"
}
# The package's swift test on a scratch of this run's own, logged to $1, so concurrent runs
# neither wait on each other nor run a test binary another run rebuilt. GPU tests skip
# without Metal. A complete run whose only failures are allowlisted timing budgets runs
# those cases once more from the same build; each retried case is logged as FLAKY.
monitor_kit_package_test() {
  local log="$1" retry_log="$1.retry" scratch rc=0 plan problems filter passed
  scratch="$(mktemp -d "$test_root/monitor-kit-test-scratch.XXXXXX")" || return $?
  local test_args=(--package-path "$monitor_kit_package" --scratch-path "$scratch" --cache-path "$test_root/package-cache" --arch arm64)
  "${monitor_kit_env[@]}" xcrun swift test "${test_args[@]}" > "$log" 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    problems="$(monitor_kit_log_problems "$log")"
    [[ -z "$problems" ]] || { printf 'MonitorKit tests exited 0 but the run is incomplete: %s\n' "$problems" >> "$log"; return 1; }
  else
    plan="$(monitor_kit_retry_plan "$log")" || { printf '%s\n' "$plan" >> "$log"; return 1; }
    printf 'FLAKY (retrying once): %s\n' $plan >> "$log"
    filter="^($(printf '%s\n' "$plan" | sed 's/\./\\./g' | paste -sd '|' -))$"
    rc=0
    "${monitor_kit_env[@]}" xcrun swift test "${test_args[@]}" --skip-build --filter "$filter" > "$retry_log" 2>&1 || rc=$?
    problems="$(monitor_kit_log_problems "$retry_log")"
    passed="$({ LC_ALL=C grep -acE "^Test Case '-\[[^ ]+ [^]]+\]' passed" "$retry_log" || true; })"
    if [[ $rc -ne 0 || -n "$problems" || -n "$(monitor_kit_failed_cases "$retry_log")" || "$passed" -ne "$(printf '%s\n' "$plan" | wc -l)" ]]; then
      printf 'MonitorKit retry failed (exit %s, %s of the retried cases passed): %s\n' "$rc" "$passed" "$retry_log" >> "$log"
      [[ -z "$problems" ]] || printf '%s\n' "$problems" >> "$log"
      return 1
    fi
    printf 'FLAKY (passed on retry): %s\n' $plan >> "$log"
  fi
  # A passing run's scratch is only rebuild cost; a failing one stays for investigation.
  [[ "$scratch" == "$test_root"/monitor-kit-test-scratch.* && -d "$scratch" ]] && rm -rf "$scratch"
  return 0
}
# The lines of a failed run worth reading: failed cases, assertion and tool errors, the
# retry decision and the log's last lines, each cut short. Assertion messages on pixel
# arrays can make the full log hundreds of megabytes.
monitor_kit_test_report() {
  local log="$1"
  echo "MonitorKit package tests failed. Log: $log"
  [[ ! -f "$log.retry" ]] || echo "Retry log: $log.retry"
  { LC_ALL=C grep -aE "^Test Case '.*' failed|: error: |^error: |Exited with|unexpected signal|Fatal error|^not retried|^FLAKY|^MonitorKit |^error line: |never finished" "$log" || true; } \
    | cut -c1-400 | head -80
  echo '--- last lines ---'
  tail -20 "$log" | cut -c1-400
}

# Fixture checks for the analysis and retry policy above. xcrun is a stub, so this needs
# neither a GPU nor a build.
monitor_kit_selftest() {
  local dir failures=0 rc plan
  dir="$(mktemp -d "${TMPDIR:-/tmp}/monitor-kit-selftest.XXXXXX")"
  test_root="$dir"
  monitor_kit_test_bundles="MonitorKitTests MonitorKitAudioTests"
  # failure "Module.Class test" KIND prints the assertion failures a failed case logs, in
  # XCTest's own wording (budget, the default, is one missed timing budget).
  failure() {
    local at="/x/File.swift:9: error: -[$1] : " over='XCTAssertLessThanOrEqual failed: ("0.42") is greater than ("0.35")' n
    case "$2" in
      budget) echo "$at$over - 1080p every tool" ;;
      three) for n in 1 2 3; do echo "$at$over - Metal 4 encode $n"; done ;;
      bare) echo "${at}XCTAssertLessThan failed: (\"12.5\") is not less than (\"10\")" ;;
      inline) echo "$at$over - 1920×1080: the library costs more than inline code" ;;
      pixels) echo "${at}XCTAssertEqual failed: (\"[SIMD4<Float>(0.29, 0.0, 0.98, 1.0)]\") is not equal to (\"[SIMD4<Float>(0.28, 0.0, 0.95, 1.0)]\") - 1920×1080: identical pixels" ;;
      # A message longer than is read whole whose tail would pass for the budget's.
      hugepixels) printf '%sXCTAssertEqual failed: ("[%s]") is not equal to ("[0]") - 1920×1080: the library costs more than inline code\n' \
        "$at" "$(head -c 3000000 /dev/zero | tr '\0' '1')" ;;
      mixed) failure "$1" inline; failure "$1" pixels ;;
      waited) echo "${at}XCTAssertLessThan failed: (\"30.424875\") is not less than (\"20.0\") - a submit waited" ;;
      leak) echo "${at}XCTAssertLessThanOrEqual failed: (\"9\") is greater than (\"8\")" ;;
      deadlock) echo "${at}XCTAssertEqual failed: (\"timedOut\") is not equal to (\"success\") - a producer is stuck: a deadlock" ;;
      floor) echo "${at}XCTAssertGreaterThan failed: (\"812\") is not greater than (\"10000\")" ;;
      thrown) echo "<unknown>:0: error: -[$1] : failed: caught error: \"device lost\"" ;;
      none) ;;
    esac
  }
  # bundle NAME passed|failed|crash CASE... where CASE is Class/test/passed|failed|skipped|started
  # and Class/test/failed:KIND names the failure (see failure).
  bundle() {
    local name="$1" end="$2" spec cls t res kind
    shift 2
    echo "Test Suite 'All tests' started at 2026-10-22 11:08:46.931."
    echo "Test Suite '$name.xctest' started at 2026-10-22 11:08:46.932."
    for spec in "$@"; do
      IFS=/ read -r cls t res <<< "$spec"
      echo "Test Case '-[$name.$cls $t]' started."
      if [[ "$res" == failed* ]]; then
        kind="${res#failed}"; kind="${kind#:}"
        failure "$name.$cls $t" "${kind:-budget}"
        res=failed
      fi
      [[ "$res" == started ]] || echo "Test Case '-[$name.$cls $t]' $res (0.010 seconds)."
    done
    if [[ "$end" == crash ]]; then
      echo 'error: Exited with unexpected signal code 11'
      return
    fi
    echo "Test Suite '$name.xctest' $end at 2026-10-22 11:08:50.000."
    echo "	 Executed $# tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds"
    echo "Test Suite 'All tests' $end at 2026-10-22 11:08:50.000."
    echo "	 Executed $# tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds"
  }
  expect() {
    if [[ "$1" == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 (got '$1', expected '$2')"; failures=$((failures + 1)); fi
  }
  # The stub replays $dir/first.log and $dir/retry.log with their exit codes and counts calls.
  mkdir -p "$dir/bin"
  cat > "$dir/bin/xcrun" << 'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")/.." && pwd)"
echo x >> "$dir/calls"
case " $* " in
  *" --skip-build "*) cat "$dir/retry.log"; exit "$(cat "$dir/retry.rc")" ;;
  *) cat "$dir/first.log"; exit "$(cat "$dir/first.rc")" ;;
esac
STUB
  chmod +x "$dir/bin/xcrun"
  scenario() {  # name first_rc retry_rc expected_rc expected_calls; first.log and retry.log already written
    local name="$1" got
    echo "$2" > "$dir/first.rc"; echo "$3" > "$dir/retry.rc"; : > "$dir/calls"
    rm -f "$dir/run.log" "$dir/run.log.retry"
    got=0
    PATH="$dir/bin:$PATH" monitor_kit_package_test "$dir/run.log" || got=$?
    expect "$got" "$4" "$name: result"
    expect "$(wc -l < "$dir/calls" | tr -d ' ')" "$5" "$name: swift test runs"
  }
  local bench=Benchmarks/testPicturePassGPUTime
  # Clean run.
  { bundle MonitorKitTests passed "$bench/passed" ContractTests/testA/passed
    bundle MonitorKitAudioTests passed RealtimeTests/testX/skipped; } > "$dir/first.log"
  expect "$(monitor_kit_log_problems "$dir/first.log")" "" "complete log has no problems"
  scenario 'clean run' 0 0 0 1
  # A timing budget failed; the retry passes.
  { bundle MonitorKitTests failed "$bench/failed" ContractTests/testA/passed
    bundle MonitorKitAudioTests passed RealtimeTests/testX/passed; } > "$dir/first.log"
  { bundle MonitorKitTests passed "$bench/passed"; bundle MonitorKitAudioTests passed; } > "$dir/retry.log"
  plan="$(monitor_kit_retry_plan "$dir/first.log")"; rc=$?
  expect "$rc:$plan" "0:MonitorKitTests.Benchmarks/testPicturePassGPUTime" 'allowlisted timing failure is retried'
  scenario 'timing flake passes on retry' 1 0 0 2
  expect "$(grep -c '^FLAKY (passed on retry): MonitorKitTests.Benchmarks/testPicturePassGPUTime$' "$dir/run.log")" 1 'flake is logged'
  # The same, but the retry fails again.
  { bundle MonitorKitTests failed "$bench/failed"; bundle MonitorKitAudioTests passed; } > "$dir/retry.log"
  scenario 'timing failure that repeats' 1 1 1 2
  # The retry exits 0 but never ran the case (a filter that matched nothing).
  { bundle MonitorKitTests passed; bundle MonitorKitAudioTests passed; } > "$dir/retry.log"
  scenario 'retry that runs nothing' 1 0 1 2
  # A timing failure plus a crash later in the bundle: never retried (the audited hole).
  { bundle MonitorKitTests crash "$bench/failed" ContractTests/testA/started
    bundle MonitorKitAudioTests passed RealtimeTests/testX/passed; } > "$dir/first.log"
  { bundle MonitorKitTests passed "$bench/passed"; bundle MonitorKitAudioTests passed; } > "$dir/retry.log"
  monitor_kit_retry_plan "$dir/first.log" > /dev/null; expect "$?" 1 'crash blocks the retry'
  scenario 'timing failure beside a crash' 1 0 1 1
  # A crash that printed no signal line still leaves a case and a bundle unfinished.
  { bundle MonitorKitTests failed "$bench/failed" | grep -v "^Test Suite 'MonitorKitTests.xctest' failed"
    bundle MonitorKitAudioTests passed RealtimeTests/testX/started; } > "$dir/first.log"
  expect "$(monitor_kit_log_problems "$dir/first.log" | wc -l | tr -d ' ')" 3 'unfinished case and bundles are reported'
  scenario 'timing failure beside an unfinished case' 1 0 1 1
  # A bundle that never ran at all.
  bundle MonitorKitTests failed "$bench/failed" > "$dir/first.log"
  scenario 'timing failure with a bundle missing' 1 0 1 1
  # A race check fails: no retry, even though it would pass alone.
  { bundle MonitorKitTests failed "$bench/failed"
    bundle MonitorKitAudioTests failed RealtimeTests/testResetNeverReappearsWhileProcessRuns/failed; } > "$dir/first.log"
  { bundle MonitorKitTests passed "$bench/passed"
    bundle MonitorKitAudioTests passed RealtimeTests/testResetNeverReappearsWhileProcessRuns/passed; } > "$dir/retry.log"
  scenario 'race check failure' 1 0 1 1
  expect "$(grep -c '^not retried, not a timing budget: MonitorKitAudioTests.RealtimeTests/testResetNeverReappearsWhileProcessRuns$' "$dir/run.log")" 1 'race failure is named'
  # An allowlisted case retries only when every assertion it failed is a timing budget.
  plan_case() {  # plan_case LABEL BUNDLE CASE EXPECTED_RC EXPECTED_FIRST_LINE (cut to 200)
    local out got=0 b
    { bundle "$2" failed "$3"
      for b in MonitorKitTests MonitorKitAudioTests; do [[ "$b" == "$2" ]] || bundle "$b" passed; done; } > "$dir/first.log"
    out="$(monitor_kit_retry_plan "$dir/first.log")" || got=$?
    expect "$got" "$4" "$1: retried?"
    expect "$(printf '%s\n' "$out" | head -1 | cut -c1-200)" "$5" "$1: plan"
  }
  local inline=ContractTests/testLibraryMatchesAHostsInlineShaderInPixelsAndGPUTime
  local handoff=HandoffTests/testHandoffUnderStressNeverBlocksEitherSide
  local equal='XCTAssertEqual failed: ("[SIMD4<Float>(0.29, 0.0, 0.98, 1.0)]") is not equal to ("[SIMD4<Float>(0.28, 0.0, 0.95, 1.0)]") - 1920×1080: identical pixels'
  local refused='not retried, not a timing budget'
  plan_case 'three missed budgets in one case' MonitorKitTests Metal4Benchmarks/testMetal4CPUEncodeCost/failed:three 0 \
    MonitorKitTests.Metal4Benchmarks/testMetal4CPUEncodeCost
  plan_case 'a budget without a message' MonitorKitTests "$bench/failed:bare" 0 "MonitorKitTests.$bench"
  plan_case 'a pixel check in a benchmark class' MonitorKitTests "$bench/failed:pixels" 1 \
    "$(printf '%s: %s: %s' "$refused" "MonitorKitTests.$bench" "$equal" | cut -c1-200)"
  plan_case 'a budget beside a pixel check' MonitorKitTests "$bench/failed:mixed" 1 \
    "$(printf '%s: %s: %s' "$refused" "MonitorKitTests.$bench" "$equal" | cut -c1-200)"
  plan_case 'a thrown error in a benchmark' MonitorKitTests "$bench/failed:thrown" 1 \
    "$refused: MonitorKitTests.$bench: failed: caught error: \"device lost\""
  plan_case 'a failed case with no assertion line' MonitorKitTests "$bench/failed:none" 1 \
    "not retried, no assertion failure logged: MonitorKitTests.$bench"
  plan_case 'the inline-shader GPU-time budget' MonitorKitTests "$inline/failed:inline" 0 "MonitorKitTests.$inline"
  plan_case 'the inline-shader pixel identity' MonitorKitTests "$inline/failed:pixels" 1 \
    "$(printf '%s: %s: %s' "$refused" "MonitorKitTests.$inline" "$equal" | cut -c1-200)"
  plan_case 'the inline-shader budget beside its pixel identity' MonitorKitTests "$inline/failed:mixed" 1 \
    "$(printf '%s: %s: %s' "$refused" "MonitorKitTests.$inline" "$equal" | cut -c1-200)"
  plan_case 'the inline-shader case with another budget label' MonitorKitTests "$inline/failed:budget" 1 \
    "$(printf '%s: %s: %s' "$refused" "MonitorKitTests.$inline" 'XCTAssertLessThanOrEqual failed: ("0.42") is greater than ("0.35") - 1080p every tool' | cut -c1-200)"
  plan_case 'a pixel message too long to read whole' MonitorKitTests "$inline/failed:hugepixels" 1 \
    "$(printf '%s: %s: XCTAssertEqual failed: ("[%s' "$refused" "MonitorKitTests.$inline" "$(head -c 300 /dev/zero | tr '\0' '1')" | cut -c1-200)"
  plan_case 'the handoff submit budget' MonitorKitUITests "$handoff/failed:waited" 0 "MonitorKitUITests.$handoff"
  plan_case 'the handoff retired-frame bound' MonitorKitUITests "$handoff/failed:leak" 1 \
    "$refused: MonitorKitUITests.$handoff: XCTAssertLessThanOrEqual failed: (\"9\") is greater than (\"8\")"
  plan_case 'the handoff deadlock check' MonitorKitUITests "$handoff/failed:deadlock" 1 \
    "$(printf '%s: %s: %s' "$refused" "MonitorKitUITests.$handoff" 'XCTAssertEqual failed: ("timedOut") is not equal to ("success") - a producer is stuck: a deadlock' | cut -c1-200)"
  plan_case 'the handoff throughput floor' MonitorKitUITests "$handoff/failed:floor" 1 \
    "$(printf '%s: %s: %s' "$refused" "MonitorKitUITests.$handoff" 'XCTAssertGreaterThan failed: ("812") is not greater than ("10000")' | cut -c1-200)"
  # End to end: the pixel identity fails once and would pass alone; it is never retried.
  { bundle MonitorKitTests failed "$inline/failed:pixels"; bundle MonitorKitAudioTests passed; } > "$dir/first.log"
  { bundle MonitorKitTests passed "$inline/passed"; bundle MonitorKitAudioTests passed; } > "$dir/retry.log"
  scenario 'pixel identity failure' 1 0 1 1
  expect "$(grep -c "^$refused: MonitorKitTests.$inline: XCTAssertEqual" "$dir/run.log")" 1 'pixel failure is named'
  # Its GPU-time budget alone is retried.
  { bundle MonitorKitTests failed "$inline/failed:inline"; bundle MonitorKitAudioTests passed; } > "$dir/first.log"
  scenario 'inline-shader budget flake' 1 0 0 2
  # A non-zero exit with every case passing (a build or tool failure).
  { bundle MonitorKitTests passed "$bench/passed"; bundle MonitorKitAudioTests passed; } > "$dir/first.log"
  scenario 'exit without a failed case' 1 0 1 1
  # Exit 0 but a bundle is missing.
  bundle MonitorKitTests passed "$bench/passed" > "$dir/first.log"
  scenario 'exit 0 with a bundle missing' 0 0 1 1
  # The failure report stays short however long the assertion messages are.
  { bundle MonitorKitTests failed "$bench/failed"; bundle MonitorKitAudioTests passed
    head -c 2000000 /dev/zero | tr '\0' 'x'; echo; } > "$dir/big.log"
  expect "$(( $(monitor_kit_test_report "$dir/big.log" | wc -c) < 20000 ))" 1 'failure report is short'
  rm -rf "$dir"
  [[ $failures -eq 0 ]] || { echo "monitor-kit-package selftest: $failures failure(s)." >&2; return 1; }
  echo 'monitor-kit-package selftest: all passed.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    snapshot) [[ $# -eq 3 ]] || { echo 'Usage: monitor-kit-package.sh snapshot TEST_ROOT SNAPSHOT' >&2; exit 2; }
      test_root="$2"; monitor_kit_build_snapshot "$3" ;;
    selftest) monitor_kit_selftest ;;
    *) echo 'Usage: monitor-kit-package.sh selftest | snapshot TEST_ROOT SNAPSHOT' >&2; exit 2 ;;
  esac
fi
