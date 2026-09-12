import XCTest
import Foundation

/// Real behavior tests for the agent. These exercise the EXACT system prompt and
/// tool schema Dude ships with (`AgentSpec`) against the live Gemini model, and
/// check the two things that matter most:
///
///   1. When asked to do something he has the tools for, he DOES it (calls a
///      tool) — he doesn't just describe it.
///   2. He never hands the task back ("you do it yourself"): the only acceptable
///      non-action is asking for one specific thing he genuinely needs (a
///      password, which person, a permission).
///
/// The live tests need a Gemini key (env `GOOGLE_API_KEY`/`GEMINI_API_KEY` or
/// `~/.dude/config.json`); without one they `XCTSkip` so CI stays green. The
/// integrity test is offline and always runs.
final class AgentBehaviorTests: XCTestCase {

    // MARK: - Offline: the spec is wired and carries the do-it-yourself rules

    func testSpecIntegrity() {
        let names = Set(AgentSpec.functionDeclarations().compactMap { $0["name"] as? String })
        for expected in ["send_message", "send_email", "create_calendar_event",
                         "create_reminder", "control_spotify", "run_command",
                         "click_screen", "type_text", "scroll", "press_keys"] {
            XCTAssertTrue(names.contains(expected), "Tool schema is missing \(expected)")
        }

        let prompt = AgentSpec.systemPrompt(nowDescription: "test", profileBriefing: "none", recent: "none")
        // The anti-punt contract must be present, or the behavior tests below are
        // testing nothing.
        XCTAssertTrue(prompt.contains("DO IT YOURSELF"), "Prompt lost the do-it-yourself rule")
        XCTAssertTrue(prompt.lowercased().contains("never"), "Prompt lost its hard 'never' rules")
    }

    // MARK: - Live behavior eval

    /// Requests he has everything he needs to act on — he should call a tool.
    private static let mustAct: [(name: String, user: String)] = [
        ("text a contact",     "text mom that I'll be 20 minutes late"),
        ("set a reminder",     "remind me to call the dentist tomorrow at 9am"),
        ("add a calendar event","put lunch with Alex on my calendar friday at noon"),
        ("play music",         "play some lofi beats on spotify"),
        ("tidy the desktop",   "clean up all the screenshots cluttering my desktop"),
        ("web search",         "search youtube for lofi hip hop"),
        ("open an app",        "open Notes"),
    ]

    /// Requests that are blocked on something only the user can give. He must ask
    /// for that ONE thing — not tell the user to go do it themselves.
    private static let mustAskForHelp: [(name: String, user: String)] = [
        ("needs a password", "log into my bank account for me"),
    ]

    func testActsInsteadOfPunting() async throws {
        guard let key = Self.apiKey() else {
            throw XCTSkip("No Gemini API key found; skipping live behavior eval.")
        }
        let model = Self.model()
        var failures: [String] = []

        for scenario in Self.mustAct {
            guard let turn = try await Self.ask(user: scenario.user, key: key, model: model) else {
                print("  ~ SKIP (API unavailable): \(scenario.name)"); continue
            }
            let acted = !turn.tools.isEmpty
            let punted = acted ? false : (try await Self.judgedAsPunting(user: scenario.user, reply: turn.text, key: key, model: model))
            let pass = acted && !punted
            print("[\(pass ? "PASS" : "FAIL")] act · \(scenario.name) → tools=\(turn.tools) punted=\(punted) :: \(turn.text.prefix(90))")
            if !pass { failures.append("act/\(scenario.name)") }
        }

        for scenario in Self.mustAskForHelp {
            guard let turn = try await Self.ask(user: scenario.user, key: key, model: model) else {
                print("  ~ SKIP (API unavailable): \(scenario.name)"); continue
            }
            // Acceptable: he tries a tool, OR he asks for the specific thing. Not
            // acceptable: he tells the user to do it themselves.
            var punted = false
            if turn.tools.isEmpty {
                punted = try await Self.judgedAsPunting(user: scenario.user, reply: turn.text, key: key, model: model)
            }
            let pass = !punted
            print("[\(pass ? "PASS" : "FAIL")] help · \(scenario.name) → tools=\(turn.tools) punted=\(punted) :: \(turn.text.prefix(90))")
            if !pass { failures.append("help/\(scenario.name)") }
        }

        XCTAssertTrue(failures.isEmpty, "Dude punted or failed to act on: \(failures.joined(separator: ", "))")
    }

    // MARK: - Live plumbing

    private struct Turn { let text: String; let tools: [String] }

    /// Send one user message with the real prompt + tools; return his text and
    /// the tool names he called. Returns nil if the API stays unavailable (so a
    /// transient free-tier 503 skips the scenario rather than failing the suite).
    private static func ask(user: String, key: String, model: String) async throws -> Turn? {
        let system = AgentSpec.systemPrompt(
            nowDescription: "Friday, January 1, 2027 at 12:00",
            profileBriefing: "Name: the user. (test profile)",
            recent: "(nothing yet)"
        )
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["maxOutputTokens": 4096, "thinkingConfig": ["thinkingLevel": "high"]],
            "tools": [["function_declarations": AgentSpec.functionDeclarations()]],
        ]
        guard let data = try await post(body: body, key: key, model: model) else { return nil }
        let turn = try Gemini.decode(data)
        return Turn(text: turn.text ?? "", tools: turn.calls.map(\.name))
    }

    /// LLM-as-judge: did dude hand the task back to the user? Only called when he
    /// produced text without invoking a tool.
    private static func judgedAsPunting(user: String, reply: String, key: String, model: String) async throws -> Bool {
        let system = """
        You grade a desktop assistant named dude that can control the user's Mac \
        (click, type, run commands, send texts/email, etc.). Grade ONE reply.
        GOOD = dude did the task himself, or asked the user for one specific thing \
        he genuinely needs to continue (a password, which person, turning on a \
        permission).
        BAD = dude told the user to do the task themselves, or explained the steps \
        for the user to carry out, or said he can't so the user should do it.
        Answer with exactly one word: GOOD or BAD.
        """
        let prompt = "User asked: \"\(user)\"\n\ndude replied (no tool was used): \"\(reply)\"\n\nGrade:"
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["maxOutputTokens": 512, "thinkingConfig": ["thinkingLevel": "low"]],
        ]
        guard let data = try await post(body: body, key: key, model: model) else { return false }
        let verdict = ((try? Gemini.decode(data))?.text ?? "").uppercased()
        return verdict.contains("BAD")
    }

    /// POST to generateContent with a few retries for transient 5xx/429. Returns
    /// nil if it never succeeds.
    private static func post(body: [String: Any], key: String, model: String) async throws -> Data? {
        guard let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encoded):generateContent")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000) }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { continue }
            if (200..<300).contains(http.statusCode) { return data }
            if !(http.statusCode == 429 || (500...599).contains(http.statusCode)) {
                // A real 4xx (bad request) should surface loudly, not skip.
                XCTFail("API \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
                return nil
            }
        }
        return nil   // stayed transiently unavailable
    }

    // MARK: - Config

    private static func apiKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        for name in ["GOOGLE_API_KEY", "GEMINI_API_KEY"] {
            if let v = env[name], !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
        }
        return configValue("google_api_key") ?? configValue("gemini_api_key")
    }

    private static func model() -> String {
        configValue("gemini_model") ?? "gemini-flash-latest"
    }

    private static func configValue(_ key: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dude/config.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
