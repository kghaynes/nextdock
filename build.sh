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

INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1   # ./build.sh --install  -> also copy to /Applications and relaunch

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

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>tech.cybercloudai.NeXTDock</string>
  <key>CFBundleName</key><string>NeXTDock</string>
  <key>CFBundleDisplayName</key><string>NeXTDock</string>
  <key>CFBundleExecutable</key><string>NeXTDock</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
  # Prefer a stable, trusted identity so macOS keeps the Accessibility permission across rebuilds:
  # Developer ID first, then the self-signed "NeXTDock Local Signing" identity, then ad-hoc.
  SIGN="-"
  DEV_ID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
  if [[ -n "$DEV_ID" ]]; then
    SIGN="$DEV_ID"
  elif security find-identity -p codesigning | grep -q "NeXTDock Local Signing"; then
    SIGN="NeXTDock Local Signing"
  fi
fi
OPTS=()
[[ "${HARDENED:-0}" == 1 ]] && OPTS=(--options runtime --timestamp)
codesign --force "${OPTS[@]}" --sign "$SIGN" "$APP"

# Verify in the temp folder; iCloud Drive may tag the copy in ./build afterwards, which is harmless.
codesign --verify --strict "$APP"
rm -rf "$OUT/NeXTDock.app"
mkdir -p "$OUT"
ditto "$APP" "$OUT/NeXTDock.app"
echo "Built $PWD/$OUT/NeXTDock.app  (v$VERSION build $BUILD_NUM, $(lipo -archs "$OUT/NeXTDock.app/Contents/MacOS/NeXTDock"), signed: $SIGN)"

if [[ $INSTALL == 1 ]]; then
  # Never replace an app while it's running: macOS can no longer verify the running copy's signature,
  # which breaks permission prompts. Quit first, swap the bundle, relaunch.
  pkill -x NeXTDock 2>/dev/null && sleep 1 || true
  rm -rf /Applications/NeXTDock.app
  ditto "$APP" /Applications/NeXTDock.app   # from the clean temp copy, not the iCloud one
  open /Applications/NeXTDock.app
  echo "Installed and launched /Applications/NeXTDock.app"
fi
