#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
build_root="${TMPDIR:-/tmp}/smk25ii-padlights-build"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/smk25ii-padlights-module-cache"
swift build --disable-sandbox --package-path . --scratch-path "$build_root" -c release
swift test --disable-sandbox --package-path . --scratch-path "$build_root"
mkdir -p bin 'Pad Lights.app/Contents/Resources' 'Pad Lights.app/Contents/MacOS'
cp Info.plist 'Pad Lights.app/Contents/Info.plist'
cp "$build_root/release/padlights" bin/padlights
cp bin/padlights 'Pad Lights.app/Contents/Resources/padlights'
swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" LightPanel.swift -o 'Pad Lights.app/Contents/MacOS/PadLightPanel'
xattr -cr 'Pad Lights.app'
codesign --force --sign - 'Pad Lights.app/Contents/Resources/padlights'
codesign --force --sign - 'Pad Lights.app'
codesign --verify --deep --strict 'Pad Lights.app'
