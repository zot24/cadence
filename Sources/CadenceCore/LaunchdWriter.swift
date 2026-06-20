import Foundation

/// Adopts/un-adopts launchd jobs for run tracking by rewriting their
/// `ProgramArguments` to invoke the recorder shim around the original command,
/// then reloading the job. Reversible: the original argv is recoverable from
/// the tokens after `--`. Only user agents (`~/Library/LaunchAgents`) can be
/// modified without elevation; others throw a clear error.
public enum LaunchdWriter {

    public enum WriteError: Error, CustomStringConvertible {
        case needsPrivileges(String)
        case notWritable(String)
        case malformed(String)
        public var description: String {
            switch self {
            case .needsPrivileges(let m): return "Requires administrator privileges: \(m)"
            case .notWritable(let p): return "Can't modify \(p)"
            case .malformed(let m): return "Unexpected plist: \(m)"
            }
        }
    }

    /// How a new launchd job should be scheduled.
    public struct ScheduleSpec: Sendable {
        public var startInterval: Int?               // seconds; "every N"
        public var calendar: LaunchdCalendarInterval? // daily/weekly time
        public var runAtLoad: Bool
        public init(startInterval: Int? = nil, calendar: LaunchdCalendarInterval? = nil, runAtLoad: Bool = false) {
            self.startInterval = startInterval
            self.calendar = calendar
            self.runAtLoad = runAtLoad
        }
    }

    /// Create a new user LaunchAgent that runs `command` (via /bin/sh -c) on the
    /// given schedule, write it to ~/Library/LaunchAgents, and bootstrap it.
    /// Returns the plist path. Optionally wraps with the recorder for tracking.
    @discardableResult
    public static func createUserAgent(label rawLabel: String, command: String,
                                       spec: ScheduleSpec, adopt: Bool) throws -> String {
        let label = sanitizeLabel(rawLabel)
        guard !label.isEmpty else { throw WriteError.malformed("empty label") }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plistURL = dir.appendingPathComponent("\(label).plist")
        guard !FileManager.default.fileExists(atPath: plistURL.path) else {
            throw WriteError.malformed("a LaunchAgent named \(label) already exists")
        }

        let dict = buildPlistDict(label: label, command: command, spec: spec, adopt: adopt)
        try writePlist(dict, to: plistURL.path)
        reload(label: label, plistPath: plistURL.path)
        return plistURL.path
    }

    /// Pure plist construction (no file IO) — the testable core of job creation.
    public static func buildPlistDict(label: String, command: String,
                                      spec: ScheduleSpec, adopt: Bool) -> [String: Any] {
        var argv = ["/bin/sh", "-c", command]
        if adopt {
            let rec = CadencePaths.recorderURL.path
            argv = [rec, "--job", "launchd:\(label)", "--label", label,
                    "--source", "launchd", "--trigger", "schedule", "--"] + argv
        }
        var dict: [String: Any] = ["Label": label, "ProgramArguments": argv]
        if let interval = spec.startInterval { dict["StartInterval"] = interval }
        if let cal = spec.calendar { dict["StartCalendarInterval"] = calendarDict(cal) }
        if spec.runAtLoad { dict["RunAtLoad"] = true }
        return dict
    }

