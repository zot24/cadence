import XCTest
@testable import CadenceCore

final class LaunchdAdoptTests: XCTestCase {
    /// Build a throwaway user-agent plist and round-trip adopt -> unadopt.
    func testAdoptUnadoptRoundTrip() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadence-launchd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let label = "com.example.testjob"
        let plistURL = tmpDir.appendingPathComponent("\(label).plist")
        let original: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/local/bin/backup.sh", "--full"],
            "StartInterval": 3600,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
        try data.write(to: plistURL)

        // We can't actually bootstrap into launchd in a test, so exercise the
        // plist-rewrite logic directly via the public helpers.
        var dict = try readDict(plistURL)
        let argv = LaunchdWriter.originalArgv(from: dict)
        XCTAssertEqual(argv, ["/usr/local/bin/backup.sh", "--full"])

        // Simulate adoption's plist transform.
        let rec = CadencePaths.recorderURL.path
        dict["ProgramArguments"] = [rec, "--job", "launchd:\(label)", "--label", label,
                                    "--source", "launchd", "--trigger", "schedule", "--"] + argv
        dict.removeValue(forKey: "Program")
        try writeDict(dict, to: plistURL)

        // Parsed back: should read as adopted, with the ORIGINAL command shown.
        let runtime: [String: LaunchdSource.RuntimeEntry] = [:]
        let job = LaunchdSource.parsePlist(at: plistURL, domain: .userAgent, runtime: runtime)
        XCTAssertNotNil(job)
        XCTAssertTrue(job!.isAdopted)
        XCTAssertEqual(job!.command, "/usr/local/bin/backup.sh --full")
        XCTAssertEqual(job!.id, "launchd:\(label)")

        // Unadopt logic: recover original argv from after the `--`.
        let adoptedArgs = dict["ProgramArguments"] as! [String]
        let sep = adoptedArgs.firstIndex(of: "--")!
        XCTAssertEqual(Array(adoptedArgs[(sep + 1)...]), ["/usr/local/bin/backup.sh", "--full"])
    }

    func testEnvReadAndTransform() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadence-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let url = tmpDir.appendingPathComponent("com.example.env.plist")

        // Write a plist with an env, then read it back.
        let base: [String: Any] = ["Label": "com.example.env",
                                   "ProgramArguments": ["/bin/echo", "hi"],
                                   "EnvironmentVariables": ["ANTHROPIC_API_KEY": "sk-test"]]
        let data = try PropertyListSerialization.data(fromPropertyList: base, format: .xml, options: 0)
        try data.write(to: url)
        XCTAssertEqual(LaunchdWriter.readEnv(plistPath: url.path)["ANTHROPIC_API_KEY"], "sk-test")

        // Transform: add a key.
        let updated = LaunchdWriter.plistWithEnv(base, env: ["ANTHROPIC_API_KEY": "sk-test", "DEBUG": "1"])
        let env = updated["EnvironmentVariables"] as? [String: String]
        XCTAssertEqual(env?["DEBUG"], "1")
        XCTAssertEqual(env?.count, 2)

        // Transform: clearing removes the key entirely.
        let cleared = LaunchdWriter.plistWithEnv(base, env: [:])
        XCTAssertNil(cleared["EnvironmentVariables"])
        XCTAssertNotNil(cleared["ProgramArguments"])   // other keys preserved
    }

    func testBuildPlistInterval() {
        let spec = LaunchdWriter.ScheduleSpec(startInterval: 1800, runAtLoad: true)
        let dict = LaunchdWriter.buildPlistDict(label: "com.x.y", command: "echo hi", spec: spec, adopt: false)
        XCTAssertEqual(dict["Label"] as? String, "com.x.y")
        XCTAssertEqual(dict["StartInterval"] as? Int, 1800)
        XCTAssertEqual(dict["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(dict["ProgramArguments"] as? [String], ["/bin/sh", "-c", "echo hi"])
        XCTAssertNil(dict["StartCalendarInterval"])
    }

    func testBuildPlistWeeklyAdopted() {
        let spec = LaunchdWriter.ScheduleSpec(calendar: LaunchdCalendarInterval(minute: 30, hour: 9, weekday: 1))
        let dict = LaunchdWriter.buildPlistDict(label: "com.x.weekly", command: "run.sh", spec: spec, adopt: true)
        let cal = dict["StartCalendarInterval"] as? [String: Int]
        XCTAssertEqual(cal?["Weekday"], 1)
        XCTAssertEqual(cal?["Hour"], 9)
        XCTAssertEqual(cal?["Minute"], 30)
        // Adopted: ProgramArguments wraps the recorder around /bin/sh -c run.sh.
        let argv = dict["ProgramArguments"] as? [String]
        XCTAssertEqual(argv?.first?.contains("cadence-rec"), true)
        XCTAssertEqual(argv?.contains("--"), true)
        XCTAssertEqual(Array(argv!.suffix(3)), ["/bin/sh", "-c", "run.sh"])
        XCTAssertNil(dict["StartInterval"])
    }

    private func readDict(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
    }
    private func writeDict(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
    }
}
