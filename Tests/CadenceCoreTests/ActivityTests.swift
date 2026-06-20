import XCTest
@testable import CadenceCore

final class ActivityTests: XCTestCase {
    private func makeStore() throws -> (RunStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadence-activity-\(UUID().uuidString).db")
        return (try RunStore(url: url), url)
    }

    func testRecentActivityOrderingAndJoin() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.touchJob(id: "cron:a", source: .cron, label: "Backup", command: "backup.sh", adopted: true)
        store.touchJob(id: "flue:b", source: .flue, label: "Digest", command: "npx flue run digest", adopted: true)

        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let r1 = store.startRun(jobID: "cron:a", startedAt: older, trigger: "schedule", stdoutPath: nil, stderrPath: nil)
        store.finishRun(id: r1, finishedAt: older.addingTimeInterval(2), exitCode: 0, durationMS: 2000)
        let r2 = store.startRun(jobID: "flue:b", startedAt: newer, trigger: "manual", stdoutPath: nil, stderrPath: nil)
        store.finishRun(id: r2, finishedAt: newer.addingTimeInterval(1), exitCode: 1, durationMS: 1000)

        let activity = store.recentActivity(limit: 10)
        XCTAssertEqual(activity.count, 2)
        // Newest first.
        XCTAssertEqual(activity[0].jobID, "flue:b")
        XCTAssertEqual(activity[0].label, "Digest")          // joined from jobs table
        XCTAssertEqual(activity[0].source, .flue)
        XCTAssertEqual(activity[0].trigger, "manual")
        XCTAssertEqual(activity[0].succeeded, false)
        XCTAssertEqual(activity[1].jobID, "cron:a")
        XCTAssertEqual(activity[1].succeeded, true)
    }

    func testActivityCSV() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = try JobRepository(store: store)
        store.touchJob(id: "cron:a", source: .cron, label: "Has, comma", command: "x", adopted: true)
        let r = store.startRun(jobID: "cron:a", startedAt: Date(timeIntervalSince1970: 1_000_000),
                               trigger: "schedule", stdoutPath: nil, stderrPath: nil)
        store.finishRun(id: r, finishedAt: Date(timeIntervalSince1970: 1_000_001), exitCode: 0, durationMS: 1000)

        let csv = repo.activityCSV()
        XCTAssertTrue(csv.hasPrefix("started_at,job,source,trigger,exit_code,duration_ms,result,model,cost_usd"))
        XCTAssertTrue(csv.contains("\"Has, comma\""))        // CSV escaping
        XCTAssertTrue(csv.contains(",success"))
    }

    func testActivityCarriesUsageCost() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.touchJob(id: "flue:c", source: .flue, label: "Agent", command: "npx flue run c", adopted: true)
        let r = store.startRun(jobID: "flue:c", startedAt: Date(timeIntervalSince1970: 1_000_000),
                               trigger: "schedule", stdoutPath: nil, stderrPath: nil)
        store.finishRun(id: r, finishedAt: Date(timeIntervalSince1970: 1_000_002), exitCode: 0, durationMS: 2000)
        store.setRunUsage(id: r, usage: Usage(model: "anthropic/claude-sonnet-4-6",
                                              inputTokens: 1000, outputTokens: 200, costUSD: 0.015))

        let activity = store.recentActivity(limit: 10)
        XCTAssertEqual(activity.first?.costUSD, 0.015)
        XCTAssertEqual(activity.first?.model, "anthropic/claude-sonnet-4-6")

        let repo = try JobRepository(store: store)
        let csv = repo.activityCSV()
        XCTAssertTrue(csv.contains("anthropic/claude-sonnet-4-6"))
        XCTAssertTrue(csv.contains("0.015000"))
    }
}
