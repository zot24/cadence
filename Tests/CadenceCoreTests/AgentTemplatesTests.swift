import XCTest
@testable import CadenceCore

final class AgentTemplatesTests: XCTestCase {
    func testTemplatesAreValid() {
        XCTAssertFalse(AgentTemplates.all.isEmpty)
        for t in AgentTemplates.all {
            // Name is already a valid slug (writeAgent/run won't mangle it).
            XCTAssertEqual(FlueScaffold.sanitize(name: t.name), t.name, "\(t.name) is not a clean slug")
            // Suggested schedule is a valid cron expression.
            XCTAssertNotNil(CronExpression(t.suggestedCron), "\(t.name) has an invalid cron")
            XCTAssertFalse(t.instructions.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    func testTemplateNamesAreUnique() {
        let names = AgentTemplates.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }
}
