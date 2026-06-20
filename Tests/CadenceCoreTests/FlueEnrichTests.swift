import XCTest
@testable import CadenceCore

final class FlueEnrichTests: XCTestCase {
    func testEnrichRecognizesFlueCliInvocation() {
        let job = Job(id: "cron:1", source: .cron, label: "x",
                      command: "cd /p && npx @flue/cli run digest", schedule: JobSchedule(), enabled: true)
        let enriched = FlueSource.enrich(job)
        XCTAssertEqual(enriched.source, .flue)
        XCTAssertEqual(enriched.flueAgentName, "digest")
    }
    func testEnrichIgnoresNonFlue() {
        let job = Job(id: "cron:2", source: .cron, label: "x",
                      command: "/usr/bin/fluent-cmd", schedule: JobSchedule(), enabled: true)
        XCTAssertEqual(FlueSource.enrich(job).source, .cron)
    }
}
