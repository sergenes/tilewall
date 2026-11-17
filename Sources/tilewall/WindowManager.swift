import ApplicationServices
import Cocoa
import TilewallCore

struct Window {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let bundleID: String?
    let title: String
    /// Where the window was when it was listed. Ask `element.frame` after moving it.
    let frame: CGRect?
    let element: AXUIElement
}

private struct SavedState: Codable {
    var included: [CGWindowID] = []
    var excluded: [CGWindowID] = []
    var order: [CGWindowID]? = []
    // Keyed by display UUID. Older state files used numeric display ids under "areas" and "homes", which are ignored.
    var displayAreas: [String: CGRect]? = [:]
    var displayHomes: [CGWindowID: String]? = [:]
    var untiledDisplays: [String]? = []
}

private struct Group {
    /// UUID of the display this group belongs to.
    let screen: String
    let name: String
    /// The rectangle this group fills: the whole screen, or wherever the user dragged it.
    let area: CGRect
    let windows: [Window]
}

/// Decides which windows are tiles, watches focus, and applies the layout.
final class WindowManager {
    private(set) var config: Config
    private(set) var paused = false
    /// Which windows were added or taken out by hand.
    private var membership = Membership()
    /// Stable tile order: first seen, first placed.
    private var order: [CGWindowID] = []
    private var lastFocus: [String: CGWindowID] = [:]
    private var applied: [CGWindowID: (target: CGRect, result: CGRect)] = [:]
    /// Group areas the user moved or resized. A display without an entry fills its whole visible frame.
    private var areas: [String: CGRect] = [:]
    /// The display whose group a window belongs to. Sticky, so a dragged group keeps its tiles.
    private var homes: [CGWindowID: String] = [:]
    /// Displays the user switched tiling off for. Kept while a display is unplugged.
    private var untiled: Set<String> = []
    private var lastGroups: [Group] = []
    /// Set while a mouse button is down and the focused tile no longer sits where tilewall put it.
    private var userChangedTile = false
    private var dragLocation: CGPoint?
    /// Set when the first movement of a drag is seen, and cleared when the button is released.
    private var dragStarted = false
    /// This drag was started with shift held: the tile moves alone and trades places with the tile it is dropped on.
    private var reorderDrag = false
    private var equal = EqualTiles()
    var equalTiles: Bool { equal.isOn }
    /// The group that held the focused window at the last retile, nil when focus was outside every group.
    private var focusedGroup: String?
    private let backdrop = Backdrop()
    private static let minGroupSize = CGSize(width: 320, height: 200)
    private var observers: [pid_t: AXObserver] = [:]
    private var pending: DispatchWorkItem?
    private var pendingDue = Date.distantPast
    private var lastPrune = Date.distantPast
    private static let reconcileInterval: TimeInterval = 5
    private static let pruneInterval: TimeInterval = 30
    private var poll: Timer?

