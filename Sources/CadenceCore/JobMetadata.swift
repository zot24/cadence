import Foundation

/// Extracts richer metadata about a job for display — plist internals, file
/// ownership/dates, working dir, env vars, log paths, cron line, Flue details.
public enum JobMetadata {
    public struct Row: Identifiable, Hashable, Sendable {
        public var id: String { key }
        public let key: String
        public let value: String
    }

    public static func rows(for job: Job) -> [Row] {
        var rows: [(String, String)] = []

        switch job.source {
        case .launchd:
            rows.append(contentsOf: launchdRows(job))
        case .cron:
            if let user = job.cronUser { rows.append(("Crontab user", user)) }
            if let line = job.cronLine?.trimmingCharacters(in: .whitespaces), !line.isEmpty {
                rows.append(("Crontab line", line))
            }
        case .flue:
            if let p = job.flueProjectPath { rows.append(("Flue project", p)) }
            if let a = job.flueAgentName { rows.append((job.flueIsWorkflow ? "Workflow" : "Agent", a)) }
            if let line = job.cronLine?.trimmingCharacters(in: .whitespaces), !line.isEmpty {
                rows.append(("Schedule line", line))
            }
        }

        if let tool = job.origin.tool {
            rows.append(("Detected tool", tool + " · \(job.origin.confidence.rawValue) confidence"))
        }
        if let ev = job.origin.evidence, !ev.isEmpty {
            rows.append(("Why", ev))
        }
        return rows.map { Row(key: $0.0, value: $0.1) }
    }

    private static func launchdRows(_ job: Job) -> [(String, String)] {
        var out: [(String, String)] = []
        if let domain = job.launchdDomain { out.append(("Domain", domain.displayName)) }
        if let pid = job.pid { out.append(("PID", String(pid))) }
        if let code = job.lastExitCode { out.append(("Last exit", String(code))) }

        guard let path = job.plistPath else { return out }
        out.append(("Plist", path))

        // File ownership + dates.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            if let owner = attrs[.ownerAccountName] as? String { out.append(("File owner", owner)) }
            if let created = attrs[.creationDate] as? Date {
                out.append(("Created", iso(created)))
            }
            if let modified = attrs[.modificationDate] as? Date {
                out.append(("Modified", iso(modified)))
            }
        }

        // Plist internals worth surfacing.
        if let data = FileManager.default.contents(atPath: path),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            if let wd = plist["WorkingDirectory"] as? String { out.append(("Working dir", wd)) }
            if let so = plist["StandardOutPath"] as? String { out.append(("stdout →", so)) }
            if let se = plist["StandardErrorPath"] as? String { out.append(("stderr →", se)) }
            if let env = plist["EnvironmentVariables"] as? [String: Any], !env.isEmpty {
                out.append(("Env vars", env.keys.sorted().joined(separator: ", ")))
            }
            if plist["KeepAlive"] != nil { out.append(("KeepAlive", "yes")) }
            if (plist["RunAtLoad"] as? Bool) == true { out.append(("RunAtLoad", "yes")) }
        }
        return out
    }

    private static func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}
