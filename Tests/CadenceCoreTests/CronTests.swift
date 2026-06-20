import XCTest
@testable import CadenceCore

final class CronTests: XCTestCase {
    func testEveryFiveMinutes() {
        XCTAssertEqual(CronHumanizer.describe("*/5 * * * *"), "Every 5 minutes")
    }

    func testEveryMinute() {
        XCTAssertEqual(CronHumanizer.describe("* * * * *"), "Every minute")
    }

    func testHourly() {
        XCTAssertEqual(CronHumanizer.describe("0 * * * *"), "Every hour")
    }

    func testWeekdayRanges() {
        XCTAssertTrue(CronHumanizer.describe("0 9 * * 1-5").contains("weekdays"))
        XCTAssertTrue(CronHumanizer.describe("0 9 * * 0,6").contains("weekends"))
        XCTAssertTrue(CronHumanizer.describe("0 9 * * 1-3").contains("Monday-Wednesday"))
        XCTAssertTrue(CronHumanizer.describe("30 8 * * mon-fri").contains("Monday-Friday"))
    }

    func testParseAndMatch() {
        guard let expr = CronExpression("30 9 * * 1") else { return XCTFail("parse failed") }
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 22 // a Monday
        comps.hour = 9; comps.minute = 30
        let date = Calendar.current.date(from: comps)!
        XCTAssertTrue(expr.matches(date))
        // Same time, wrong weekday.
        comps.day = 23 // Tuesday
        let tue = Calendar.current.date(from: comps)!
        XCTAssertFalse(expr.matches(tue))
    }

    func testStepRange() {
        guard let expr = CronExpression("0 9-17/2 * * *") else { return XCTFail("parse failed") }
        XCTAssertTrue(expr.hours.contains(9))
        XCTAssertTrue(expr.hours.contains(11))
        XCTAssertFalse(expr.hours.contains(10))
        XCTAssertTrue(expr.hours.contains(17))
    }

    func testNextRuns() {
        guard let expr = CronExpression("0 0 * * *") else { return XCTFail("parse failed") }
        let runs = expr.nextRuns(after: Date(), count: 3)
        XCTAssertEqual(runs.count, 3)
    }

    func testCronParseLine() {
        let parsed = CronSource.parse("*/15 * * * * /usr/bin/say hello\n# a comment\n@daily /bin/echo hi")
        XCTAssertEqual(parsed.jobs.count, 2)
        XCTAssertEqual(parsed.jobs.first?.schedule.summary, "Every 15 minutes")
    }

    func testAgentHeuristic() {
        XCTAssertTrue(AgentHeuristics.looksAgentCreated(command: "npx flue run hello-world"))
        XCTAssertFalse(AgentHeuristics.looksAgentCreated(command: "/usr/bin/backup.sh"))
    }
}
