import CoreGraphics
import Foundation

/// Which way the tiles are laid out.
public enum Orientation: String, Codable, Equatable {
    /// Rows: the focused row grows taller, and only the tiles in that row change width.
    case landscape
    /// Same slots, opposite rule: the focused column grows wider, and only the tiles in that column change height.
    case portrait
}

public struct LayoutOptions: Equatable {
    /// Share of each screen axis the focused tile takes. 0.5 on both axes is a quarter of the screen.
    public var focusFraction: Double
    /// Space between tiles and around the screen edge, in points.
    public var gap: Double
    /// Preferred width / height of an unfocused tile, used to pick the grid shape.
    public var targetAspect: Double
    public var orientation: Orientation

    public init(focusFraction: Double = 0.5, gap: Double = 0, targetAspect: Double = 1.5, orientation: Orientation = .landscape) {
        self.focusFraction = focusFraction
        self.gap = gap
        self.targetAspect = targetAspect
        self.orientation = orientation
    }
}

/// Fisheye grid: every window keeps its slot, the focused row and column are stretched.
public enum Layout {
    /// How many windows go in each row, top to bottom. Rows differ by at most one window.
    public static func rowCounts(count: Int, size: CGSize, targetAspect: Double) -> [Int] {
        guard count > 0 else { return [] }
        guard size.width > 0, size.height > 0, targetAspect > 0 else { return [count] }
        var bestRows = 1
        var bestScore = Double.infinity
        for rows in 1...count {
            let cols = Int((Double(count) / Double(rows)).rounded(.up))
            let aspect = (Double(size.width) / Double(cols)) / (Double(size.height) / Double(rows))
            let empty = Double(rows * cols - count) / Double(count)
            let score = abs(log(aspect / targetAspect)) + 0.5 * empty
            if score < bestScore - 1e-9 {
                bestScore = score
                bestRows = rows
            }
        }
        let base = count / bestRows
        let extra = count % bestRows
        return (0..<bestRows).map { $0 < extra ? base + 1 : base }
    }

    /// Splits a length into `count` parts. The focused part gets `fraction` of it, the rest share what is left.
    public static func split(length: Double, count: Int, focused: Int?, fraction: Double) -> [Double] {
        guard count > 0 else { return [] }
        guard count > 1, let focused, focused >= 0, focused < count else {
            return Array(repeating: length / Double(count), count: count)
        }
        let share = min(max(fraction, 1 / Double(count)), 1)
        let big = length * share
        let small = (length - big) / Double(count - 1)
        return (0..<count).map { $0 == focused ? big : small }
    }

    /// Frames for `count` windows inside `area`, in window order (row by row, left to right).
    public static func frames(count: Int, focused: Int?, area: CGRect, options: LayoutOptions = .init()) -> [CGRect] {
        rows(count: count, focused: focused, area: area, options: options).flatMap { $0 }
    }

    /// The same frames grouped by row, top to bottom.
    public static func rows(count: Int, focused: Int?, area: CGRect, options: LayoutOptions = .init()) -> [[CGRect]] {
        guard count > 0 else { return [] }
        let half = options.gap / 2
        let inner = area.insetBy(dx: half, dy: half)
        let rows = rowCounts(count: count, size: inner.size, targetAspect: options.targetAspect)
        let focus = focused.flatMap { $0 >= 0 && $0 < count ? $0 : nil }

        var focusRow: Int?
        var focusCol: Int?
        if let focus {
            var start = 0
            for (r, n) in rows.enumerated() {
                if focus < start + n {
                    focusRow = r
                    focusCol = focus - start
                    break
                }
                start += n
            }
        }

        let heights = split(length: inner.height, count: rows.count, focused: focusRow, fraction: options.focusFraction)

        var result: [[CGRect]] = []
        var y = Double(inner.minY)
        for (r, n) in rows.enumerated() {
            // Only the focused row gives its focused tile extra width. Every other row stays an even split,
            // so a focus change resizes those tiles on one axis only.
            let widths = split(length: inner.width, count: n, focused: r == focusRow ? focusCol : nil, fraction: options.focusFraction)
            var row: [CGRect] = []
            var x = Double(inner.minX)
            for w in widths {
                let left = (x + half).rounded()
                let top = (y + half).rounded()
                let right = (x + w - half).rounded()
                let bottom = (y + heights[r] - half).rounded()
                row.append(CGRect(x: left, y: top, width: max(right - left, 1), height: max(bottom - top, 1)))
                x += w
            }
            result.append(row)
            y += heights[r]
        }
        return result
    }

