import ApplicationServices
import Cocoa
import MosaicCore

/// Square window corners through an undocumented AppKit default (macOS 26.4 and later).
///
/// The value is read by an app when it starts, so a change only shows after that app is relaunched.
/// It is a global default: it applies to every app, not only to tiles.
enum Corners {
    private static let key = "NSConvolutionOverride1" as CFString

    static var isSquare: Bool {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let value = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? NSNumber).map { $0.doubleValue < 4 } ?? false
    }

    static func setSquare(_ square: Bool) {
        // A radius of 1 is the smallest value AppKit is known to honour.
        let value: CFNumber? = square ? (1 as CFNumber) : nil
        CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

/// Finds tmux sessions shown in Terminal windows and opens new windows attached to them.
enum TerminalSessions {
    static let bundleID = "com.apple.Terminal"

    /// The tmux session a Terminal window title refers to, for example "aaw-kids" in "tmux attach -t =aaw-kids".
    static func session(inTitle title: String) -> String? {
        guard let range = title.range(of: #"tmux attach(-session)? -t =?[A-Za-z0-9._-]+"#, options: .regularExpression) else { return nil }
        return String(title[range]).components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Sessions attached in any Terminal window, on every space, in window order.
    static func attached() -> [String] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var seen: Set<String> = []
        return element.elements(kAXWindowsAttribute)
            .compactMap { $0.string(kAXTitleAttribute).flatMap(session(inTitle:)) }
            .filter { seen.insert($0).inserted }
    }

    /// Opens a new Terminal window attached to the session. Works whether or not Terminal is running.
    static func open(_ session: String) throws {
        guard session.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "mosaic", code: 3, userInfo: [NSLocalizedDescriptionKey: "unsupported session name \"\(session)\""])
        }
        let directory = Paths.home.appendingPathComponent("attach", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("\(session).command")
        try "#!/bin/zsh -l\nclear\nexec tmux attach -t '=\(session)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-a", "Terminal", script.path]
        try opener.run()
        opener.waitUntilExit()
        guard opener.terminationStatus == 0 else {
            throw NSError(domain: "mosaic", code: 4, userInfo: [NSLocalizedDescriptionKey: "could not open Terminal for \(session)"])
        }
    }
}
