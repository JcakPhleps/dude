import Foundation

/// Minimal client for Google's Gemini API (AI Studio / Generative Language API).
///
/// There's no official Google Gen AI SDK for Swift, so this talks raw HTTPS to
/// `generateContent` using the multimodal shape (an inline image part followed
/// by a text part). It also speaks Gemini's function-calling protocol so Dude
/// can actually *do* things (send a text, add an event, drive Spotify) instead
/// of just describing them.
///
/// The wire shapes and encode/decode live in `Gemini` (GeminiProtocol.swift);
/// this type owns the HTTP round-trip and adds a timeout plus a short retry with
/// backoff, since the free tier hands out transient 429/503s under load.
///
/// Default model is `gemini-flash-latest` (Gemini 3 Flash) — the smartest model
/// still on the free tier; it reasons dynamically and does vision. Override via
/// config (see `Secrets.geminiModel`), e.g. `gemini-flash-lite-latest` for lower
/// latency.
///
/// Because the default model *thinks* before answering, requests need generous
/// `maxOutputTokens` headroom: thinking tokens draw from the same budget, so too
/// small a cap can be spent entirely on reasoning, leaving an empty reply. Hence
/// the per-call `maxOutputTokens` argument (big for the agentic loop, modest for
/// the observer's one-liner).
struct GeminiClient {
    /// Kept as a nested alias so existing call sites (and error handling that
    /// switches on it) don't need to change.
    typealias ClientError = Gemini.WireError

    private static let base = "https://generativelanguage.googleapis.com/v1beta/models"

    /// Per-request ceiling. A hung request would otherwise strand Dude in the
    /// "thinking" pose forever, since the caller keeps `isBusy` until we return.
    private let timeout: TimeInterval = 45

    /// Total attempts (1 try + retries) for transient failures.
    private let maxAttempts = 3

    // MARK: - Public API

    /// Simple one-shot text ask (used by the background Observer). No tools.
    /// A modest output budget — enough for a short reply plus the model's own
    /// thinking — keeps this cheap on the free tier.
    func ask(system: String, question: String, imageBase64: String?) async throws -> String {
        var parts: [Gemini.Part] = []
        if let imageBase64 { parts.append(.image(base64: imageBase64)) }
        parts.append(.text(question))
        let turn = try await generate(system: system, history: [.init(role: "user", parts: parts)],
                                      useTools: false, maxOutputTokens: 1024)
        return turn.text ?? ""
    }

    /// Full turn: send the running `history`, optionally advertising Dude's
    /// tools, and get back text and/or the tool calls the model wants to make.
    /// `maxOutputTokens` must leave room for the model's thinking as well as the
    /// visible answer (see the type doc).
    func generate(system: String, history: [Gemini.Turn], useTools: Bool,
                  maxOutputTokens: Int = 2048) async throws -> Gemini.ModelTurn {
        guard let key = Secrets.googleAPIKey else { throw ClientError.missingAPIKey }

        let model = Secrets.geminiModel
        // A bad `gemini_model` in config (spaces, junk) used to crash on a
        // force-unwrapped URL. Validate and fail soft instead.
        guard
            let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "\(Self.base)/\(encodedModel):generateContent")
        else {
            throw ClientError.badModel(model)
        }

        var body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": history.map(Gemini.encode),
            "generationConfig": ["maxOutputTokens": maxOutputTokens],
        ]
        if useTools {
            body["tools"] = [["function_declarations": ActionRunner.functionDeclarations()]]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await send(request)
    }

    // MARK: - Transport (timeout + retry with backoff)

    /// Fire the request, retrying a few times on transient failures (rate limits,
    /// 5xx, dropped connections) with a short exponential backoff. Non-transient
    /// errors (bad key, safety block, malformed) fail fast — retrying won't help.
    private func send(_ request: URLRequest) async throws -> Gemini.ModelTurn {
        var lastError: Error = ClientError.malformedResponse

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                // 0.6s, then 1.8s — enough to ride out a brief overload without
                // making the user wait ages.
                let backoff = UInt64(0.6 * pow(3.0, Double(attempt - 1)) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: backoff)
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ClientError.malformedResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    let bodyText = String(data: data, encoding: .utf8) ?? "<no body>"
                    let error = ClientError.http(status: http.statusCode, body: bodyText)
                    if Gemini.isRetryable(status: http.statusCode) {
                        lastError = error
                        continue
                    }
                    throw error
                }
                return try Gemini.decode(data)
            } catch let error as ClientError {
                // Our own decoded errors are terminal — don't burn retries on them.
                throw error
            } catch {
                // URLSession threw (timeout, connection lost, offline). These are
                // worth another shot.
                lastError = error
                if !Self.isTransientTransportError(error) { throw error }
            }
        }
        throw lastError
    }

    /// Network-level errors that a retry might clear (as opposed to, say, a bad
    /// URL, which won't).
    private static func isTransientTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .dnsLookupFailed, .notConnectedToInternet, .cannotFindHost,
             .resourceUnavailable, .badServerResponse:
            return true
        default:
            return false
        }
    }
}
