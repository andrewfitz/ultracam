#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
auto_switcher_source="$(python3 "$repo_root/scripts/auto_switcher_source.py")"
test_root="$(mktemp -d /tmp/ultracam-program-cadence-cpu.XXXXXX)"
frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$(python3 "$repo_root/scripts/work_paths.py" --path build_root)/auto-switcher-target}"
cargo build --locked --release --lib --manifest-path "$auto_switcher_source/Cargo.toml"
xcrun swiftc -import-objc-header "$auto_switcher_source/include/auto_switcher.h" -L "$CARGO_TARGET_DIR/release" -lauto_switcher -Onone -D CAPTURE_LIFECYCLE_TESTS -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
  -I "$libraries" -L "$libraries" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$libraries" \
  "$repo_root/Tests/ProgramCadenceCPU/Boundaries.swift" \
  "$repo_root/Sources/Shared/VideoContract.swift" "$repo_root/Sources/Shared/VideoOutputOptions.swift" "$repo_root/Sources/Shared/SourceFormat.swift" \
  "$repo_root/Sources/Shared/ColorimetryContract.swift" "$repo_root/Sources/Shared/ProcessedFrame.swift" \
  "$repo_root/Sources/Shared/VideoBufferLayout.swift" "$repo_root/Sources/Shared/DerivedOutputAdmission.swift" "$repo_root/Sources/Shared/ProgramOutputRoute.swift" \
  "$repo_root/Sources/Shared/ProgramTimestampMapper.swift" "$repo_root/Sources/Shared/SwitcherCoordinator.swift" \
  "$repo_root/Sources/Shared/MediaRetention.swift" "$repo_root/Sources/Shared/GPUAllocationBudget.swift" \
  "$repo_root/Sources/Program/ProgramStreamVideo.swift" "$repo_root/Sources/Program/ProgramColourDescription.swift" "${ULTRACAM_CADENCE_BRIDGE_SOURCE:-$repo_root/Sources/App/ProgramOutputBridge.swift}" \
  "$repo_root/Tests/ProcessedFrameChecks.swift" "$repo_root/Tests/ProgramCadenceCPUChecks.swift" "$repo_root/Tests/ProgramStageRetentionChecks.swift" \
  "$repo_root/Tests/ProgramCadenceCPU/main.swift" -o "$test_root/checks"
"$test_root/checks"
