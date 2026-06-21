import XCTest
@testable import CadenceCore

final class LaunchdInspectTests: XCTestCase {
    func testParsesCuratedFields() {
        let out = """
        gui/501/com.example = {
        \tactive count = 1
        \tstate = running
        \tpid = 4242
        \tprogram = /usr/bin/foo
        \tlast exit code = 0
        \truns = 7
        }
        """
        let d = LaunchdInspect.parse(out)
        func v(_ l: String) -> String? { d.first { $0.label == l }?.value }
        XCTAssertEqual(v("State"), "running")
        XCTAssertEqual(v("PID"), "4242")
        XCTAssertEqual(v("Last exit"), "0")
        XCTAssertEqual(v("Run count"), "7")
        XCTAssertEqual(v("Program"), "/usr/bin/foo")
    }

    func testOrderFollowsWantedKeys() {
        let out = "runs = 3\npid = 9\nstate = running"
        XCTAssertEqual(LaunchdInspect.parse(out).map(\.label), ["State", "PID", "Run count"])
    }

    func testNoMatchesIsEmpty() {
        XCTAssertTrue(LaunchdInspect.parse("no equals signs here").isEmpty)
    }
}
