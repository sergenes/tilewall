import XCTest
@testable import TilewallCore

final class TilesTests: XCTestCase {
    // MARK: Membership

    func testRuleMatchedWindowIsATileUntilExcluded() {
        var m = Membership()
        XCTAssertTrue(m.isTile(1, matchesRule: true))
        m.set(false, id: 1, matchesRule: true)
        XCTAssertFalse(m.isTile(1, matchesRule: true))
        XCTAssertEqual(m.excluded, [1])
        m.set(true, id: 1, matchesRule: true)
        XCTAssertTrue(m.isTile(1, matchesRule: true))
        XCTAssertEqual(m, Membership())
    }

    func testOtherWindowIsATileOnlyWhenIncluded() {
        var m = Membership()
        XCTAssertFalse(m.isTile(2, matchesRule: false))
        m.set(true, id: 2, matchesRule: false)
        XCTAssertTrue(m.isTile(2, matchesRule: false))
        XCTAssertEqual(m.included, [2])
        m.set(false, id: 2, matchesRule: false)
        XCTAssertEqual(m, Membership())
    }

    func testClosedWindowsAreForgotten() {
        var m = Membership(included: [1, 2], excluded: [3, 4])
        m.keep([2, 3, 9])
        XCTAssertEqual(m, Membership(included: [2], excluded: [3]))
    }

    // MARK: Order

    func testMovingATileSwapsItWithItsNeighbourInTheGroup() {
        // Windows 20 and 40 sit on another display, so they are not neighbours of 10, 30 and 50.
        let order: [UInt32] = [10, 20, 30, 40, 50]
        let group: [UInt32] = [10, 30, 50]
        XCTAssertEqual(TileOrder.moving(10, by: 1, in: group, order: order), [30, 20, 10, 40, 50])
        XCTAssertEqual(TileOrder.moving(50, by: -1, in: group, order: order), [10, 20, 50, 40, 30])
        XCTAssertEqual(TileOrder.moving(10, by: 2, in: group, order: order), [50, 20, 30, 40, 10])
    }

    func testMovingPastTheEndDoesNothing() {
        let order: [UInt32] = [10, 30, 50]
        XCTAssertNil(TileOrder.moving(10, by: -1, in: order, order: order))
        XCTAssertNil(TileOrder.moving(50, by: 1, in: order, order: order))
        XCTAssertNil(TileOrder.moving(30, by: 0, in: order, order: order))
        XCTAssertNil(TileOrder.moving(99, by: 1, in: order, order: order))
    }

    func testFocusCyclesAndWraps() {
        XCTAssertEqual(TileOrder.cycled(from: 0, by: 1, count: 3), 1)
        XCTAssertEqual(TileOrder.cycled(from: 2, by: 1, count: 3), 0)
        XCTAssertEqual(TileOrder.cycled(from: 0, by: -1, count: 3), 2)
        XCTAssertEqual(TileOrder.cycled(from: nil, by: 1, count: 3), 0)
        XCTAssertNil(TileOrder.cycled(from: nil, by: 1, count: 0))
    }

    // MARK: Drag and resize

    func testUnchangedTile() {
        let r = CGRect(x: 10, y: 20, width: 300, height: 200)
        XCTAssertEqual(TileChange.between(r, r), .none)
    }

    func testDraggedTileReportsItsOffset() {
        let before = CGRect(x: 10, y: 20, width: 300, height: 200)
        XCTAssertEqual(TileChange.between(before, before.offsetBy(dx: -40, dy: 15)), .moved(dx: -40, dy: 15))
        // Apps that snap to character cells can be off by a point while they move.
        let wobble = CGRect(x: 50, y: 20, width: 301, height: 199)
        XCTAssertEqual(TileChange.between(before, wobble), .moved(dx: 40, dy: 0))
    }

    func testResizedTile() {
        let before = CGRect(x: 10, y: 20, width: 300, height: 200)
        XCTAssertEqual(TileChange.between(before, CGRect(x: 10, y: 20, width: 240, height: 200)), .resized)
        // Resizing from the top left corner also moves the origin, and is still a resize.
        XCTAssertEqual(TileChange.between(before, CGRect(x: 60, y: 50, width: 250, height: 170)), .resized)
    }

    // MARK: Displays

    private let screens: [(id: String, area: CGRect)] = [
        ("main", CGRect(x: 0, y: 33, width: 1728, height: 1084)),
        ("left", CGRect(x: -1920, y: 30, width: 1920, height: 1050)),
    ]

    func testPointInsideADisplay() {
        XCTAssertEqual(Screens.nearest(to: CGPoint(x: 800, y: 500), in: screens), "main")
        XCTAssertEqual(Screens.nearest(to: CGPoint(x: -5, y: 500), in: screens), "left")
    }

