import Foundation

/// Decides whether GitHub has a newer Unsit than the one running.
/// Parsing and comparison only, no networking, so it's unit tested.
public enum UpdateCheck {
    /// The newest published version and the page that describes it.
    public struct Latest: Hashable, Sendable {
        public var version: String
        public var url: URL?

        public init(version: String, url: URL? = nil) {
            self.version = version
            self.url = url
        }
    }

    /// True when `candidate` is a higher version than `current`.
    /// Versions are dotted numbers ("0.2.0"). A leading "v" and any "-beta" or "+build" suffix
    /// are ignored, and missing parts count as zero, so "1.2" equals "1.2.0" and "1.10" beats "1.9".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(in: candidate)
        let b = numbers(in: current)
        guard !a.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// "v0.3.0" → "0.3.0", for showing to people.
    public static func display(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    }

    static func numbers(in version: String) -> [Int] {
        let core = display(version).split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        let parts = core.split(separator: ".")
        var result: [Int] = []
        for part in parts {
            guard let n = Int(part.prefix(while: { $0.isNumber })) else { return [] }
            result.append(n)
        }
        return result
    }

    /// The newest release, from GitHub's `GET /repos/{owner}/{repo}/releases/latest` reply.
    public static func latest(fromReleaseJSON data: Data) -> Latest? {
        struct Release: Decodable {
            let tag_name: String
            let html_url: String?
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.tag_name.isEmpty
        else { return nil }
        return Latest(version: release.tag_name, url: release.html_url.flatMap { URL(string: $0) })
    }

    /// The version in an app Info.plist. The one on main is what a fresh source build would be,
    /// which covers the time before any release is published.
    public static func version(fromInfoPlist data: Data) -> String? {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return (plist as? [String: Any])?["CFBundleShortVersionString"] as? String
    }
}
