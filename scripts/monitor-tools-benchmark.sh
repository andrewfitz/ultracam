#!/bin/bash
# Synthetic GPU monitor benchmark (picture and scope GPU time, CPU encode,
# steady-state allocations); never opens devices or installed apps.
set -euo pipefail
harness_root="$(cd "$(dirname "$0")/.." && pwd)"
source_root="${MONITOR_BENCHMARK_SOURCE_ROOT:-$harness_root}"
build_root="${MONITOR_BENCHMARK_BUILD_ROOT:-/Volumes/8TB/cinesomatic-build/ultracam-monitor-upgrade-20261021/microbenchmark}"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
test_root="$build_root/$run_id"
package="$source_root/Packages/MonitorTools"
export TMPDIR=/Volumes/8TB/cinesomatic-director-work/tmp
export MACOSX_DEPLOYMENT_TARGET=26.0
export CLANG_MODULE_CACHE_PATH="$test_root/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$test_root/modules"
mkdir -p "$TMPDIR" "$test_root/modules"
shasum -a 256 "$harness_root/Tools/MonitorToolsBenchmark/main.swift" "$harness_root/scripts/monitor-tools-benchmark.sh" > "$test_root/harness-sha256.txt"
python3 "$source_root/scripts/monitor-tools-fingerprint.py" capture "$test_root/source-manifest.json"
resource_api=0
defines=(-swift-version 5)
scratch="$test_root/monitor-package"
if [[ -n "${MONITOR_BENCHMARK_REUSE_HELPER_DIR:-}" ]]; then
  # Reuse is valid only when this complete source fingerprint still matches.
  python3 "$source_root/scripts/monitor-tools-fingerprint.py" verify "$MONITOR_BENCHMARK_REUSE_HELPER_DIR/source-manifest.json"
  scratch="$MONITOR_BENCHMARK_REUSE_HELPER_DIR/monitor-package"
else
  for product in MonitorToolsCore MonitorToolsMetal; do
    xcrun swift build --package-path "$package" --scratch-path "$scratch" --cache-path "$test_root/package-cache" \
      --configuration release --arch arm64 --product "$product" -Xswiftc -strict-concurrency=complete \
      >> "$test_root/compile.log" 2>&1 || { cat "$test_root/compile.log"; exit 1; }
  done
fi
package_bin="$(xcrun swift build --package-path "$package" --scratch-path "$scratch" --cache-path "$test_root/package-cache" \
  --configuration release --arch arm64 --show-bin-path)"
[[ -f "$package_bin/libMonitorToolsCore.a" && -f "$package_bin/libMonitorToolsMetal.a" ]] || {
  echo 'Expected compiled package archives missing.' >&2; exit 1;
}
found_resource=false
shopt -s nullglob
for bundle in "$package_bin"/*.bundle; do
  cp -R "$bundle" "$test_root/"
  if [[ "$bundle" == *MonitorToolsMetal.bundle ]]; then found_resource=true; fi
done
shopt -u nullglob
[[ "$found_resource" == true ]] || { echo 'MonitorToolsMetal bundle missing.' >&2; exit 1; }
xcrun swiftc -O -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
  -module-cache-path "$test_root/modules" "${defines[@]}" -I "$package_bin" -I "$package_bin/Modules" -L "$package_bin" \
  -lMonitorToolsMetal -lMonitorToolsCore -framework Metal -framework CoreVideo -framework CoreMedia \
  "$harness_root/Tools/MonitorToolsBenchmark/main.swift" -o "$test_root/monitor-benchmark" \
  >> "$test_root/compile.log" 2>&1 || { cat "$test_root/compile.log"; exit 1; }
python3 "$source_root/scripts/monitor-tools-fingerprint.py" verify "$test_root/source-manifest.json"
shasum -a 256 -c "$test_root/harness-sha256.txt"
python3 - "$test_root" "$source_root" "$harness_root" "$package_bin" "$resource_api" <<'PY'
import datetime,hashlib,json,pathlib,sys
root,source,harness,package=map(pathlib.Path,sys.argv[1:5]);api=sys.argv[5]=='1'
paths=[root/'monitor-benchmark',root/'source-manifest.json',harness/'Tools/MonitorToolsBenchmark/main.swift',harness/'scripts/monitor-tools-benchmark.sh',package/'libMonitorToolsCore.a',package/'libMonitorToolsMetal.a']
paths.extend(p for bundle in root.glob('*.bundle') for p in bundle.rglob('*') if p.is_file())
receipt={'built_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source_root':str(source),'harness_root':str(harness),'package_bin':str(package),'resource_statistics_define':api,'files':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}}
(root/'build-receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
PY
echo "Built isolated benchmark: $test_root"
if [[ "${MONITOR_BUILD_ONLY:-0}" == 1 ]]; then exit 0; fi
python3 - "$test_root" <<'PY'
import datetime,hashlib,json,os,pathlib,subprocess,sys,time
root=pathlib.Path(sys.argv[1]);build=json.loads((root/'build-receipt.json').read_text())
for name,expected in build['files'].items():
 if hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest()!=expected:raise SystemExit('Benchmark input changed: '+name)
env=os.environ.copy();env.update(MONITOR_SOURCE_MANIFEST_SHA256=hashlib.sha256((root/'source-manifest.json').read_bytes()).hexdigest(),MONITOR_BINARY_SHA256=hashlib.sha256((root/'monitor-benchmark').read_bytes()).hexdigest(),MONITOR_BENCHMARK_HARNESS_SHA256=hashlib.sha256((pathlib.Path(build['harness_root'])/'Tools/MonitorToolsBenchmark/main.swift').read_bytes()).hexdigest())
started=time.monotonic();command=[str(root/'monitor-benchmark'),str(root/'results')]
(root/'declaration.json').write_text(json.dumps({'command':command,'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'watchdog_seconds':180,'synthetic_only':True},indent=2)+'\n')
timed_out=False
with (root/'run.log').open('w') as log:
 child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,env=env)
 try:code=child.wait(timeout=180)
 except subprocess.TimeoutExpired:timed_out=True;child.kill();code=child.wait()
verification=subprocess.run([sys.executable,str(pathlib.Path(build['source_root'])/'scripts/monitor-tools-fingerprint.py'),'verify',str(root/'source-manifest.json')])
result={'exit_code':code,'watchdog_expired':timed_out,'wall_seconds':time.monotonic()-started,'completed_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source_manifest_verified_after_run':verification.returncode==0}
(root/'execution.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
for name,expected in build['files'].items():
 if hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest()!=expected:raise SystemExit('Benchmark input changed during run: '+name)
print((root/'run.log').read_text(),end='');print(json.dumps(result));sys.exit(code or verification.returncode)
PY
python3 "$source_root/scripts/monitor-tools-fingerprint.py" verify "$test_root/source-manifest.json"
