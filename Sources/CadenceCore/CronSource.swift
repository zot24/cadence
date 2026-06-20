import Foundation
import CryptoKit

/// Reads and writes the current user's crontab, turning each job line into a
/// unified `Job`. Cadence stores a stable id for each job in a trailing
/// `# cadence:<id>` marker comment so identity (and run history) survives edits.
public enum CronSource {

    /// Map of cron `@` shortcuts to equivalent 5-field expressions.
    private static let shortcuts: [String: String] = [
        "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *",
        "@monthly": "0 0 1 * *", "@weekly": "0 0 * * 0",
        "@daily": "0 0 * * *", "@midnight": "0 0 * * *",
        "@hourly": "0 * * * *"
    ]

    public struct ParsedCrontab {
        public var jobs: [Job]
        /// The full raw crontab text (so we can round-trip edits safely).
        public var raw: String
    }

    /// Load the user's crontab. Returns empty when no crontab is installed.
    public static func load() -> ParsedCrontab {
        let result = Shell.run("/usr/bin/crontab", ["-l"])
        // crontab -l exits non-zero with "no crontab for <user>" when empty.
        guard result.ok else {
            return ParsedCrontab(jobs: [], raw: "")
        }
        return parse(result.stdout)
    }

    public static func parse(_ text: String) -> ParsedCrontab {
        var jobs: [Job] = []
        var pendingID: String?

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                // Look for our identity marker on a preceding comment line.
                if let id = extractMarker(line) { pendingID = id }
                continue
            }
            // Skip environment assignments (NAME=value with no schedule).
            if isEnvAssignment(line) { continue }

            guard let job = parseJobLine(rawLine, markerID: pendingID) else {
                pendingID = nil
                continue
            }
            jobs.append(job)
            pendingID = nil
        }
        return ParsedCrontab(jobs: jobs, raw: text)
    }

    /// Like `parse`, but also reports the raw line index of each job (and
    /// whether the job line was commented out / disabled). Used by the writer
    /// to edit specific entries in place.
    public static func indexedJobs(_ text: String) -> [(job: Job, lineIndex: Int, disabled: Bool)] {
        var out: [(Job, Int, Bool)] = []
        var pendingID: String?
        let lines = text.components(separatedBy: "\n")
        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if let id = extractMarker(line) { pendingID = id }
                // A disabled job is a comment that still parses as a job line.
                let uncommented = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                if let job = parseJobLine(uncommented, markerID: pendingID), !uncommented.isEmpty,
                   (uncommented.first == "*" || uncommented.first == "@" || uncommented.first?.isNumber == true) {
                    out.append((job, idx, true))
                    pendingID = nil
                }
                continue
            }
            if isEnvAssignment(line) { continue }
            guard let job = parseJobLine(rawLine, markerID: pendingID) else { pendingID = nil; continue }
            out.append((job, idx, false))
            pendingID = nil
        }
        return out
    }

    // MARK: - Line parsing

    private static func parseJobLine(_ rawLine: String, markerID: String?) -> Job? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        var scheduleExpr: String?
        var specialSummary: String?
        var command: String

        if line.hasPrefix("@") {
            // @shortcut command — mapped to 5-field, or a non-recurring special.
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            let token = String(parts[0]).lowercased()
            command = String(parts[1])
            if let mapped = shortcuts[token] {
                scheduleExpr = mapped
            } else {
                // @reboot and friends: keep the job, but it has no recurring cron expression.
                specialSummary = token == "@reboot" ? "At startup" : token
            }
        } else {
            // 5 schedule fields then the command.
            let fields = splitFields(line, count: 5)
            guard let f = fields else { return nil }
            scheduleExpr = f.schedule
            command = f.command
        }
        command = command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }

        // Strip a trailing inline cadence marker from the command if present.
        var inlineID: String?
        if let range = command.range(of: "# cadence:") {
            let idPart = command[range.upperBound...].trimmingCharacters(in: .whitespaces)
            inlineID = idPart.split(separator: " ").first.map(String.init)
            command = String(command[command.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        let isAdopted = command.contains("cadence-rec")
        let (displayCommand, recordedID) = unwrapRecorder(command)
        let id = inlineID ?? markerID ?? recordedID ?? "cron:" + sha(displayCommand)

        let schedule: JobSchedule
        if let expr = scheduleExpr {
            schedule = JobSchedule(cronExpression: expr, summary: CronHumanizer.describe(expr))
        } else {
            schedule = JobSchedule(summary: specialSummary ?? "On demand")
        }
        return Job(
            id: id.hasPrefix("cron:") ? id : "cron:" + id,
            source: .cron,
            label: deriveLabel(displayCommand),
            command: displayCommand,
            schedule: schedule,
            enabled: true,
            status: .idle,
            cronLine: rawLine,
            cronUser: NSUserName(),
            isAdopted: isAdopted,
            isAgentCreated: AgentHeuristics.looksAgentCreated(command: displayCommand)
        )
    }

    /// Split a line into the first `count` whitespace fields plus the remainder.
    private static func splitFields(_ line: String, count: Int) -> (schedule: String, command: String)? {
        var fields: [String] = []
        var remainder = Substring(line)
        for _ in 0..<count {
            remainder = remainder.drop(while: { $0 == " " || $0 == "\t" })
            guard let spaceIdx = remainder.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            fields.append(String(remainder[remainder.startIndex..<spaceIdx]))
            remainder = remainder[spaceIdx...]
        }
        let command = remainder.trimmingCharacters(in: .whitespaces)
        guard fields.count == count, !command.isEmpty else { return nil }
        return (fields.joined(separator: " "), command)
    }

    private static func isEnvAssignment(_ line: String) -> Bool {
        guard let eq = line.firstIndex(of: "="), let space = line.firstIndex(of: " ") else {
            return line.contains("=") && !line.contains(" ")
        }
        // NAME=value form: '=' appears before any space.
        return eq < space && !line.hasPrefix("*") && !CharacterSet.decimalDigits.contains(line.unicodeScalars.first!)
    }

    private static func extractMarker(_ comment: String) -> String? {
        guard let range = comment.range(of: "cadence:") else { return nil }
        let id = comment[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return id.split(separator: " ").first.map(String.init)
    }

    /// If a command is wrapped by the recorder shim, return the inner command
    /// and the embedded job id.
    private static func unwrapRecorder(_ command: String) -> (display: String, id: String?) {
        guard command.contains("cadence-rec") else { return (command, nil) }
        // Form: <recorder> --job <id> --label <label> -- <real command...>
        var id: String?
        if let r = command.range(of: "--job ") {
            id = command[r.upperBound...].split(separator: " ").first.map(String.init)
        }
        if let sep = command.range(of: " -- ") {
            return (String(command[sep.upperBound...]).trimmingCharacters(in: .whitespaces), id)
        }
        return (command, id)
    }

    public static func deriveLabel(_ command: String) -> String {
        // Use the basename of the first path-like token, else the first word.
        let first = command.split(separator: " ").first.map(String.init) ?? command
        let base = (first as NSString).lastPathComponent
        return base.isEmpty ? command : base
    }

    static func sha(_ s: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }
}

/// Heuristics for guessing whether a job was created by an AI/automation agent.
public enum AgentHeuristics {
    private static let signals = [
        "claude", "flue", "openai", "agent", "anthropic", "automation",
        "/.claude/", "cadence", "cron create", "scheduled-agent", "routine"
    ]
    public static func looksAgentCreated(command: String) -> Bool {
        let lower = command.lowercased()
        return signals.contains { lower.contains($0) }
    }
}
