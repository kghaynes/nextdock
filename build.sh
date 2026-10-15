#!/bin/zsh
# Builds NeXTDock.app. Needs Xcode or the Command Line Tools (xcode-select --install).
#
#   ./build.sh            Build for this Mac into ./build, signed with "NeXTDock Local Signing"
#                         if that identity exists (see README), otherwise ad-hoc.
#
# Settings used by release.sh (environment variables):
#   OUT=dir               Output folder (default: build)
#   UNIVERSAL=1           Build for both Apple Silicon and Intel
#   SIGN_ID="..."         Signing identity to use
#   HARDENED=1            Hardened runtime + secure timestamp (required for notarization)
#
# Compiles and signs in a temp folder because iCloud Drive keeps adding file tags that codesign rejects.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(tr -d '[:space:]' < VERSION)
BUILD_NUM=$(git rev-list --count HEAD 2>/dev/null || echo 1)
OUT="${OUT:-build}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/NeXTDock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SWIFT_FLAGS=(-O -swift-version 5 -framework AppKit -framework ServiceManagement)
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  for arch in arm64 x86_64; do
    swiftc "${SWIFT_FLAGS[@]}" -target "$arch-apple-macos13.0" -o "$TMP/NeXTDock-$arch" main.swift
  done
  lipo -create -output "$APP/Contents/MacOS/NeXTDock" "$TMP/NeXTDock-arm64" "$TMP/NeXTDock-x86_64"
else
  swiftc "${SWIFT_FLAGS[@]}" -target "$(uname -m)-apple-macos13.0" -o "$APP/Contents/MacOS/NeXTDock" main.swift
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.NeXTDock</string>
  <key>CFBundleName</key><string>NeXTDock</string>
  <key>CFBundleDisplayName</key><string>NeXTDock</string>
  <key>CFBundleExecutable</key><string>NeXTDock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUM</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Kenneth Haynes and CyberCloudAI.tech. MIT License.</string>
</dict>
</plist>
PLIST

xattr -cr "$APP"

SIGN="${SIGN_ID:-}"
if [[ -z "$SIGN" ]]; then
  # Stable local identity so macOS remembers permissions (Accessibility) across rebuilds; falls back to ad-hoc.
  SIGN="-"
  security find-identity -p codesigning | grep -q "NeXTDock Local Signing" && SIGN="NeXTDock Local Signing"
fi
OPTS=()
[[ "${HARDENED:-0}" == 1 ]] && OPTS=(--options runtime --timestamp)
codesign --force "${OPTS[@]}" --sign "$SIGN" "$APP"

rm -rf "$OUT/NeXTDock.app"
mkdir -p "$OUT"
ditto "$APP" "$OUT/NeXTDock.app"
codesign --verify --strict "$OUT/NeXTDock.app"
echo "Built $PWD/$OUT/NeXTDock.app  (v$VERSION build $BUILD_NUM, $(lipo -archs "$OUT/NeXTDock.app/Contents/MacOS/NeXTDock"), signed: $SIGN)"
