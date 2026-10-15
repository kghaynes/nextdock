// NeXTDock: a NeXT-style dock for macOS.
//
//  - Pinned items stay exactly where you put them. Nothing gets added, moved,
//    or removed unless you do it.
//  - Running apps that aren't pinned get their own section below a divider.
//  - Pin anything: apps, folders, files, scripts, Shortcuts.
//  - Drop files on an app, script, or Shortcut tile to open/run them with it.
//  - Per-app "Never Show in Dock" for background junk.
//
// Build:  ./build.sh        Config: ~/Library/Application Support/NeXTDock/config.json
// Script logs: ~/Library/Logs/NeXTDock/

import AppKit
import ServiceManagement
import ApplicationServices

// MARK: - Paths and small helpers

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/NeXTDock")
let configURL = supportDir.appendingPathComponent("config.json")
let logDir = home.appendingPathComponent("Library/Logs/NeXTDock")
let shortcutsAppPath = "/System/Applications/Shortcuts.app"
let finderPath = "/System/Library/CoreServices/Finder.app"
let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

extension NSPasteboard.PasteboardType {
    static let dockIndex = NSPasteboard.PasteboardType("local.NeXTDock.index")
}

@discardableResult
func runSync(_ exe: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { handler() }
}

func newMenu() -> NSMenu { let m = NSMenu(); m.autoenablesItems = false; return m }

func menuItem(_ title: String, checked: Bool = false, _ handler: @escaping () -> Void) -> NSMenuItem {
    let i = ClosureMenuItem(title, handler)
    i.state = checked ? .on : .off
    return i
}

func disabledItem(_ title: String) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
}

func submenuItem(_ title: String, _ menu: NSMenu) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.submenu = menu
    return i
}

// MARK: - Model

enum ItemKind: String, Codable { case app, folder, file, script, shortcut, clock, spaces }

let calendarAppURL = URL(fileURLWithPath: "/System/Applications/Calendar.app")

struct DockItem: Codable, Equatable {
    var kind: ItemKind
    var path: String          // filesystem path; for .shortcut, the Shortcut's name
    var label: String? = nil
}

struct Config: Codable {
    var pinned: [DockItem] = []
    var neverShow: [String] = []          // bundle IDs kept out of the running section
    var edge: String = "right"            // "left" or "right"
    var tileSize: Double = 64
    var showRunning = true
    var nextStyleIndicator = false        // NeXT style: "..." under apps that are NOT running
    var doubleClickToLaunch = false       // NeXT style: double-click to launch apps / run scripts
    var locked = false
    var appleDockHidden = false
    var appleDockPrevAutohide = false
    var spaceNames: [String] = []         // optional names for Desktop 1, 2, ... (shown on hover)

    init() {}

    // Tolerate missing keys so hand-edited or older config files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        pinned = try c.decodeIfPresent([DockItem].self, forKey: .pinned) ?? d.pinned
        neverShow = try c.decodeIfPresent([String].self, forKey: .neverShow) ?? d.neverShow
        edge = try c.decodeIfPresent(String.self, forKey: .edge) ?? d.edge
        tileSize = try c.decodeIfPresent(Double.self, forKey: .tileSize) ?? d.tileSize
        showRunning = try c.decodeIfPresent(Bool.self, forKey: .showRunning) ?? d.showRunning
        nextStyleIndicator = try c.decodeIfPresent(Bool.self, forKey: .nextStyleIndicator) ?? d.nextStyleIndicator
        doubleClickToLaunch = try c.decodeIfPresent(Bool.self, forKey: .doubleClickToLaunch) ?? d.doubleClickToLaunch
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? d.locked
        appleDockHidden = try c.decodeIfPresent(Bool.self, forKey: .appleDockHidden) ?? d.appleDockHidden
        appleDockPrevAutohide = try c.decodeIfPresent(Bool.self, forKey: .appleDockPrevAutohide) ?? d.appleDockPrevAutohide
        spaceNames = try c.decodeIfPresent([String].self, forKey: .spaceNames) ?? d.spaceNames
    }
}

let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "command", "py", "rb", "pl", "scpt", "scptd", "applescript"]

func classify(_ path: String) -> ItemKind {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    if ext == "app" { return .app }
    if scriptExtensions.contains(ext) { return .script }
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        return NSWorkspace.shared.isFilePackage(atPath: path) ? .file : .folder
    }
    if ext.isEmpty && fm.isExecutableFile(atPath: path) { return .script }
    return .file
}

/// First run: copy whatever is pinned in Apple's Dock so you start from familiar ground.
func seedFromAppleDock() -> [DockItem] {
    var out: [DockItem] = [DockItem(kind: .app, path: finderPath)]
    guard let d = UserDefaults(suiteName: "com.apple.dock") else { return out }
    for key in ["persistent-apps", "persistent-others"] {
        for entry in (d.array(forKey: key) as? [[String: Any]]) ?? [] {
            guard let td = entry["tile-data"] as? [String: Any],
                  let fd = td["file-data"] as? [String: Any],
                  let s = fd["_CFURLString"] as? String else { continue }
            let url = URL(string: s) ?? URL(fileURLWithPath: s)
            guard url.isFileURL else { continue }
            var path = url.path
            if path.hasSuffix("/") && path.count > 1 { path.removeLast() }
            guard fm.fileExists(atPath: path), !out.contains(where: { $0.path == path }) else { continue }
            out.append(DockItem(kind: classify(path), path: path))
        }
    }
    return out
}

enum RunState { case busy, ok, failed }

// MARK: - Desktops (Spaces)
// Reading which desktop is active uses the window server's own (undocumented but stable) call,
// the same one Mission Control utilities use. Switching presses macOS's built-in
// "Switch to Desktop N" shortcut (Control-N), which needs Accessibility permission.

