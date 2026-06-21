import XCTest
@testable import CadenceCore

final class ProvenanceTests: XCTestCase {
    private func cron(_ command: String, label: String = "job") -> Job {
        Job(id: "cron:1", source: .cron, label: label, command: command,
            schedule: JobSchedule(), enabled: true)
    }

    func testFlue() {
        XCTAssertEqual(JobProvenance.classify(cron("cd /p && npx flue run digest")), .flue)
        var j = cron("node x.js"); j.source = .flue; j.flueAgentName = "x"
        XCTAssertEqual(JobProvenance.classify(j), .flue)
    }

    func testAIAgent() {
        XCTAssertEqual(JobProvenance.classify(cron("python ~/.claude/scripts/run.py")), .aiAgent)
        XCTAssertEqual(JobProvenance.classify(cron("codex exec 'do thing'")), .aiAgent)
    }

    func testMoreLocalAgents() {
        XCTAssertEqual(JobProvenanceDetector.detect(cron("aider --message x")).tool, "Aider")
        XCTAssertEqual(JobProvenanceDetector.detect(cron("opencode run task")).tool, "OpenCode")
        XCTAssertEqual(JobProvenance.classify(cron("/opt/homebrew/bin/aider")), .aiAgent)
    }

    func testAutomation() {
        XCTAssertEqual(JobProvenance.classify(cron("shortcuts run 'Backup'")), .automation)
    }

    func testHermesAndOpenClaw() {
        XCTAssertEqual(JobProvenance.classify(cron("/opt/homebrew/bin/hermes run digest")), .aiAgent)
        XCTAssertEqual(JobProvenanceDetector.detect(cron("hermes run x")).tool, "Hermes")
        XCTAssertEqual(JobProvenance.classify(cron("openclaw task daily")), .aiAgent)
        XCTAssertEqual(JobProvenanceDetector.detect(cron("openclaw task")).tool, "OpenClaw")
    }

    func testHomebrew() {
        let j = Job(id: "launchd:homebrew.mxcl.x", source: .launchd, label: "homebrew.mxcl.postgresql",
                    command: "/opt/homebrew/opt/postgresql/bin/postgres", schedule: JobSchedule(),
                    enabled: true, launchdDomain: .userAgent)
        XCTAssertEqual(JobProvenance.classify(j), .packageManager)
    }

    func testSystem() {
        let j = Job(id: "launchd:com.apple.x", source: .launchd, label: "com.apple.something",
                    command: "/usr/libexec/x", schedule: JobSchedule(), enabled: true,
                    launchdDomain: .systemDaemon)
        XCTAssertEqual(JobProvenance.classify(j), .system)
    }

    /// The exact false positive the user flagged: "agent" in a name must NOT
    /// make it an AI-agent job.
    func testAgentWordInNameIsNotAgentCreated() {
        let j = Job(id: "launchd:com.apple.x", source: .launchd, label: "com.apple.useractivityd.agent",
                    command: "/usr/libexec/useractivityd", schedule: JobSchedule(), enabled: true,
                    launchdDomain: .systemDaemon)
        let origin = JobProvenanceDetector.detect(j)
        XCTAssertFalse(origin.isAgentic)
        XCTAssertEqual(origin.category, .system)
    }

    /// Reverse-DNS vendor label classifies even with no binary evidence in the
    /// command — the ai.hermes.gateway-residencyos case the user hit.
    func testHermesVendorLabelWithoutCommandEvidence() {
        let j = Job(id: "launchd:ai.hermes.gateway-residencyos", source: .launchd,
                    label: "ai.hermes.gateway-residencyos",
                    command: "/Users/x/.local/bin/node /opt/residencyos/run.js",
                    schedule: JobSchedule(), enabled: true, launchdDomain: .userAgent)
        let o = JobProvenanceDetector.detect(j)
        XCTAssertEqual(o.category, .aiAgent)
        XCTAssertEqual(o.tool, "Hermes")
        XCTAssertTrue(o.isAgentic)
    }

    func testUser() {
        XCTAssertEqual(JobProvenance.classify(cron("/usr/local/bin/backup.sh")), .user)
        XCTAssertFalse(JobProvenanceDetector.detect(cron("/usr/local/bin/manage-agents.sh")).isAgentic,
                       "the word 'agent' in a script path must not imply an AI agent")
    }

    func testAgenticFlag() {
        XCTAssertTrue(JobProvenance.flue.isAgentic)
        XCTAssertTrue(JobProvenance.aiAgent.isAgentic)
        XCTAssertFalse(JobProvenance.automation.isAgentic)
        XCTAssertFalse(JobProvenance.user.isAgentic)
    }
}
