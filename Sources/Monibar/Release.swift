import Foundation

/// Semantic-ish version strings such as "0.1.0" or the tag "v0.1.0".
enum AppVersion {
    /// Without the "v" of a tag.
    static func normalized(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
    }

    /// Numeric components, a pre-release suffix ("-beta.1") ignored.
    /// Empty when the string does not start with a number.
    static func components(_ s: String) -> [Int] {
        let core = normalized(s).split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        var result: [Int] = []
        for part in core.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part) else { break }
            result.append(n)
        }
        return result
    }

    /// Whether `a` is a later version than `b`. Missing components count
    /// as 0, so "0.1" equals "0.1.0". A malformed `a` is never newer.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = components(a), pb = components(b)
        guard !pa.isEmpty else { return false }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// The parts of a GitHub "latest release" answer the updater uses.
struct GitHubRelease: Equatable, Sendable {
    let version: String
    let pageURL: URL
    /// The DMG asset, `nil` when the release has none: the update then
    /// opens the release page instead.
    let dmgURL: URL?

    init(version: String, pageURL: URL, dmgURL: URL?) {
        self.version = version
        self.pageURL = pageURL
        self.dmgURL = dmgURL
    }

    /// Parses `GET /repos/{owner}/{repo}/releases/latest`. Only an https
    /// asset named `assetName` is kept.
    static func parse(_ data: Data, assetName: String, fallbackPage: URL) throws -> GitHubRelease {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
            let tag_name: String
            let html_url: String?
            let assets: [Asset]?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let dmg = payload.assets?
            .first { $0.name == assetName }
            .flatMap { URL(string: $0.browser_download_url) }
            .flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        return GitHubRelease(
            version: AppVersion.normalized(payload.tag_name),
            pageURL: payload.html_url.flatMap(URL.init(string:)) ?? fallbackPage,
            dmgURL: dmg
        )
    }
}

/// When the background update check runs and when it notifies.
enum UpdatePolicy {
    /// At most once per `interval`. A last check in the future (clock set
    /// back) does not block checks.
    static func shouldCheck(lastCheck: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastCheck, lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// A newer version, not notified before.
    static func shouldNotify(latest: String, current: String, lastNotified: String?) -> Bool {
        AppVersion.isNewer(latest, than: current) && latest != lastNotified
    }
}
