import ApplicationServices
import Cocoa
import TilewallCore

struct Window {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let bundleID: String?
    let title: String
    let element: AXUIElement
}

private struct SavedState: Codable {
    var included: [CGWindowID] = []
    var excluded: [CGWindowID] = []
    var order: [CGWindowID]? = []
    var areas: [CGDirectDisplayID: CGRect]? = [:]
    var homes: [CGWindowID: CGDirectDisplayID]? = [:]
}

private struct Group {
    let screen: CGDirectDisplayID
    /// The rectangle this group fills: the whole screen, or wherever the user dragged it.
    let area: CGRect
    let windows: [Window]
}

/// Decides which windows are tiles, watches focus, and applies the layout.
final class WindowManager {
    private(set) var config: Config
    private(set) var paused = false
    /// Windows added by hand that no rule matches.
    private var included: Set<CGWindowID> = []
    /// Windows a rule matches that were removed by hand.
    private var excluded: Set<CGWindowID> = []
    /// Stable tile order: first seen, first placed.
    private var order: [CGWindowID] = []
    private var lastFocus: [CGDirectDisplayID: CGWindowID] = [:]
    private var applied: [CGWindowID: (target: CGRect, result: CGRect)] = [:]
    /// Group areas the user moved or resized. A display without an entry fills its whole visible frame.
    private var areas: [CGDirectDisplayID: CGRect] = [:]
    /// The display whose group a window belongs to. Sticky, so a dragged group keeps its tiles.
    private var homes: [CGWindowID: CGDirectDisplayID] = [:]
    private var lastGroups: [Group] = []
    /// Set while a mouse button is down and the focused tile no longer sits where tilewall put it.
    private var userChangedTile = false
    /// The group that held the focused window at the last retile, nil when focus was outside every group.
    private var focusedGroup: CGDirectDisplayID?
    private let backdrop = Backdrop()
    private static let minGroupSize = CGSize(width: 320, height: 200)
    private var observers: [pid_t: AXObserver] = [:]
    private var pending: DispatchWorkItem?
    private var poll: Timer?

    init(config: Config) {
        self.config = config
        if let data = try? Data(contentsOf: Paths.state), let saved = try? JSONDecoder().decode(SavedState.self, from: data) {
            included = Set(saved.included)
            excluded = Set(saved.excluded)
            order = saved.order ?? []
            areas = saved.areas ?? [:]
            homes = saved.homes ?? [:]
        }
    }