    func testPointOutsideEveryDisplayGoesToTheClosest() {
        // In the menu bar strip above the main display.
        XCTAssertEqual(Screens.nearest(to: CGPoint(x: 800, y: 5), in: screens), "main")
        XCTAssertEqual(Screens.nearest(to: CGPoint(x: -3000, y: 2000), in: screens), "left")
        XCTAssertNil(Screens.nearest(to: .zero, in: []))
    }

    func testNextDisplayWraps() {
        XCTAssertEqual(Screens.next(after: "main", in: ["main", "left"]), "left")
        XCTAssertEqual(Screens.next(after: "left", in: ["main", "left"]), "main")
        XCTAssertEqual(Screens.next(after: nil, in: ["main", "left"]), "left")
        XCTAssertEqual(Screens.next(after: "gone", in: ["main", "left"]), "left")
        XCTAssertNil(Screens.next(after: "main", in: ["main"]))
    }

    // MARK: Versions

    func testNewerVersions() {
        XCTAssertTrue(Version.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(Version.isNewer("v0.10.0", than: "0.9.3"))
        XCTAssertTrue(Version.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(Version.isNewer("0.2.0.1", than: "0.2"))
        XCTAssertFalse(Version.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(Version.isNewer("0.2", than: "0.2.0"))
        XCTAssertFalse(Version.isNewer("0.1.9", than: "0.2.0"))
    }

    func testNonReleaseVersionsAreNeverNewer() {
        XCTAssertNil(Version.parts("dev"))
        XCTAssertNil(Version.parts("0.2.0-beta"))
        XCTAssertNil(Version.parts(""))
        XCTAssertFalse(Version.isNewer("0.2.0", than: "dev"))
        XCTAssertFalse(Version.isNewer("latest", than: "0.1.0"))
    }

    // MARK: Text

    func testLongTitlesAreCutInTheMiddle() {
        XCTAssertEqual(Text.middleTruncated("short", limit: 10), "short")
        XCTAssertEqual(Text.middleTruncated("abcdefghijkl", limit: 7), "abc…jkl")
        XCTAssertEqual(Text.middleTruncated("abcdefghijkl", limit: 7).count, 7)
    }

    // MARK: Rules

    func testTerminalAppsAreTiledByDefault() {
        let config = Config()
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"] {
            XCTAssertFalse(config.rules(forBundleID: id, appName: nil).isEmpty, id)
        }
        XCTAssertTrue(config.rules(forBundleID: "com.apple.Safari", appName: "Safari").isEmpty)
    }

    func testAddingARuleOnce() {
        var config = Config(rules: [])
        XCTAssertTrue(config.addRule(app: "com.apple.Safari"))
        XCTAssertFalse(config.addRule(app: "COM.APPLE.SAFARI"))
        XCTAssertEqual(config.rules, [Rule(app: "com.apple.Safari")])
    }

    func testAddingARuleNextToATitleRuleTilesEveryWindow() {
        var config = Config(rules: [Rule(app: "Terminal", title: "^tmux")])
        XCTAssertTrue(config.addRule(app: "Terminal"))
        XCTAssertEqual(config.rules.count, 2)
    }

    func testRemovingRulesByBundleIDOrName() {
        var config = Config(rules: [Rule(app: "com.apple.Terminal"), Rule(app: "Terminal", title: "^tmux"), Rule(app: "com.apple.Safari")])
        XCTAssertEqual(config.removeRules(bundleID: "com.apple.Terminal", appName: "Terminal"), 2)
        XCTAssertEqual(config.rules, [Rule(app: "com.apple.Safari")])
        XCTAssertEqual(config.removeRules(bundleID: "org.example", appName: "Example"), 0)
    }

    func testInvalidTitlePatternMatchesNothing() {
        let rule = Rule(app: "Terminal", title: "([")
        XCTAssertFalse(rule.matches(bundleID: nil, appName: "Terminal", title: "anything"))
        XCTAssertFalse(rule.matches(bundleID: nil, appName: "Terminal", title: "anything"))
    }

    func testTitlePatternIsReusedAcrossWindows() {
        let rule = Rule(app: "Terminal", title: "^tmux attach")
        XCTAssertTrue(rule.matches(bundleID: nil, appName: "Terminal", title: "tmux attach -t =api"))
        XCTAssertFalse(rule.matches(bundleID: nil, appName: "Terminal", title: "zsh"))
        XCTAssertTrue(rule.matches(bundleID: nil, appName: "Terminal", title: "TMUX ATTACH -t =web"))
    }
}
