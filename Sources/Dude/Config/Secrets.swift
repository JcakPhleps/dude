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
    /// Default model: the smartest model still on Google's **free** tier —
    /// Gemini Flash (currently Gemini 3 Flash), which reasons ("thinks")
    /// dynamically and does vision. The `-latest` alias tracks the current
    /// Flash so a pinned model can't get retired out from under us. Free-tier
    /// limits (~1,500 requests/day) are plenty for a desktop buddy. For lower
    /// latency / even less quota, set `"gemini_model": "gemini-flash-lite-latest"`
    /// in config.json.
    static let defaultGeminiModel = "gemini-flash-latest"

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

    /// The key saved in `~/.dude/config.json` (ignoring the environment), so the
    /// Setup UI can show and edit exactly what the user typed.
    static var storedAPIKey: String? { configValue(for: "google_api_key") }

    /// Save (or clear, if empty) the Gemini key to `~/.dude/config.json`, keeping
    /// any other settings intact. Creates the folder if needed.
    static func setGoogleAPIKey(_ key: String) {
        setConfigValue(key.trimmingCharacters(in: .whitespacesAndNewlines), for: "google_api_key")
    }

    /// Make sure `~/.dude/` exists with a starter config the first time Dude runs,
    /// so people always have a place (and a template) for their key — even before
    /// they open Setup. Safe to call on every launch.
    static func bootstrapConfig() {
        let fm = FileManager.default
        try? fm.createDirectory(at: configDirURL, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: configURL.path(percentEncoded: false)) {
            let template = """
            {
              "google_api_key": "",
              "gemini_model": "\(defaultGeminiModel)"
            }
            """
            try? template.data(using: .utf8)?.write(to: configURL)
        }

        let readme = configDirURL.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path(percentEncoded: false)) {
            let text = """
            dude — settings folder
            ======================

            Your Gemini API key and preferences live in config.json (in this folder).
            The easy way to set your key is in the app: click dude ▸ menu-bar item ▸
            Setup… and paste it there.

            Or edit config.json by hand:
              {
                "google_api_key": "PASTE_YOUR_KEY_HERE",
                "gemini_model": "\(defaultGeminiModel)"
              }

            Get a free key at https://aistudio.google.com/apikey
            Nothing here is ever uploaded except the key you choose to use.
            """
            try? text.data(using: .utf8)?.write(to: readme)
        }
    }

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

    private static var configDirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dude", isDirectory: true)
    }

    private static var configURL: URL {
        configDirURL.appendingPathComponent("config.json")
    }

    /// Read the config (or an empty dict), set/clear one key, write it back
    /// pretty-printed. Creates `~/.dude/` if it isn't there yet.
    private static func setConfigValue(_ value: String, for key: String) {
        try? FileManager.default.createDirectory(at: configDirURL, withIntermediateDirectories: true)
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = json
        }
        if value.isEmpty { dict.removeValue(forKey: key) } else { dict[key] = value }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL)
        }
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
