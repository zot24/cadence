import Foundation

/// Writes changes back to the user's crontab. All edits go through
/// `installCrontab`, which pipes the full text to `crontab -`. Each managed job
/// carries a `# cadence:<id>` marker so identity (and run history) is stable.
public enum CronWriter {

    public enum WriteError: Error, CustomStringConvertible {
        case installFailed(String)
        case notFound(String)
        public var description: String {
            switch self {
            case .installFailed(let m): return "Could not update crontab: \(m)"
            case .notFound(let id): return "No cron job with id \(id)"
            }
        }
    }

    public static func currentRaw() -> String {
        CronSource.load().raw
    }

    /// Replace the entire crontab with `text`.
    public static func installCrontab(_ text: String) throws {
        // Ensure trailing newline (cron requires it).
        let payload = text.hasSuffix("\n") ? text : text + "\n"
        let result = Shell.run("/usr/bin/crontab", ["-"], input: payload)
        guard result.ok else {
            throw WriteError.installFailed(result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr)
        }
    }

    /// Add a new cron job. Returns the new job's id.
    @discardableResult
    public static func addJob(schedule: String, command: String, label: String?, adopt: Bool) throws -> String {
        let id = "cron:" + CronSource.sha(command + schedule)
        let shortID = String(id.dropFirst("cron:".count))
        let finalCommand = adopt ? wrap(command: command, id: id, label: label ?? CronSource.deriveLabel(command), source: .cron) : command
        var raw = currentRaw()
        if !raw.isEmpty && !raw.hasSuffix("\n") { raw += "\n" }
        let labelComment = label.map { "# \($0)\n" } ?? ""
        raw += "\(labelComment)# cadence:\(shortID)\n\(schedule) \(finalCommand)\n"
        try installCrontab(raw)
        return id
    }

    /// Remove a job (and its marker/label comment block) by id.
    public static func removeJob(id: String) throws {
        let lines = currentRaw().components(separatedBy: "\n")
        guard let target = CronSource.indexedJobs(currentRaw()).first(where: { $0.job.id == id })?.lineIndex else {
            throw WriteError.notFound(id)
        }
        var kept: [String] = []
        for (idx, line) in lines.enumerated() {
            if idx == target { continue }
            // Drop an immediately-preceding cadence marker / label comment.
            if idx == target - 1, line.trimmingCharacters(in: .whitespaces).hasPrefix("# cadence:") { continue }
            kept.append(line)
        }
        try installCrontab(kept.joined(separator: "\n"))
    }