enum Desktops {
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias CopyFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let conn: Int32? = {
        guard let s = sky, let f = dlsym(s, "SLSMainConnectionID") else { return nil }
        return unsafeBitCast(f, to: ConnFn.self)()
    }()
    private static let copySpaces: CopyFn? = {
        guard let s = sky, let f = dlsym(s, "SLSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(f, to: CopyFn.self)
    }()

    /// Regular desktops on the main display (full-screen app spaces left out) and which one is showing.
    static func read() -> (count: Int, current: Int?) {
        guard let c = conn, let fn = copySpaces,
              let raw = fn(c)?.takeRetainedValue() as? [[String: Any]], !raw.isEmpty else { return (0, nil) }
        var mainID = "Main"
        if let u = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue(),
           let str = CFUUIDCreateString(nil, u) as String? {
            mainID = str
        }
        let disp = raw.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(mainID) == .orderedSame }
            ?? raw.first { ($0["Display Identifier"] as? String) == "Main" } ?? raw[0]
        let spaces = (disp["Spaces"] as? [[String: Any]]) ?? []
        let ids = spaces.filter { ($0["type"] as? Int) == 0 }.compactMap { $0["ManagedSpaceID"] as? Int }
        let cur = (disp["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
        return (ids.count, cur.flatMap { ids.firstIndex(of: $0) })
    }

    // Key codes for the 1...9 keys.
    static let keyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// Turn on macOS's "Switch to Desktop N" shortcut as Control-N if it isn't already. Returns true if changed.
    static func ensureShortcut(_ i: Int) -> Bool {
        let key = String(118 + i)   // 118 = Desktop 1, 119 = Desktop 2, ...
        let want = [49 + i, Int(keyCodes[i]), 262144]   // character, key code, Control modifier
        let hk = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        if let e = hk?[key] as? [String: Any], (e["enabled"] as? Bool) == true,
           let v = e["value"] as? [String: Any], (v["parameters"] as? [Int]) == want {
            return false
        }
        let xml = "<dict><key>enabled</key><true/><key>value</key><dict><key>type</key><string>standard</string>"
            + "<key>parameters</key><array><integer>\(want[0])</integer><integer>\(want[1])</integer>"
            + "<integer>\(want[2])</integer></array></dict></dict>"
        runSync("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "-dict-add", key, xml])
        return true
    }

    /// Make the system pick up shortcut changes without logging out.
    static func applyShortcutChanges() {
        runSync("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
    }

    static func pressControl(_ i: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: keyCodes[i], keyDown: down)
            e?.flags = .maskControl
            e?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Hover label
// Standard tooltips only appear for the active app, and NeXTDock never activates,
// so hover names are drawn in our own small floating panel beside the dock.

final class HoverLabel {
    private let panel: NSPanel
    private let field = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.94).cgColor
        bg.layer?.borderColor = NSColor(white: 0.55, alpha: 1).cgColor
        bg.layer?.borderWidth = 1
        bg.layer?.cornerRadius = 4
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = .white
        bg.addSubview(field)
        panel.contentView = bg
    }

    func show(_ text: String, beside view: NSView, edge: String) {
        guard let win = view.window, !text.isEmpty else { return }
        field.stringValue = text
        field.sizeToFit()
        let padX: CGFloat = 9, padY: CGFloat = 5
        let size = NSSize(width: field.frame.width + padX * 2, height: field.frame.height + padY * 2)
        field.setFrameOrigin(NSPoint(x: padX, y: padY))
        let r = win.convertToScreen(view.convert(view.bounds, to: nil))
        let x = edge == "left" ? r.maxX + 6 : r.minX - 6 - size.width
        panel.setFrame(NSRect(x: x, y: r.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

func hoverTracking(_ v: NSView) {
    v.trackingAreas.forEach { v.removeTrackingArea($0) }
    v.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                     owner: v, userInfo: nil))
}

// MARK: - Controller

final class DockController: NSObject, NSMenuDelegate {
    var config = Config()
    var status: [String: RunState] = [:]      // keyed by item path; drives the colored tile border
    var suspendRebuild = false
    let hover = HoverLabel()
    var desktops: (count: Int, current: Int?) = (0, nil)
    let panel: NSPanel
    let dockView: DockView
    private var signature = ""
    private var bundleIDCache: [String: String] = [:]

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        dockView = DockView(frame: .zero)
        super.init()
        dockView.controller = self
        panel.contentView = dockView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        loadConfig()

        let wnc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        for n in names { wnc.addObserver(self, selector: #selector(workspaceChanged), name: n, object: nil) }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Safety net: some apps switch from background to regular after launch.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshIfNeeded()
            self?.tickClock()
            self?.tickSpaces()
        }
        wnc.addObserver(self, selector: #selector(spaceChanged),
                        name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        desktops = Desktops.read()

        rebuild(force: true)
        panel.orderFrontRegardless()
    }

    // MARK: Config

    func loadConfig() {
        if let data = try? Data(contentsOf: configURL),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            config = c
            return
        }
        if fm.fileExists(atPath: configURL.path) {
            // Unreadable file: keep a copy instead of silently overwriting the user's edits.
            let bad = configURL.appendingPathExtension("bad")
            try? fm.removeItem(at: bad)
            try? fm.moveItem(at: configURL, to: bad)
            alert("Config file couldn't be read",
                  "It was saved as config.json.bad and a fresh config was created from Apple's Dock.")
        }
        config = Config()
        config.pinned = seedFromAppleDock()
        save()
    }

    func save() {
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(config) { try? data.write(to: configURL, options: .atomic) }
    }

    // MARK: Running apps

    func bundleID(forAppPath p: String) -> String? {
        if let c = bundleIDCache[p] { return c }
        let id = Bundle(path: p)?.bundleIdentifier
        if let id { bundleIDCache[p] = id }
        return id
    }

    func runningApp(for item: DockItem) -> NSRunningApplication? {
        guard item.kind == .app else { return nil }
        let std = URL(fileURLWithPath: item.path).standardizedFileURL.path
        let apps = NSWorkspace.shared.runningApplications
        if let a = apps.first(where: { $0.bundleURL?.standardizedFileURL.path == std }) { return a }
        if let id = bundleID(forAppPath: item.path) { return apps.first { $0.bundleIdentifier == id } }
        return nil
    }

    /// Regular (windowed) apps that are running, not pinned, and not on the never-show list.
    /// Ordered by launch time so they never shuffle.
    func runningExtras() -> [NSRunningApplication] {
        guard config.showRunning else { return [] }
        let pinnedApps = config.pinned.filter { $0.kind == .app }
        let pinnedPaths = Set(pinnedApps.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let pinnedIDs = Set(pinnedApps.compactMap { bundleID(forAppPath: $0.path) })
        let never = Set(config.neverShow)
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular, let url = app.bundleURL else { return false }
                let id = app.bundleIdentifier ?? ""
                return !never.contains(id) && !pinnedIDs.contains(id)
                    && !pinnedPaths.contains(url.standardizedFileURL.path)
            }
            .sorted {
                let a = $0.launchDate ?? .distantPast, b = $1.launchDate ?? .distantPast
                return a == b ? $0.processIdentifier < $1.processIdentifier : a < b
            }
    }

    private func computeSignature() -> String {
        var parts: [String] = ["\(config.edge)|\(config.tileSize)"]
        for p in config.pinned {
            let a = runningApp(for: p)
            parts.append("\(p.path)|\(a != nil)|\(a?.isHidden ?? false)")
        }
        for a in runningExtras() { parts.append("r\(a.processIdentifier)|\(a.isHidden)") }
        parts.append("f\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
        return parts.joined(separator: ";")
    }

    @objc private func workspaceChanged() { refreshIfNeeded() }
    @objc private func screensChanged() { rebuild(force: true) }

    func refreshIfNeeded() {
        guard !suspendRebuild else { return }
        if computeSignature() != signature { rebuild() }
    }

    func redraw() { dockView.subviews.forEach { $0.needsDisplay = true } }

    private var lastMinute = ""
    /// Repaint the clock tile when the minute (or day) changes.
    func tickClock() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmm"
        let now = f.string(from: Date())
        guard now != lastMinute else { return }
        lastMinute = now
        dockView.subviews.compactMap { $0 as? Tile }.filter { $0.item.kind == .clock }.forEach { $0.needsDisplay = true }
    }

    /// Repaint the desktop switcher when the current desktop or the number of desktops changes.
    func tickSpaces() {
        let d = Desktops.read()
        guard d.count != desktops.count || d.current != desktops.current else { return }
        desktops = d
        dockView.subviews.compactMap { $0 as? Tile }.filter { $0.item.kind == .spaces }.forEach { $0.needsDisplay = true }
    }

    @objc private func spaceChanged() {
        // The window server can report the new desktop a moment after the notification.
        tickSpaces()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.tickSpaces() }
    }

    func addDesktops() {
        guard !config.pinned.contains(where: { $0.kind == .spaces }) else { return }
        let after = config.pinned.firstIndex(where: { $0.kind == .clock }).map { $0 + 1 } ?? min(1, config.pinned.count)
        config.pinned.insert(DockItem(kind: .spaces, path: "spaces"), at: after)
        save(); rebuild(force: true)
    }

    func switchToDesktop(_ i: Int, from tile: Tile) {
        guard i < Desktops.keyCodes.count, desktops.current != i else { return }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            hover.show("Allow NeXTDock in Privacy & Security → Accessibility, then click again",
                       beside: tile, edge: config.edge)
            flash(tile.item.path, .failed)
            return
        }
        let changed = Desktops.ensureShortcut(i)
        if changed { Desktops.applyShortcutChanges() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (changed ? 0.6 : 0)) { Desktops.pressControl(i) }
    }

    func addClock() {
        guard !config.pinned.contains(where: { $0.kind == .clock }) else { return }
        config.pinned.insert(DockItem(kind: .clock, path: "clock"), at: min(1, config.pinned.count))
        save(); rebuild(force: true)
    }

    // MARK: Layout

    func rebuild(force: Bool = false) {
        if suspendRebuild && !force { return }
        hover.hide()
        signature = computeSignature()
        dockView.subviews.forEach { $0.removeFromSuperview() }
        dockView.pinnedTiles = []
        dockView.dividerY = nil

        let extras = runningExtras()
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let divider: CGFloat = 10
        var s = CGFloat(config.tileSize)
        func plusHeight(_ s: CGFloat) -> CGFloat { (s * 0.4).rounded() }
        func total(_ s: CGFloat) -> CGFloat {
            CGFloat(config.pinned.count) * s
                + (extras.isEmpty ? 0 : divider + CGFloat(extras.count) * s)
                + plusHeight(s)
        }
        while total(s) > vf.height && s > 24 { s -= 2 }   // shrink to fit the screen

        var y: CGFloat = 0
        for (i, item) in config.pinned.enumerated() {
            let t = Tile(frame: NSRect(x: 0, y: y, width: s, height: s), item: item, role: .pinned(i), controller: self)
            dockView.addSubview(t)
            dockView.pinnedTiles.append(t)
            y += s
        }
        if !extras.isEmpty {
            dockView.dividerY = y + divider / 2
            y += divider
            for app in extras {
                guard let url = app.bundleURL else { continue }
                let item = DockItem(kind: .app, path: url.path, label: app.localizedName)
                let t = Tile(frame: NSRect(x: 0, y: y, width: s, height: s), item: item, role: .running, controller: self)
                t.runningOverride = app
                dockView.addSubview(t)
                y += s
            }
        }
        let plus = PlusView(frame: NSRect(x: 0, y: y, width: s, height: plusHeight(s)), controller: self)
        dockView.addSubview(plus)
        y += plus.frame.height

        let x = config.edge == "left" ? vf.minX : vf.maxX - s
        let frame = NSRect(x: x, y: vf.maxY - y, width: s, height: y)
        panel.setFrame(frame, display: false)
        dockView.frame = NSRect(origin: .zero, size: frame.size)
        dockView.needsDisplay = true
    }

    // MARK: Actions

    func activate(_ tile: Tile, clickCount: Int) {
        let item = tile.item
        if ![.shortcut, .clock, .spaces].contains(item.kind) && !fm.fileExists(atPath: item.path) {
            flash(item.path, .failed); return
        }
        let needsDouble = config.doubleClickToLaunch && clickCount < 2
        switch item.kind {
        case .app:
            let running = tile.runningApp
            if running == nil && needsDouble { return }
            if let r = running, r.isHidden { r.unhide() }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            // Same call Apple's Dock effectively makes: launches, or "reopens" a running app
            // (which brings back a window if it had none).
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: item.path), configuration: cfg) { _, err in
                if err != nil { DispatchQueue.main.async { self.flash(item.path, .failed) } }
            }
        case .folder:
            tile.popUpFolderMenu()
        case .file:
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        case .script, .shortcut:
            if needsDouble { return }
            run(item, inputs: [])
        case .clock:
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: calendarAppURL, configuration: cfg, completionHandler: nil)
        case .spaces:
            break   // handled per button in Tile.mouseUp
        }
    }

