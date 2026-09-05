import XCTest

/// The classifier gates reads of private data (Messages, Mail, Calendar,
/// Reminders), so both misses and false positives matter. The false-positive
/// cases are regressions against the old naive `contains` matching.
final class QueryClassifierTests: XCTestCase {

    private func sources(_ q: String) -> Set<QueryClassifier.Source> {
        QueryClassifier.sources(in: q)
    }

    // MARK: - True positives

    func testMessagesQueries() {
        XCTAssertTrue(sources("any new texts?").contains(.message))
        XCTAssertTrue(sources("did I get a message from Sarah").contains(.message))
        XCTAssertTrue(sources("read me my imessage").contains(.message))
        XCTAssertTrue(sources("any word from Gavin yet").contains(.message))
        XCTAssertTrue(sources("who wrote me").contains(.message))
    }

    func testEmailQueries() {
        XCTAssertTrue(sources("check my email").contains(.email))
        XCTAssertTrue(sources("anything new in my inbox").contains(.email))
        XCTAssertTrue(sources("did I get any e-mail").contains(.email))
    }

    func testCalendarQueries() {
        XCTAssertTrue(sources("what's on my calendar today").contains(.calendar))
        XCTAssertTrue(sources("do I have any meetings").contains(.calendar))
        XCTAssertTrue(sources("am I free today").contains(.calendar))
        XCTAssertTrue(sources("what's my next appointment").contains(.calendar))
    }

    func testReminderQueries() {
        XCTAssertTrue(sources("what are my reminders").contains(.reminder))
        XCTAssertTrue(sources("show my todos").contains(.reminder))
        XCTAssertTrue(sources("remind me to call the dentist").contains(.reminder))
        XCTAssertTrue(sources("any tasks left").contains(.reminder))
    }

    // MARK: - False-positive regressions (old contains() misfired on these)

    func testContextDoesNotTriggerMessages() {
        // "context" contains "text" — must NOT read Messages.
        XCTAssertFalse(sources("give me more context on this error").contains(.message))
    }

    func testAdminDoesNotTriggerMessages() {
        // "admin" contains "dm" — must NOT read Messages.
        XCTAssertFalse(sources("open the admin panel").contains(.message))
    }

    func testMultitaskDoesNotTriggerReminders() {
        // "multitask" contains "task" — must NOT read Reminders.
        XCTAssertFalse(sources("how do I multitask better").contains(.reminder))
    }

    func testUnrelatedQuestionTouchesNothing() {
        XCTAssertTrue(sources("what's the weather like").isEmpty)
        XCTAssertTrue(sources("summarize what's on my screen").isEmpty)
    }

    // MARK: - Tokenizer

    func testTokenizeKeepsHyphenatedWordsWhole() {
        let tokens = QueryClassifier.tokenize("check my e-mail, please!")
        XCTAssertTrue(tokens.contains("e-mail"))
        XCTAssertTrue(tokens.contains("check"))
        XCTAssertFalse(tokens.contains(""))
    }
}