    /// Enable/disable by commenting or uncommenting the job line.
    public static func setEnabled(id: String, enabled: Bool) throws {
        var lines = currentRaw().components(separatedBy: "\n")
        guard let entry = CronSource.indexedJobs(currentRaw()).first(where: { $0.job.id == id }) else {
            throw WriteError.notFound(id)
        }
        let idx = entry.lineIndex
        let line = lines[idx]
        if enabled {
            // Strip a single leading "# " used for disabling.
            var stripped = line
            while stripped.hasPrefix("#") { stripped.removeFirst() }
            lines[idx] = stripped.trimmingCharacters(in: .whitespaces)
        } else if !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            lines[idx] = "# " + line
        }
        try installCrontab(lines.joined(separator: "\n"))
    }

    /// Change a cron job's schedule expression, preserving its command, marker,
    /// and enabled/disabled state. Used by adaptive (agent-requested) scheduling.
    public static func setSchedule(id: String, cron: String) throws {
        let raw = currentRaw()
        guard let entry = CronSource.indexedJobs(raw).first(where: { $0.job.id == id }) else {
            throw WriteError.notFound(id)
        }
        var lines = raw.components(separatedBy: "\n")
        let idx = entry.lineIndex
        guard let rewritten = rewriteScheduleOnLine(lines[idx], cron: cron) else {
            throw WriteError.installFailed("could not isolate the command")
        }
        lines[idx] = rewritten
        try installCrontab(lines.joined(separator: "\n"))
    }

    /// Pure: replace the schedule on a raw cron job line, preserving the command
    /// (incl. recorder wrap) and the disabled `#` prefix. Returns nil if no command.
    public static func rewriteScheduleOnLine(_ rawLine: String, cron: String) -> String? {
        var line = rawLine
        let wasDisabled = line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        while let f = line.first, f == "#" || f == " " || f == "\t" { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        let command: String
        if line.hasPrefix("@") {
            command = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        } else {
            var remainder = Substring(line)
            for _ in 0..<5 {
                remainder = remainder.drop(while: { $0 == " " || $0 == "\t" })
                if let sp = remainder.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                    remainder = remainder[sp...]
                }
            }
            command = remainder.trimmingCharacters(in: .whitespaces)
        }
        guard !command.isEmpty else { return nil }
        return (wasDisabled ? "# " : "") + "\(cron) \(command)"
    }

    /// Adopt (wrap with recorder) or un-adopt the job, preserving its id.
    public static func setAdopted(id: String, adopted: Bool, label: String) throws {
        let raw = currentRaw()
        guard let entry = CronSource.indexedJobs(raw).first(where: { $0.job.id == id }) else {
            throw WriteError.notFound(id)
        }
        var lines = raw.components(separatedBy: "\n")
        let idx = entry.lineIndex
        let job = entry.job
        // Recompose the schedule + (un)wrapped command on the existing line.
        guard let schedule = job.schedule.cronExpression else { return }
        let prefix = entry.disabled ? "# " : ""
        let newCommand = adopted ? wrap(command: job.command, id: id, label: label, source: .cron) : job.command
        lines[idx] = "\(prefix)\(schedule) \(newCommand)"
        // Make sure an id marker exists so identity survives.
        try installCrontab(ensureMarker(lines, beforeIndex: idx, id: id))
    }

    // MARK: - Inline environment (KEY=val prefixes)

    /// Read the inline env vars from a raw cron job line.
    public static func envFromLine(_ rawLine: String) -> [String: String] {
        var line = rawLine
        while let f = line.first, f == "#" || f == " " || f == "\t" { line.removeFirst() }
        guard let (_, rest) = splitSchedule(line) else { return [:] }
        return Dictionary(peelEnv(rest).env, uniquingKeysWith: { a, _ in a })
    }

    /// Pure: rewrite the inline env prefix on a raw cron line, preserving the
    /// schedule, the command (incl. recorder wrap), and the disabled `#`.
    public static func rewriteEnvOnLine(_ rawLine: String, env: [String: String]) -> String? {
        let disabled = rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        var line = rawLine
        while let f = line.first, f == "#" || f == " " || f == "\t" { line.removeFirst() }
        guard let (sched, rest) = splitSchedule(line) else { return nil }
        let command = peelEnv(rest).command
        guard !command.isEmpty else { return nil }
        let prefix = env.keys.sorted().map { "\($0)=\(quoteIfNeeded(env[$0]!))" }.joined(separator: " ")
        let body = prefix.isEmpty ? command : "\(prefix) \(command)"
        return (disabled ? "# " : "") + "\(sched) \(body)"
    }

    /// Set the inline env on a cron job (by id) and reinstall the crontab.
    public static func setInlineEnv(id: String, env: [String: String]) throws {
        let raw = currentRaw()
        guard let entry = CronSource.indexedJobs(raw).first(where: { $0.job.id == id }) else {
            throw WriteError.notFound(id)
        }
        var lines = raw.components(separatedBy: "\n")
        guard let rewritten = rewriteEnvOnLine(lines[entry.lineIndex], env: env) else {
            throw WriteError.installFailed("could not isolate the command")
        }
        lines[entry.lineIndex] = rewritten
        try installCrontab(lines.joined(separator: "\n"))
    }

    /// Split "min hr dom mon dow" (or "@shortcut") off the front; return (schedule, rest).
    static func splitSchedule(_ line: String) -> (schedule: String, rest: String)? {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("@") {
            let parts = l.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]).trimmingCharacters(in: .whitespaces))
        }
        var remainder = Substring(l)
        var fields: [String] = []
        for _ in 0..<5 {
            remainder = remainder.drop(while: { $0 == " " || $0 == "\t" })
            guard let sp = remainder.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            fields.append(String(remainder[remainder.startIndex..<sp]))
            remainder = remainder[sp...]
        }
        return (fields.joined(separator: " "), remainder.trimmingCharacters(in: .whitespaces))
    }

    /// Peel leading `KEY=val` assignments off the command part.
    static func peelEnv(_ rest: String) -> (env: [(String, String)], command: String) {
        var env: [(String, String)] = []
        let tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            guard let eq = t.firstIndex(of: "="), eq != t.startIndex else { break }
            let key = String(t[t.startIndex..<eq])
            guard let first = key.first, first.isLetter || first == "_",
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { break }
            env.append((key, stripQuotes(String(t[t.index(after: eq)...]))))
            i += 1
        }
        return (env, tokens[i...].joined(separator: " "))
    }

    private static func stripQuotes(_ s: String) -> String {
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
    private static func quoteIfNeeded(_ s: String) -> String {
        s.contains(" ") || s.contains("\t") ? "\"\(s)\"" : s
    }

    /// Build the recorder-wrapped command form.
    public static func wrap(command: String, id: String, label: String, source: JobSource) -> String {
        let rec = CadencePaths.recorderURL.path
        let shortID = id
        return "\(shellQuote(rec)) --job \(shellQuote(shortID)) --label \(shellQuote(label)) --source \(source.rawValue) --trigger schedule -- \(command)"
    }

    private static func ensureMarker(_ lines: [String], beforeIndex idx: Int, id: String) -> String {
        let shortID = String(id.dropFirst("cron:".count))
        if idx > 0, lines[idx - 1].trimmingCharacters(in: .whitespaces).hasPrefix("# cadence:") {
            return lines.joined(separator: "\n")
        }
        var copy = lines
        copy.insert("# cadence:\(shortID)", at: idx)
        return copy.joined(separator: "\n")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