    // MARK: Lifecycle

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // A freshly launched app often rejects observers until its accessibility tree is up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.observe(app) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observers[app.processIdentifier] = nil
            self?.scheduleRetile()
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleRetile() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRetile()
        }
        NSWorkspace.shared.runningApplications.forEach(observe)
        // Closed windows and anything the notifications miss are picked up by this slow reconcile.
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.retile() }
        retile()
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, observers[pid] == nil, pid != getpid() else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue().scheduleRetile()
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    func scheduleRetile(after delay: TimeInterval = 0.03) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.retile() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Window discovery

    private func windows(of app: NSRunningApplication) -> [Window] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)
        return element.elements(kAXWindowsAttribute).compactMap { describe($0, app: app) }
    }

    private func describe(_ element: AXUIElement, app: NSRunningApplication) -> Window? {
        guard element.string(kAXSubroleAttribute) == (kAXStandardWindowSubrole as String),
              element.bool(kAXMinimizedAttribute) != true,
              element.bool("AXFullScreen") != true,
              let id = element.windowID else { return nil }
        return Window(id: id, pid: app.processIdentifier, app: app.localizedName ?? "?", bundleID: app.bundleIdentifier,
                      title: element.string(kAXTitleAttribute) ?? "", element: element)
    }

    private func matchesRule(_ w: Window) -> Bool {
        config.rules.contains { $0.matches(bundleID: w.bundleID, appName: w.app, title: w.title) }
    }

    private func isManaged(_ w: Window) -> Bool {
        matchesRule(w) ? !excluded.contains(w.id) : included.contains(w.id)
    }

    /// Window id to owning process, for the windows the window server reports under these options.
    private func windowOwners(_ options: CGWindowListOption) -> [CGWindowID: pid_t] {
        let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        var owners: [CGWindowID: pid_t] = [:]
        for entry in info {
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            owners[id] = pid
        }
        return owners
    }

    /// Standard windows that are visible on the current spaces.
    /// With `candidatesOnly` only apps that can own a tile are queried, which keeps the periodic reconcile cheap.
    private func visibleWindows(candidatesOnly: Bool = false) -> [Window] {
        let onScreen = windowOwners([.optionOnScreenOnly, .excludeDesktopElements])
        let includedPids = Set(included.compactMap { onScreen[$0] })
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != getpid() }
            .filter { app in
                guard candidatesOnly else { return true }
                return includedPids.contains(app.processIdentifier) || config.rules.contains {
                    Rule(app: $0.app).matches(bundleID: app.bundleIdentifier, appName: app.localizedName, title: "")
                }
            }
            .flatMap(windows(of:))
            .filter { onScreen[$0.id] != nil }
    }

    func focusedWindow() -> Window? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)
        guard let window = element.element(kAXFocusedWindowAttribute) else { return nil }
        return describe(window, app: app)
    }

    /// Managed windows grouped by the display they belong to, each group in tile order.
    private func tiles() -> [Group] {
        let managed = visibleWindows(candidatesOnly: true).filter(isManaged)
        let known = (order.count, homes)
        for w in managed where !order.contains(w.id) { order.append(w.id) }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let screens = screenAreas()
        let screenIDs = Set(screens.map(\.id))
        let desktop = screens.reduce(CGRect.null) { $0.union($1.area) }
        var clamped: [CGDirectDisplayID: CGRect] = [:]
        for screen in screens {
            guard let area = areas[screen.id] else { continue }
            clamped[screen.id] = Layout.clamp(area, screen: screen.area, desktop: desktop)
        }
        let areasChanged = clamped != areas
        areas = clamped
        var groups: [CGDirectDisplayID: [Window]] = [:]
        for w in managed {
            if let home = homes[w.id], screenIDs.contains(home) {
                groups[home, default: []].append(w)
                continue
            }
            guard let frame = w.element.frame, !screens.isEmpty else { continue }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let home = screens.first { $0.area.contains(center) } ?? screens.min {
                distance(center, to: $0.area) < distance(center, to: $1.area)
            }!
            homes[w.id] = home.id
            groups[home.id, default: []].append(w)
        }
        if known != (order.count, homes) || areasChanged { save() }
        lastGroups = screens.compactMap { screen in
            guard let group = groups[screen.id] else { return nil }
            return Group(screen: screen.id, area: areas[screen.id] ?? screen.area,
                         windows: group.sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) })
        }
        return lastGroups
    }

    private func distance(_ p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    // MARK: Tiling

    func retile() {
        pending?.cancel()
        pending = nil
        guard !paused else { return backdrop.hide() }
        // Resizing a window under a pressed mouse button turns the click into a drag or a text selection.
        // While the button is down tilewall only follows: a dragged tile takes the rest of its group along.
        guard NSEvent.pressedMouseButtons == 0 else {
            followDrag()
            return scheduleRetile(after: 0.03)
        }

        let focus = focusedWindow()?.id
        var groups = tiles()
        if userChangedTile {
            userChangedTile = false
            if adoptDropOnOtherDisplay(focus: focus, in: groups) || adoptUserResize(focus: focus, in: groups) { groups = tiles() }
        }
        raiseGroupIfEntered(focus: focus, groups: groups)
        var alive: Set<CGWindowID> = []
        for group in groups {
            let ids = group.windows.map(\.id)
            alive.formUnion(ids)
            if let focus, ids.contains(focus) { lastFocus[group.screen] = focus }
            let focusIndex = lastFocus[group.screen].flatMap { ids.firstIndex(of: $0) }
            Layout.arrange(count: ids.count, focused: focusIndex, area: group.area, options: config.layoutOptions) { index, target in
                let window = group.windows[index]
                // Apps such as Terminal snap to whole character cells, so compare against what the last apply produced.
                if let last = applied[window.id], last.target == target, window.element.frame == last.result {
                    return last.result.size
                }
                window.element.setFrame(target)
                let result = window.element.frame ?? target
                applied[window.id] = (target, result)
                return result.size
            }
        }
        forgetClosedWindows(visible: alive)
        refreshBackdrop()
    }

    private func refreshBackdrop() {
        let frames = lastGroups.map { group in
            (screen: group.screen,
             frame: group.windows.compactMap { applied[$0.id]?.result }.reduce(CGRect.null) { $0.union($1) },
             tiles: group.windows.map(\.id))
        }
        backdrop.update(frames, color: Backdrop.color(config.backdrop))
    }

    /// A group behaves like one window: when focus enters it from outside, all of its tiles come to the front.
    private func raiseGroupIfEntered(focus: CGWindowID?, groups: [Group]) {
        let group = groups.first { g in g.windows.contains { $0.id == focus } }
        defer { focusedGroup = group?.screen }
        guard let group, group.screen != focusedGroup, let focused = group.windows.first(where: { $0.id == focus }) else { return }
        for window in group.windows where window.id != focused.id {
            AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        }
        AXUIElementPerformAction(focused.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(focused.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// Called repeatedly while a mouse button is down. Moves the whole group along with a dragged tile.
    private func followDrag() {
        guard let dragged = focusedWindow(), let last = applied[dragged.id], let now = dragged.element.frame,
              now != last.result, let group = lastGroups.first(where: { g in g.windows.contains { $0.id == dragged.id } }) else { return }
        userChangedTile = true
        // A changed size is a resize in progress: the group is rescaled once, when the button is released.
        guard abs(now.width - last.result.width) < 2, abs(now.height - last.result.height) < 2 else { return }
        let dx = now.minX - last.result.minX
        let dy = now.minY - last.result.minY
        areas[group.screen] = group.area.offsetBy(dx: dx, dy: dy)
        lastGroups = lastGroups.map { $0.screen == group.screen ? Group(screen: $0.screen, area: $0.area.offsetBy(dx: dx, dy: dy), windows: $0.windows) : $0 }
        for window in group.windows {
            guard let previous = applied[window.id] else { continue }
            let moved = (target: previous.target.offsetBy(dx: dx, dy: dy), result: previous.result.offsetBy(dx: dx, dy: dy))
            applied[window.id] = moved
            guard window.id != dragged.id else { continue }
            var origin = moved.result.origin
            if let value = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, value)
            }
        }
        refreshBackdrop()
    }

    /// After the button is released: a group dropped on another display moves there and fills that screen.
    private func adoptDropOnOtherDisplay(focus: CGWindowID?, in groups: [Group]) -> Bool {
        guard let focus, let group = groups.first(where: { g in g.windows.contains { $0.id == focus } }),
              let primary = NSScreen.screens.first else { return false }
        let mouse = NSEvent.mouseLocation
        let drop = CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)
        let screens = screenAreas()
        guard let target = screens.first(where: { $0.area.contains(drop) })
                ?? screens.min(by: { distance(drop, to: $0.area) < distance(drop, to: $1.area) }),
              target.id != group.screen else { return false }
        for window in group.windows { homes[window.id] = target.id }
        // Both screens go back to full size: the tiles join whatever is already tiled on the target.
        areas[group.screen] = nil
        areas[target.id] = nil
        applied.removeAll()
        save()
        return true
    }

    /// After the button is released: a tile the user resized rescales its whole group. Returns true when an area changed.
    private func adoptUserResize(focus: CGWindowID?, in groups: [Group]) -> Bool {
        defer { save() }
        guard let focus, let last = applied[focus],
              let group = groups.first(where: { g in g.windows.contains { $0.id == focus } }),
              let now = group.windows.first(where: { $0.id == focus })?.element.frame, now != last.result else { return false }
        areas[group.screen] = Layout.area(group.area, followingTileFrom: last.result, to: now, minSize: WindowManager.minGroupSize)
        return true
    }

    private func forgetClosedWindows(visible: Set<CGWindowID>) {
        applied = applied.filter { visible.contains($0.key) }
        // Windows on other spaces still exist and keep their slot and their manual include or exclude.
        let existing = Set(windowOwners([.optionAll]).keys)
        let before = (included, excluded, order)
        homes = homes.filter { existing.contains($0.key) }
        order.removeAll { !existing.contains($0) }
        included.formIntersection(existing)
        excluded.formIntersection(existing)
        if before != (included, excluded, order) { save() }
    }

    private func save() {
        let state = SavedState(included: included.sorted(), excluded: excluded.sorted(), order: order, areas: areas, homes: homes)
        do {
            try FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: Paths.state, options: .atomic)
        } catch {
            log("cannot save state: \(error.localizedDescription)")
        }
    }

    // MARK: Commands

    func setPaused(_ value: Bool) -> String {
        paused = value
        if value { backdrop.hide() }
        if !value {
            applied.removeAll()
            retile()
        }
        return value ? "paused" : "resumed"
    }

    /// Switches between rows and columns, and stores the choice in the config file.
    func setOrientation(_ orientation: Orientation) -> String {
        config.orientation = orientation
        do { try ConfigStore.save(config) } catch { return "error: cannot write the config: \(error.localizedDescription)" }
        applied.removeAll()
        retile()
        return "orientation: \(orientation.rawValue)"
    }

    func reload() -> String {
        do {
            config = try ConfigStore.load()
            applied.removeAll()
            retile()
            return "config reloaded"
        } catch {
            return "error: invalid config, keeping the old one: \(error)"
        }
    }

    /// include: true adds, false removes, nil flips.
    func setManaged(_ include: Bool?, window: Window? = nil) -> String {
        guard let w = window ?? focusedWindow() else { return "error: no focused standard window" }
        let want = include ?? !isManaged(w)
        if matchesRule(w) {
            if want { excluded.remove(w.id) } else { excluded.insert(w.id) }
        } else {
            if want { included.insert(w.id) } else { included.remove(w.id) }
        }
        save()
        applied.removeAll()
        retile()
        return "\(want ? "included" : "excluded") \(w.id) \(w.app): \(w.title)"
    }

    func setManaged(_ include: Bool?, id: CGWindowID) -> String {
        guard let w = visibleWindows().first(where: { $0.id == id }) else { return "error: no visible window with id \(id)" }
        return setManaged(include, window: w)
    }

    func focus(_ w: Window) {
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        scheduleRetile()
    }

    func focus(id: CGWindowID) -> String {
        guard let w = visibleWindows().first(where: { $0.id == id }) else { return "error: no visible window with id \(id)" }
        focus(w)
        return "focused \(w.id) \(w.app): \(w.title)"
    }

    /// Moves focus to the next or previous tile on the screen of the focused tile.
    func cycle(_ step: Int) -> String {
        let groups = tiles()
        let current = focusedWindow()?.id
        guard let group = groups.first(where: { g in g.windows.contains { $0.id == current } }) ?? groups.first,
              !group.windows.isEmpty else { return "error: no tiles" }
        let n = group.windows.count
        let index = group.windows.firstIndex { $0.id == current }.map { (($0 + step) % n + n) % n } ?? 0
        focus(group.windows[index])
        return "focused \(group.windows[index].id) \(group.windows[index].app): \(group.windows[index].title)"
    }

    func managedWindows() -> [Window] { tiles().flatMap(\.windows) }

    /// Tiles every window the rules match again, undoing all manual excludes, and resumes tiling.
    func tileAll() -> String {
        excluded.removeAll()
        paused = false
        save()
        applied.removeAll()
        retile()
        return "tiling \(lastGroups.reduce(0) { $0 + $1.windows.count }) windows"
    }

    /// Releases every tile on the current space. The windows stay where they are and can be moved freely.
    func untileAll() -> String {
        let tiles = managedWindows()
        for w in tiles {
            if matchesRule(w) { excluded.insert(w.id) } else { included.remove(w.id) }
        }
        save()
        applied.removeAll()
        retile()
        return "released \(tiles.count) windows"
    }

    /// Puts every group back to filling its whole screen.
    func fillScreens() -> String {
        areas.removeAll()
        save()
        applied.removeAll()
        retile()
        return "groups fill their screens"
    }

    /// Sets the area of the group that holds the focused tile, or of the first group. Accessibility coordinates.
    func setArea(_ area: CGRect) -> String {
        let groups = tiles()
        let focus = focusedWindow()?.id
        guard let group = groups.first(where: { g in g.windows.contains { $0.id == focus } }) ?? groups.first else { return "error: no tiles" }
        guard area.width >= WindowManager.minGroupSize.width, area.height >= WindowManager.minGroupSize.height else {
            return "error: a group must be at least \(Int(WindowManager.minGroupSize.width))x\(Int(WindowManager.minGroupSize.height))"
        }
        areas[group.screen] = area
        save()
        retile()
        return "group \(group.screen) at \(describe(area))"
    }

    /// Moves a tile to the group of the next display.
    func send(id: CGWindowID?) -> String {
        guard let w = id.map({ wanted in visibleWindows().first { $0.id == wanted } }) ?? focusedWindow() else { return "error: no such window" }
        guard isManaged(w) else { return "error: \(w.id) is not a tile" }
        let screens = screenAreas().map(\.id)
        guard screens.count > 1 else { return "error: there is only one display" }
        let current = homes[w.id].flatMap { screens.firstIndex(of: $0) } ?? 0
        homes[w.id] = screens[(current + 1) % screens.count]
        save()
        retile()
        return "sent \(w.id) to display \(homes[w.id]!)"
    }

    private func describe(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }

    func status(all: Bool) -> String {
        let focus = focusedWindow()?.id
        let rules = config.rules.map { rule in rule.title.map { "\(rule.app) /\($0)/" } ?? rule.app }
        var lines = ["tilewall \(paused ? "paused" : "running"), rules: \(rules.joined(separator: ", "))"]
        let groups = tiles()
        for group in groups {
            lines.append("display \(group.screen), group at \(describe(group.area))\(areas[group.screen] == nil ? " (fills the screen)" : ""): \(group.windows.count) tiles")
            for w in group.windows {
                let f = w.element.frame ?? .zero
                let mark = w.id == focus ? "*" : (w.id == lastFocus[group.screen] ? "+" : " ")
                lines.append(" \(mark) \(w.id)\t\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))\t\(w.app): \(w.title)")
            }
        }
        if groups.isEmpty { lines.append("no tiles on the current space") }
        if all {
            let managed = Set(groups.flatMap { $0.windows.map(\.id) })
            lines.append("not tiled:")
            for w in visibleWindows() where !managed.contains(w.id) {
                lines.append("   \(w.id)\t\(w.app): \(w.title)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Tabs

    /// Turns every native tab of the rule-matched apps into its own window, so each one becomes a tile.
    func untab(done: @escaping (String) -> Void) {
        untabStep(moved: 0, done: done)
    }

    private func untabStep(moved: Int, done: @escaping (String) -> Void) {
        let menuTitle = "Move Tab to New Window"
        guard moved < 200 else { return done("stopped after \(moved) tabs") }
        let tabbed = visibleWindows().first { matchesRule($0) && $0.element.tabCount > 1 }
        guard let w = tabbed else { return done("moved \(moved) tab\(moved == 1 ? "" : "s") to new windows") }
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            let app = AXUIElementCreateApplication(w.pid)
            guard let item = app.element(kAXMenuBarAttribute)?.menuItem(titled: menuTitle),
                  AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
                return done("error: \(w.app) has no usable \"\(menuTitle)\" menu item, moved \(moved)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.untabStep(moved: moved + 1, done: done) }
        }
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8))
}
