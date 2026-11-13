import XCTest
@testable import TilewallCore

final class LayoutTests: XCTestCase {
    let screen = CGRect(x: -1876, y: 37, width: 1876, height: 1080)
    let noGap = LayoutOptions(focusFraction: 0.5, gap: 0, targetAspect: 1.5)

    func testEmptyAndSingle() {
        XCTAssertEqual(Layout.frames(count: 0, focused: nil, area: screen, options: noGap), [])
        XCTAssertEqual(Layout.frames(count: 1, focused: 0, area: screen, options: noGap), [screen])
    }

    func testRowCountsAreBalancedAndComplete() {
        for n in 1...200 {
            let rows = Layout.rowCounts(count: n, size: screen.size, targetAspect: 1.5)
            XCTAssertEqual(rows.reduce(0, +), n)
            XCTAssertLessThanOrEqual(rows.max()! - rows.min()!, 1)
        }
        XCTAssertEqual(Layout.rowCounts(count: 16, size: screen.size, targetAspect: 1.5), [4, 4, 4, 4])
        XCTAssertEqual(Layout.rowCounts(count: 13, size: screen.size, targetAspect: 1.5), [4, 3, 3, 3])
        XCTAssertEqual(Layout.rowCounts(count: 2, size: screen.size, targetAspect: 1.5), [2])
    }

    func testFocusedTileIsAQuarterOfTheScreen() {
        // With 3 or fewer windows there is not enough to fill the rest, so the focused tile is larger.
        for n in 4...60 {
            for focus in 0..<n {
                let frames = Layout.frames(count: n, focused: focus, area: screen, options: noGap)
                let f = frames[focus]
                XCTAssertEqual(f.width, screen.width / 2, accuracy: 1, "n=\(n) focus=\(focus)")
                XCTAssertEqual(f.height, screen.height / 2, accuracy: 1, "n=\(n) focus=\(focus)")
            }
        }
    }

    func testTilesCoverTheAreaWithoutOverlap() {
        for n in 1...40 {
            for focus in [nil, 0, n / 2, n - 1] as [Int?] {
                let frames = Layout.frames(count: n, focused: focus, area: screen, options: noGap)
                XCTAssertEqual(frames.count, n)
                let total = frames.reduce(0.0) { $0 + Double($1.width * $1.height) }
                XCTAssertEqual(total, Double(screen.width * screen.height), accuracy: 1, "n=\(n)")
                for (i, a) in frames.enumerated() {
                    XCTAssertTrue(screen.contains(a), "n=\(n) tile \(i) leaves the screen")
                    for b in frames[(i + 1)...] {
                        let overlap = a.intersection(b)
                        XCTAssertTrue(overlap.isNull || overlap.width * overlap.height == 0, "n=\(n) tiles overlap")
                    }
                }
            }
        }
    }

    func testFocusChangeKeepsEveryWindowInItsRowAndOrder() {
        let a = Layout.rows(count: 12, focused: 0, area: screen, options: noGap)
        let b = Layout.rows(count: 12, focused: 7, area: screen, options: noGap)
        XCTAssertEqual(a.map(\.count), b.map(\.count))
        for rows in [a, b] {
            for (r, row) in rows.enumerated() {
                for c in 1..<row.count { XCTAssertEqual(row[c].minX, row[c - 1].maxX) }
                if r > 0 { XCTAssertEqual(row[0].minY, rows[r - 1][0].maxY) }
            }
        }
    }

    func testOnlyTheFocusedRowChangesWidth() {
        let even = Layout.rows(count: 12, focused: nil, area: screen, options: noGap)
        let focused = Layout.rows(count: 12, focused: 5, area: screen, options: noGap)   // row 1, column 1
        for r in [0, 2] {
            XCTAssertEqual(focused[r].map(\.width), even[r].map(\.width), "row \(r) keeps its widths")
            XCTAssertEqual(focused[r].map(\.minX), even[r].map(\.minX))
            XCTAssertLessThan(focused[r][0].height, even[r][0].height, "row \(r) only gets shorter")
        }
        XCTAssertEqual(focused[1][1].width, screen.width / 2, accuracy: 1)
        XCTAssertEqual(focused[1][1].height, screen.height / 2, accuracy: 1)
    }

