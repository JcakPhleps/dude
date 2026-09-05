import Foundation

/// Pure, dependency-free helpers behind Dude's actions: escaping strings for
/// AppleScript, validating tool arguments, and parsing the date strings the
/// model hands back. Split out from `ActionRunner` (which is `@MainActor` and
/// pulls in AppKit/EventKit) so these can be unit-tested in isolation.
enum ActionParsing {

    /// Escape a string for interpolation into an AppleScript double-quoted
    /// literal. Backslash first (so we don't double-escape our own escapes), then
    /// quotes and every line/tab break — an unescaped newline or a stray quote in
    /// a recipient/subject/body would otherwise break out of the literal and
    /// change what the script does.
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\r\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\n")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Trim, then treat an all-whitespace or empty argument as absent.
    static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Accept ISO-8601 (with or without seconds/zone) and a couple of plain
    /// "yyyy-MM-dd HH:mm" shapes, interpreted in the local time zone.
    static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = .current
            df.dateFormat = format
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}
