import XCTest
@testable import CadenceCore

/// Covers the pure `LaunchdControl.explainFailure` helper — never the live
/// launchctl, per the project's "test the pure helper" convention.
final class LaunchdControlTests: XCTestCase {

    // The exact failure the user hit: toggling a global agent off.
    func testPrivilegedBootoutGivesCleanMessageWithoutLeakingRawText() {
        let err = LaunchdControl.explainFailure(
            operation: .disable, label: "com.apple.something", domain: .globalAgent,
            exitCode: 1, stderr: "Boot-out failed: 1: Operation not permitted")
        guard case .needsPrivileges(let msg) = err else {
            return XCTFail("expected .needsPrivileges, got \(err)")
        }
        XCTAssertTrue(msg.contains("com.apple.something"), "should name the job")
        XCTAssertTrue(msg.lowercased().contains("administrator privileges"))
        XCTAssertFalse(msg.contains("Boot-out failed"), "raw launchctl text must not leak")
        XCTAssertFalse(msg.contains("Operation not permitted"), "raw launchctl text must not leak")
    }

    func testSystemDaemonPermissionDenied() {
        let err = LaunchdControl.explainFailure(
            operation: .remove, label: "com.example.daemon", domain: .systemDaemon,
            exitCode: 5, stderr: "Could not remove service: 1: Permission denied")
        guard case .needsPrivileges(let msg) = err else {
            return XCTFail("expected .needsPrivileges, got \(err)")
        }
        XCTAssertTrue(msg.contains("system daemon"))
    }

    // A user agent failing is a real error the user should see verbatim — not a
    // privilege wall (user agents run in the user's own gui domain).
    func testUserAgentRealFailureShowsRawError() {
        let err = LaunchdControl.explainFailure(
            operation: .run, label: "com.me.agent", domain: .userAgent,
            exitCode: 5, stderr: "Could not find service \"com.me.agent\"")
        guard case .failed(let msg) = err else {
            return XCTFail("expected .failed, got \(err)")
        }
        XCTAssertTrue(msg.contains("Could not find service"))
    }

    func testUserAgentExitOneIsNotTreatedAsPrivilege() {
        let err = LaunchdControl.explainFailure(
            operation: .disable, label: "com.me.agent", domain: .userAgent,
            exitCode: 1, stderr: "some failure")
        guard case .failed = err else {
            return XCTFail("user-agent failures must not be reported as needing privileges")
        }
    }

    func testEmptyStderrFallsBackToExitCode() {
        let err = LaunchdControl.explainFailure(
            operation: .enable, label: "com.me.agent", domain: .userAgent,
            exitCode: 78, stderr: "")
        XCTAssertEqual(err, .failed("exit 78"))
    }

    func testDescriptionDoesNotDoublePrefixPrivilegeMessage() {
        let err = LaunchdControl.ControlError.needsPrivileges("X requires administrator privileges.")
        XCTAssertEqual(err.description, "X requires administrator privileges.")
    }

    // MARK: - Elevated (privileged) command builders

    func testElevatedDisableCommand() {
        let cmd = LaunchdControl.elevatedSetEnabledCommand(
            label: "com.adobe.ARMDC.Communicator", domain: .systemDaemon,
            plistPath: "/Library/LaunchDaemons/com.adobe.ARMDC.Communicator.plist", enabled: false)
        XCTAssertTrue(cmd.contains("launchctl bootout system/com.adobe.ARMDC.Communicator"))
        XCTAssertTrue(cmd.contains("launchctl disable system/com.adobe.ARMDC.Communicator"))
    }

    func testElevatedEnableCommandQuotesPlist() {
        let cmd = LaunchdControl.elevatedSetEnabledCommand(
            label: "com.x", domain: .systemDaemon,
            plistPath: "/Library/LaunchDaemons/com.x.plist", enabled: true)
        XCTAssertTrue(cmd.contains("launchctl enable system/com.x"))
        XCTAssertTrue(cmd.contains("launchctl bootstrap system '/Library/LaunchDaemons/com.x.plist'"))
    }

    func testElevatedRemoveCommand() {
        let cmd = LaunchdControl.elevatedRemoveCommand(
            label: "com.x", domain: .systemDaemon, plistPath: "/Library/LaunchDaemons/com.x.plist")
        XCTAssertTrue(cmd.contains("launchctl bootout system/com.x"))
        XCTAssertTrue(cmd.contains("rm -f '/Library/LaunchDaemons/com.x.plist'"))
    }

    func testElevatedKickstartCommand() {
        let cmd = LaunchdControl.elevatedKickstartCommand(label: "com.x", domain: .systemDaemon)
        XCTAssertEqual(cmd, "/bin/launchctl kickstart -k system/com.x")
    }

    func testAppleScriptEscaping() {
        XCTAssertEqual(PrivilegedExec.escapeForAppleScript(#"a "b" \c"#), #"a \"b\" \\c"#)
    }
}