    func testPortraitIsTheLandscapeLayoutWithSwappedAxes() {
        let area = CGRect(x: 100, y: 50, width: 1600, height: 1000)
        var placed: [CGRect] = Array(repeating: .zero, count: 12)
        let portrait = LayoutOptions(focusFraction: 0.5, gap: 0, targetAspect: 1.5, orientation: .portrait)
        Layout.arrange(count: 12, focused: 5, area: area, options: portrait) { index, wanted in
            placed[index] = wanted
            return wanted.size
        }
        let total = placed.reduce(0.0) { $0 + Double($1.width * $1.height) }
        XCTAssertEqual(total, Double(area.width * area.height), accuracy: 1)
        for (i, a) in placed.enumerated() {
            XCTAssertTrue(area.contains(a))
            for b in placed[(i + 1)...] { XCTAssertTrue(a.intersection(b).isEmpty || a.intersection(b).width * a.intersection(b).height == 0) }
        }
        XCTAssertEqual(placed[5].width, area.width / 2, accuracy: 1)
        XCTAssertEqual(placed[5].height, area.height / 2, accuracy: 1)
        // Tiles run down columns: the first two share a column, and only the focused column has uneven heights.
        XCTAssertEqual(placed[0].minX, placed[1].minX)
        XCTAssertEqual(placed[1].minY, placed[0].maxY)
        let columns = Dictionary(grouping: placed, by: \.minX)
        for (x, tiles) in columns where x != placed[5].minX {
            // Even up to the one point that rounding to whole points can cost.
            XCTAssertLessThanOrEqual(tiles.map(\.height).max()! - tiles.map(\.height).min()!, 1, "column at \(x) keeps even heights")
        }
    }

    func testGapSeparatesTilesAndEdges() {
        let options = LayoutOptions(focusFraction: 0.5, gap: 10, targetAspect: 1.5)
        let frames = Layout.frames(count: 4, focused: 0, area: CGRect(x: 0, y: 0, width: 1000, height: 800), options: options)
        XCTAssertEqual(frames[0], CGRect(x: 10, y: 10, width: 485, height: 385))
        XCTAssertEqual(frames[1].minX - frames[0].maxX, 10)
        XCTAssertEqual(frames[2].minY - frames[0].maxY, 10)
        XCTAssertEqual(frames[3].maxX, 990)
        XCTAssertEqual(frames[3].maxY, 790)
    }

    /// A fake terminal: sizes snap down to whole 7x15 character cells.
    private func packed(count: Int, focused: Int?, area: CGRect, gap: Double) -> [CGRect] {
        let options = LayoutOptions(focusFraction: 0.5, gap: gap, targetAspect: 1.5)
        var placed: [CGRect] = []
        Layout.pack(rows: Layout.rows(count: count, focused: focused, area: area, options: options), gap: gap) { _, wanted in
            let size = CGSize(width: (wanted.width / 7).rounded(.down) * 7, height: (wanted.height / 15).rounded(.down) * 15)
            placed.append(CGRect(origin: wanted.origin, size: size))
            return size
        }
        return placed
    }

    func testPackingLeavesNoGapsBetweenSnappingWindows() {
        for n in [2, 5, 13, 16] {
            let frames = packed(count: n, focused: n / 2, area: screen, gap: 0)
            let rows = Layout.rowCounts(count: n, size: screen.size, targetAspect: 1.5)
            var i = 0
            for (r, k) in rows.enumerated() {
                XCTAssertEqual(frames[i].minX, screen.minX)
                for c in 1..<max(k, 1) where k > 1 {
                    XCTAssertEqual(frames[i + c].minX, frames[i + c - 1].maxX, "n=\(n) row \(r)")
                    XCTAssertEqual(frames[i + c].minY, frames[i].minY)
                }
                // The slack ends up at the right edge and is smaller than one character cell.
                XCTAssertLessThan(screen.maxX - frames[i + k - 1].maxX, 7)
                XCTAssertGreaterThanOrEqual(screen.maxX - frames[i + k - 1].maxX, 0)
                if r > 0 { XCTAssertEqual(frames[i].minY, frames[i - 1].maxY, "n=\(n) row \(r)") }
                i += k
            }
            XCTAssertLessThan(screen.maxY - frames[n - 1].maxY, 15)
        }
    }

    func testPackingWithExactWindowsMatchesTheIdealFrames() {
        let options = LayoutOptions(focusFraction: 0.5, gap: 8, targetAspect: 1.5)
        let rows = Layout.rows(count: 7, focused: 3, area: screen, options: options)
        var placed: [CGRect] = []
        Layout.pack(rows: rows, gap: 8) { _, wanted in
            placed.append(wanted)
            return wanted.size
        }
        XCTAssertEqual(placed, rows.flatMap { $0 })
    }

