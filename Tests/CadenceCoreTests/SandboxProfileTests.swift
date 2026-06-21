import XCTest
@testable import CadenceCore

final class SandboxProfileTests: XCTestCase {

    func testProfileStructure() {
        let p = SandboxProfile.sbpl(projectPath: "/Users/me/proj", home: "/Users/me", allowNetwork: true)
        XCTAssertTrue(p.contains("(version 1)"))
        XCTAssertTrue(p.contains("(allow default)"))
        // Writes default-deny + allow-list.
        XCTAssertTrue(p.contains("(deny file-write*)"))
        XCTAssertTrue(p.contains("(subpath \"/Users/me/proj\")"))
        XCTAssertTrue(p.contains("(deny file-write-setugid)"))
        // Credential read-denies (best-effort).
        XCTAssertTrue(p.contains("(deny file-read*"))
        XCTAssertTrue(p.contains("(subpath \"/Users/me/.ssh\")"))
        XCTAssertTrue(p.contains("(subpath \"/Users/me/Library/Keychains\")"))
        XCTAssertFalse(p.contains("(subpath \"/Users/me/.npmrc\")"), "denying .npmrc breaks npx")
        // Exec hardening.
        XCTAssertTrue(p.contains("(deny process-exec*)"))
        XCTAssertTrue(p.contains("(literal \"/usr/bin/osascript\")"))
        XCTAssertTrue(p.contains("(deny appleevent-send)"))
        XCTAssertTrue(p.contains("(deny iokit-open)"))
    }

    func testNetworkToggle() {
        XCTAssertFalse(SandboxProfile.sbpl(projectPath: "/p", home: "/h", allowNetwork: true)
                        .contains("(deny network*)"))
        let noNet = SandboxProfile.sbpl(projectPath: "/p", home: "/h", allowNetwork: false)
        XCTAssertTrue(noNet.contains("(deny network*)"))
        XCTAssertTrue(noNet.contains("localhost:*"), "loopback (local model servers) must survive")
        XCTAssertTrue(noNet.contains("mDNSResponder"), "DNS must survive")
    }

    func testWrapStripsSSHAgentAndUsesSandboxExec() {
        let w = SandboxProfile.wrap(command: "cd '/p' && npx flue run x", profilePath: "/tmp/p.sb")
        XCTAssertTrue(w.hasPrefix("/usr/bin/sandbox-exec -f '/tmp/p.sb'"))
        XCTAssertTrue(w.contains("/usr/bin/env -u SSH_AUTH_SOCK -u SSH_AGENT_PID"))
        XCTAssertTrue(w.contains("/bin/sh -c 'cd '\\''/p'\\'' && npx flue run x'"))
    }

    func testPathsAreCanonicalized() {
        XCTAssertEqual(SandboxProfile.canonical("/tmp"), "/private/tmp")
        let p = SandboxProfile.sbpl(projectPath: "/tmp", home: "/tmp", allowNetwork: true)
        XCTAssertTrue(p.contains("(subpath \"/private/tmp\")"))
        XCTAssertFalse(p.contains("(subpath \"/tmp\")"), "unresolved path would silently not match")
    }

    // End-to-end against real Seatbelt: confirms the generated profile both
    // ENFORCES (write-confine, exec-block, secret-deny) and DOESN'T BREAK node.
    func testSeatbeltEnforcesPolicyEndToEnd() throws {
        let home = NSHomeDirectory()
        let nodeCandidates = ["\(home)/.hermes/node/bin/node", "/opt/homebrew/bin/node",
                              "/usr/local/bin/node", "/usr/bin/node"]
        let which = Shell.run("/usr/bin/which", ["node"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let nodePath = nodeCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? (which.isEmpty ? nil : which)
        guard let node = nodePath.map({ SandboxProfile.canonical($0) }) else {
            throw XCTSkip("no node found")
        }
        try XCTSkipUnless(Shell.run(node, ["-e", "process.stdout.write('ok')"]).stdout == "ok",
                          "baseline node failed — skipping")

        let fm = FileManager.default
        let proj = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("cad-sb-\(UUID().uuidString)")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: proj) }
        let readme = proj.appendingPathComponent("readme.txt")
        try "PROJDATA".write(to: readme, atomically: true, encoding: .utf8)
        let profile = proj.appendingPathComponent("p.sb")
        try SandboxProfile.sbpl(projectPath: proj.path, home: home, allowNetwork: true)
            .write(to: profile, atomically: true, encoding: .utf8)
        func sb(_ args: [String]) -> Shell.Result {
            Shell.run("/usr/bin/sandbox-exec", ["-f", profile.path] + args)
        }

        // 1. node runs (not broken by the profile).
        XCTAssertEqual(sb([node, "-e", "process.stdout.write('ok')"]).stdout, "ok",
                       "node must run under the sandbox")
        // 2. project read allowed.
        XCTAssertTrue(sb(["/bin/cat", readme.path]).stdout.contains("PROJDATA"))
        // 3. write outside the project denied.
        let evil = URL(fileURLWithPath: home).appendingPathComponent(".cadsb-evil-\(UUID().uuidString)")
        XCTAssertFalse(sb(["/usr/bin/touch", evil.path]).ok, "write outside project must be denied")
        try? fm.removeItem(at: evil)   // in case of regression
        // 4. write inside the project allowed.
        XCTAssertTrue(sb(["/usr/bin/touch", proj.appendingPathComponent("out").path]).ok)
        // 5. privilege-escalation / GUI-scripting tool denied.
        XCTAssertFalse(sb(["/usr/bin/osascript", "-e", "return 1"]).ok, "osascript must be blocked")
        // 6. credential store denied (only if it exists on this machine).
        if fm.fileExists(atPath: "\(home)/.ssh") {
            XCTAssertFalse(sb(["/bin/ls", "\(home)/.ssh"]).ok, "~/.ssh read must be denied")
        }
    }
}
