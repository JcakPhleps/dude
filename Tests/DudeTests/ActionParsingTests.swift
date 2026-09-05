import XCTest

final class ActionParsingTests: XCTestCase {

    // MARK: - esc (AppleScript literal escaping / injection hardening)

    func testEscapesQuotesAndBackslashes() {
        XCTAssertEqual(ActionParsing.esc(#"say "hi""#), #"say \"hi\""#)
        XCTAssertEqual(ActionParsing.esc(#"a\b"#), #"a\\b"#)
    }

    func testEscapesNewlinesAndTabs() {
        XCTAssertEqual(ActionParsing.esc("line1\nline2"), #"line1\nline2"#)
        XCTAssertEqual(ActionParsing.esc("a\r\nb"), #"a\nb"#)   // CRLF collapses to one \n
        XCTAssertEqual(ActionParsing.esc("a\rb"), #"a\nb"#)
        XCTAssertEqual(ActionParsing.esc("a\tb"), #"a\tb"#)
    }

    func testEscapesBackslashBeforeQuote() {
        // Backslash must be escaped first, or the escape of the quote would be
        // double-processed. Input: \"  ->  \\\"
        XCTAssertEqual(ActionParsing.esc("\\\""), #"\\\""#)
    }

    // MARK: - nonEmpty

    func testNonEmpty() {
        XCTAssertNil(ActionParsing.nonEmpty(nil))
        XCTAssertNil(ActionParsing.nonEmpty(""))
        XCTAssertNil(ActionParsing.nonEmpty("   \n\t "))
        XCTAssertEqual(ActionParsing.nonEmpty("  hello  "), "hello")
    }

    // MARK: - parseDate

    func testParsesISOWithZone() throws {
        let d = try XCTUnwrap(ActionParsing.parseDate("2026-08-09T15:00:00Z"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let parts = cal.dateComponents([.year, .month, .day, .hour], from: d)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 8)
        XCTAssertEqual(parts.day, 9)
        XCTAssertEqual(parts.hour, 15)
    }

    func testParsesISOFractionalSeconds() {
        XCTAssertNotNil(ActionParsing.parseDate("2026-08-09T15:00:00.500Z"))
    }

    func testParsesLocalShapesWithoutZone() {
        XCTAssertNotNil(ActionParsing.parseDate("2026-08-09T15:00"))
        XCTAssertNotNil(ActionParsing.parseDate("2026-08-09 15:00"))
        XCTAssertNotNil(ActionParsing.parseDate("2026-08-09"))
    }

    func testRejectsGarbageAndEmpty() {
        XCTAssertNil(ActionParsing.parseDate(""))
        XCTAssertNil(ActionParsing.parseDate("   "))
        XCTAssertNil(ActionParsing.parseDate("tomorrow at noon"))
        XCTAssertNil(ActionParsing.parseDate("not-a-date"))
    }
}