    func logURL(for item: DockItem) -> URL {
        let name = (item.kind == .shortcut ? item.path : URL(fileURLWithPath: item.path).lastPathComponent)
            .replacingOccurrences(of: "/", with: "-")
        return logDir.appendingPathComponent(name + ".log")
    }

    /// Runs a script or Shortcut in the background. Output goes to ~/Library/Logs/NeXTDock/<name>.log.
    /// Tile border: yellow while running, green on success, red on failure.
    func run(_ item: DockItem, inputs: [URL]) {
        let path = item.path
        let a = inputs.map(\.path)
        let exe: String
        var args: [String]
        switch item.kind {
        case .shortcut:
            exe = "/usr/bin/shortcuts"
            args = ["run", path]
            for u in inputs { args += ["-i", u.path] }
        case .script:
            switch URL(fileURLWithPath: path).pathExtension.lowercased() {
            case "command" where inputs.isEmpty:
                NSWorkspace.shared.open(URL(fileURLWithPath: path))   // .command = run visibly in Terminal
                return
            case "scpt", "scptd", "applescript":
                exe = "/usr/bin/osascript"; args = [path] + a
            case "py":
                exe = "/usr/bin/env"; args = ["python3", path] + a
            default:
                if fm.isExecutableFile(atPath: path) { exe = path; args = a }
                else { exe = "/bin/zsh"; args = [path] + a }
            }
        default:
            return
        }

        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let log = logURL(for: item)
        fm.createFile(atPath: log.path, contents: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = item.kind == .script ? URL(fileURLWithPath: path).deletingLastPathComponent() : home
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        if let h = try? FileHandle(forWritingTo: log) {
            h.write(Data("=== \(Date())  \(exe) \(args.joined(separator: " "))\n".utf8))
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { proc in
            DispatchQueue.main.async { self.flash(path, proc.terminationStatus == 0 ? .ok : .failed) }
        }
        do {
            try p.run()
            status[path] = .busy
            redraw()
        } catch {
            flash(path, .failed)
        }
    }

    func flash(_ path: String, _ s: RunState) {
        status[path] = s
        redraw()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.status[path] == s else { return }
            self.status[path] = nil
            self.redraw()
        }
    }

    func open(_ urls: [URL], with tile: Tile) {
        switch tile.item.kind {
        case .app:
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: tile.item.path),
                                    configuration: cfg, completionHandler: nil)
        case .script, .shortcut:
            run(tile.item, inputs: urls)
        default:
            break
        }
    }

    // MARK: Editing the pinned list

    func pin(_ paths: [String], at index: Int) {
        var idx = min(max(index, 0), config.pinned.count)
        for p in paths where !config.pinned.contains(where: { $0.path == p }) {
            config.pinned.insert(DockItem(kind: classify(p), path: p), at: idx)
            idx += 1
        }
        save(); rebuild(force: true)
    }

    func pinShortcut(_ name: String) {
        guard !config.pinned.contains(where: { $0.kind == .shortcut && $0.path == name }) else { return }
        config.pinned.append(DockItem(kind: .shortcut, path: name))
        save(); rebuild(force: true)
    }

    func unpin(at i: Int) {
        guard config.pinned.indices.contains(i) else { return }
        config.pinned.remove(at: i)
        save(); rebuild(force: true)
    }

    func movePinned(from: Int, to: Int) {
        guard config.pinned.indices.contains(from) else { return }
        let it = config.pinned.remove(at: from)
        let dest = min(max(to > from ? to - 1 : to, 0), config.pinned.count)
        config.pinned.insert(it, at: dest)
        save(); rebuild(force: true)
    }

    func neverShow(_ id: String) {
        if !config.neverShow.contains(id) { config.neverShow.append(id) }
        save(); rebuild(force: true)
    }

    // MARK: Menus

    func menu(for tile: Tile) -> NSMenu {
        let m = newMenu()
        let item = tile.item
        m.addItem(disabledItem(tile.displayName))
        m.addItem(.separator())

        if let app = tile.runningApp {
            m.addItem(menuItem(app.isHidden ? "Show" : "Hide") {
                if app.isHidden { app.unhide() } else { app.hide() }
            })
            let quit = menuItem("Quit") { app.terminate() }
            let force = menuItem("Force Quit") { app.forceTerminate() }
            force.isAlternate = true
            force.keyEquivalentModifierMask = .option
            m.addItem(quit)
            m.addItem(force)
            m.addItem(.separator())
        }

        if item.kind == .script || item.kind == .shortcut {
            m.addItem(menuItem("Run") { self.run(item, inputs: []) })
            m.addItem(menuItem("Open Last Log") {
                let log = self.logURL(for: item)
                if fm.fileExists(atPath: log.path) {
                    NSWorkspace.shared.open([log], withApplicationAt: textEditURL, configuration: NSWorkspace.OpenConfiguration())
                }
            })
            if item.kind == .script {
                m.addItem(menuItem("Edit Script") {
                    NSWorkspace.shared.open([URL(fileURLWithPath: item.path)], withApplicationAt: textEditURL,
                                            configuration: NSWorkspace.OpenConfiguration())
                })
            }
            m.addItem(.separator())
        }

        if item.kind == .spaces {
            let mc = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            m.addItem(menuItem("Mission Control") {
                NSWorkspace.shared.openApplication(at: mc, configuration: NSWorkspace.OpenConfiguration(),
                                                   completionHandler: nil)
            })
            m.addItem(disabledItem("Add or remove desktops in Mission Control (+ at top right)"))
            m.addItem(menuItem("Name Desktops (edit spaceNames in config)…") {
                NSWorkspace.shared.open([configURL], withApplicationAt: textEditURL,
                                        configuration: NSWorkspace.OpenConfiguration())
            })
            m.addItem(.separator())
        }

        if item.kind == .clock {
            m.addItem(menuItem("Open Calendar") {
                NSWorkspace.shared.openApplication(at: calendarAppURL, configuration: NSWorkspace.OpenConfiguration(),
                                                   completionHandler: nil)
            })
            m.addItem(menuItem("Date & Time Settings…") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension") {
                    NSWorkspace.shared.open(u)
                }
            })
            m.addItem(.separator())
        }

        switch tile.role {
        case .pinned(let i):
            if config.locked {
                m.addItem(disabledItem("Dock is locked"))
            } else {
                if i > 0 { m.addItem(menuItem("Move Up") { self.movePinned(from: i, to: i - 1) }) }
                if i < config.pinned.count - 1 { m.addItem(menuItem("Move Down") { self.movePinned(from: i, to: i + 2) }) }
                m.addItem(menuItem("Remove from Dock") { self.unpin(at: i) })
            }
        case .running:
            if !config.locked {
                m.addItem(menuItem("Keep in Dock") { self.pin([item.path], at: self.config.pinned.count) })
            }
            if let id = tile.runningApp?.bundleIdentifier {
                m.addItem(menuItem("Never Show in Dock") { self.neverShow(id) })
            }
        }

        if ![.shortcut, .clock, .spaces].contains(item.kind) {
            m.addItem(menuItem("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            })
        }
        m.addItem(.separator())
        m.addItem(submenuItem("NeXTDock", dockMenu()))
        return m
    }

    func folderMenu(_ path: String) -> NSMenu {
        let m = newMenu()
        let url = URL(fileURLWithPath: path)
        m.addItem(menuItem("Open in Finder") { NSWorkspace.shared.open(url) })
        m.addItem(.separator())
        var items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                                                  options: [.skipsHiddenFiles])) ?? []
        if url.lastPathComponent == "Downloads" {
            func date(_ u: URL) -> Date {
                (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            }
            items.sort { date($0) > date($1) }   // newest first
        } else {
            items.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        if items.isEmpty { m.addItem(disabledItem("Empty")) }
        let limit = 150
        for u in items.prefix(limit) {
            let mi = menuItem(fm.displayName(atPath: u.path)) { NSWorkspace.shared.open(u) }
            let img = NSWorkspace.shared.icon(forFile: u.path)
            img.size = NSSize(width: 16, height: 16)
            mi.image = img
            m.addItem(mi)
        }
        if items.count > limit { m.addItem(disabledItem("… \(items.count - limit) more")) }
        return m
    }

    func dockMenu() -> NSMenu {
        let m = newMenu()
        if !config.locked {
            m.addItem(menuItem("Add Apps, Folders, Files or Scripts…") { self.addViaOpenPanel() })
            let sc = newMenu()
            sc.identifier = NSUserInterfaceItemIdentifier("shortcuts")
            sc.delegate = self
            sc.addItem(disabledItem("Loading…"))
            m.addItem(submenuItem("Add Shortcut", sc))
            if !config.pinned.contains(where: { $0.kind == .clock }) {
                m.addItem(menuItem("Add Clock") { self.addClock() })
            }
            if !config.pinned.contains(where: { $0.kind == .spaces }) {
                m.addItem(menuItem("Add Desktop Switcher") { self.addDesktops() })
            }
            m.addItem(.separator())
        }

        let pos = newMenu()
        for e in ["left", "right"] {
            pos.addItem(menuItem(e.capitalized, checked: config.edge == e) {
                self.config.edge = e; self.save(); self.rebuild(force: true)
            })
        }
        m.addItem(submenuItem("Position", pos))

        let size = newMenu()
        for v in [48.0, 56, 64, 72, 80] {
            size.addItem(menuItem("\(Int(v))", checked: config.tileSize == v) {
                self.config.tileSize = v; self.save(); self.rebuild(force: true)
            })
        }
        m.addItem(submenuItem("Tile Size", size))

        m.addItem(toggle("Show Running Apps", \.showRunning))
        m.addItem(toggle("NeXT-Style Running Indicator", \.nextStyleIndicator))
        m.addItem(toggle("Double-Click to Launch", \.doubleClickToLaunch))
        m.addItem(toggle("Lock Dock", \.locked))

        let hidden = newMenu()
        if config.neverShow.isEmpty { hidden.addItem(disabledItem("None")) }
        for id in config.neverShow {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { fm.displayName(atPath: $0.path) } ?? id
            hidden.addItem(menuItem("Show “\(name)” Again") {
                self.config.neverShow.removeAll { $0 == id }; self.save(); self.rebuild(force: true)
            })
        }
        m.addItem(submenuItem("Hidden Apps", hidden))

        m.addItem(.separator())
        m.addItem(menuItem(config.appleDockHidden ? "Restore Apple Dock" : "Hide Apple Dock") {
            self.setAppleDockHidden(!self.config.appleDockHidden)
        })
        m.addItem(menuItem("Launch at Login", checked: SMAppService.mainApp.status == .enabled) { self.toggleLogin() })
        m.addItem(menuItem("Edit Config File") {
            NSWorkspace.shared.open([configURL], withApplicationAt: textEditURL, configuration: NSWorkspace.OpenConfiguration())
        })
        m.addItem(menuItem("Reload Config") { self.loadConfig(); self.rebuild(force: true) })
        m.addItem(.separator())
        m.addItem(menuItem("Quit NeXTDock") { NSApp.terminate(nil) })
        return m
    }

    private func toggle(_ title: String, _ kp: WritableKeyPath<Config, Bool>) -> NSMenuItem {
        menuItem(title, checked: config[keyPath: kp]) {
            self.config[keyPath: kp].toggle(); self.save(); self.rebuild(force: true)
        }
    }

    // Fill the "Add Shortcut" submenu only when it's opened (asks the `shortcuts` tool for the list).
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier?.rawValue == "shortcuts" else { return }
        menu.removeAllItems()
        let names = runSync("/usr/bin/shortcuts", ["list"])
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if names.isEmpty { menu.addItem(disabledItem("No Shortcuts found")) }
        for n in names {
            let pinned = config.pinned.contains { $0.kind == .shortcut && $0.path == n }
            menu.addItem(menuItem(n, checked: pinned) { self.pinShortcut(n) })
        }
    }

    func addViaOpenPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.prompt = "Add to Dock"
        if p.runModal() == .OK { pin(p.urls.map(\.path), at: config.pinned.count) }
    }

    func setAppleDockHidden(_ hide: Bool) {
        if hide {
            config.appleDockPrevAutohide = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
            runSync("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"])
            runSync("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
        } else {
            runSync("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-delay"])
            runSync("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool",
                                          config.appleDockPrevAutohide ? "true" : "false"])
        }
        runSync("/usr/bin/killall", ["Dock"])
        config.appleDockHidden = hide
        save()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.rebuild(force: true) }
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Couldn't change Launch at Login", error.localizedDescription)
        }
    }

    func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}

