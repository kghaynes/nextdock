# NeXTDock

A NeXTSTEP-style dock for modern macOS: a fixed column of beveled tiles on the edge of the screen that stays exactly the way you set it up.

It doesn't replace Apple's Dock (that's a protected system app). It runs alongside it, and can push Apple's Dock out of sight while leaving Mission Control and Spaces working.

## Why

The modern macOS Dock mixes running apps in with pinned ones, shows background apps you can't get rid of, and makes it awkward to pin folders, scripts, or Shortcuts. NeXTDock fixes that:

- **Pinned items never move** unless you move them. Nothing gets added or removed on its own, and dragging a tile out of the dock does nothing, so you can't lose one by accident.
- **Running apps get their own section** below a divider, in launch order.
- **Pin anything**: apps, folders, files, shell/Python/AppleScript scripts, and Shortcuts.
- **Hide any app** from the running section with "Never Show in Dock".

## Features

| Tile | What it does |
|---|---|
| App | Click to launch or bring to front. Drop documents on it to open them with that app. |
| Folder | Click for a pop-up menu of its contents (Downloads is sorted newest first). |
| Script | Runs in the background. Border turns yellow while running, then green (success) or red (failure). `.command` files open in Terminal. Drop files on it to pass them in as arguments. Output is logged to `~/Library/Logs/NeXTDock/`. |
| Shortcut | Runs a macOS Shortcut. Drop files on it to use them as input. |
| Clock | NeXT-style live clock and calendar page. Click to open Calendar. |
| Desktops | Solaris CDE-style desktop switcher: one button per desktop, the current one pressed in. Click a number to jump straight to that desktop. |

Other options (click the **+** tile at the bottom): left or right edge, tile size, lock the dock, launch at login, NeXT-style double-click to launch, NeXT-style running indicator, and hide or restore Apple's Dock.

## Build

Requires macOS 13 or later and Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/kghaynes/nextdock.git
cd nextdock
./build.sh
open build/NeXTDock.app
```

On first launch it copies whatever is pinned in Apple's Dock so you start from a familiar layout.

### Signing

`build.sh` signs the app with a code-signing identity named **NeXTDock Local Signing** if one exists in your keychain, and falls back to an ad-hoc signature otherwise. A stable identity matters because macOS ties the Accessibility permission (needed by the desktop switcher) to the app's signature. With ad-hoc signing you have to re-grant the permission after every rebuild.

To create the local identity (one time):

```sh
D=$(mktemp -d); cd "$D"
cat > cs.cnf <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=NeXTDock Local Signing
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cs.cnf
openssl pkcs12 -export -inkey key.pem -in cert.pem -out cs.p12 -passout pass:nextdock \
  -name "NeXTDock Local Signing" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import cs.p12 -k ~/Library/Keychains/login.keychain-db -P nextdock -T /usr/bin/codesign
cd - && rm -rf "$D"
```

## Permissions

- **Accessibility** (only for the desktop switcher): switching desktops works by pressing macOS's built-in "Switch to Desktop N" shortcut (Control-1 through Control-9). NeXTDock turns those shortcuts on for you the first time you use each one.

## Configuration

Settings live in `~/Library/Application Support/NeXTDock/config.json`. It's plain JSON and safe to edit by hand; use **+ → Reload Config** afterward. Optional keys include `spaceNames` (names shown when hovering over desktop buttons):

```json
"spaceNames": ["Main", "Email", "Clients", "Lab"]
```

## Uninstall

```sh
pkill -x NeXTDock
defaults delete com.apple.dock autohide-delay; killall Dock   # only if you hid Apple's Dock
rm -rf ~/Library/Application\ Support/NeXTDock ~/Library/Logs/NeXTDock
```

## Limitations

- Notification badges (unread counts) aren't shown yet.
- The desktop switcher follows the main display's desktops only.
- Moving a window to another desktop by dropping it on a desktop button isn't possible without disabling System Integrity Protection.
