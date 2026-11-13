import Foundation

/// A window is tiled automatically when its app, and optionally its title, match a rule.
public struct Rule: Codable, Equatable {
    /// Bundle identifier or app name, case insensitive.
    public var app: String
    /// Optional regular expression the window title must match.
    public var title: String?

    public init(app: String, title: String? = nil) {
        self.app = app
        self.title = title
    }

    public func matches(bundleID: String?, appName: String?, title windowTitle: String) -> Bool {
        let wanted = app.lowercased()
        guard bundleID?.lowercased() == wanted || appName?.lowercased() == wanted else { return false }
        guard let pattern = title, !pattern.isEmpty else { return true }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(windowTitle.startIndex..., in: windowTitle)
        return regex.firstMatch(in: windowTitle, range: range) != nil
    }
}

public struct Config: Codable, Equatable {
    public var rules: [Rule]
    public var focusFraction: Double
    public var gap: Double
    public var targetAspect: Double
    /// Action name to key combination, for example "toggle": "ctrl+alt+m". An empty string disables the hotkey.
    public var hotkeys: [String: String]

    /// The backdrop behind each group: "auto" follows the system appearance, "#rrggbb" is a fixed color, "none" disables it.
    public var backdrop: String
    /// "landscape" lays tiles out in rows, "portrait" in columns.
    public var orientation: Orientation

    /// All defaults sit under the left hand, next to the left control and option keys.
    public static let defaultHotkeys: [String: String] = [
        "toggle": "ctrl+alt+t",
        "next": "ctrl+alt+d",
        "prev": "ctrl+alt+a",
        "fill": "ctrl+alt+f",
        "send": "ctrl+alt+s",
        "retile": "ctrl+alt+r",
        "pause": "ctrl+alt+z",
        "help": "ctrl+alt+q",
    ]

    public init(
        rules: [Rule] = [Rule(app: "com.apple.Terminal")],
        focusFraction: Double = 0.5,
        gap: Double = 0,
        targetAspect: Double = 1.5,
        hotkeys: [String: String] = Config.defaultHotkeys,
        backdrop: String = "auto",
        orientation: Orientation = .landscape
    ) {
        self.rules = rules
        self.focusFraction = focusFraction
        self.gap = gap
        self.targetAspect = targetAspect
        self.hotkeys = hotkeys
        self.backdrop = backdrop
        self.orientation = orientation
    }

    public init(from decoder: Decoder) throws {
        let defaults = Config()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? defaults.rules
        focusFraction = try c.decodeIfPresent(Double.self, forKey: .focusFraction) ?? defaults.focusFraction
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? defaults.gap
        targetAspect = try c.decodeIfPresent(Double.self, forKey: .targetAspect) ?? defaults.targetAspect
        hotkeys = defaults.hotkeys.merging(try c.decodeIfPresent([String: String].self, forKey: .hotkeys) ?? [:]) { _, new in new }
        backdrop = try c.decodeIfPresent(String.self, forKey: .backdrop) ?? defaults.backdrop
        orientation = try c.decodeIfPresent(Orientation.self, forKey: .orientation) ?? defaults.orientation
        guard focusFraction > 0, focusFraction <= 1 else {
            throw DecodingError.dataCorruptedError(forKey: .focusFraction, in: c, debugDescription: "focusFraction must be in (0, 1]")
        }
        guard gap >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .gap, in: c, debugDescription: "gap must not be negative")
        }
    }

    public var layoutOptions: LayoutOptions {
        LayoutOptions(focusFraction: focusFraction, gap: gap, targetAspect: targetAspect, orientation: orientation)
    }
}

public enum Paths {
    public static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["TILEWALL_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tilewall", isDirectory: true)
    }
    public static var config: URL { home.appendingPathComponent("config.json") }
    public static var state: URL { home.appendingPathComponent("state.json") }
    public static var socket: URL { home.appendingPathComponent("tilewall.sock") }
    public static var log: URL { home.appendingPathComponent("tilewall.log") }
}

public enum ConfigStore {
    /// Loads the config, writing the defaults first when the file does not exist.
    public static func save(_ config: Config, to url: URL = Paths.config) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    public static func load(from url: URL = Paths.config) throws -> Config {
        if !FileManager.default.fileExists(atPath: url.path) { try save(Config(), to: url) }
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }
}
