#!/bin/zsh
# Builds NeXTDock.app into ./build. Needs Xcode or the Command Line Tools (xcode-select --install).
# Compiles and signs in a temp folder because iCloud Drive keeps adding file tags that codesign rejects.
set -euo pipefail
cd "$(dirname "$0")"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/NeXTDock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework ServiceManagement \
  -o "$APP/Contents/MacOS/NeXTDock" main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.NeXTDock</string>
  <key>CFBundleName</key><string>NeXTDock</string>
  <key>CFBundleExecutable</key><string>NeXTDock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

xattr -cr "$APP"
# Stable local identity so macOS remembers permissions (Accessibility) across rebuilds; falls back to ad-hoc.
SIGN="-"
security find-identity -p codesigning | grep -q "NeXTDock Local Signing" && SIGN="NeXTDock Local Signing"
codesign --force --sign "$SIGN" "$APP"

rm -rf build
mkdir -p build
ditto "$APP" build/NeXTDock.app
codesign --verify build/NeXTDock.app && echo "Built $PWD/build/NeXTDock.app (signature OK)"
