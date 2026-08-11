import Foundation

/// Checks GitHub Releases for a newer build. dude ships outside the App Store as
/// a signed DMG, so "updating" means: notice a newer release, then send the user
/// to download it. No background installer — just a nudge and a download link.
enum UpdateChecker {
    static let repo = "magwann/dude"

    struct Release: Sendable {
        let version: String        // normalized tag, e.g. "1.1"
        let notes: String
        let pageURL: URL
        let dmgURL: URL?           // direct .dmg download, when present
    }

    /// The running app's version (CFBundleShortVersionString).
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// The newest release, or nil on any network/parse error.
    static func latestRelease() async -> Release? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("dude-app", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }

        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(repo)/releases/latest")!
        var dmg: URL?
        if let assets = json["assets"] as? [[String: Any]] {
            for a in assets where (a["name"] as? String)?.lowercased().hasSuffix(".dmg") == true {
                dmg = (a["browser_download_url"] as? String).flatMap(URL.init(string:))
                break
            }
        }
        return Release(version: normalize(tag),
                       notes: (json["body"] as? String) ?? "",
                       pageURL: page, dmgURL: dmg)
    }

    /// The latest release, but only if it's newer than what's running.
    static func availableUpdate() async -> Release? {
        guard let latest = await latestRelease() else { return nil }
        return isNewer(latest.version, than: currentVersion) ? latest : nil
    }

    static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Numeric version compare; pads missing components so "1.1" > "1.0.3".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = components(a), pb = components(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ s: String) -> [Int] {
        s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
