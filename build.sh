#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
if [[ $# -ne 1 ]]; then
    printf 'Usage: %s OUTPUT_DIRECTORY\n' "$0" >&2
    exit 2
fi

mkdir -p -- "$1"
output_dir="$(cd -- "$1" && pwd)"
app="$output_dir/MIDI Codex.app"
if [[ -e "$app" || -L "$app" ]]; then
    printf 'Output already exists: %s\n' "$app" >&2
    exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/midi-codex-build.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
bundle="$work_dir/MIDI Codex.app"
source_dir=Sources/MIDICodex
mkdir -p "$bundle/Contents/"{MacOS,Resources}
swift build --package-path PadLights --scratch-path "$work_dir/swiftpm" -c release
install -m 755 "$work_dir/swiftpm/release/padlights" "$bundle/Contents/Resources/padlights"
swiftc -O -module-cache-path "$work_dir/modules" \
    "$source_dir/main.swift" "$source_dir/DesktopPadLights.swift" "$source_dir/Quota.swift" \
    -o "$bundle/Contents/MacOS/MIDICodex"
install -m 644 "$source_dir/Info.plist" "$bundle/Contents/Info.plist"
install -m 644 "$source_dir/Resources/"{AppIcon.icns,DockIcon.png} "$bundle/Contents/Resources/"
codesign --force --sign - "$bundle/Contents/Resources/padlights"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
mv -n -- "$bundle" "$app"
test ! -e "$bundle"
printf '%s\n' "$app"
