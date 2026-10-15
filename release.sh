#!/bin/zsh
# Builds a signed, notarized, drag-to-install DMG in ./dist.
#
#   ./release.sh              build + sign + notarize + staple
#   ./release.sh --publish    ...then create a GitHub Release (tag v<VERSION>) with the DMG attached
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your keychain (Xcode → Settings → Accounts → Manage Certificates).
#   2. Saved notarization credentials (asks for an app-specific password from account.apple.com):
#        xcrun notarytool store-credentials nextdock-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
set -euo pipefail
cd "$(dirname "$0")"

PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1
PROFILE="${NOTARY_PROFILE:-nextdock-notary}"
VERSION=$(tr -d '[:space:]' < VERSION)

ID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
[[ -n "$ID" ]] || { echo "No 'Developer ID Application' certificate found in your keychain."; exit 1; }

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Warning: uncommitted changes. The release will include them."
  [[ $PUBLISH == 1 ]] && { echo "Commit before publishing."; exit 1; }
fi

echo "==> Building universal app, signed with: $ID"
OUT=dist/app UNIVERSAL=1 HARDENED=1 SIGN_ID="$ID" ./build.sh
APP=dist/app/NeXTDock.app

echo "==> Making DMG"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/stage"
ditto "$APP" "$WORK/stage/NeXTDock.app"
ln -s /Applications "$WORK/stage/Applications"
DMG_NAME="NeXTDock-$VERSION.dmg"
hdiutil create -quiet -volname "NeXTDock $VERSION" -srcfolder "$WORK/stage" -ov -format UDZO "$WORK/$DMG_NAME"
codesign --force --timestamp --sign "$ID" "$WORK/$DMG_NAME"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "==> Notarizing (Apple's automated scan, usually 1-5 minutes)"
  xcrun notarytool submit "$WORK/$DMG_NAME" --keychain-profile "$PROFILE" --wait --output-format json > "$WORK/notary.json" || true
  STATUS=$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status",""))' "$WORK/notary.json" 2>/dev/null || true)
  if [[ "$STATUS" != "Accepted" ]]; then
    SUB=$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("id",""))' "$WORK/notary.json" 2>/dev/null || true)
    echo "Notarization failed (status: ${STATUS:-unknown})."
    [[ -n "$SUB" ]] && xcrun notarytool log "$SUB" --keychain-profile "$PROFILE"
    exit 1
  fi
  xcrun stapler staple -q "$WORK/$DMG_NAME"
  NOTARIZED=1
else
  echo "!! Skipping notarization: no saved credentials named '$PROFILE'. See the setup notes at the top of this script."
  NOTARIZED=0
fi

mkdir -p dist
rm -f "dist/$DMG_NAME"
cp "$WORK/$DMG_NAME" "dist/$DMG_NAME"
echo "==> Checking with Gatekeeper"
spctl -a -t open --context context:primary-signature -v "dist/$DMG_NAME" 2>&1 || true
echo "Done: $PWD/dist/$DMG_NAME (notarized: $([[ $NOTARIZED == 1 ]] && echo yes || echo NO))"

if [[ $PUBLISH == 1 ]]; then
  [[ $NOTARIZED == 1 ]] || { echo "Not publishing an un-notarized DMG."; exit 1; }
  git push
  gh release create "v$VERSION" "dist/$DMG_NAME" --title "NeXTDock $VERSION" --generate-notes
fi
