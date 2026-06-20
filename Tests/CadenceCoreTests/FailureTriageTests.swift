import XCTest
@testable import CadenceCore

final class FailureTriageTests: XCTestCase {
    func testSuccessIsNotDiagnosed() {
        XCTAssertNil(FailureTriage.diagnose(exitCode: 0, stderr: "", stdout: "", command: "x", timedOut: false))
    }

    func testTimeout() {
        let t = FailureTriage.diagnose(exitCode: 124, stderr: "", stdout: "", command: "x", timedOut: true)
        XCTAssertEqual(t?.category, "Timed out")
        XCTAssertEqual(t?.confidence, .high)
    }

    func testCommandNotFound() {
        let t = FailureTriage.diagnose(exitCode: 127, stderr: "/bin/sh: node: command not found",
                                       stdout: "", command: "node x.js", timedOut: false)
        XCTAssertEqual(t?.category, "Command not found")
    }

    func testAuthFailure() {
        let t = FailureTriage.diagnose(exitCode: 1, stderr: "Error: 401 Unauthorized - invalid api key",
                                       stdout: "", command: "npx flue run x", timedOut: false)
        XCTAssertEqual(t?.category, "Authentication failed")
    }

    func testRateLimited() {
        let t = FailureTriage.diagnose(exitCode: 1, stderr: "429 Too Many Requests",
                                       stdout: "", command: "x", timedOut: false)
        XCTAssertEqual(t?.category, "Rate limited")
    }

    func testPermissionDenied() {
        let t = FailureTriage.diagnose(exitCode: 126, stderr: "permission denied: ./run.sh",
                                       stdout: "", command: "./run.sh", timedOut: false)
        XCTAssertEqual(t?.category, "Permission denied")
    }

    func testGenericFallbackUsesLastStderrLine() {
        let t = FailureTriage.diagnose(exitCode: 2, stderr: "doing thing\nsomething weird broke",
                                       stdout: "", command: "x", timedOut: false)
        XCTAssertTrue(t?.category.hasPrefix("Failed") ?? false)
        XCTAssertTrue(t?.likelyCause.contains("something weird broke") ?? false)
        XCTAssertEqual(t?.confidence, .low)
    }
}