// MARK: - Dock view (handles all drag and drop)

final class DockView: NSView {
    weak var controller: DockController?
    var pinnedTiles: [Tile] = []
    var dividerY: CGFloat? { didSet { needsDisplay = true } }

    private let insertLine: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        return v
    }()
    private var highlighted: Tile? {
        didSet { if oldValue !== highlighted { oldValue?.dropHighlight = false; highlighted?.dropHighlight = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .dockIndex])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let y = dividerY else { return }
        // Grooved divider between pinned and running sections.
        NSColor(white: 0.14, alpha: 0.92).setFill()
        NSRect(x: 0, y: y - 5, width: bounds.width, height: 10).fill()
        NSColor(white: 0.03, alpha: 1).setFill()
        NSRect(x: 4, y: y - 1, width: bounds.width - 8, height: 1).fill()
        NSColor(white: 0.55, alpha: 1).setFill()
        NSRect(x: 4, y: y, width: bounds.width - 8, height: 1).fill()
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let c = controller else { return }
        NSMenu.popUpContextMenu(c.dockMenu(), with: e, for: self)
    }

    func tile(at p: NSPoint) -> Tile? { subviews.compactMap { $0 as? Tile }.first { $0.frame.contains(p) } }

    func pinnedInsertIndex(at p: NSPoint) -> Int {
        for (i, t) in pinnedTiles.enumerated() where p.y < t.frame.midY { return i }
        return pinnedTiles.count
    }

    private func showInsert(_ idx: Int?) {
        guard let idx else { insertLine.removeFromSuperview(); return }
        let y = idx < pinnedTiles.count ? pinnedTiles[idx].frame.minY : (pinnedTiles.last?.frame.maxY ?? 0)
        insertLine.frame = NSRect(x: 0, y: max(0, y - 2), width: bounds.width, height: 4)
        if insertLine.superview == nil { addSubview(insertLine, positioned: .above, relativeTo: nil) }
    }

    private enum DropAction { case reorder(Int, Int), openWith(Tile, [URL]), pin([URL], Int), none }

    private func action(for s: NSDraggingInfo) -> DropAction {
        guard let c = controller else { return .none }
        let p = convert(s.draggingLocation, from: nil)
        let pb = s.draggingPasteboard
        if let str = pb.string(forType: .dockIndex), let from = Int(str) {
            return c.config.locked ? .none : .reorder(from, pinnedInsertIndex(at: p))
        }
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return .none }
        // Dropping apps always means "pin". Dropping documents on an app/script/Shortcut means
        // "open/run with it" unless Option is held (Option = pin instead).
        let allApps = urls.allSatisfy { $0.pathExtension.lowercased() == "app" }
        if !allApps, !NSEvent.modifierFlags.contains(.option), let t = tile(at: p),
           [ItemKind.app, .script, .shortcut].contains(t.item.kind) {
            return .openWith(t, urls)
        }
        return c.config.locked ? .none : .pin(urls, pinnedInsertIndex(at: p))
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }

    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        switch action(for: s) {
        case .reorder(_, let to): highlighted = nil; showInsert(to); return .move
        case .openWith(let t, _): highlighted = t; showInsert(nil); return .copy
        case .pin(_, let i): highlighted = nil; showInsert(i); return .copy
        case .none: highlighted = nil; showInsert(nil); return []
        }
    }

    override func draggingExited(_ s: NSDraggingInfo?) { highlighted = nil; showInsert(nil) }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let a = action(for: s)
        highlighted = nil
        showInsert(nil)
        guard let c = controller else { return false }
        switch a {
        case .reorder(let from, let to): c.movePinned(from: from, to: to)
        case .openWith(let tile, let urls): c.open(urls, with: tile)
        case .pin(let urls, let i): c.pin(urls.map(\.path), at: i)
        case .none: return false
        }
        return true
    }
}

