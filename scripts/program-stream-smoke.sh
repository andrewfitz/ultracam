#!/bin/bash
# Decode stream output at an independent loopback receiver. Use the directory
# holding the Swift and libaom products from the app build.
set -euo pipefail
if [[ $# -lt 1 ]]; then
  echo 'Usage: program-stream-smoke.sh PRODUCT_DIRECTORY [--only SCENARIO ...] [--certificate PEM --private-key PEM --certificate-host HOST]' >&2
  exit 2
fi
products="$1"
shift
repo="$(cd "$(dirname "$0")/.." && pwd)"
root="$(python3 "$repo/scripts/work_paths.py" --path build_root)"
mkdir -p "$root/program-stream-smoke"
run="$(mktemp -d "$root/program-stream-smoke/run.XXXXXXXX")"
fixture="$repo/Tools/ProgramStreamSmoke"
source "$repo/scripts/program-stream-link.sh"
program_stream_link_args "$products"
sources=("$repo/Sources/Shared/VideoOutputOptions.swift" "$repo/Sources/Shared/ProcessedFrame.swift" "$repo/Sources/App/ProgramStreamAV1.swift"
         "$repo/Sources/App/ProgramStreamPublisher.swift" "$repo/Sources/App/ProgramStreamMedia.swift"
         "$repo/Sources/App/ProgramStreamSession.swift" "$fixture/FixturePublisher.swift" "$fixture/main.swift")
shasum -a 256 "${sources[@]}" "$fixture/inspect_media.py" "$fixture/run_receiver.py" > "$run/source-sha256"
for link_argument in "${stream_link_args[@]}"; do
  if [[ -f "$link_argument" ]]; then
    shasum -a 256 "$link_argument"
  fi
done > "$run/linked-products-sha256"
xcrun swiftc -parse-as-library -O -whole-module-optimization -num-threads 2 -target arm64-apple-macos26.0 -swift-version 5 \
  -strict-concurrency=complete -warnings-as-errors -DULTRACAM_STREAM_PUBLISHING -DULTRACAM_STREAM_SMOKE "${stream_link_args[@]}" \
  "${sources[@]}" \
  -o "$run/program-stream-smoke"
echo "Program stream receiver artifacts: $run"
PYTHONDONTWRITEBYTECODE=1 python3 "$fixture/run_receiver.py" "$run/program-stream-smoke" "$run" "$@"
