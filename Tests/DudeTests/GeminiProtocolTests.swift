import XCTest

/// Attacks the Gemini wire decode/encode from every angle a live API throws at
/// it: happy path, tool calls, prompt- and candidate-level safety blocks,
/// truncated-but-usable answers, and assorted garbage.
final class GeminiProtocolTests: XCTestCase {

    private func decode(_ json: String) throws -> Gemini.ModelTurn {
        try Gemini.decode(Data(json.utf8))
    }

    // MARK: - Happy paths

    func testDecodesPlainText() throws {
        let turn = try decode(#"{"candidates":[{"content":{"parts":[{"text":"hello there"}]},"finishReason":"STOP"}]}"#)
        XCTAssertEqual(turn.text, "hello there")
        XCTAssertTrue(turn.calls.isEmpty)
    }

    func testJoinsMultipleTextParts() throws {
        let turn = try decode(#"{"candidates":[{"content":{"parts":[{"text":"foo "},{"text":"bar"}]}}]}"#)
        XCTAssertEqual(turn.text, "foo bar")
    }

    func testDecodesFunctionCallWithThoughtSignature() throws {
        let json = #"""
        {"candidates":[{"content":{"parts":[
          {"functionCall":{"name":"send_message","args":{"recipient":"mom","body":"hi"},"id":"call-1"},"thoughtSignature":"sig-xyz"}
        ]}}]}
        """#
        let turn = try decode(json)
        XCTAssertNil(turn.text)
        XCTAssertEqual(turn.calls.count, 1)
        let call = try XCTUnwrap(turn.calls.first)
        XCTAssertEqual(call.name, "send_message")
        XCTAssertEqual(call.args["recipient"], "mom")
        XCTAssertEqual(call.args["body"], "hi")
        XCTAssertEqual(call.id, "call-1")
        XCTAssertEqual(call.thoughtSignature, "sig-xyz")
    }

    func testKeepsPartialTextOnMaxTokens() throws {
        // A cut-off answer is still useful — we must not throw it away.
        let turn = try decode(#"{"candidates":[{"content":{"parts":[{"text":"here's what I fou"}]},"finishReason":"MAX_TOKENS"}]}"#)
        XCTAssertEqual(turn.text, "here's what I fou")
    }

    // MARK: - Blocks & errors

    func testPromptLevelBlockThrowsBlocked() {
        XCTAssertThrowsError(try decode(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#)) {
            XCTAssertEqual($0 as? Gemini.WireError, .blocked(reason: "SAFETY"))
        }
    }

    func testCandidateSafetyWithNoPartsThrowsBlocked() {
        // Real Gemini shape when the *candidate* is blocked: a finishReason but
        // no content/parts at all.
        XCTAssertThrowsError(try decode(#"{"candidates":[{"finishReason":"SAFETY"}]}"#)) {
            XCTAssertEqual($0 as? Gemini.WireError, .blocked(reason: "SAFETY"))
        }
    }

    func testEmptyTextWithBenignFinishReasonIsMalformed() {
        XCTAssertThrowsError(try decode(#"{"candidates":[{"content":{"parts":[{"text":"   "}]},"finishReason":"STOP"}]}"#)) {
            XCTAssertEqual($0 as? Gemini.WireError, .malformedResponse)
        }
    }

    func testNoCandidatesIsMalformed() {
        XCTAssertThrowsError(try decode(#"{"usageMetadata":{"totalTokenCount":5}}"#)) {
            XCTAssertEqual($0 as? Gemini.WireError, .malformedResponse)
        }
    }

    func testNonJSONIsMalformed() {
        XCTAssertThrowsError(try Gemini.decode(Data("<<not json>>".utf8))) {
            XCTAssertEqual($0 as? Gemini.WireError, .malformedResponse)
        }
    }

    func testEmptyDataIsMalformed() {
        XCTAssertThrowsError(try Gemini.decode(Data())) {
            XCTAssertEqual($0 as? Gemini.WireError, .malformedResponse)
        }
    }

    // MARK: - Retry policy

    func testRetryableStatuses() {
        for s in [429, 500, 502, 503, 504] { XCTAssertTrue(Gemini.isRetryable(status: s), "\(s)") }
        for s in [200, 400, 401, 403, 404, 501] { XCTAssertFalse(Gemini.isRetryable(status: s), "\(s)") }
    }

    // MARK: - stringify (bool vs number disambiguation)

    func testStringifyDistinguishesBoolFromNumber() throws {
        // Parsed from JSON so `true` is a real CFBoolean and `1` a real number —
        // the exact ambiguity the CFBooleanGetTypeID check guards against.
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(#"{"flag":true,"count":1,"name":"x"}"#.utf8)) as? [String: Any]
        )
        let out = Gemini.stringify(obj)
        XCTAssertEqual(out["flag"], "true")
        XCTAssertEqual(out["count"], "1")
        XCTAssertEqual(out["name"], "x")
    }

    // MARK: - Encoding round-trip

    func testEncodesFunctionCallEchoingIdAndSignature() throws {
        let turn = Gemini.Turn(role: "model", parts: [
            .functionCall(name: "send_message", argsJSON: #"{"recipient":"mom"}"#, id: "c1", thoughtSignature: "sig"),
        ])
        let dict = Gemini.encode(turn)
        XCTAssertEqual(dict["role"] as? String, "model")
        let parts = try XCTUnwrap(dict["parts"] as? [[String: Any]])
        let call = try XCTUnwrap(parts.first?["functionCall"] as? [String: Any])
        XCTAssertEqual(call["name"] as? String, "send_message")
        XCTAssertEqual((call["args"] as? [String: Any])?["recipient"] as? String, "mom")
        XCTAssertEqual(call["id"] as? String, "c1")
        XCTAssertEqual(parts.first?["thoughtSignature"] as? String, "sig")
    }

    func testEncodesFunctionResponseWithResult() throws {
        let turn = Gemini.Turn(role: "user", parts: [
            .functionResponse(name: "send_message", id: "c1", result: "Sent."),
        ])
        let parts = try XCTUnwrap(Gemini.encode(turn)["parts"] as? [[String: Any]])
        let fr = try XCTUnwrap(parts.first?["functionResponse"] as? [String: Any])
        XCTAssertEqual(fr["name"] as? String, "send_message")
        XCTAssertEqual(fr["id"] as? String, "c1")
        XCTAssertEqual((fr["response"] as? [String: Any])?["result"] as? String, "Sent.")
    }
}
