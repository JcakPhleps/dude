import Foundation

/// Resolves the Google (Gemini) API key without ever hardcoding it.
///
/// Get a **free** key at https://aistudio.google.com/apikey — the Gemini API
/// has a no-cost tier with generous rate limits.
///
/// Lookup order (first match wins):
///   1. `GOOGLE_API_KEY` or `GEMINI_API_KEY` environment variable.
///   2. `~/.dude/config.json` → `{ "google_api_key": "..." }`
///
/// When no key is found, Dude runs in "stub" mode: the app is fully usable and
/// explains that it needs a key to actually see your screen and answer.
enum Secrets {
    /// Default model: cheapest tier that still does vision, and on the free
    /// tier. The `-latest` alias tracks the current flash-lite so a pinned
    /// model can't get retired out from under us. Override in config.json with
    /// `"gemini_model": "gemini-flash-latest"` for sharper answers.
    static let defaultGeminiModel = "gemini-flash-lite-latest"

    static var googleAPIKey: String? {
        let env = ProcessInfo.processInfo.environment
        for name in ["GOOGLE_API_KEY", "GEMINI_API_KEY"] {
            if let value = env[name], !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        return configValue(for: "google_api_key") ?? configValue(for: "gemini_api_key")
    }

    static var hasKey: Bool { googleAPIKey != nil }

    static var geminiModel: String {
        configValue(for: "gemini_model") ?? defaultGeminiModel
    }

    /// How often background observation captures the screen, in seconds.
    /// Override in config.json with `"observe_interval_seconds": 300`.
    /// Floored at 30s to stay friendly to the free tier.
    static var observeIntervalSeconds: Double {
        if let v = configNumber(for: "observe_interval_seconds") { return max(30, v) }
        return 180
    }

    /// Path shown to the user so they know where to drop the key in.
    static var configPath: String {
        configURL.path(percentEncoded: false)
    }

    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dude", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private static func configValue(for key: String) -> String? {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return value
    }

    private static func configNumber(for key: String) -> Double? {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = json[key] as? NSNumber
        else { return nil }
        return number.doubleValue
    }
}
