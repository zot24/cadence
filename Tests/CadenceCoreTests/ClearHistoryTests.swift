import XCTest
@testable import CadenceCore

final class ClearHistoryTests: XCTestCase {
    func testClearAllRuns() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cadence-clr-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try RunStore(url: url)
        let r = store.startRun(jobID: "j", startedAt: Date(timeIntervalSince1970: 1), trigger: "schedule", stdoutPath: nil, stderrPath: nil)
        store.finishRun(id: r, finishedAt: Date(timeIntervalSince1970: 2), exitCode: 0, durationMS: 1)
        XCTAssertEqual(store.recentActivity(limit: 5).count, 1)
        store.clearAllRuns()
        XCTAssertEqual(store.recentActivity(limit: 5).count, 0)
    }
}