// MARK: - Tile

final class Tile: NSView, NSDraggingSource {
    enum Role { case pinned(Int), running }

    let item: DockItem
    let role: Role
    unowned let controller: DockController
    var runningOverride: NSRunningApplication?
    var dropHighlight = false { didSet { needsDisplay = true } }
    private var downPoint: NSPoint?
    private var dragging = false
    private lazy var icon: NSImage = {
        if item.kind == .shortcut { return NSWorkspace.shared.icon(forFile: shortcutsAppPath) }
        if fm.fileExists(atPath: item.path) { return NSWorkspace.shared.icon(forFile: item.path) }
        return NSImage(named: NSImage.cautionName) ?? NSImage()
    }()

    init(frame: NSRect, item: DockItem, role: Role, controller: DockController) {
        self.item = item
        self.role = role
        self.controller = controller
        super.init(frame: frame)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverTracking(self)
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hoverTracking(self) }

    func hoverText(at p: NSPoint?) -> String {
        if item.kind == .spaces {
            guard let p, let i = desktopIndex(at: p) else { return "Desktops" }
            let names = controller.config.spaceNames
            var t = "Desktop \(i + 1)"
            if i < names.count, !names[i].isEmpty { t += " — " + names[i] }
            if controller.desktops.current == i { t += "  (current)" }
            return t
        }
        if item.kind == .clock {
            let f = DateFormatter()
            f.dateStyle = .full
            f.timeStyle = .short
            return f.string(from: Date())
        }
        if let app = runningApp, app.isHidden { return displayName + " (hidden)" }
        return displayName
    }

