#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d /tmp/ultracam-program-cadence-cpu.XXXXXX)"
frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -Onone -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
  -I "$libraries" -L "$libraries" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$libraries" \
  "$repo_root/Tests/ProgramCadenceCPU/Boundaries.swift" \
  "$repo_root/Sources/Shared/VideoContract.swift" "$repo_root/Sources/Shared/SourceFormat.swift" \
  "$repo_root/Sources/Shared/ColorimetryContract.swift" "$repo_root/Sources/Shared/ProcessedFrame.swift" \
  "$repo_root/Sources/Shared/VideoBufferLayout.swift" "$repo_root/Sources/Shared/DerivedOutputAdmission.swift" "$repo_root/Sources/Shared/ProgramOutputRoute.swift" \
  "$repo_root/Sources/Shared/ProgramTimestampMapper.swift" "$repo_root/Sources/Shared/SwitcherCoordinator.swift" \
  "$repo_root/Sources/Shared/NaturalTalkingHeadAutoSwitcher.swift" \
  "$repo_root/Sources/Shared/MediaRetention.swift" "$repo_root/Sources/Shared/GPUAllocationBudget.swift" \
  "$repo_root/Sources/Program/ProgramColourDescription.swift" "${ULTRACAM_CADENCE_BRIDGE_SOURCE:-$repo_root/Sources/App/ProgramOutputBridge.swift}" \
  "$repo_root/Tests/ProcessedFrameChecks.swift" "$repo_root/Tests/ProgramCadenceCPUChecks.swift" "$repo_root/Tests/ProgramStageRetentionChecks.swift" \
  "$repo_root/Tests/ProgramCadenceCPU/main.swift" -o "$test_root/checks"
"$test_root/checks"
