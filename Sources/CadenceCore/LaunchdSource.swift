import Foundation

/// Discovers macOS launchd jobs (LaunchAgents + LaunchDaemons), parses their
/// plists, and merges in live runtime status from `launchctl list`.
public enum LaunchdSource {

    private static func searchPaths() -> [(LaunchdDomain, URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (.userAgent, home.appendingPathComponent("Library/LaunchAgents")),
            (.globalAgent, URL(fileURLWithPath: "/Library/LaunchAgents")),
            (.systemDaemon, URL(fileURLWithPath: "/Library/LaunchDaemons")),
        ]
    }

    public static func load() -> [Job] {
        let runtime = launchctlList()
        var jobs: [Job] = []
        let fm = FileManager.default

        for (domain, dir) in searchPaths() {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in entries where url.pathExtension == "plist" {
                guard let job = parsePlist(at: url, domain: domain, runtime: runtime) else { continue }
                jobs.append(job)
            }
        }
        return jobs
    }

    public static func parsePlist(at url: URL, domain: LaunchdDomain, runtime: [String: RuntimeEntry]) -> Job? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }

        let label = (plist["Label"] as? String) ?? (url.deletingPathExtension().lastPathComponent)
        let command = commandString(from: plist)
        // Detect adoption from the RAW args (commandString unwraps for display).
        let isAdopted = (plist["ProgramArguments"] as? [String])?.first?.contains("cadence-rec") == true
        let schedule = parseSchedule(from: plist)

        let disabled = (plist["Disabled"] as? Bool) ?? false
        let rt = runtime[label]
        var status: JobRuntimeStatus = .idle
        if disabled { status = .disabled }
        else if let rt, rt.pid != nil { status = .running }
        else if let rt, let exit = rt.lastExitStatus, exit != 0 { status = .errored }

        return Job(
            id: "launchd:" + label,
            source: .launchd,
            label: label,
            command: command,
            schedule: schedule,
            enabled: !disabled,
            status: status,
            launchdDomain: domain,
            plistPath: url.path,
            pid: rt?.pid,
            lastExitCode: rt?.lastExitStatus,
            isAdopted: isAdopted,
            isAgentCreated: AgentHeuristics.looksAgentCreated(command: command) || AgentHeuristics.looksAgentCreated(command: label)
        )
    }

    private static func commandString(from plist: [String: Any]) -> String {
        if let args = plist["ProgramArguments"] as? [String], !args.isEmpty {
            // If adopted, show the original command (the part after the `--`).
            if args.first?.contains("cadence-rec") == true, let sep = args.firstIndex(of: "--") {
                return Array(args[(sep + 1)...]).joined(separator: " ")
            }
            return args.joined(separator: " ")
        }
        if let program = plist["Program"] as? String {
            return program
        }
        return "(no program)"
    }

    private static func parseSchedule(from plist: [String: Any]) -> JobSchedule {
        var schedule = JobSchedule()
        schedule.runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
        // KeepAlive can be a Bool or a Dictionary.
        if let ka = plist["KeepAlive"] as? Bool { schedule.keepAlive = ka }
        else if plist["KeepAlive"] is [String: Any] { schedule.keepAlive = true }

        if let interval = plist["StartInterval"] as? Int {
            schedule.startInterval = interval
        }

        // StartCalendarInterval: a single dict OR an array of dicts.
        var calendars: [LaunchdCalendarInterval] = []
        if let dict = plist["StartCalendarInterval"] as? [String: Any] {
            calendars.append(calendarInterval(from: dict))
        } else if let arr = plist["StartCalendarInterval"] as? [[String: Any]] {
            calendars = arr.map { calendarInterval(from: $0) }
        }
        schedule.calendarIntervals = calendars
        schedule.summary = summarize(schedule)
        return schedule
    }

    private static func calendarInterval(from dict: [String: Any]) -> LaunchdCalendarInterval {
        LaunchdCalendarInterval(
            minute: dict["Minute"] as? Int,
            hour: dict["Hour"] as? Int,
            day: dict["Day"] as? Int,
            weekday: dict["Weekday"] as? Int,
            month: dict["Month"] as? Int
        )
    }

    static func summarize(_ schedule: JobSchedule) -> String {
        if let interval = schedule.startInterval {
            return "Every " + humanInterval(interval)
        }
        if !schedule.calendarIntervals.isEmpty {
            return schedule.calendarIntervals.map { describeCalendar($0) }.joined(separator: ", ")
        }
        if schedule.keepAlive { return "Always running (KeepAlive)" }
        if schedule.runAtLoad { return "At load / login" }
        return "On demand"
    }

    private static func describeCalendar(_ c: LaunchdCalendarInterval) -> String {
        let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        var bits: [String] = []
        if let wd = c.weekday, (0...7).contains(wd) { bits.append(weekdayNames[wd % 7]) }
        if let h = c.hour, let m = c.minute { bits.append(String(format: "%02d:%02d", h, m)) }
        else if let h = c.hour { bits.append("hour \(h)") }
        else if let m = c.minute { bits.append("minute \(m)") }
        if let d = c.day { bits.append("day \(d)") }
        return bits.isEmpty ? "Calendar interval" : bits.joined(separator: " ")
    }

    private static func humanInterval(_ seconds: Int) -> String {
        if seconds % 86400 == 0 { let d = seconds / 86400; return "\(d) day\(d == 1 ? "" : "s")" }
        if seconds % 3600 == 0 { let h = seconds / 3600; return "\(h) hour\(h == 1 ? "" : "s")" }
        if seconds % 60 == 0 { let m = seconds / 60; return "\(m) minute\(m == 1 ? "" : "s")" }
        return "\(seconds) seconds"
    }

    // MARK: - Runtime status via launchctl

    public struct RuntimeEntry: Sendable {
        public var pid: Int?
        public var lastExitStatus: Int?
    }

    /// Parse `launchctl list` output: columns are PID, Status, Label.
    public static func launchctlList() -> [String: RuntimeEntry] {
        let result = Shell.run("/bin/launchctl", ["list"])
        guard result.ok else { return [:] }
        var map: [String: RuntimeEntry] = [:]
        for line in result.stdout.components(separatedBy: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init).filter { !$0.isEmpty }
            guard cols.count >= 3 else { continue }
            let pid = Int(cols[0])
            let exit = Int(cols[1])
            let label = cols[2...].joined(separator: " ")
            map[label] = RuntimeEntry(pid: pid, lastExitStatus: exit)
        }
        return map
    }
}