    override func mouseEntered(with e: NSEvent) {
        controller.hover.show(hoverText(at: convert(e.locationInWindow, from: nil)), beside: self,
                              edge: controller.config.edge)
    }

    override func mouseMoved(with e: NSEvent) {
        guard item.kind == .spaces else { return }
        controller.hover.show(hoverText(at: convert(e.locationInWindow, from: nil)), beside: self,
                              edge: controller.config.edge)
    }

    override func mouseExited(with e: NSEvent) { controller.hover.hide() }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var runningApp: NSRunningApplication? { runningOverride ?? controller.runningApp(for: item) }

    var displayName: String {
        if let l = item.label { return l }
        if item.kind == .shortcut { return item.path }
        if item.kind == .clock { return "Clock" }
        if item.kind == .spaces { return "Desktops" }
        var n = fm.displayName(atPath: item.path)
        if n.hasSuffix(".app") { n.removeLast(4) }
        return n
    }

    override func draw(_ dirtyRect: NSRect) {
        let s = bounds.width
        let b = bounds.insetBy(dx: 0.5, dy: 0.5)

        // NeXT-style beveled gray tile.
        NSGradient(starting: NSColor(white: 0.42, alpha: 0.96), ending: NSColor(white: 0.24, alpha: 0.96))?
            .draw(in: b, angle: 90)
        let light = NSBezierPath()
        light.move(to: NSPoint(x: b.minX, y: b.maxY))
        light.line(to: NSPoint(x: b.minX, y: b.minY))
        light.line(to: NSPoint(x: b.maxX, y: b.minY))
        NSColor(white: 0.78, alpha: 1).setStroke()
        light.stroke()
        let dark = NSBezierPath()
        dark.move(to: NSPoint(x: b.maxX, y: b.minY))
        dark.line(to: NSPoint(x: b.maxX, y: b.maxY))
        dark.line(to: NSPoint(x: b.minX, y: b.maxY))
        NSColor(white: 0.04, alpha: 1).setStroke()
        dark.stroke()

        if item.kind == .clock || item.kind == .spaces {
            if item.kind == .clock { drawClock(s) } else { drawDesktops() }
            if let st = controller.status[item.path], st == .failed { border(.systemRed) }
            if dropHighlight { border(.controlAccentColor) }
            return
        }

        let app = runningApp
        let inset = (s * 0.12).rounded()
        let fraction: CGFloat = (app?.isHidden == true) ? 0.5 : 1
        icon.draw(in: bounds.insetBy(dx: inset, dy: inset), from: .zero, operation: .sourceOver,
                  fraction: fraction, respectFlipped: true, hints: nil)

        if item.kind == .script || item.kind == .shortcut { drawLabel(s) }

        if item.kind == .app {
            if controller.config.nextStyleIndicator {
                if app == nil {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.boldSystemFont(ofSize: max(9, s * 0.18)),
                        .foregroundColor: NSColor.black,
                    ]
                    ("…" as NSString).draw(at: NSPoint(x: 3, y: s - max(9, s * 0.18) - 6), withAttributes: attrs)
                }
            } else if let app {
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
                let d = max(4, (s * 0.07).rounded())
                (front ? NSColor.white : NSColor(white: 0.82, alpha: 0.9)).setFill()
                NSBezierPath(ovalIn: NSRect(x: (s - d) / 2, y: s - d - 2, width: d, height: d)).fill()
            }
        }

