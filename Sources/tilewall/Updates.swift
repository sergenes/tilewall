import Foundation
import TilewallCore

/// Looks up the latest release on GitHub. Nothing is downloaded or installed: the user gets a link to the release page.
enum Updates {
    struct Release {
        let version: String
        let page: URL
    }

    private static let latest = URL(string: "https://api.github.com/repos/sergenes/tilewall/releases/latest")!
    /// The newer release found by the last check, if any.
    private(set) static var available: Release?

    /// Asks GitHub for the latest release. The completion runs on the main thread.
    static func check(completion: @escaping (Result<Release, Error>) -> Void) {
        var request = URLRequest(url: latest, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("tilewall", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Release, Error>
            if let error {
                result = .failure(error)
            } else if let data, (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String, Version.parts(tag) != nil,
                      let page = (json["html_url"] as? String).flatMap(URL.init(string:)), page.host == "github.com" {
                result = .success(Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page))
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = .failure(NSError(domain: "tilewall", code: 5, userInfo: [NSLocalizedDescriptionKey: "unexpected reply from GitHub (status \(status))"]))
            }
            DispatchQueue.main.async {
                if case .success(let release) = result {
                    available = Version.isNewer(release.version, than: App.version) ? release : nil
                }
                completion(result)
            }
        }.resume()
    }

    /// One line that says how this copy compares to the latest release.
    static func describe(_ release: Release) -> String {
        if Version.parts(App.version) == nil {
            return "this is a development build, the latest release is \(release.version): \(release.page.absoluteString)"
        }
        return Version.isNewer(release.version, than: App.version)
            ? "tilewall \(release.version) is available, you have \(App.version): \(release.page.absoluteString)"
            : "tilewall \(App.version) is the latest release"
    }
}
