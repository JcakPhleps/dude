import XCTest

/// Confirmation parsing decides whether an outward action (a text, an email, a
/// shell command) actually fires. A wrong "yes" sends something unwanted, so the
/// unclear/negative bias matters as much as the happy path.
final class ConfirmationParserTests: XCTestCase {

    func testClearYeses() {
        for r in ["yes", "yep", "yeah", "ya", "sure", "ok", "okay", "do it",
                  "send it", "go for it", "y", "confirm", "👍", "sounds good"] {
            XCTAssertEqual(ConfirmationParser.interpret(r), .yes, "expected yes for \(r)")
        }
    }

    func testClearNos() {
        for r in ["no", "nope", "nah", "cancel", "stop", "don't", "nevermind",
                  "wait", "n", "abort", "👎"] {
            XCTAssertEqual(ConfirmationParser.interpret(r), .no, "expected no for \(r)")
        }
    }

    func testPunctuationAndCaseIgnored() {
        XCTAssertEqual(ConfirmationParser.interpret("Yes!"), .yes)
        XCTAssertEqual(ConfirmationParser.interpret("  ya. "), .yes)
        XCTAssertEqual(ConfirmationParser.interpret("NOPE."), .no)
    }

    func testPrefixMatchingButNotSubstring() {
        XCTAssertEqual(ConfirmationParser.interpret("yeah send that"), .yes)
        // "yesterday" starts with "yes" but isn't a confirmation.
        XCTAssertEqual(ConfirmationParser.interpret("yesterday was rough"), .unclear)
    }

    func testNegativeBiasWhenBothPresent() {
        // "no" leads → treat as no; safer to not send on a mixed reply.
        XCTAssertEqual(ConfirmationParser.interpret("no wait, actually send it"), .no)
    }

    func testUnclearRepliesStaySafe() {
        for r in ["", "   ", "maybe", "what do you think", "hmm", "who is that"] {
            XCTAssertEqual(ConfirmationParser.interpret(r), .unclear, "expected unclear for “\(r)”")
        }
    }

    func testConvenienceWrappers() {
        XCTAssertTrue(ConfirmationParser.isAffirmative("yep"))
        XCTAssertFalse(ConfirmationParser.isAffirmative("nope"))
        XCTAssertTrue(ConfirmationParser.isNegative("cancel"))
        XCTAssertFalse(ConfirmationParser.isNegative("sure"))
    }
}