        if let st = controller.status[item.path] {
            let color: NSColor = st == .busy ? .systemYellow : (st == .ok ? .systemGreen : .systemRed)
            border(color)
        }
        if dropHighlight { border(.controlAccentColor) }
    }

    // CDE-style workspace buttons: one button per desktop, the current one pressed in.
    func desktopCells() -> [NSRect] {
        let n = min(controller.desktops.count, Desktops.keyCodes.count)
        guard n > 0 else { return [] }
        let m = (bounds.width * 0.08).rounded()
        let area = bounds.insetBy(dx: m, dy: m)
        let cols = n <= 3 ? 1 : (n <= 6 ? 2 : 3)
        let rows = Int((Double(n) / Double(cols)).rounded(.up))
        let gap: CGFloat = 2
        let cw = (area.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let ch = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        return (0..<n).map { i in
            let r = i / cols, c = i % cols
            return NSRect(x: area.minX + CGFloat(c) * (cw + gap), y: area.minY + CGFloat(r) * (ch + gap),
                          width: cw, height: ch).integral
        }
    }

    func desktopIndex(at p: NSPoint) -> Int? { desktopCells().firstIndex { $0.contains(p) } }

    private func drawDesktops() {
        let cells = desktopCells()
        if cells.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: bounds.width * 0.3),
                                                        .foregroundColor: NSColor(white: 0.8, alpha: 1)]
            let sz = ("?" as NSString).size(withAttributes: attrs)
            ("?" as NSString).draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2),
                                   withAttributes: attrs)
            return
        }
        let light = NSColor(white: 0.9, alpha: 1), dark = NSColor(white: 0.08, alpha: 1)
        for (i, r) in cells.enumerated() {
            let cur = controller.desktops.current == i
            (cur ? NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.58, alpha: 1) : NSColor(white: 0.66, alpha: 1)).setFill()
            r.fill()
            // Raised bevel for normal buttons, sunken for the current one.
            (cur ? dark : light).setFill()
            NSRect(x: r.minX, y: r.minY, width: r.width, height: 1).fill()
            NSRect(x: r.minX, y: r.minY, width: 1, height: r.height).fill()
            (cur ? light : dark).setFill()
            NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
            NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()

            let label = String(i + 1) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(8, min(r.height, r.width) * 0.55), weight: .bold),
                .foregroundColor: cur ? NSColor.white : NSColor.black,
            ]
            let sz = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
        }
    }

    // NeXT-style clock: time in a recessed dark window, below it a calendar page
    // with weekday, big date number, and month.
    private func drawClock(_ s: CGFloat) {
        let now = Date()
        let m = (s * 0.08).rounded()
        let w = s - 2 * m

        let tf = DateFormatter()
        tf.setLocalizedDateFormatFromTemplate("jmm")
        var timeStr = tf.string(from: now)
        timeStr = timeStr.replacingOccurrences(of: "\u{202F}", with: " ")

        // Time window
        let timeH = (s * 0.22).rounded()
        let timeRect = NSRect(x: m, y: m, width: w, height: timeH)
        NSColor(white: 0.06, alpha: 1).setFill()
        timeRect.fill()
        NSColor(white: 0.6, alpha: 1).setFill()
        NSRect(x: timeRect.minX, y: timeRect.maxY - 1, width: w, height: 1).fill()
        var tSize = timeH * 0.72
        var tAttrs: [NSAttributedString.Key: Any] = [:]
        repeat {
            tAttrs = [.font: NSFont.monospacedDigitSystemFont(ofSize: tSize, weight: .medium),
                      .foregroundColor: NSColor(calibratedRed: 1, green: 0.72, blue: 0.25, alpha: 1)]
            if (timeStr as NSString).size(withAttributes: tAttrs).width <= w - 4 || tSize <= 6 { break }
            tSize -= 0.5
        } while true
        let tsz = (timeStr as NSString).size(withAttributes: tAttrs)
        (timeStr as NSString).draw(at: NSPoint(x: timeRect.midX - tsz.width / 2, y: timeRect.midY - tsz.height / 2),
                                   withAttributes: tAttrs)

        // Calendar page
        let pageTop = timeRect.maxY + (s * 0.04).rounded()
        let page = NSRect(x: m, y: pageTop, width: w, height: s - m - pageTop)
        NSColor(white: 0.95, alpha: 1).setFill()
        page.fill()
        NSColor(white: 0.1, alpha: 1).setStroke()
        NSBezierPath(rect: page.insetBy(dx: 0.5, dy: 0.5)).stroke()

        let df = DateFormatter()
        df.dateFormat = "EEE"
        let wd = df.string(from: now).uppercased()
        df.dateFormat = "d"
        let day = df.string(from: now)
        df.dateFormat = "MMM"
        let mon = df.string(from: now).uppercased()

        let small = max(7, (s * 0.11).rounded())
        let lines: [(String, NSFont, NSColor)] = [
            (wd, NSFont.systemFont(ofSize: small, weight: .bold), NSColor(calibratedRed: 0.75, green: 0.1, blue: 0.1, alpha: 1)),
            (day, NSFont.systemFont(ofSize: max(11, (s * 0.24).rounded()), weight: .bold), .black),
            (mon, NSFont.systemFont(ofSize: small, weight: .semibold), NSColor(white: 0.25, alpha: 1)),
        ]
        let sizes = lines.map { ($0.0 as NSString).size(withAttributes: [.font: $0.1]) }
        let gap = max(0, (page.height - sizes.reduce(0) { $0 + $1.height }) / 4)
        var y = page.minY + gap
        for (i, l) in lines.enumerated() {
            (l.0 as NSString).draw(at: NSPoint(x: page.midX - sizes[i].width / 2, y: y),
                                   withAttributes: [.font: l.1, .foregroundColor: l.2])
            y += sizes[i].height + gap
        }
    }

    private func border(_ color: NSColor) {
        color.setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        p.lineWidth = 3
        p.stroke()
    }

    private func drawLabel(_ s: CGFloat) {
        let font = NSFont.systemFont(ofSize: max(8, (s * 0.14).rounded()), weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white, .shadow: shadow, .paragraphStyle: para,
        ]
        let h = font.pointSize + 4
        (displayName as NSString).draw(in: NSRect(x: 2, y: s - h - 1, width: s - 4, height: h), withAttributes: attrs)
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        controller.hover.hide()
        downPoint = convert(e.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with e: NSEvent) {
        guard !dragging, let start = downPoint else { return }
        let p = convert(e.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 5 else { return }
        let pb = NSPasteboardItem()
        switch role {
        case .pinned(let i):
            if controller.config.locked { return }
            pb.setString(String(i), forType: .dockIndex)           // reorder within the dock only
        case .running:
            pb.setString(URL(fileURLWithPath: item.path).absoluteString, forType: .fileURL)  // drag up to pin
        }
        dragging = true
        let di = NSDraggingItem(pasteboardWriter: pb)
        di.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [di], event: e, source: self)
    }

    override func mouseUp(with e: NSEvent) {
        defer { downPoint = nil }
        if dragging { return }
        if e.modifierFlags.contains(.control) { showMenu(e); return }
        if item.kind == .spaces {
            if let i = desktopIndex(at: convert(e.locationInWindow, from: nil)) { controller.switchToDesktop(i, from: self) }
            return
        }
        controller.activate(self, clickCount: e.clickCount)
    }

    override func rightMouseDown(with e: NSEvent) { controller.hover.hide(); showMenu(e) }

    private func showMenu(_ e: NSEvent) {
        NSMenu.popUpContextMenu(controller.menu(for: self), with: e, for: self)
    }

    func popUpFolderMenu() {
        let m = controller.folderMenu(item.path)
        let x = controller.config.edge == "left" ? bounds.maxX : -m.size.width
        m.popUp(positioning: nil, at: NSPoint(x: x, y: 0), in: self)
    }

    private func snapshot() -> NSImage {
        let img = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            img.addRepresentation(rep)
        }
        return img
    }

    // MARK: Drag source (dragging out of the dock does nothing, so nothing gets removed by accident)

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        controller.suspendRebuild = true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller.suspendRebuild = false
        let c = controller
        DispatchQueue.main.async { c.rebuild(force: true) }
    }
}

