import XCTest
@testable import CadenceCore

final class BulkTrackTests: XCTestCase {
    private func job(id: String, source: JobSource, origin: JobProvenance, adopted: Bool,
                     domain: LaunchdDomain? = nil, cronLine: String? = "*/5 * * * * x") -> Job {
        Job(id: id, source: source, label: id, command: "x", schedule: JobSchedule(), enabled: true,
            launchdDomain: domain, plistPath: domain != nil ? "/tmp/x.plist" : nil,
            cronLine: domain == nil ? cronLine : nil,
            isAdopted: adopted, origin: JobOrigin(category: origin))
    }

    func testSelectsOnlyUntrackedAdoptableAgentJobs() {
        let jobs = [
            job(id: "a", source: .flue, origin: .flue, adopted: false),        // ✓ agent, cron-backed, untracked
            job(id: "b", source: .cron, origin: .aiAgent, adopted: false),     // ✓ agent, cron, untracked
            job(id: "c", source: .cron, origin: .aiAgent, adopted: true),      // ✗ already tracked
            job(id: "d", source: .cron, origin: .user, adopted: false),        // ✗ not an agent
            job(id: "e", source: .launchd, origin: .aiAgent, adopted: false, domain: .systemDaemon), // ✗ not adoptable (system)
            job(id: "f", source: .launchd, origin: .aiAgent, adopted: false, domain: .userAgent),    // ✓ agent, user agent
        ]
        let ids = Set(JobRepository.trackableAgentJobs(jobs).map(\.id))
        XCTAssertEqual(ids, ["a", "b", "f"])
    }

    func testEmptyWhenNoAgents() {
        let jobs = [job(id: "x", source: .cron, origin: .user, adopted: false)]
        XCTAssertTrue(JobRepository.trackableAgentJobs(jobs).isEmpty)
    }
}
