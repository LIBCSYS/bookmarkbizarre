#!/bin/sh
# Rebuild the app icon set from design/AppIcon.svg. Run from anywhere.
# xcrun swiftc, not `swift`: a swiftly/other toolchain on PATH may not match
# the macOS SDK; Xcode's compiler always does.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
mkdir -p "$root/build/icon-tool"
xcrun swiftc -O "$here/render_icon.swift" -o "$root/build/icon-tool/render_icon"
"$root/build/icon-tool/render_icon" "$here/AppIcon.svg" "$root/BookmarkBizarre/Assets.xcassets/AppIcon.appiconset"