    /// The portrait layout, grouped by column, left to right. Each entry carries the tile's index in window order.
    ///
    /// Every tile keeps the slot it has in landscape (same row, same position in the row), so switching
    /// orientation does not shuffle windows. What changes is the rule: the focused column grows wider,
    /// and only the tiles in that column change height. The other columns keep even heights and just get narrower.
    public static func columns(count: Int, focused: Int?, area: CGRect, options: LayoutOptions = .init()) -> [[(index: Int, frame: CGRect)]] {
        guard count > 0 else { return [] }
        let half = options.gap / 2
        let inner = area.insetBy(dx: half, dy: half)
        let rows = rowCounts(count: count, size: inner.size, targetAspect: options.targetAspect)
        let focus = focused.flatMap { $0 >= 0 && $0 < count ? $0 : nil }

        // Column c holds the tile at position c of every row that is long enough.
        var members: [[Int]] = Array(repeating: [], count: rows.max() ?? 0)
        var start = 0
        for n in rows {
            for c in 0..<n { members[c].append(start + c) }
            start += n
        }
        let focusColumn = focus.flatMap { f in members.firstIndex { $0.contains(f) } }
        let widths = split(length: inner.width, count: members.count, focused: focusColumn, fraction: options.focusFraction)

        var result: [[(index: Int, frame: CGRect)]] = []
        var x = Double(inner.minX)
        for (c, column) in members.enumerated() {
            let focusInColumn = c == focusColumn ? focus.flatMap { column.firstIndex(of: $0) } : nil
            let heights = split(length: inner.height, count: column.count, focused: focusInColumn, fraction: options.focusFraction)
            var tiles: [(index: Int, frame: CGRect)] = []
            var y = Double(inner.minY)
            for (i, index) in column.enumerated() {
                let left = (x + half).rounded()
                let top = (y + half).rounded()
                let right = (x + widths[c] - half).rounded()
                let bottom = (y + heights[i] - half).rounded()
                tiles.append((index, CGRect(x: left, y: top, width: max(right - left, 1), height: max(bottom - top, 1))))
                y += heights[i]
            }
            result.append(tiles)
            x += widths[c]
        }
        return result
    }

    /// Lays out and places `count` tiles in `area`, honouring the orientation.
    /// `place` receives the tile index and the wanted frame, applies it, and returns the size the window ended up with.
    public static func arrange(count: Int, focused: Int?, area: CGRect, options: LayoutOptions, place: (Int, CGRect) -> CGSize) {
        guard options.orientation == .portrait else {
            return pack(rows: rows(count: count, focused: focused, area: area, options: options), gap: options.gap, place: place)
        }
        // Packing works along rows, so hand it the columns with the two axes swapped.
        let columns = columns(count: count, focused: focused, area: area, options: options)
        let order = columns.flatMap { $0.map(\.index) }
        pack(rows: columns.map { $0.map { transpose($0.frame) } }, gap: options.gap) { position, wanted in
            let actual = place(order[position], transpose(wanted))
            return CGSize(width: actual.height, height: actual.width)
        }
    }

    private static func transpose(_ r: CGRect) -> CGRect {
        CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width)
    }

    /// Places tiles one by one, feeding the size each window really took into the position of the next one.
    ///
    /// Apps such as terminals snap to whole character cells, so a window is rarely exactly the size it was asked to be.
    /// Packing keeps neighbours `gap` apart anyway: the last tile of a row and the last row absorb what is left,
    /// which pushes the unavoidable slack to the right and bottom edge of the group.
    /// `place` receives the tile index and the wanted frame, applies it, and returns the size the window ended up with.
    public static func pack(rows: [[CGRect]], gap: Double, place: (Int, CGRect) -> CGSize) {
        guard let first = rows.first?.first, let last = rows.last?.last else { return }
        var index = 0
        var y = first.minY
        for (r, row) in rows.enumerated() {
            let height = r == rows.count - 1 ? max(last.maxY - y, 1) : row[0].height
            var x = row[0].minX
            var tallest: CGFloat = 0
            for (c, ideal) in row.enumerated() {
                let width = c == row.count - 1 ? max(row[row.count - 1].maxX - x, 1) : ideal.width
                let actual = place(index, CGRect(x: x, y: y, width: width, height: height))
                x += actual.width + gap
                tallest = max(tallest, actual.height)
                index += 1
            }
            y += tallest + gap
        }
    }

    /// Keeps a group area usable: no larger than its screen, never above the top of the desktop
    /// (macOS refuses to place windows there, which would make tiles pile up), and never dragged fully out of sight.
    public static func clamp(_ area: CGRect, screen: CGRect, desktop: CGRect) -> CGRect {
        let width = min(area.width, screen.width)
        let height = min(area.height, screen.height)
        let margin: CGFloat = 120
        let x = min(max(area.minX, desktop.minX - width + margin), desktop.maxX - margin)
        let y = min(max(area.minY, desktop.minY), desktop.maxY - margin)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The group area after the user moved or resized one of its tiles from `old` to `new`.
    /// The group scales by the same factor as the tile and stays attached to it.
    public static func area(_ area: CGRect, followingTileFrom old: CGRect, to new: CGRect, minSize: CGSize) -> CGRect {
        guard old.width > 0, old.height > 0 else { return area }
        let sx = abs(new.width - old.width) < 2 ? 1 : new.width / old.width
        let sy = abs(new.height - old.height) < 2 ? 1 : new.height / old.height
        let width = max(area.width * sx, minSize.width)
        let height = max(area.height * sy, minSize.height)
        let x = new.minX - (old.minX - area.minX) * (width / area.width)
        let y = new.minY - (old.minY - area.minY) * (height / area.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
    }
}
