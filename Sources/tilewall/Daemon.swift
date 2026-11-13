import ApplicationServices
import Cocoa
import TilewallCore

final class Daemon: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var manager: WindowManager!
    private let hotkeys = Hotkeys()
    private var statusItem: NSStatusItem!
    private var menuWindows: [Window] = []
    private let help = HelpWindow()

    static func run() -> Never {
        if IPC.send("ping") != nil {
            print("tilewall is already running")
            exit(0)
        }
        let app = NSApplication.shared
        let daemon = Daemon()
        app.delegate = daemon
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(daemon) { app.run() }
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config: Config
        do {
            config = try ConfigStore.load()
        } catch {
            log("invalid config at \(Paths.config.path): \(error)")
            exit(1)
        }
        manager = WindowManager(config: config)
        do {
            try IPC.serve { [weak self] command, reply in self?.handle(command, reply: reply) }
        } catch {
            log(error.localizedDescription)
            exit(1)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "tilewall")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        registerHotkeys()
        waitForAccessibility()
    }

    private func waitForAccessibility() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            log("tilewall \(App.version) started, config \(Paths.config.path)")
            manager.start()
        } else {
            log("waiting for Accessibility permission: System Settings > Privacy & Security > Accessibility")
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                log("Accessibility granted, started")
                self?.manager.start()
            }
        }
    }

    private func perform(_ action: String) {
        switch action {
        case "toggle": _ = manager.setManaged(nil)
        case "next": _ = manager.cycle(1)
        case "prev": _ = manager.cycle(-1)
        case "fill": _ = manager.fillScreens()
        case "send": _ = manager.send(id: nil)
        case "retile": manager.retile()
        case "pause": _ = manager.setPaused(!manager.paused)
        case "help": help.show(config: manager.config)
        default: break
        }
    }

    private func registerHotkeys() {
        hotkeys.unregisterAll()
        let known = Set(hotkeyActions.map(\.name))
        for (name, text) in manager.config.hotkeys.sorted(by: { $0.key < $1.key }) where !text.isEmpty {
            guard known.contains(name) else { log("unknown hotkey action \"\(name)\""); continue }
            guard let combo = KeyCombo(text) else { log("cannot parse hotkey \"\(text)\" for \(name)"); continue }
            if !hotkeys.register(combo, action: { [weak self] in self?.perform(name) }) {
                log("hotkey \(text) for \(name) is taken by another app")
            }
        }
    }

    private func handle(_ command: String, reply: @escaping (String) -> Void) {
        let parts = command.split(separator: " ").map(String.init)
        let id = parts.count > 1 ? CGWindowID(parts[1]) : nil
        switch parts.first ?? "" {
        case "ping": reply("pong")
        case "status", "list": reply(manager.status(all: parts.contains("--all")))
        case "toggle": reply(id.map { manager.setManaged(nil, id: $0) } ?? manager.setManaged(nil))
        case "include": reply(id.map { manager.setManaged(true, id: $0) } ?? manager.setManaged(true))
        case "exclude": reply(id.map { manager.setManaged(false, id: $0) } ?? manager.setManaged(false))
        case "focus":
            switch parts.dropFirst().first {
            case "next": reply(manager.cycle(1))
            case "prev": reply(manager.cycle(-1))
            default: reply(id.map { manager.focus(id: $0) } ?? "error: usage: tilewall focus next|prev|<window id>")
            }
        case "retile": manager.retile(); reply("retiled")
        case "orientation":
            guard parts.count == 2, let orientation = Orientation(rawValue: parts[1]) else {
                return reply(parts.count == 1 ? "orientation: \(manager.config.orientation.rawValue)" : "error: usage: tilewall orientation [landscape|portrait]")
            }
            reply(manager.setOrientation(orientation))
        case "all": reply(manager.tileAll())
        case "none": reply(manager.untileAll())
        case "fill": reply(manager.fillScreens())
        case "send": reply(manager.send(id: id))
        case "area":
            let numbers = parts.dropFirst().compactMap(Double.init)
            guard numbers.count == 4, parts.count == 5 else { reply("error: usage: tilewall area <x> <y> <width> <height>"); break }
            reply(manager.setArea(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])))
        case "pause": reply(manager.setPaused(true))
        case "resume": reply(manager.setPaused(false))
        case "reload":
            let result = manager.reload()
            registerHotkeys()
            reply(result)
        case "untab": manager.untab(done: reply)
        case "guide": help.show(config: manager.config); reply("help window opened")
        case "corners":
            switch parts.dropFirst().first {
            case "square": Corners.setSquare(true)
            case "round": Corners.setSquare(false)
            case nil: break
            default: return reply("error: usage: tilewall corners [square|round]")
            }
            reply("corners: \(Corners.isSquare ? "square" : "round") for apps started from now on, restart an app to apply")
        case "attach":
            guard parts.count == 2 else { return reply("error: usage: tilewall attach <tmux session>") }
            do { try TerminalSessions.open(parts[1]); reply("opened \(parts[1])") } catch { reply("error: \(error.localizedDescription)") }
        case "sessions": reply(TerminalSessions.attached().joined(separator: "\n"))
        case "quit", "stop":
            reply("bye")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                unlink(Paths.socket.path)
                exit(0)
            }
        default: reply("error: unknown command \"\(command)\", try: tilewall help")
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult
        func add(_ title: String, _ action: Selector, hotkey: String? = nil, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            // Shows the global hotkey next to the item, the same way app menus show shortcuts.
            if let hotkey, let combo = KeyCombo(manager.config.hotkeys[hotkey] ?? ""), let key = Daemon.keyEquivalent(combo.key) {
                item.keyEquivalent = key
                var mask: NSEvent.ModifierFlags = []
                if combo.modifiers & KeyCombo.control != 0 { mask.insert(.control) }
                if combo.modifiers & KeyCombo.option != 0 { mask.insert(.option) }
                if combo.modifiers & KeyCombo.shift != 0 { mask.insert(.shift) }
                if combo.modifiers & KeyCombo.cmd != 0 { mask.insert(.command) }
                item.keyEquivalentModifierMask = mask
            }
            menu.addItem(item)
            return item
        }
        func title(_ name: String) -> String { hotkeyActions.first { $0.name == name }!.title }

        let version = NSMenuItem(title: "tilewall \(App.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        add("Tile All", #selector(tileAll))
        add("Untile All", #selector(untileAll))
        add(title("toggle"), #selector(menuAction(_:)), hotkey: "toggle").representedObject = "toggle"
        add(title("next"), #selector(menuAction(_:)), hotkey: "next").representedObject = "next"
        add(title("prev"), #selector(menuAction(_:)), hotkey: "prev").representedObject = "prev"
        if NSScreen.screens.count > 1 {
            add(title("send"), #selector(menuAction(_:)), hotkey: "send").representedObject = "send"
        }
        menu.addItem(.separator())
        add(title("fill"), #selector(menuAction(_:)), hotkey: "fill").representedObject = "fill"
        add(title("retile"), #selector(menuAction(_:)), hotkey: "retile").representedObject = "retile"
        add(manager.paused ? "Resume Tiling" : "Pause Tiling", #selector(menuAction(_:)), hotkey: "pause").representedObject = "pause"
        add("Portrait Layout", #selector(toggleOrientation)).state = manager.config.orientation == .portrait ? .on : .off
        add("Split Tabs Into Windows", #selector(untabNow))
        add("Square Window Corners", #selector(toggleCorners)).state = Corners.isSquare ? .on : .off
        menu.addItem(.separator())

        menuWindows = manager.managedWindows()
        if menuWindows.isEmpty {
            let empty = NSMenuItem(title: "No tiles on this space", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let focused = manager.focusedWindow()?.id
        let oneApp = Set(menuWindows.map(\.app)).count == 1
        for (i, w) in menuWindows.enumerated() {
            let item = add(Daemon.menuTitle(for: w, withApp: !oneApp), #selector(focusTile(_:)), tag: i)
            item.state = w.id == focused ? .on : .off
            item.toolTip = "\(w.app): \(w.title)"
        }
        menu.addItem(.separator())
        add("tilewall Help", #selector(menuAction(_:)), hotkey: "help").representedObject = "help"
        if !App.supportURL.isEmpty { add("Support tilewall…", #selector(openSupport)) }
        add("Reload Config", #selector(reloadConfig))
        if App.isBundled { add("Launch at Login", #selector(toggleLogin)).state = App.launchesAtLogin ? .on : .off }
        add("Quit tilewall", #selector(quit))
    }

    /// Menu titles are cut in the middle, because window titles tend to differ at the start and at the end.
    static func menuTitle(for window: Window, withApp: Bool, limit: Int = 48) -> String {
        var title = window.title.isEmpty ? window.app : window.title
        // A tmux client is best named by its session.
        if let session = TerminalSessions.session(inTitle: title) { title = session }
        if withApp, title != window.app { title = "\(window.app): \(title)" }
        guard title.count > limit else { return title }
        let head = (limit - 1) / 2
        return String(title.prefix(head)) + "…" + String(title.suffix(limit - 1 - head))
    }

    static func keyEquivalent(_ key: String) -> String? {
        if key.count == 1 { return key }
        let special: [String: Int] = ["left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey, "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey]
        if let code = special[key], let scalar = UnicodeScalar(code) { return String(Character(scalar)) }
        return ["tab": "\t", "space": " ", "return": "\r", "escape": "\u{1b}"][key]
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        perform(action)
    }
    @objc private func toggleCorners() {
        Corners.setSquare(!Corners.isSquare)
        let alert = NSAlert()
        alert.messageText = Corners.isSquare ? "Square window corners are on" : "Square window corners are off"
        alert.informativeText = """
        macOS applies this when an app starts, and to every app, not only to tiles. \
        Apps that are already open keep their corners until you quit and reopen them.

        tilewall does not restart apps for you. Before quitting Terminal, make sure nothing you need is running in it.
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func openSupport() { URL(string: App.supportURL).map { _ = NSWorkspace.shared.open($0) } }
    @objc private func toggleLogin() { App.launchesAtLogin.toggle() }
    @objc private func toggleOrientation() {
        log(manager.setOrientation(manager.config.orientation == .portrait ? .landscape : .portrait))
    }
    @objc private func tileAll() { log(manager.tileAll()) }
    @objc private func untileAll() { log(manager.untileAll()) }
    @objc private func untabNow() { manager.untab { log($0) } }
    @objc private func reloadConfig() { log(manager.reload()); registerHotkeys() }
    @objc private func focusTile(_ sender: NSMenuItem) {
        guard menuWindows.indices.contains(sender.tag) else { return }
        manager.focus(menuWindows[sender.tag])
    }
    @objc private func quit() {
        unlink(Paths.socket.path)
        exit(0)
    }
}
