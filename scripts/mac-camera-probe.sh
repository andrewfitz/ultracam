#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ultracam-mac-camera-probe.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -whole-module-optimization -swift-version 5 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
  "$root/Tools/MacCameraProbe/main.swift" "$root/Sources/Shared/VirtualCameraRegistry.swift" \
  "$root/Vendors/MacCamera/Sources/MacCameraModes.swift" \
  "$root/Sources/DeviceAPI/"{PluginError,VendorDescriptor,VendorSetting}.swift \
  "$root/Sources/Shared/VirtualCameraRegistryTransport.swift" \
  "$root/Sources/Shared/"{VideoContract,VideoOutputOptions,VideoBufferLayout,SourceFormat,ColorimetryContract}.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$root/Tools/MacCameraProbe/Info.plist" \
  -o "$work/mac-camera-probe"
"$work/mac-camera-probe" "$@"