    func testAreaFollowsAMovedTile() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let old = CGRect(x: 500, y: 400, width: 250, height: 200)
        let moved = Layout.area(area, followingTileFrom: old, to: old.offsetBy(dx: 30, dy: -40), minSize: CGSize(width: 320, height: 200))
        XCTAssertEqual(moved, CGRect(x: 30, y: -40, width: 1000, height: 800))
    }

    func testAreaScalesWithAResizedTile() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let old = CGRect(x: 500, y: 400, width: 250, height: 200)
        // Dragging the bottom right corner in: the tile keeps its origin and halves.
        let shrunk = Layout.area(area, followingTileFrom: old, to: CGRect(x: 500, y: 400, width: 125, height: 100), minSize: CGSize(width: 320, height: 200))
        XCTAssertEqual(shrunk, CGRect(x: 250, y: 200, width: 500, height: 400))
        let clamped = Layout.area(area, followingTileFrom: old, to: CGRect(x: 500, y: 400, width: 25, height: 20), minSize: CGSize(width: 320, height: 200))
        XCTAssertEqual(clamped.size, CGSize(width: 320, height: 200))
    }

    func testClampKeepsTheGroupOnTheDesktop() {
        let screen = CGRect(x: -1876, y: 30, width: 1876, height: 1050)
        let desktop = screen.union(CGRect(x: 0, y: 33, width: 1728, height: 1084))
        // The broken state seen in practice: twice the screen height, starting above the top.
        XCTAssertEqual(Layout.clamp(CGRect(x: -1862, y: -483, width: 1876, height: 2061), screen: screen, desktop: desktop),
                       CGRect(x: -1862, y: 30, width: 1876, height: 1050))
        let fine = CGRect(x: -1500, y: 200, width: 900, height: 600)
        XCTAssertEqual(Layout.clamp(fine, screen: screen, desktop: desktop), fine)
        // Dragged far off to the right and down: a strip stays reachable.
        let lost = Layout.clamp(CGRect(x: 5000, y: 5000, width: 900, height: 600), screen: screen, desktop: desktop)
        XCTAssertTrue(desktop.intersects(lost))
        XCTAssertEqual(lost.size, fine.size)
    }

    func testUnfocusedIsAnEvenGrid() {
        let frames = Layout.frames(count: 4, focused: nil, area: CGRect(x: 0, y: 0, width: 1000, height: 800), options: noGap)
        XCTAssertEqual(Set(frames.map { $0.size.width }), [500])
        XCTAssertEqual(Set(frames.map { $0.size.height }), [400])
    }
}

final class ConfigTests: XCTestCase {
    func testRuleMatching() {
        let rule = Rule(app: "com.apple.Terminal")
        XCTAssertTrue(rule.matches(bundleID: "com.apple.Terminal", appName: "Terminal", title: "x"))
        XCTAssertTrue(Rule(app: "terminal").matches(bundleID: "com.apple.Terminal", appName: "Terminal", title: "x"))
        XCTAssertFalse(rule.matches(bundleID: "com.apple.Safari", appName: "Safari", title: "x"))
        let titled = Rule(app: "Terminal", title: "^aaw-")
        XCTAssertTrue(titled.matches(bundleID: nil, appName: "Terminal", title: "aaw-tilewall"))
        XCTAssertFalse(titled.matches(bundleID: nil, appName: "Terminal", title: "zsh"))
    }

    func testPartialConfigFallsBackToDefaults() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"gap": 12, "hotkeys": {"toggle": ""}}"#.utf8))
        XCTAssertEqual(config.gap, 12)
        XCTAssertEqual(config.focusFraction, 0.5)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).gap, 0)
        XCTAssertEqual(config.rules, [Rule(app: "com.apple.Terminal")])
        XCTAssertEqual(config.hotkeys["toggle"], "")
        XCTAssertEqual(config.hotkeys["next"], "ctrl+alt+d")
        XCTAssertEqual(config.backdrop, "auto")
        XCTAssertEqual(config.orientation, .landscape)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data(#"{"orientation": "portrait"}"#.utf8)).orientation, .portrait)
    }

    func testDefaultHotkeysAreReachableWithTheLeftHand() {
        let leftHand = Set("qwertasdfgzxcvb12345`".map(String.init) + ["tab", "escape"])
        var seen: Set<String> = []
        for (action, text) in Config.defaultHotkeys {
            let combo = KeyCombo(text)
            XCTAssertNotNil(combo, action)
            XCTAssertTrue(leftHand.contains(combo?.key ?? ""), "\(action): \(text)")
            XCTAssertTrue(seen.insert(text).inserted, "duplicate hotkey \(text)")
        }
    }

    func testInvalidConfigIsRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(#"{"focusFraction": 0}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(#"{"gap": -1}"#.utf8)))
    }

    func testKeyCombo() {
        XCTAssertEqual(KeyCombo("ctrl+alt+m"), KeyCombo("Control + Option + M"))
        XCTAssertEqual(KeyCombo("ctrl+alt+m")?.keyCode, 46)
        XCTAssertEqual(KeyCombo("cmd+shift+left")?.modifiers, KeyCombo.cmd | KeyCombo.shift)
        XCTAssertEqual(KeyCombo("ctrl+alt+t")?.display, "⌃⌥T")
        XCTAssertEqual(KeyCombo("cmd+shift+left")?.display, "⇧⌘←")
        XCTAssertEqual(KeyCombo("Ctrl+Alt+Tab")?.key, "tab")
        XCTAssertNil(KeyCombo("m"))
        XCTAssertNil(KeyCombo("ctrl+nope"))
        XCTAssertNil(KeyCombo(""))
    }
}
