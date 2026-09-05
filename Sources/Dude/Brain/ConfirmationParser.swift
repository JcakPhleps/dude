import Foundation

/// Reads a user's reply to a staged action ("send this text?" / "run this?") as
/// a clear yes, a clear no, or neither. Anything ambiguous returns `.unclear`,
/// and the Brain keeps the action staged and re-asks rather than guessing — we
/// never fire or drop an outward action on a coin-flip.
enum ConfirmationParser {

    enum Answer {
        case yes, no, unclear
    }

    static func interpret(_ reply: String) -> Answer {
        let l = normalize(reply)
        guard !l.isEmpty else { return .unclear }
        // Check "no" first: a false negative here means an unwanted send, which
        // is the worse mistake, so bias toward *not* acting when either matches.
        if matches(l, negatives) { return .no }
        if matches(l, affirmatives) { return .yes }
        return .unclear
    }

    static func isAffirmative(_ reply: String) -> Bool { interpret(reply) == .yes }
    static func isNegative(_ reply: String) -> Bool { interpret(reply) == .no }

    // MARK: - Word lists

    private static let affirmatives: [String] = [
        "yes", "yep", "yeah", "yea", "ya", "yah", "yuh", "yup", "yis",
        "sure", "ok", "okay", "k", "kk", "do it", "doit", "send it",
        "sendit", "send", "send that", "go", "go ahead", "go for it",
        "please", "confirm", "confirmed", "y", "yes please", "mhm",
        "mmhm", "absolutely", "definitely", "yessir", "sounds good",
        "sgtm", "👍", "✅", "🆗",
    ]

    private static let negatives: [String] = [
        "no", "nope", "nah", "naw", "don't", "dont", "do not",
        "cancel", "stop", "nevermind", "never mind", "wait", "hold on",
        "n", "no thanks", "no thank you", "negative", "abort", "❌", "👎",
    ]

    /// A reply matches if it *is* the word or *starts with* the word followed by
    /// a space (so "yeah send it" reads as yes, but "yesterday" does not).
    private static func matches(_ reply: String, _ words: [String]) -> Bool {
        words.contains { reply == $0 || reply.hasPrefix($0 + " ") }
    }

    /// Lowercase and strip surrounding punctuation/whitespace so "Yes!", " ya. ",
    /// etc. still read as a plain confirmation. Emoji (symbols) are preserved so
    /// a lone 👍 still counts.
    static func normalize(_ reply: String) -> String {
        reply.lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.union(.symbols).inverted)
    }
}