// MARK: - "+" tile at the bottom: options menu and an always-visible drop target

final class PlusView: NSView {
    unowned let controller: DockController

    init(frame: NSRect, controller: DockController) {
        self.controller = controller
        super.init(frame: frame)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverTracking(self)
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hoverTracking(self) }

    override func mouseEntered(with e: NSEvent) {
        controller.hover.show("NeXTDock options — drop files here to pin", beside: self, edge: controller.config.edge)
    }

    override func mouseExited(with e: NSEvent) { controller.hover.hide() }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.17, alpha: 0.92).setFill()
        bounds.fill()
        NSColor(white: 0.45, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let font = NSFont.systemFont(ofSize: bounds.height * 0.7, weight: .light)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.75, alpha: 1)]
        let str = "+" as NSString
        let sz = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
    }

    override func mouseDown(with e: NSEvent) {
        controller.hover.hide()
        NSMenu.popUpContextMenu(controller.dockMenu(), with: e, for: self)
    }
    override func rightMouseDown(with e: NSEvent) { mouseDown(with: e) }
}

// MARK: - App entry

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: DockController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let me = Bundle.main.bundleIdentifier ?? "local.NeXTDock"
        if NSRunningApplication.runningApplications(withBundleIdentifier: me).count > 1 {
            NSApp.terminate(nil)
            return
        }
        controller = DockController()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
