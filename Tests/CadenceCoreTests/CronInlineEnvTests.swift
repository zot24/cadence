import XCTest
@testable import CadenceCore

final class CronInlineEnvTests: XCTestCase {
    func testEnvFromLineNone() {
        XCTAssertEqual(CronWriter.envFromLine("*/5 * * * * /bin/echo hi"), [:])
    }

    func testEnvFromLineWithPrefix() {
        let env = CronWriter.envFromLine("*/5 * * * * ANTHROPIC_API_KEY=sk-abc DEBUG=1 /bin/run.sh")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-abc")
        XCTAssertEqual(env["DEBUG"], "1")
    }

    func testEnvFromLineDoesNotMisreadCommandArgs() {
        // KEY=val only counts as env when it's a *leading* token.
        let env = CronWriter.envFromLine("0 9 * * * /bin/run --flag X=1")
        XCTAssertTrue(env.isEmpty)
    }

    func testRewriteAddsPrefix() {
        let out = CronWriter.rewriteEnvOnLine("*/5 * * * * /bin/run.sh", env: ["KEY": "v"])
        XCTAssertEqual(out, "*/5 * * * * KEY=v /bin/run.sh")
    }

    func testRewriteReplacesExistingPrefixPreservesWrapAndDisabled() {
        let line = "# */5 * * * * OLD=1 '/p/cadence-rec' --job cron:a --label X --source cron --trigger schedule -- npx flue run x"
        let out = CronWriter.rewriteEnvOnLine(line, env: ["ANTHROPIC_API_KEY": "sk-new"])
        XCTAssertEqual(out, "# */5 * * * * ANTHROPIC_API_KEY=sk-new '/p/cadence-rec' --job cron:a --label X --source cron --trigger schedule -- npx flue run x")
    }

    func testRewriteClearingRemovesPrefix() {
        let out = CronWriter.rewriteEnvOnLine("0 9 * * * KEY=v /bin/run.sh", env: [:])
        XCTAssertEqual(out, "0 9 * * * /bin/run.sh")
    }

    func testShortcutLine() {
        let out = CronWriter.rewriteEnvOnLine("@daily KEY=old /bin/run.sh", env: ["KEY": "new"])
        XCTAssertEqual(out, "@daily KEY=new /bin/run.sh")
    }

    func testRoundTrip() {
        let line = "*/15 * * * * /usr/local/bin/agent.sh"
        let withEnv = CronWriter.rewriteEnvOnLine(line, env: ["A": "1", "B": "2"])!
        XCTAssertEqual(CronWriter.envFromLine(withEnv), ["A": "1", "B": "2"])
    }
}
