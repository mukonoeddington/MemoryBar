#!/bin/bash
# Builds MemoryBar.app next to this script (universal: Apple Silicon + Intel).
# Requires Xcode Command Line Tools:  xcode-select --install
#
#   ./build.sh            build MemoryBar.app
#   ./build.sh --zip      also create MemoryBar.zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

APP="MemoryBar.app"
VERSION="1.0.0"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "Compiling for arm64…"
swiftc -O -target arm64-apple-macos13.0 main.swift -o "$BUILD_DIR/MemoryBar-arm64"
echo "Compiling for x86_64…"
swiftc -O -target x86_64-apple-macos13.0 main.swift -o "$BUILD_DIR/MemoryBar-x86_64"
lipo -create "$BUILD_DIR/MemoryBar-arm64" "$BUILD_DIR/MemoryBar-x86_64" -output "$APP/Contents/MacOS/MemoryBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MemoryBar</string>
    <key>CFBundleDisplayName</key><string>MemoryBar</string>
    <key>CFBundleIdentifier</key><string>io.github.mukonoeddington.memorybar</string>
    <key>CFBundleExecutable</key><string>MemoryBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# Ad-hoc signature (not notarized): fine for running locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/MemoryBar"))"

if [[ "${1:-}" == "--zip" ]]; then
    rm -f MemoryBar.zip
    ditto -c -k --keepParent "$APP" MemoryBar.zip
    echo "Created MemoryBar.zip"
fi

echo "Run it:      open $APP"
echo "Install it:  mv $APP /Applications/ && open /Applications/$APP"
