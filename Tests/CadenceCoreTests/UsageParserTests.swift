import XCTest
@testable import CadenceCore

final class UsageParserTests: XCTestCase {
    func testCanonicalLine() {
        let out = """
        running agent...
        CADENCE_USAGE {"model":"anthropic/claude-sonnet-4-6","input_tokens":1200,"output_tokens":340,"cost_usd":0.0123}
        done
        """
        let u = UsageParser.parse(out)
        XCTAssertEqual(u?.model, "anthropic/claude-sonnet-4-6")
        XCTAssertEqual(u?.inputTokens, 1200)
        XCTAssertEqual(u?.outputTokens, 340)
        XCTAssertEqual(u?.costUSD, 0.0123)
        XCTAssertEqual(u?.totalTokens, 1540)
    }

    func testCanonicalAltKeys() {
        let u = UsageParser.parse(#"CADENCE_USAGE {"model":"openai/gpt-5.1","prompt_tokens":50,"completion_tokens":10,"cost":0.5}"#)
        XCTAssertEqual(u?.inputTokens, 50)
        XCTAssertEqual(u?.outputTokens, 10)
        XCTAssertEqual(u?.costUSD, 0.5)
    }

    func testBestEffortFreeText() {
        let out = "Model anthropic/claude-opus-4-8 used. input_tokens: 900 output_tokens: 120 cost_usd: 0.044"
        let u = UsageParser.parse(out)
        XCTAssertEqual(u?.model, "anthropic/claude-opus-4-8")
        XCTAssertEqual(u?.inputTokens, 900)
        XCTAssertEqual(u?.outputTokens, 120)
        XCTAssertEqual(u?.costUSD, 0.044)
    }

    func testNoUsageReturnsNil() {
        XCTAssertNil(UsageParser.parse("just some normal log output\nnothing to see here"))
    }
}
