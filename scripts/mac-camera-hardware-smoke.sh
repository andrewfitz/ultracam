#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 5 ]]; then
  echo 'Usage: mac-camera-hardware-smoke.sh --audio-inputs | --formats INPUT_UID | --capture INPUT_UID FORMAT_ID FPS [MICROPHONE_UID] | INPUT_UID [CAPTURE_FORMAT_INDEX [MICROPHONE_UID]]' >&2
  exit 2
fi
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="$(python3 "$task_root/scripts/work_paths.py" --path tmp_root)"
mkdir -p "$work_root"
check_root="$(mktemp -d "$work_root/mac-camera-hardware-smoke.XXXXXX")"
trap 'rm -rf "$check_root"' EXIT
source "$task_root/scripts/vendor-build.sh"
vendor_configure app maccamera

xcrun swiftc -whole-module-optimization -swift-version 5 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
  -module-cache-path "$check_root/modules" \
  "$task_root/Tools/MacCameraHardwareSmoke/main.swift" \
  "$task_root/Sources/DeviceAPI/"{CPUMemoryPlaneLayout,CapturedCPUMemoryFrame,CaptureAudioPacket,CaptureDelivery,CaptureSourcePlugin,DeviceAPI,DeviceDiagnostics,DeviceObservation,DeviceStatus,DriverStatus,PluginError,VendorDescriptor,VendorSetting,VendorSettingsPolicy}.swift \
  "$task_root/Sources/Shared/"{ColorimetryContract,NDIPlanarLayout,NoCopyIngestLease,SourceAdmission,SourceFormat,SourceSize,VideoBufferLayout,VideoContract,VideoOutputOptions,VirtualCameraRegistry,VirtualCameraRegistryTransport}.swift \
  "${vendor_swift_sources[@]}" "${vendor_link_args[@]}" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$task_root/Tools/MacCameraProbe/Info.plist" \
  -o "$check_root/mac-camera-hardware-smoke"
"$check_root/mac-camera-hardware-smoke" "$@"