    /// A safe reverse-DNS-ish label (letters, numbers, dots, dashes).
    public static func sanitizeLabel(_ s: String) -> String {
        let mapped = s.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_") ? ch : "-"
        }
        var out = String(mapped)
        while out.contains("..") { out = out.replacingOccurrences(of: "..", with: ".") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: ".-_ "))
    }

    private static func calendarDict(_ c: LaunchdCalendarInterval) -> [String: Int] {
        var d: [String: Int] = [:]
        if let m = c.minute { d["Minute"] = m }
        if let h = c.hour { d["Hour"] = h }
        if let day = c.day { d["Day"] = day }
        if let wd = c.weekday { d["Weekday"] = wd }
        if let mon = c.month { d["Month"] = mon }
        return d
    }

    /// Wrap the job's command with the recorder.
    public static func adopt(label: String, plistPath: String, domain: LaunchdDomain) throws {
        guard domain == .userAgent else {
            throw WriteError.needsPrivileges("editing \(domain.displayName) plists")
        }
        var plist = try readPlist(plistPath)
        let argv = originalArgv(from: plist)
        guard !argv.isEmpty else { throw WriteError.malformed("no Program/ProgramArguments in \(label)") }
        if argv.first?.contains("cadence-rec") == true { return } // already adopted

        let rec = CadencePaths.recorderURL.path
        let wrapped: [String] = [
            rec, "--job", "launchd:\(label)", "--label", label,
            "--source", "launchd", "--trigger", "schedule", "--",
        ] + argv
        plist["ProgramArguments"] = wrapped
        plist.removeValue(forKey: "Program")   // recorder is now the executable
        try writePlist(plist, to: plistPath)
        reload(label: label, plistPath: plistPath)
    }

    /// Restore the job's original command.
    public static func unadopt(label: String, plistPath: String, domain: LaunchdDomain) throws {
        guard domain == .userAgent else {
            throw WriteError.needsPrivileges("editing \(domain.displayName) plists")
        }
        var plist = try readPlist(plistPath)
        guard let args = plist["ProgramArguments"] as? [String],
              args.first?.contains("cadence-rec") == true,
              let sep = args.firstIndex(of: "--") else {
            return // not adopted
        }
        let original = Array(args[(sep + 1)...])
        guard !original.isEmpty else { throw WriteError.malformed("no original command after -- in \(label)") }
        if original.count == 1 {
            plist["Program"] = original[0]
            plist["ProgramArguments"] = original
        } else {
            plist["ProgramArguments"] = original
        }
        try writePlist(plist, to: plistPath)
        reload(label: label, plistPath: plistPath)
    }

    // MARK: - Environment variables

    /// Read a job's EnvironmentVariables (read-only; any domain).
    public static func readEnv(plistPath: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let env = plist["EnvironmentVariables"] as? [String: String] else { return [:] }
        return env
    }

    /// Set a job's EnvironmentVariables and reload it. User agents only — this is
    /// the fix for the #1 scheduled-agent failure (API keys that live in the
    /// shell profile, which launchd never loads).
    public static func setEnv(label: String, plistPath: String, domain: LaunchdDomain, env: [String: String]) throws {
        guard domain == .userAgent else {
            throw WriteError.needsPrivileges("editing \(domain.displayName) plists")
        }
        let plist = plistWithEnv(try readPlist(plistPath), env: env)
        try writePlist(plist, to: plistPath)
        reload(label: label, plistPath: plistPath)
    }

    /// Set a launchd job's run interval (StartInterval, seconds) and reload it.
    /// Used by adaptive (agent-requested) scheduling. User agents only.
    public static func setInterval(label: String, plistPath: String, domain: LaunchdDomain, seconds: Int) throws {
        guard domain == .userAgent else {
            throw WriteError.needsPrivileges("editing \(domain.displayName) plists")
        }
        guard seconds > 0 else { throw WriteError.malformed("interval must be positive") }
        let plist = plistWithInterval(try readPlist(plistPath), seconds: seconds)
        try writePlist(plist, to: plistPath)
        reload(label: label, plistPath: plistPath)
    }

    /// Pure transform: set StartInterval and drop StartCalendarInterval.
    public static func plistWithInterval(_ plist: [String: Any], seconds: Int) -> [String: Any] {
        var p = plist
        p["StartInterval"] = seconds
        p.removeValue(forKey: "StartCalendarInterval")
        return p
    }

    /// Pure transform: set/clear EnvironmentVariables on a plist dict.
    public static func plistWithEnv(_ plist: [String: Any], env: [String: String]) -> [String: Any] {
        var p = plist
        if env.isEmpty { p.removeValue(forKey: "EnvironmentVariables") }
        else { p["EnvironmentVariables"] = env }
        return p
    }

    // MARK: - Helpers

    /// The job's command as an argv array, from ProgramArguments or Program.
    public static func originalArgv(from plist: [String: Any]) -> [String] {
        if let args = plist["ProgramArguments"] as? [String], !args.isEmpty { return args }
        if let program = plist["Program"] as? String { return [program] }
        return []
    }

    private static func readPlist(_ path: String) throws -> [String: Any] {
        guard FileManager.default.isWritableFile(atPath: path) else {
            throw WriteError.notWritable(path)
        }
        guard let data = FileManager.default.contents(atPath: path),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { throw WriteError.malformed(path) }
        return dict
    }

    private static func writePlist(_ dict: [String: Any], to path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// bootout + bootstrap so launchd picks up the rewritten ProgramArguments.
    private static func reload(label: String, plistPath: String) {
        let target = "gui/\(getuid())"
        _ = Shell.run("/bin/launchctl", ["bootout", "\(target)/\(label)"])
        _ = Shell.run("/bin/launchctl", ["bootstrap", target, plistPath])
    }
}
