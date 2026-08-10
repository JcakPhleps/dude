import Foundation

/// Minimal client for Google's Gemini API (AI Studio / Generative Language API).
///
/// There's no official Google Gen AI SDK for Swift, so this talks raw HTTPS to
/// `generateContent` using the multimodal shape (an inline image part followed
/// by a text part). It also speaks Gemini's function-calling protocol so Dude
/// can actually *do* things (send a text, add an event, drive Spotify) instead
/// of just describing them.
///
/// Default model is `gemini-flash-lite-latest` — the cheapest model that still
/// does vision, and covered by the free tier. Override via config (see
/// `Secrets.geminiModel`) for sharper answers.
struct GeminiClient {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case http(status: Int, body: String)
        case blocked(reason: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Google API key configured."
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
    enum Part: Sendable {
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

    struct Turn: Sendable {
        let role: String    // "user" or "model"
        let parts: [Part]
    }

    struct FunctionCall: Sendable {
        let name: String
        let args: [String: String]
        let argsJSON: String
        let id: String?
        let thoughtSignature: String?
    }

    /// What the model produced this round: some text, and/or tool calls.
    struct ModelTurn: Sendable {
        let text: String?
        let calls: [FunctionCall]
    }

    private static let base = "https://generativelanguage.googleapis.com/v1beta/models"

    // MARK: - Public API

    /// Simple one-shot text ask (used by the background Observer). No tools.
    func ask(system: String, question: String, imageBase64: String?) async throws -> String {
        var parts: [Part] = []
        if let imageBase64 { parts.append(.image(base64: imageBase64)) }
        parts.append(.text(question))
        let turn = try await generate(system: system, history: [Turn(role: "user", parts: parts)], useTools: false)
        return turn.text ?? ""
    }

    /// Full turn: send the running `history`, optionally advertising Dude's
    /// tools, and get back text and/or the tool calls the model wants to make.
    func generate(system: String, history: [Turn], useTools: Bool) async throws -> ModelTurn {
        guard let key = Secrets.googleAPIKey else { throw ClientError.missingAPIKey }

        var body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": history.map(Self.encode),
            "generationConfig": ["maxOutputTokens": 1024],
        ]
        if useTools {
            body["tools"] = [["function_declarations": ActionRunner.functionDeclarations()]]
        }

        let model = Secrets.geminiModel
        let url = URL(string: "\(Self.base)/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<no body>")
        }
        return try Self.parseTurn(from: data)
    }

    // MARK: - Encoding

    private static func encode(_ turn: Turn) -> [String: Any] {
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

    private static func parseTurn(from data: Data) throws -> ModelTurn {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.malformedResponse
        }

        // A safety/policy block comes back with no candidates and a reason.
        if let feedback = json["promptFeedback"] as? [String: Any],
           let reason = feedback["blockReason"] as? String {
            throw ClientError.blocked(reason: reason)
        }

        guard
            let candidates = json["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            throw ClientError.malformedResponse
        }

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
        if text.isEmpty && calls.isEmpty {
            throw ClientError.malformedResponse
        }
        return ModelTurn(text: text.isEmpty ? nil : text, calls: calls)
    }

    /// Flatten a JSON args object to `[String: String]` (all our tool params are
    /// scalar strings; coerce anything else to its string form).
    private static func stringify(_ obj: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
            else if let n = v as? NSNumber { out[k] = n.stringValue }
            else if let b = v as? Bool { out[k] = b ? "true" : "false" }
            else { out[k] = String(describing: v) }
        }
        return out
    }
}
