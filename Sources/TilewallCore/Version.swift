import Foundation

/// Release versions such as "0.2.0" or the tag "v0.2.0".
public enum Version {
    /// The numeric parts of a version, nil when it is not a dotted number such as a development build's "dev".
    public static func parts(_ text: String) -> [Int]? {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let numbers = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
        return numbers.compactMap { $0 }
    }

    /// True when `candidate` is a later release than `current`. False when either is not a release version.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
