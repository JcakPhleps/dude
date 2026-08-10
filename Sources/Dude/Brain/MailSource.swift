import Foundation

/// One email read from Apple Mail's local store.
struct EmailItem {
    let from: String
    let subject: String
    let date: String
    let snippet: String
}

/// Reads recent messages from Apple Mail's on-disk store
/// (`~/Library/Mail/V*/…/*.emlx`) — i.e. whatever account(s) are set up in the
/// default Mail app, no separate login. Requires **Full Disk Access** (the same
/// grant as Messages). Only called when the user asks about email.
enum MailSource {
    enum SourceError: Error { case notReadable }

    static func recentEmails(limit: Int = 12) throws -> [EmailItem] {
        guard let root = mailRoot() else { throw SourceError.notReadable }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { throw SourceError.notReadable }

        // Keep the newest `limit` .emlx files by modification date. Bounded scan
        // so a huge mailbox doesn't stall.
        var newest: [(date: Date, url: URL)] = []
        var scanned = 0
        for case let url as URL in walker {
            guard url.pathExtension == "emlx" else { continue }
            scanned += 1
            if scanned > 20_000 { break }
            let mod = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            newest.append((mod, url))
        }
        newest.sort { $0.date > $1.date }

        return newest.prefix(limit).compactMap { parse($0.url) }
    }

    // MARK: - Locating the store

    /// Highest-numbered `~/Library/Mail/V<n>` directory. Returns nil (→ treated
    /// as "not readable") if Mail isn't set up or Full Disk Access is missing.
    private static func mailRoot() -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil
        ) else { return nil }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("V") && Int($0.lastPathComponent.dropFirst()) != nil }
            .max { (Int($0.lastPathComponent.dropFirst()) ?? 0) < (Int($1.lastPathComponent.dropFirst()) ?? 0) }
    }

    // MARK: - Parsing

    private static func parse(_ url: URL) -> EmailItem? {
        guard let data = try? Data(contentsOf: url),
              let firstNewline = data.firstIndex(of: 0x0a) else { return nil }
        // .emlx starts with a byte-count line; the RFC822 message follows.
        // Normalize CRLF → LF up front: Swift treats "\r\n" as a single
        // Character, so splitting on "\n" wouldn't find CRLF line breaks.
        let message = String(decoding: data[(firstNewline + 1)...], as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let headers = unfoldedHeaders(from: message)
        let from = decodeMIMEWords(headers["from"] ?? "").trimmingCharacters(in: .whitespaces)
        let subject = decodeMIMEWords(headers["subject"] ?? "(no subject)").trimmingCharacters(in: .whitespaces)
        let date = headers["date"] ?? ""

        return EmailItem(
            from: prettyFrom(from),
            subject: subject.isEmpty ? "(no subject)" : subject,
            date: date,
            snippet: snippet(from: message)
        )
    }

    /// Parse the header block (up to the first blank line), unfolding
    /// continuation lines, into a lowercased-name → value map.
    private static func unfoldedHeaders(from message: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentName: String?
        var currentValue = ""

        func commit() {
            if let name = currentName {
                headers[name.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
            }
        }

        for rawLine in message.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty { commit(); break } // end of headers
            if line.first == " " || line.first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces) // folded continuation
            } else if let colon = line.firstIndex(of: ":") {
                commit()
                currentName = String(line[..<colon])
                currentValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return headers
    }

    /// Prefer a display name over a bare address when the From header has both.
    private static func prettyFrom(_ from: String) -> String {
        if let lt = from.firstIndex(of: "<"), lt != from.startIndex {
            let name = from[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
        }
        return from.isEmpty ? "(unknown)" : from
    }

    private static func snippet(from message: String) -> String {
        guard let blank = message.range(of: "\r\n\r\n") ?? message.range(of: "\n\n") else { return "" }
        let body = message[blank.upperBound...]
        // Skip obvious MIME/HTML noise for the snippet.
        let firstText = body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                !line.isEmpty && !line.hasPrefix("--") && !line.hasPrefix("<")
                    && !line.lowercased().hasPrefix("content-")
            } ?? ""
        return String(firstText.prefix(140))
    }

    // MARK: - MIME encoded-word decoding (=?UTF-8?B?…?= / =?…?Q?…?=)

    private static func decodeMIMEWords(_ input: String) -> String {
        guard input.contains("=?"),
              let regex = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=")
        else { return input }

        let ns = input as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let enc = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            if enc == "B", let d = Data(base64Encoded: payload) {
                out += String(data: d, encoding: .utf8) ?? payload
            } else if enc == "Q" {
                out += decodeQ(payload)
            } else {
                out += payload
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out.isEmpty ? input : out
    }

    private static func decodeQ(_ s: String) -> String {
        var bytes: [UInt8] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "_" {
                bytes.append(0x20); i += 1
            } else if c == "=", i + 2 < chars.count, let b = UInt8(String(chars[i + 1...i + 2]), radix: 16) {
                bytes.append(b); i += 3
            } else {
                bytes.append(contentsOf: Array(String(c).utf8)); i += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? s
    }
}
