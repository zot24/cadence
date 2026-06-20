import XCTest
@testable import CadenceCore

final class FlueScaffoldTests: XCTestCase {
    func testSanitize() {
        XCTAssertEqual(FlueScaffold.sanitize(name: "Daily News Digest!"), "daily-news-digest")
        XCTAssertEqual(FlueScaffold.sanitize(name: "  weird__name  "), "weird-name")
        XCTAssertEqual(FlueScaffold.sanitize(name: "Agent#1"), "agent-1")
    }

    func testAgentSourceContainsModelAndEscapes() {
        let src = FlueScaffold.agentSource(name: "x", model: "anthropic/claude-sonnet-4-6",
                                           instructions: "Use `backticks` and $vars safely")
        XCTAssertTrue(src.contains("anthropic/claude-sonnet-4-6"))
        XCTAssertTrue(src.contains("createAgent"))
        XCTAssertTrue(src.contains("\\`backticks\\`"))   // backticks escaped for template literal
        XCTAssertTrue(src.contains("\\$vars"))
        XCTAssertTrue(src.contains("CADENCE_USAGE"))     // self-documents the cost protocol
        XCTAssertTrue(src.contains("CADENCE_NEXT"))      // and the adaptive-schedule protocol
    }

    func testWriteAgentAndWorkspace() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadence-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FlueScaffold.scaffoldWorkspaceIfNeeded(at: tmp)
        XCTAssertTrue(FlueSource.isFlueProject(tmp), "scaffolded dir should be a Flue project")

        let fileURL = try FlueScaffold.writeAgent(intoProject: tmp, name: "My Agent",
                                                  model: "anthropic/claude-opus-4-8",
                                                  instructions: "Do the thing.")
        XCTAssertEqual(fileURL.lastPathComponent, "my-agent.ts")
        let written = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(written.contains("anthropic/claude-opus-4-8"))

        // The agent should be discoverable as a Flue agent. (Compare by folder
        // name: macOS temp dirs resolve /var -> /private/var, so full paths differ.)
        let projects = FlueSource.discoverProjects(in: [tmp.deletingLastPathComponent()])
        let mine = projects.first { URL(fileURLWithPath: $0.path).lastPathComponent == tmp.lastPathComponent }
        XCTAssertNotNil(mine)
        XCTAssertTrue(mine?.agents.contains { $0.name == "my-agent" } ?? false)
    }

    func testReadAgentInfoRoundTrip() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadence-info-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FlueScaffold.scaffoldWorkspaceIfNeeded(at: tmp)
        try FlueScaffold.writeAgent(intoProject: tmp, name: "digest",
                                    model: "anthropic/claude-sonnet-4-6",
                                    instructions: "Summarize my unread GitHub notifications.")
        let info = FlueSource.readAgentInfo(projectPath: tmp.path, agentName: "digest", isWorkflow: false)
        XCTAssertEqual(info?.model, "anthropic/claude-sonnet-4-6")
        XCTAssertEqual(info?.instructions, "Summarize my unread GitHub notifications.")
    }

    func testExtractProjectPathFromCommand() {
        let cmd = "cd '/Users/me/code/agents' && npx flue run digest"
        XCTAssertEqual(FlueSource.extractProjectPath(from: cmd), "/Users/me/code/agents")
    }

    func testStringLiteralVariants() {
        XCTAssertEqual(FlueSource.stringLiteral(after: "model:", in: "model: 'a/b'"), "a/b")
        XCTAssertEqual(FlueSource.stringLiteral(after: "model:", in: "model:   \"x/y\""), "x/y")
        XCTAssertEqual(FlueSource.stringLiteral(after: "instructions:", in: "instructions: `multi\nline`"), "multi\nline")
    }
}
