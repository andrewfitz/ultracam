#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build --release --locked --bin auto-switcher
bundle="build/Auto Switcher.app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources"
cp "${CARGO_TARGET_DIR:-target}/release/auto-switcher" "$bundle/MacOS/"
swiftc -parse-as-library -O macos/Menu.swift -o "$bundle/MacOS/AutoSwitcher"
cp -R profiles models adapters "$bundle/Resources/"
cp LICENSE NOTICE "$bundle/Resources/"
cp macos/Info.plist "$bundle/"
codesign --force --sign - "$bundle/MacOS/auto-switcher"
codesign --force --sign - "build/Auto Switcher.app"
