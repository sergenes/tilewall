import Foundation
import ServiceManagement

/// Facts about how this copy of tilewall was built and started.
enum App {
    /// True when running from inside tilewall.app, false for a bare command line binary.
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// The app bundle this binary lives in, also when it was started through a symlink such as ~/.local/bin/tilewall.
    static let bundleURL: URL? = {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }()

    static var version: String {
        let bundle = bundleURL.flatMap(Bundle.init(url:)) ?? Bundle.main
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Where people can support the project. The menu item is hidden while this is empty.
    static let supportURL = ""
    static let sourceURL = "https://github.com/sergenes/tilewall"

    /// Start at login. Only an app bundle can register itself as a login item.
    static var launchesAtLogin: Bool {
        get { isBundled && SMAppService.mainApp.status == .enabled }
        set {
            guard isBundled else { return }
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log("cannot change the login item: \(error.localizedDescription)")
            }
        }
    }
}
