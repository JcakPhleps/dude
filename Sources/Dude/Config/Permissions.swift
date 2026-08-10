import Foundation

/// Runtime permission probes. Full Disk Access can't be queried through an API,
/// so we detect it by actually trying to read a file that only an FDA-granted
/// app can open.
enum Permissions {
    /// True if this process can read Full-Disk-Access-protected files right now.
    ///
    /// Probes a couple of always-present, always-protected paths. `TCC.db` exists
    /// on every Mac and is FDA-gated, so it's the reliable signal; the others are
    /// fallbacks. Note: a grant made while the app is already running only takes
    /// effect on the *next launch*, so this can read false until Dude restarts.
    static var hasFullDiskAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari/Bookmarks.plist",
            "Library/Messages/chat.db",
        ]
        for path in probes {
            let url = home.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                if (try? handle.read(upToCount: 1)) != nil { return true }
            }
            // Exists but unreadable → almost certainly no FDA; keep probing in
            // case this particular file is the odd one out.
        }
        return false
    }
}
