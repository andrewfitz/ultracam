#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
cargo build --release --locked --bin auto-switcher
bundle="build/Auto Switcher.app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources"
cp "${CARGO_TARGET_DIR:-target}/release/auto-switcher" "$bundle/MacOS/"
swiftc -parse-as-library -O macos/Menu.swift -o "$bundle/MacOS/AutoSwitcher"
for resource in profiles models adapters; do
  rsync -a --delete --delete-excluded --exclude __pycache__ "$resource/" "$bundle/Resources/$resource/"
done
cp LICENSE NOTICE "$bundle/Resources/"
cp macos/Info.plist "$bundle/"
codesign --force --sign - "$bundle/MacOS/auto-switcher"
codesign --force --sign - "build/Auto Switcher.app"