    init(config: Config) {
        self.config = config
        if let data = try? Data(contentsOf: Paths.state), let saved = try? JSONDecoder().decode(SavedState.self, from: data) {
            membership = Membership(included: Set(saved.included), excluded: Set(saved.excluded))
            order = saved.order ?? []
            areas = saved.displayAreas ?? [:]
            homes = saved.displayHomes ?? [:]
            untiled = Set(saved.untiledDisplays ?? [])
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
        // Notifications drive the tiling. This slow reconcile only picks up what they miss.
        poll = Timer.scheduledTimer(withTimeInterval: WindowManager.reconcileInterval, repeats: true) { [weak self] _ in self?.retile() }
        poll?.tolerance = 1
        retile()
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, observers[pid] == nil, pid != getpid() else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
            guard (notification as String) == kAXTitleChangedNotification else { return manager.scheduleRetile() }
            // Terminal titles change many times a second while an agent works. They only decide anything
            // when a rule has a title pattern, and then once a second is often enough.
            if manager.config.rules.contains(where: { !($0.title ?? "").isEmpty }) { manager.scheduleRetile(after: 1) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                     kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification,
                     kAXTitleChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    /// Retiles soon. A burst of notifications leads to one retile: a request never postpones one that is already due earlier.
    func scheduleRetile(after delay: TimeInterval = 0.03) {
        let due = Date().addingTimeInterval(delay)
        if pending != nil, pendingDue <= due { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.retile() }
        pending = work
        pendingDue = due
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Window discovery

    private func windows(of app: NSRunningApplication) -> [Window] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)
        return element.elements(kAXWindowsAttribute).compactMap { describe($0, app: app) }
    }

    private static let described = [kAXSubroleAttribute, kAXMinimizedAttribute, "AXFullScreen", kAXTitleAttribute,
                                    kAXPositionAttribute, kAXSizeAttribute]

    private func describe(_ element: AXUIElement, app: NSRunningApplication) -> Window? {
        // One round trip per window: this runs for every window on every retile.
        let found = element.values(WindowManager.described)
        guard found[0] as? String == (kAXStandardWindowSubrole as String),
              found[1] as? Bool != true,
              found[2] as? Bool != true,
              let id = element.windowID else { return nil }
        return Window(id: id, pid: app.processIdentifier, app: app.localizedName ?? "?", bundleID: app.bundleIdentifier,
                      title: found[3] as? String ?? "", frame: AXUIElement.frame(position: found[4], size: found[5]), element: element)
    }

    private func matchesRule(_ w: Window) -> Bool {
        config.rules.contains { $0.matches(bundleID: w.bundleID, appName: w.app, title: w.title) }
    }

    private func isManaged(_ w: Window) -> Bool {
        membership.isTile(w.id, matchesRule: matchesRule(w))
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
        let includedPids = Set(membership.included.compactMap { onScreen[$0] })
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != getpid() }
            .filter { app in
                guard candidatesOnly else { return true }
                return includedPids.contains(app.processIdentifier)
                    || !config.rules(forBundleID: app.bundleIdentifier, appName: app.localizedName).isEmpty
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
    /// Windows that belong to a display with tiling switched off are in no group.
    private func tiles() -> [Group] {
        let managed = visibleWindows(candidatesOnly: true).filter(isManaged)
        let known = (order.count, homes)
        for w in managed where !order.contains(w.id) { order.append(w.id) }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let screens = screenAreas()
        let connected = Set(screens.map(\.id))
        let desktop = screens.reduce(CGRect.null) { $0.union($1.area) }
        // Areas of unplugged displays are kept, so a group comes back the way it was left.
        var clamped = areas.filter { !connected.contains($0.key) }
        for screen in screens {
            guard let area = areas[screen.id], !untiled.contains(screen.id) else { continue }
            clamped[screen.id] = Layout.clamp(area, screen: screen.area, desktop: desktop)
        }
        let areasChanged = clamped != areas
        areas = clamped
        var groups: [String: [Window]] = [:]
        for w in managed {
            guard let current = display(of: w, in: screens) else { continue }
            let decision = Placement.decide(home: homes[w.id], current: current, connected: connected, untiled: untiled)
            homes[w.id] = decision.home
            if case .tile(let display) = decision.placement { groups[display, default: []].append(w) }
        }
        if known != (order.count, homes) || areasChanged { save() }
        lastGroups = screens.compactMap { screen in
            guard let group = groups[screen.id] else { return nil }
            return Group(screen: screen.id, name: screen.name, area: areas[screen.id] ?? screen.area,
                         windows: group.sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) })
        }
        return lastGroups
    }

    /// The display a window is on right now, judged by its center.
    private func display(of window: Window, in screens: [Display]) -> String? {
        guard let frame = window.frame else { return nil }
        return Screens.nearest(to: CGPoint(x: frame.midX, y: frame.midY), in: screens.map { ($0.id, $0.area) })
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
            let changed = reorderDrag ? adoptReorder(focus: focus, in: groups)
                : adoptDropOnOtherDisplay(focus: focus, in: groups) || adoptUserResize(focus: focus, in: groups)
            if changed { groups = tiles() }
        }
        dragStarted = false
        reorderDrag = false
        equal.observe(focus: focus, isTile: groups.contains { g in g.windows.contains { $0.id == focus } })
        raiseGroupIfEntered(focus: focus, groups: groups)
        var alive: Set<CGWindowID> = []
        for group in groups {
            let ids = group.windows.map(\.id)
            alive.formUnion(ids)
            if let focus, ids.contains(focus) { lastFocus[group.screen] = focus }
            let focusIndex = equal.isOn ? nil : lastFocus[group.screen].flatMap { ids.firstIndex(of: $0) }
            Layout.arrange(count: ids.count, focused: focusIndex, area: group.area, options: config.layoutOptions) { index, target in
                let window = group.windows[index]
                // Apps such as Terminal snap to whole character cells, so compare against what the last apply produced.
                if let last = applied[window.id], last.target == target, window.frame == last.result {
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
        // Where the pointer is while the button is still down. After the release it may already be somewhere else.
        dragLocation = NSEvent.mouseLocation
        guard let dragged = focusedWindow(), let last = applied[dragged.id], let now = dragged.frame,
              let group = lastGroups.first(where: { g in g.windows.contains { $0.id == dragged.id } }) else { return }
        let change = TileChange.between(last.result, now)
        guard change != .none else { return }
        userChangedTile = true
        guard case .moved(let dx, let dy) = change else { return }
        if !dragStarted {
            dragStarted = true
            reorderDrag = NSEvent.modifierFlags.contains(.shift)
        }
        // A shift drag moves this tile alone. Where it is dropped decides its new slot, once the button is released.
        guard !reorderDrag else { return }
        areas[group.screen] = group.area.offsetBy(dx: dx, dy: dy)
        lastGroups = lastGroups.map { $0.screen == group.screen ? Group(screen: $0.screen, name: $0.name, area: $0.area.offsetBy(dx: dx, dy: dy), windows: $0.windows) : $0 }
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
        let mouse = dragLocation ?? NSEvent.mouseLocation
        dragLocation = nil
        let drop = CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)
        guard let target = Screens.nearest(to: drop, in: screenAreas().map { ($0.id, $0.area) }), target != group.screen else { return false }
        for window in group.windows { homes[window.id] = target }
        // Both screens go back to full size: the tiles join whatever is already tiled on the target.
        areas[group.screen] = nil
        areas[target] = nil
        applied.removeAll()
        save()
        return true
    }

    /// After the button is released on a shift drag: the tile trades slots with the tile it was dropped on.
    /// Dropped on a tile of another display, it joins that group in front of that tile. Dropped anywhere else, it goes back.
    private func adoptReorder(focus: CGWindowID?, in groups: [Group]) -> Bool {
        guard let focus, let own = groups.first(where: { g in g.windows.contains { $0.id == focus } }),
              let primary = NSScreen.screens.first else { return false }
        // The tile has to be laid out again whatever happens, either in its new slot or back in its old one.
        applied[focus] = nil
        let mouse = dragLocation ?? NSEvent.mouseLocation
        dragLocation = nil
        let drop = CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)
        let frames = groups.flatMap { g in g.windows.compactMap { w in applied[w.id].map { (id: w.id, frame: $0.result) } } }
        guard let target = TileOrder.tile(at: drop, among: frames, excluding: focus),
              let other = groups.first(where: { g in g.windows.contains { $0.id == target } }) else { return false }
        let moved = other.screen == own.screen ? TileOrder.swapping(focus, with: target, in: order)
                                               : TileOrder.placing(focus, before: target, in: order)
        guard let moved else { return false }
        order = moved
        homes[focus] = other.screen
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
        // Listing every window of every app is the most expensive call here, and stale ids do no harm for a while.
        guard Date().timeIntervalSince(lastPrune) >= WindowManager.pruneInterval else { return }
        lastPrune = Date()
        // Windows on other spaces still exist and keep their slot and their manual include or exclude.
        let existing = Set(windowOwners([.optionAll]).keys)
        let before = (membership, order)
        homes = homes.filter { existing.contains($0.key) }
        order.removeAll { !existing.contains($0) }
        membership.keep(existing)
        if before != (membership, order) { save() }
    }

    private func save() {
        let state = SavedState(included: membership.included.sorted(), excluded: membership.excluded.sorted(), order: order,
                               displayAreas: areas, displayHomes: homes, untiledDisplays: untiled.sorted())
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

    // MARK: Rules

    func hasRule(for app: NSRunningApplication) -> Bool {
        !config.rules(forBundleID: app.bundleIdentifier, appName: app.localizedName).isEmpty
    }

    /// Adds or removes the rule that tiles every window of an app, and stores it in the config file.
    /// `app` is a bundle identifier or a name. A running app given by name is stored by its bundle identifier.
    func setRule(_ on: Bool, app: String) -> String {
        let running = NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && Rule(app: app).matches(bundleID: $0.bundleIdentifier, appName: $0.localizedName)
        }
        var changed = config
        if on {
            guard changed.addRule(app: running?.bundleIdentifier ?? app) else { return "\(app) is already tiled by a rule" }
        } else {
            guard changed.removeRules(bundleID: running?.bundleIdentifier ?? app, appName: running?.localizedName ?? app) > 0 else {
                return "error: no rule for \(app)"
            }
        }
        do { try ConfigStore.save(changed) } catch { return "error: cannot write the config: \(error.localizedDescription)" }
        config = changed
        applied.removeAll()
        retile()
        return on ? "added a rule for \(running?.bundleIdentifier ?? app)" : "removed the rules for \(app)"
    }

    func rulesText() -> String {
        config.rules.isEmpty ? "no rules" : config.rules.map { rule in rule.title.map { "\(rule.app)  title /\($0)/" } ?? rule.app }.joined(separator: "\n")
    }

    /// include: true adds, false removes, nil flips.
    func setManaged(_ include: Bool?, window: Window? = nil) -> String {
        guard let w = window ?? focusedWindow() else { return "error: no focused standard window" }
        let want = include ?? !isManaged(w)
        membership.set(want, id: w.id, matchesRule: matchesRule(w))
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
        guard let index = TileOrder.cycled(from: group.windows.firstIndex { $0.id == current }, by: step, count: group.windows.count) else { return "error: no tiles" }
        focus(group.windows[index])
        return "focused \(group.windows[index].id) \(group.windows[index].app): \(group.windows[index].title)"
    }

    /// Swaps a tile with its neighbour in the group, so it takes that slot. The focused tile when no id is given.
    func move(_ step: Int, id: CGWindowID?) -> String {
        let groups = tiles()
        guard let wanted = id ?? focusedWindow()?.id,
              let group = groups.first(where: { g in g.windows.contains { $0.id == wanted } }),
              let w = group.windows.first(where: { $0.id == wanted }) else {
            return id == nil ? "error: the focused window is not a tile" : "error: \(id!) is not a tile"
        }
        guard let moved = TileOrder.moving(wanted, by: step, in: group.windows.map(\.id), order: order) else {
            return "error: \(w.id) is already the \(step < 0 ? "first" : "last") tile"
        }
        order = moved
        save()
        applied.removeAll()
        retile()
        return "moved \(w.id) \(w.app): \(w.title)"
    }

    /// Makes every tile the same size, or lets the focused one grow again. Nil flips.
    func setEqual(_ on: Bool?) -> String {
        equal.set(on ?? !equal.isOn, focus: focusedWindow()?.id)
        applied.removeAll()
        retile()
        return equal.isOn ? "tiles are equal until you focus one" : "the focused tile grows"
    }

    func managedWindows() -> [Window] { tiles().flatMap(\.windows) }

    /// Tiles every window the rules match again, undoing all manual excludes, and resumes tiling.
    func tileAll() -> String {
        membership.excluded.removeAll()
        paused = false
        save()
        applied.removeAll()
        retile()
        return "tiling \(lastGroups.reduce(0) { $0 + $1.windows.count }) windows"
    }

    /// Releases every tile on the current space. The windows stay where they are and can be moved freely.
    func untileAll() -> String {
        let tiles = managedWindows()
        for w in tiles { membership.set(false, id: w.id, matchesRule: matchesRule(w)) }
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
        return "group on \(group.name) at \(describe(area))"
    }

    /// Moves a window to the next display. It joins that display's group, or is simply placed there when tiling is off for it.
    func send(id: CGWindowID?) -> String {
        guard let w = id.map({ wanted in visibleWindows().first { $0.id == wanted } }) ?? focusedWindow() else { return "error: no such window" }
        guard isManaged(w) else { return "error: \(w.id) is not a tile" }
        let screens = screenAreas()
        guard screens.count > 1 else { return "error: there is only one display" }
        // Start from where the window is shown now, which differs from its home while that display is unplugged.
        let shown = lastGroups.first { g in g.windows.contains { $0.id == w.id } }?.screen ?? display(of: w, in: screens)
        guard let next = Screens.next(after: shown, in: screens.map(\.id)), let target = screens.first(where: { $0.id == next }) else {
            return "error: there is only one display"
        }
        homes[w.id] = target.id
        if untiled.contains(target.id), let frame = w.element.frame {
            let size = CGSize(width: min(frame.width, target.area.width), height: min(frame.height, target.area.height))
            w.element.setFrame(CGRect(x: target.area.midX - size.width / 2, y: target.area.midY - size.height / 2, width: size.width, height: size.height))
        }
        save()
        applied.removeAll()
        retile()
        return "sent \(w.id) to \(target.name)"
    }

    // MARK: Displays

    struct DisplayState {
        let id: String
        let name: String
        let tiled: Bool
        let tiles: Int
    }

    func displays() -> [DisplayState] {
        let groups = tiles()
        return screenAreas().map { screen in
            DisplayState(id: screen.id, name: screen.name, tiled: !untiled.contains(screen.id),
                         tiles: groups.first { $0.screen == screen.id }?.windows.count ?? 0)
        }
    }

    /// Switches tiling on or off for one display. Off leaves its windows exactly where they are.
    func setTiled(_ tiled: Bool, display id: String) -> String {
        guard let screen = screenAreas().first(where: { $0.id == id }) else { return "error: no such display" }
        if tiled { untiled.remove(id) } else { untiled.insert(id) }
        save()
        applied.removeAll()
        retile()
        return "\(screen.name): tiling \(tiled ? "on" : "off")"
    }

    func displayGroups() -> [(name: String, windows: [Window])] { tiles().map { ($0.name, $0.windows) } }

    private func describe(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }

    func status(all: Bool) -> String {
        let focus = focusedWindow()?.id
        let rules = config.rules.map { rule in rule.title.map { "\(rule.app) /\($0)/" } ?? rule.app }
        var lines = ["tilewall \(paused ? "paused" : "running"), rules: \(rules.joined(separator: ", "))"]
        let groups = tiles()
        for group in groups {
            lines.append("display \(group.name), group at \(describe(group.area))\(areas[group.screen] == nil ? " (fills the screen)" : ""): \(group.windows.count) tiles")
            for w in group.windows {
                let f = w.element.frame ?? .zero
                let mark = w.id == focus ? "*" : (w.id == lastFocus[group.screen] ? "+" : " ")
                lines.append(" \(mark) \(w.id)\t\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))\t\(w.app): \(w.title)")
            }
        }
        if groups.isEmpty { lines.append("no tiles on the current space") }
        for screen in screenAreas() where untiled.contains(screen.id) { lines.append("display \(screen.name): tiling off") }
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
