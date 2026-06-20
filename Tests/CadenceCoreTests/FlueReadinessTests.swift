import XCTest
@testable import CadenceCore

final class FlueReadinessTests: XCTestCase {
    private func check(_ checks: [ReadinessCheck], _ name: String) -> Bool {
        checks.first { $0.name == name }?.passed ?? false
    }

    func testBareProjectFailsMostChecks() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadence-ready-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let checks = FlueReadiness.check(projectPath: tmp.path, agentName: "digest", isWorkflow: false)
        XCTAssertFalse(check(checks, "Flue project"))   // no flue.config
        XCTAssertFalse(check(checks, "Dependencies"))   // no node_modules
        XCTAssertFalse(check(checks, "Agent file"))     // no agents/digest.ts
        XCTAssertFalse(check(checks, "API key"))        // no .env
        XCTAssertFalse(FlueReadiness.ready(checks))
    }

    func testFullySetUpProjectPasses() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadence-ready2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FlueScaffold.scaffoldWorkspaceIfNeeded(at: tmp)   // flue.config + .env + agents/
        try FlueScaffold.writeAgent(intoProject: tmp, name: "digest",
                                    model: "anthropic/claude-sonnet-4-6", instructions: "do it")
        // Simulate installed deps and a set key.
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("node_modules/@flue"),
                                                withIntermediateDirectories: true)
        try DotEnv.write(["ANTHROPIC_API_KEY": "sk-test"], to: tmp.appendingPathComponent(".env"))

        let checks = FlueReadiness.check(projectPath: tmp.path, agentName: "digest", isWorkflow: false)
        XCTAssertTrue(check(checks, "Flue project"))
        XCTAssertTrue(check(checks, "Dependencies"))
        XCTAssertTrue(check(checks, "Agent file"))
        XCTAssertTrue(check(checks, "API key"))
    }

    func testEmptyKeyDoesNotCount() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadence-ready3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "ANTHROPIC_API_KEY=\n".write(to: tmp.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let checks = FlueReadiness.check(projectPath: tmp.path, agentName: nil, isWorkflow: false)
        XCTAssertFalse(check(checks, "API key"))   // present but empty
    }
}
