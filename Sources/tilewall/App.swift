import Foundation
import ServiceManagement

/// Facts about how this copy of tilewall was built and started.
enum App {
    /// True when running from inside tilewall.app, false for a bare command line binary.
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
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
