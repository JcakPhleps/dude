import Foundation

/// The wire protocol for Google's Gemini `generateContent` API: the request /
/// response *shapes* and the pure encode/decode between them and Dude's own
/// conversation model.
///
/// This is deliberately dependency-free (Foundation only) — no `Secrets`, no
/// `ActionRunner`, no networking — so it can be exercised by unit tests without
/// dragging in the whole app or a live API key. `GeminiClient` owns the actual
/// HTTP round-trip and layers timeout/retry on top of these primitives.
enum Gemini {

    // MARK: - Errors

    enum WireError: LocalizedError, Equatable {
        case missingAPIKey
        case badModel(String)
        case http(status: Int, body: String)
        case blocked(reason: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Google API key configured."
            case .badModel(let name):
                return "That model name (\(name)) isn't valid — check gemini_model in your config."
            case .http(let status, let body):
                return "API error \(status): \(body)"
            case .blocked(let reason):
                return "The request was blocked (\(reason))."
            case .malformedResponse:
                return "Couldn't read the model's response."
            }
        }
    }

    // MARK: - Conversation model (Sendable so it crosses actors cleanly)

    /// One part of a turn. Covers the shapes we actually send/receive.
    enum Part: Sendable, Equatable {
        case text(String)
        case image(base64: String)
        /// A tool call the model made — `argsJSON` is the raw JSON object so we
        /// can echo it back verbatim. `id`/`thoughtSignature` come straight from
        /// the model and MUST be echoed back (Gemini 3.x rejects the follow-up
        /// request otherwise).
        case functionCall(name: String, argsJSON: String, id: String?, thoughtSignature: String?)
        /// Our reply to a tool call, fed back so the model can keep going. `id`
        /// pairs it to the originating call.
        case functionResponse(name: String, id: String?, result: String)
    }

    struct Turn: Sendable, Equatable {
        let role: String    // "user" or "model"
        let parts: [Part]
    }

    struct FunctionCall: Sendable, Equatable {
        let name: String
        let args: [String: String]
        let argsJSON: String
        let id: String?
        let thoughtSignature: String?
    }

    /// What the model produced this round: some text, and/or tool calls.
    struct ModelTurn: Sendable, Equatable {
        let text: String?
        let calls: [FunctionCall]
    }

    // MARK: - Retry policy

    /// HTTP statuses worth retrying: rate-limiting and the transient 5xx family
    /// that the free tier hands out under load. 4xx (other than 429) are the
    /// caller's fault and won't fix themselves, so we don't retry those.
    static func isRetryable(status: Int) -> Bool {
        status == 429 || status == 500 || status == 502 || status == 503 || status == 504
    }

    // MARK: - Encoding

    static func encode(_ turn: Turn) -> [String: Any] {
        var parts: [[String: Any]] = []
        for part in turn.parts {
            switch part {
            case .text(let t):
                parts.append(["text": t])
            case .image(let b64):
                parts.append(["inline_data": ["mime_type": "image/jpeg", "data": b64]])
            case .functionCall(let name, let argsJSON, let id, let thoughtSignature):
                let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) ?? [:]
                var call: [String: Any] = ["name": name, "args": args]
                if let id { call["id"] = id }
                var part: [String: Any] = ["functionCall": call]
                if let thoughtSignature { part["thoughtSignature"] = thoughtSignature }
                parts.append(part)
            case .functionResponse(let name, let id, let result):
                var fr: [String: Any] = ["name": name, "response": ["result": result]]
                if let id { fr["id"] = id }
                parts.append(["functionResponse": fr])
            }
        }
        return ["role": turn.role, "parts": parts]
    }

    // MARK: - Decoding

    /// Finish reasons that mean the model refused / was cut off for policy, not
    /// that it merely ran long. We surface these as a `.blocked` so Dude can say
    /// something honest instead of "couldn't read the response".
    private static let refusalReasons: Set<String> = [
        "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "IMAGE_SAFETY",
    ]

    /// Turn a raw `generateContent` response body into a `ModelTurn`, or throw a
    /// `WireError` that explains what went wrong.
    static func decode(_ data: Data) throws -> ModelTurn {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WireError.malformedResponse
        }

        // A prompt-level safety/policy block comes back with no candidates and a
        // reason on promptFeedback.
        if let feedback = json["promptFeedback"] as? [String: Any],
           let reason = feedback["blockReason"] as? String {
            throw WireError.blocked(reason: reason)
        }

        guard
            let candidates = json["candidates"] as? [[String: Any]],
            let first = candidates.first
        else {
            throw WireError.malformedResponse
        }

        let finishReason = first["finishReason"] as? String

        // Parts can legitimately be absent when the candidate was itself blocked.
        let parts = (first["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []

        var textChunks: [String] = []
        var calls: [FunctionCall] = []
        for part in parts {
            if let text = part["text"] as? String {
                textChunks.append(text)
            }
            if let call = part["functionCall"] as? [String: Any],
               let name = call["name"] as? String {
                let argsObj = call["args"] as? [String: Any] ?? [:]
                let argsJSON = (try? JSONSerialization.data(withJSONObject: argsObj))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                calls.append(FunctionCall(
                    name: name,
                    args: stringify(argsObj),
                    argsJSON: argsJSON,
                    id: call["id"] as? String,
                    thoughtSignature: part["thoughtSignature"] as? String
                ))
            }
        }

        let text = textChunks.joined().trimmingCharacters(in: .whitespacesAndNewlines)

        // Nothing usable came back. If the candidate was cut for policy, say so;
        // otherwise it's a shape we didn't understand.
        if text.isEmpty && calls.isEmpty {
            if let finishReason, refusalReasons.contains(finishReason) {
                throw WireError.blocked(reason: finishReason)
            }
            throw WireError.malformedResponse
        }

        // MAX_TOKENS (and friends) still leave us a partial-but-useful answer —
        // return it rather than throwing the good text away.
        return ModelTurn(text: text.isEmpty ? nil : text, calls: calls)
    }

    /// Flatten a JSON args object to `[String: String]` (all our tool params are
    /// scalar strings; coerce anything else to its string form).
    static func stringify(_ obj: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String {
                out[k] = s
            } else if let n = v as? NSNumber {
                // JSON booleans bridge to NSNumber too; tell them apart by the
                // CF type so a real `1` doesn't come out as "true".
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    out[k] = n.boolValue ? "true" : "false"
                } else {
                    out[k] = n.stringValue
                }
            } else {
                out[k] = String(describing: v)
            }
        }
        return out
    }
}
