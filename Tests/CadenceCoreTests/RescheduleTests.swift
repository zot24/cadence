import XCTest
@testable import CadenceCore

final class RescheduleTests: XCTestCase {
    // MARK: - Parser

    func testParseExplicitCron() {
        let r = RescheduleParser.parse(#"found nothing\nCADENCE_NEXT {"cron":"0 */4 * * *"}"#)
        XCTAssertEqual(r?.normalizedCron, "0 */4 * * *")
    }

    func testParseInMinutesNormalizes() {
        XCTAssertEqual(RescheduleParser.parse(#"CADENCE_NEXT {"in_minutes":15}"#)?.normalizedCron, "*/15 * * * *")
        XCTAssertEqual(RescheduleParser.parse(#"CADENCE_NEXT {"in_minutes":120}"#)?.normalizedCron, "0 */2 * * *")
        XCTAssertEqual(RescheduleParser.parse(#"CADENCE_NEXT {"in_minutes":1440}"#)?.normalizedCron, "0 0 * * *")
    }

    func testParseInvalidIgnored() {
        XCTAssertNil(RescheduleParser.parse("no directive here"))
        XCTAssertNil(RescheduleParser.parse(#"CADENCE_NEXT {"cron":"not a cron"}"#))
        XCTAssertNil(RescheduleParser.parse(#"CADENCE_NEXT {"in_minutes":7}"#))  // 7 doesn't divide cleanly
    }

    // MARK: - launchd interval derivation

    func testIntervalFromInMinutes() {
        XCTAssertEqual(RescheduleParser.parse(#"CADENCE_NEXT {"in_minutes":30}"#)?.intervalSeconds, 1800)
    }

    func testIntervalFromCron() {
        XCTAssertEqual(RescheduleParser.parse(#"CADENCE_NEXT {"cron":"*/10 * * * *"}"#)?.intervalSeconds, 600)
        XCTAssertEqual(RescheduleParser.parse(#"CADENCE_NEXT {"cron":"0 */3 * * *"}"#)?.intervalSeconds, 10800)
        XCTAssertEqual(RescheduleParser.parse(#"CADENCE_NEXT {"cron":"0 0 * * *"}"#)?.intervalSeconds, 86400)
    }

    func testIntervalNilForComplexCron() {
        // A weekday-specific cron can't be a plain launchd interval.
        XCTAssertNil(RescheduleParser.parse(#"CADENCE_NEXT {"cron":"0 9 * * 1"}"#)?.intervalSeconds)
    }

    func testLaunchdPlistWithInterval() {
        let base: [String: Any] = ["Label": "x", "StartCalendarInterval": ["Hour": 9],
                                   "ProgramArguments": ["/bin/echo"]]
        let out = LaunchdWriter.plistWithInterval(base, seconds: 1800)
        XCTAssertEqual(out["StartInterval"] as? Int, 1800)
        XCTAssertNil(out["StartCalendarInterval"])   // replaced
        XCTAssertNotNil(out["ProgramArguments"])      // preserved
    }

    // MARK: - Schedule rewrite (pure)

    func testRewriteFiveField() {
        XCTAssertEqual(CronWriter.rewriteScheduleOnLine("*/5 * * * * /bin/echo hi", cron: "0 * * * *"),
                       "0 * * * * /bin/echo hi")
    }

    func testRewriteShortcut() {
        XCTAssertEqual(CronWriter.rewriteScheduleOnLine("@daily /bin/echo hi", cron: "0 9 * * *"),
                       "0 9 * * * /bin/echo hi")
    }

    func testRewritePreservesDisabledAndWrap() {
        let line = "# */5 * * * * '/path/cadence-rec' --job cron:abc --label X --source cron --trigger schedule -- npx flue run x"
        let out = CronWriter.rewriteScheduleOnLine(line, cron: "0 */6 * * *")
        XCTAssertEqual(out, "# 0 */6 * * * '/path/cadence-rec' --job cron:abc --label X --source cron --trigger schedule -- npx flue run x")
    }
}
