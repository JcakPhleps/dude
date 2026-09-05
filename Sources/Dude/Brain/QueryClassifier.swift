import Foundation

/// Decides which personal-data source a question is actually about, so Dude only
/// reaches into Messages / Mail / Calendar / Reminders when the ask calls for it
/// (and never otherwise — those reads touch private data and cost permission
/// prompts).
///
/// Matching is **token-based, not substring**: we split the question into words
/// and match whole words, plus a few explicit multi-word phrases. Naive
/// `contains` was the old approach and it misfired badly — "give me more
/// **context**" pulled in Messages ("text"), "the **admin** panel" pulled in
/// Messages ("dm"), and "multi**task**" pulled in Reminders. Whole-word matching
/// kills those false positives while still catching the real questions.
enum QueryClassifier {

    enum Source: CaseIterable {
        case message, email, calendar, reminder
    }

    /// Every source a question touches (usually zero or one).
    static func sources(in question: String) -> Set<Source> {
        var out: Set<Source> = []
        for source in Source.allCases where matches(question, source) {
            out.insert(source)
        }
        return out
    }

    static func matches(_ question: String, _ source: Source) -> Bool {
        let lower = question.lowercased()
        let tokens = tokenize(lower)
        let rule = rules[source]!
        if rule.phrases.contains(where: { lower.contains($0) }) { return true }
        return !tokens.isDisjoint(with: rule.words)
    }

    // MARK: - Rules

    private struct Rule {
        let words: Set<String>      // matched as whole tokens
        let phrases: [String]       // matched as substrings (multi-word)
    }

    private static let rules: [Source: Rule] = [
        .message: Rule(
            words: ["message", "messages", "text", "texts", "texted", "imessage",
                    "dm", "dms", "sms"],
            phrases: ["hear from", "who wrote", "any word from", "heard from"]),
        .email: Rule(
            words: ["email", "emails", "e-mail", "e-mails", "inbox", "mailbox",
                    "gmail", "mail"],
            phrases: []),
        .calendar: Rule(
            words: ["calendar", "schedule", "agenda", "event", "events", "meeting",
                    "meetings", "appointment", "appointments", "busy"],
            // Deliberately NOT a bare "what's on" — that collides with "what's
            // on my screen". Real calendar asks hit the tokens above or these
            // more specific phrases.
            phrases: ["what's on my calendar", "whats on my calendar", "on my schedule",
                      "free today", "free tomorrow", "am i free"]),
        .reminder: Rule(
            words: ["reminder", "reminders", "todo", "todos", "task", "tasks"],
            phrases: ["to-do", "to do", "remind me"]),
    ]

    /// Lowercase words, split on anything that isn't a letter/number. Keeps
    /// hyphenated forms like "e-mail" as their own token by not splitting on `-`.
    static func tokenize(_ text: String) -> Set<String> {
        var separators = CharacterSet.alphanumerics.inverted
        separators.remove(charactersIn: "-")
        return Set(
            text.components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
                .filter { !$0.isEmpty }
        )
    }
}
