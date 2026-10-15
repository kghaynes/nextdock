#!/bin/zsh
# Regenerates the README images in docs/ from a demo layout of standard macOS apps
# (your own dock configuration is not used). Running apps that aren't in the demo
# layout appear in the "running" section, as they would in real use.
#   tools/screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh >/dev/null
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p docs

# A demo script so the script tile has something real to point at.
printf '#!/bin/zsh\necho "backing up..."\n' > "$TMP/backup.sh"; chmod +x "$TMP/backup.sh"

cat > "$TMP/demo.json" <<JSON
{
  "edge": "right", "tileSize": 64, "showRunning": true,
  "pinned": [
    {"kind": "app", "path": "/System/Library/CoreServices/Finder.app"},
    {"kind": "clock", "path": "clock"},
    {"kind": "spaces", "path": "spaces"},
    {"kind": "app", "path": "/Applications/Safari.app"},
    {"kind": "app", "path": "/System/Applications/Mail.app"},
    {"kind": "app", "path": "/System/Applications/Notes.app"},
    {"kind": "app", "path": "/System/Applications/Utilities/Terminal.app"},
    {"kind": "folder", "path": "/Applications"},
    {"kind": "folder", "path": "$HOME/Downloads"},
    {"kind": "script", "path": "$TMP/backup.sh"},
    {"kind": "shortcut", "path": "Morning Briefing"}
  ]
}
JSON

build/NeXTDock.app/Contents/MacOS/NeXTDock --snapshot "$TMP/dock.png" --config "$TMP/demo.json"
swift tools/annotate.swift "$TMP/dock.png" docs/screenshot.png
sips -Z 256 Resources/AppIcon.icns --setProperty format png --out docs/icon.png >/dev/null
echo "Updated docs/screenshot.png and docs/icon.png"
