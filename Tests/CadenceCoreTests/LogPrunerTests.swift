import XCTest
@testable import CadenceCore

final class LogPrunerTests: XCTestCase {
    func testKeepsMostRecentRuns() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cadence-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...200 {
            try "".write(to: dir.appendingPathComponent("\(i).out"), atomically: true, encoding: .utf8)
            try "".write(to: dir.appendingPathComponent("\(i).err"), atomically: true, encoding: .utf8)
        }
        LogPruner.prune(directory: dir, keepRuns: 50)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let ids = Set(remaining.compactMap { Int($0.split(separator: ".").first ?? "") })
        XCTAssertEqual(ids.count, 50)
        XCTAssertTrue(ids.contains(200))   // newest kept
        XCTAssertFalse(ids.contains(150))  // 200..151 kept, 150 pruned
        XCTAssertTrue(ids.contains(151))
    }
}
