import Foundation
import SQLite3

/// One message read from the local Messages database.
struct MessageItem {
    let sender: String   // handle (phone/email) of the other party, or "me"
    let body: String
    let date: Date
    let fromMe: Bool
}

/// Reads recent iMessage/SMS conversations straight from the local Messages
/// store (`~/Library/Messages/chat.db`).
///
/// Requires **Full Disk Access** — macOS blocks reads of this file otherwise.
/// Opened read-only + immutable, so it's safe even while Messages is running.
/// Dude only calls this when you explicitly ask about your messages; it never
/// runs in the background.
enum MessagesSource {
    enum SourceError: Error { case notReadable }

    static var dbURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
    }

    static func recentMessages(limit: Int = 15) throws -> [MessageItem] {
        var db: OpaquePointer?
        let uri = "file:\(dbURL.path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw SourceError.notReadable
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT h.id, m.is_from_me, m.date, m.text, m.attributedBody
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        ORDER BY m.date DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SourceError.notReadable
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var out: [MessageItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sender = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "unknown"
            let fromMe = sqlite3_column_int(stmt, 1) == 1
            let rawDate = sqlite3_column_int64(stmt, 2)

            var body = ""
            if let t = sqlite3_column_text(stmt, 3) {
                body = String(cString: t)
            }
            // Modern macOS leaves `text` NULL and stores the body in
            // `attributedBody` (a legacy streamtyped archive) — decode it.
            if body.isEmpty, sqlite3_column_type(stmt, 4) == SQLITE_BLOB,
               let blob = sqlite3_column_blob(stmt, 4) {
                let n = Int(sqlite3_column_bytes(stmt, 4))
                body = decodeAttributedBody(Data(bytes: blob, count: n)) ?? ""
            }

            guard !body.isEmpty else { continue }
            out.append(MessageItem(
                sender: fromMe ? "me" : sender,
                body: body,
                date: appleDate(rawDate),
                fromMe: fromMe
            ))
        }
        return out.reversed() // chronological (oldest → newest)
    }

    // MARK: - Helpers

    /// Messages stores dates as nanoseconds (modern) or seconds (legacy) since
    /// the 2001 reference date.
    private static func appleDate(_ raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1e9 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Pulls the message text out of a `streamtyped` NSAttributedString blob.
    /// Uses the well-known length-prefix heuristic (works for the vast majority
    /// of messages): locate "NSString", then the `+` marker, then a 1–3 byte
    /// length, then the UTF-8 bytes.
    private static func decodeAttributedBody(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let start = firstIndex(of: Array("NSString".utf8), in: bytes) else { return nil }

        var i = start + "NSString".count
        while i < bytes.count, bytes[i] != 0x2b { i += 1 } // find '+'
        i += 1
        guard i < bytes.count else { return nil }

        var length = Int(bytes[i]); i += 1
        if length == 0x81 {
            guard i + 1 < bytes.count else { return nil }
            length = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            i += 2
        } else if length == 0x82 {
            guard i + 2 < bytes.count else { return nil }
            length = Int(bytes[i]) | (Int(bytes[i + 1]) << 8) | (Int(bytes[i + 2]) << 16)
            i += 3
        }

        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<(i + length)], encoding: .utf8)
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for start in 0...(bytes.count - pattern.count) {
            var matched = true
            for j in 0..<pattern.count where bytes[start + j] != pattern[j] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }
}
