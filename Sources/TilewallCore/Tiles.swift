import CoreGraphics
import Foundation

/// Which windows are tiles: the ones a rule matches, minus those taken out by hand, plus those added by hand.
public struct Membership: Equatable {
    /// Windows added by hand that no rule matches.
    public var included: Set<UInt32>
    /// Windows a rule matches that were removed by hand.
    public var excluded: Set<UInt32>

    public init(included: Set<UInt32> = [], excluded: Set<UInt32> = []) {
        self.included = included
        self.excluded = excluded
    }

    public func isTile(_ id: UInt32, matchesRule: Bool) -> Bool {
        matchesRule ? !excluded.contains(id) : included.contains(id)
    }

    /// Makes the window a tile or takes it out, whichever list that needs.
    public mutating func set(_ tile: Bool, id: UInt32, matchesRule: Bool) {
        if matchesRule {
            if tile { excluded.remove(id) } else { excluded.insert(id) }
        } else {
            if tile { included.insert(id) } else { included.remove(id) }
        }
    }

    /// Forgets windows that no longer exist.
    public mutating func keep(_ existing: Set<UInt32>) {
        included.formIntersection(existing)
        excluded.formIntersection(existing)
    }
}

/// The order of tiles. `order` lists every known window, a group is the part of it that sits on one display.
public enum TileOrder {
    /// Swaps a tile with its neighbour in its group, `step` places away. Nil when it is already at that end or not in the group.
    public static func moving(_ id: UInt32, by step: Int, in group: [UInt32], order: [UInt32]) -> [UInt32]? {
        guard let from = group.firstIndex(of: id), group.indices.contains(from + step), step != 0,
              let a = order.firstIndex(of: id), let b = order.firstIndex(of: group[from + step]) else { return nil }
        var result = order
        result.swapAt(a, b)
        return result
    }

    /// A tile dropped on another tile of its group: the two trade slots. Nil when either is unknown or they are the same.
    public static func swapping(_ id: UInt32, with other: UInt32, in order: [UInt32]) -> [UInt32]? {
        guard id != other, let a = order.firstIndex(of: id), let b = order.firstIndex(of: other) else { return nil }
        var result = order
        result.swapAt(a, b)
        return result
    }

    /// A tile dropped on a tile of another group: it goes in front of that tile, which keeps the other group's order intact.
    public static func placing(_ id: UInt32, before other: UInt32, in order: [UInt32]) -> [UInt32]? {
        guard id != other, order.contains(id), order.contains(other) else { return nil }
        var result = order.filter { $0 != id }
        result.insert(id, at: result.firstIndex(of: other)!)
        return result
    }

    /// The tile under a point, ignoring the one being dragged.
    public static func tile(at point: CGPoint, among frames: [(id: UInt32, frame: CGRect)], excluding dragged: UInt32) -> UInt32? {
        frames.first { $0.id != dragged && $0.frame.contains(point) }?.id
    }

    /// The index focus moves to from `current`, wrapping around. Without a current tile focus goes to the first one.
    public static func cycled(from current: Int?, by step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return ((current + step) % count + count) % count
    }
}

/// "Equal tiles": no tile is enlarged, until focus arrives on a tile again.
public struct EqualTiles: Equatable {
    public private(set) var isOn = false
    private var seen: UInt32?

    public init() {}

    /// Switches the mode. `focus` is the window that has focus right now, which stays equal until focus moves.
    public mutating func set(_ on: Bool, focus: UInt32?) {
        isOn = on
        seen = focus
    }

    /// Call with the focused window on every retile. Focus arriving on a tile, from another tile or from
    /// any other window, ends the mode, so the tile that was picked grows as usual.
    public mutating func observe(focus: UInt32?, isTile: Bool) {
        if isOn, isTile, focus != seen { isOn = false }
        seen = focus
    }
}

/// What the user did to a tile while the mouse button was down.
public enum TileChange: Equatable {
    case none
    /// Dragged by its title bar: the whole group follows by this offset.
    case moved(dx: CGFloat, dy: CGFloat)
    /// Its size changed: the group is rescaled once, when the button is released.
    case resized

    public static func between(_ before: CGRect, _ now: CGRect, tolerance: CGFloat = 2) -> TileChange {
        if before == now { return .none }
        guard abs(now.width - before.width) < tolerance, abs(now.height - before.height) < tolerance else { return .resized }
        return .moved(dx: now.minX - before.minX, dy: now.minY - before.minY)
    }
}

public enum Screens {
    /// The display that contains the point, or the closest one when the point is outside all of them.
    public static func nearest(to point: CGPoint, in areas: [(id: String, area: CGRect)]) -> String? {
        if let inside = areas.first(where: { $0.area.contains(point) }) { return inside.id }
        return areas.min { distance(point, to: $0.area) < distance(point, to: $1.area) }?.id
    }

    static func distance(_ p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// The display after `current` in the list, wrapping around. Nil with fewer than two displays.
    public static func next(after current: String?, in ids: [String]) -> String? {
        guard ids.count > 1 else { return nil }
        let index = current.flatMap { ids.firstIndex(of: $0) } ?? 0
        return ids[(index + 1) % ids.count]
    }
}

public enum Text {
    /// Cuts a long title in the middle, because window titles tend to differ at the start and at the end.
    public static func middleTruncated(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        let head = (limit - 1) / 2
        return String(text.prefix(head)) + "…" + String(text.suffix(limit - 1 - head))
    }
}
