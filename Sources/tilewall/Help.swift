import Cocoa
import TilewallCore

/// The actions a hotkey can trigger, in the order they are shown.
let hotkeyActions: [(name: String, title: String, detail: String)] = [
    ("toggle", "Include or Exclude Focused Window", "Adds the focused window to the tiles, or takes it out."),
    ("next", "Focus Next Tile", "Moves focus to the next tile, which then grows."),
    ("prev", "Focus Previous Tile", "Moves focus to the previous tile."),
    ("fill", "Fill Screen", "Puts every group back to filling its whole screen."),
    ("send", "Send Tile to Next Display", "Moves the focused tile to the group on the next display."),
    ("retile", "Retile Now", "Lays the tiles out again."),
    ("pause", "Pause or Resume Tiling", "While paused, windows stay wherever you put them."),
    ("help", "Help", "Opens a window that explains Tilewall and lists the hotkeys."),
]

final class HelpWindow {
    private var window: NSWindow?

    func show(config: Config) {
        let window = self.window ?? makeWindow()
        self.window = window
        (window.contentView?.subviews.first as? NSScrollView).flatMap { $0.documentView as? NSTextView }?
            .textStorage?.setAttributedString(text(config: config))
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Tilewall Help"
        window.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = window.contentView!.bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 20, height: 20)
        window.contentView!.addSubview(scroll)
        return window
    }

    private func text(config: Config) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        paragraph.lineSpacing = 2
        func add(_ string: String, font: NSFont = body, color: NSColor = .labelColor, style: NSParagraphStyle? = nil) {
            out.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style ?? paragraph]))
        }
        func heading(_ string: String) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = out.length == 0 ? 0 : 14
            style.paragraphSpacing = 6
            add(string + "\n", font: .systemFont(ofSize: 15, weight: .semibold), style: style)
        }

        heading("What Tilewall does")
        add("Tilewall arranges windows as tiles in a grid, so you can watch all of them at once. ")
        add("The focused tile grows to a quarter of the group. The other tiles keep their place and shrink.\n")
        add("Click a tile, or use the hotkeys below, to choose which one is large.\n")

        heading("Which windows are tiles")
        let rules = config.rules.map { rule in rule.title.map { "\(rule.app) with a title matching \($0)" } ?? rule.app }
        add("Windows of these apps are tiled automatically: \(rules.isEmpty ? "none" : rules.joined(separator: ", ")).\n")
        add("Any other window can be added by hand, and any tile can be taken out, with Include or Exclude Focused Window.\n")
        add("Tile All tiles every matching window again. Untile All releases every tile so the windows can be moved freely.\n")
        add("Tabs are not windows. Use Split Tabs Into Windows to turn each tab into a tile.\n")

        heading("The group works like one window")
        add("Drag any tile by its title bar to move the whole group.\n")
        add("Resize any tile by an edge or corner to scale the whole group, for example to see the desktop behind it.\n")
        add("Fill Screen puts the group back to full size.\n")
        add("Drop the group on another display and it fills that screen.\n")
        add("Tiling can be switched off per display in the menu. Windows there are left alone, also when that display is unplugged.\n")
        add("Each display has its own group. Send Tile to Next Display moves a tile between them.\n")

        heading("Hotkeys")
        let table = NSMutableParagraphStyle()
        table.tabStops = [NSTextTab(textAlignment: .left, location: 70)]
        table.headIndent = 70
        table.paragraphSpacing = 6
        for action in hotkeyActions {
            let keys = KeyCombo(config.hotkeys[action.name] ?? "")?.display ?? "not set"
            add(keys + "\t", font: .monospacedSystemFont(ofSize: 13, weight: .medium), style: table)
            add(action.title + "\n", font: .systemFont(ofSize: 13, weight: .medium), style: table)
            add("\t" + action.detail + "\n", color: .secondaryLabelColor, style: table)
        }

        heading("Settings")
        add("Hotkeys, rules, gap and backdrop color are set in\n")
        add(Paths.config.path + "\n", font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        add("Choose Reload Config after editing it. Run ")
        add("tilewall help", font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        add(" in a terminal for the command line.\n")

        heading("About")
        add("Tilewall \(App.version) is free and open source: \(App.sourceURL)\n")
        if !App.supportURL.isEmpty { add("If it is useful to you, you can support it: \(App.supportURL)\n") }
        return out
    }
}
