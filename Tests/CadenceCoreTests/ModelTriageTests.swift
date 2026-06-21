import XCTest
@testable import CadenceCore

final class ModelTriageTests: XCTestCase {

    func testMessagesIncludeKeyContext() {
        let det = TriageResult(category: "Authentication failed", likelyCause: "no key",
                               suggestedFix: "set it", confidence: .high)
        let (system, user) = ModelTriage.messages(
            command: "cd /x && npx flue run digest", stderr: "401 unauthorized",
            stdout: "", exitCode: 1, timedOut: false, deterministic: det)
        XCTAssertTrue(system.lowercased().contains("scheduled job"))
        XCTAssertTrue(user.contains("npx flue run digest"))
        XCTAssertTrue(user.contains("Exit code: 1"))
        XCTAssertTrue(user.contains("Authentication failed"))   // folds in the rule-based guess
        XCTAssertTrue(user.contains("401 unauthorized"))
    }

    func testMessagesNoteTimeout() {
        let (_, user) = ModelTriage.messages(command: "x", stderr: "", stdout: "",
                                             exitCode: nil, timedOut: true, deterministic: nil)
        XCTAssertTrue(user.lowercased().contains("timed out"))
    }

    func testRequestBodyOpenAIShape() throws {
        let p = ModelProvider(kind: .xai, modelID: "grok-4", apiKeyValue: "k")
        let data = try ModelTriage.requestBody(provider: p, system: "S", user: "U", maxTokens: 123)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "grok-4")
        XCTAssertEqual(obj["max_tokens"] as? Int, 123)
        let messages = try XCTUnwrap(obj["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertNil(obj["system"], "OpenAI shape puts the system prompt in messages, not a top-level field")
    }

    func testRequestBodyAnthropicShape() throws {
        let p = ModelProvider(kind: .anthropic, modelID: "claude-sonnet-4-6", apiKeyValue: "k")
        let data = try ModelTriage.requestBody(provider: p, system: "S", user: "U")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["system"] as? String, "S")
        let messages = try XCTUnwrap(obj["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
    }

    func testParseAnswerOpenAI() {
        let p = ModelProvider(kind: .ollama, modelID: "llama3.2:3b")
        let json = #"{"choices":[{"message":{"role":"assistant","content":"  Add the key.  "}}]}"#
        XCTAssertEqual(ModelTriage.parseAnswer(provider: p, data: Data(json.utf8)), "Add the key.")
    }

    func testParseAnswerAnthropic() {
        let p = ModelProvider(kind: .anthropic, modelID: "claude-sonnet-4-6")
        let json = #"{"content":[{"type":"text","text":"PATH is minimal. Use an absolute path."}]}"#
        XCTAssertEqual(ModelTriage.parseAnswer(provider: p, data: Data(json.utf8)),
                       "PATH is minimal. Use an absolute path.")
    }

    func testParseAnswerGarbageReturnsNil() {
        let p = ModelProvider(kind: .xai, modelID: "grok-4")
        XCTAssertNil(ModelTriage.parseAnswer(provider: p, data: Data("not json".utf8)))
    }
}
