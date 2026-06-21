import Foundation

/// One labeled live-detail row for a launchd job.
public struct ProcessDetail: Sendable, Hashable, Identifiable {
    public var id: String { label }
    public var label: String
    public var value: String
    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

/// Reads richer live detail for a launchd job via `launchctl print` (+ `ps` for
/// the running PID). The parser is pure + testable; `inspect` runs the tools.
public enum LaunchdInspect {

    /// Curated `launchctl print` keys → display labels, in display order.
    static let wantedKeys: [(key: String, label: String)] = [
        ("state", "State"),
        ("pid", "PID"),
        ("last exit code", "Last exit"),
        ("runs", "Run count"),
        ("program", "Program"),
    ]

    /// Parse `key = value` lines from `launchctl print` output (pure).
    public static func parse(_ output: String) -> [ProcessDetail] {
        let strip = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "{};\""))
        var found: [String: String] = [:]
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let r = line.range(of: " = ") else { continue }
            let key = String(line[..<r.lowerBound]).lowercased()
            let value = String(line[r.upperBound...]).trimmingCharacters(in: strip)
            if found[key] == nil, !value.isEmpty { found[key] = value }
        }
        return wantedKeys.compactMap { w in found[w.key].map { ProcessDetail(w.label, $0) } }
    }

    /// Live detail for a job. Empty if `launchctl print` is unavailable (e.g. a
    /// system daemon that needs root to inspect).
    public static func inspect(label: String, domain: LaunchdDomain) -> [ProcessDetail] {
        let target: String
        switch domain {
        case .systemDaemon:            target = "system/\(label)"
        case .userAgent, .globalAgent: target = "gui/\(getuid())/\(label)"
        }
        let out = Shell.run("/bin/launchctl", ["print", target])
        guard out.ok else { return [] }
        var details = parse(out.stdout)

        // Live CPU / memory / uptime from ps, when there's a running PID.
        if let pid = details.first(where: { $0.label == "PID" })?.value, Int(pid) != nil {
            let ps = Shell.run("/bin/ps", ["-o", "%cpu=,%mem=,etime=,rss=", "-p", pid])
            let cols = ps.stdout.split { $0 == " " || $0 == "\t" || $0 == "\n" }.map(String.init)
            if cols.count >= 4 {
                let rssMB = Int(cols[3]).map { "\($0 / 1024) MB" } ?? cols[3]
                details.append(ProcessDetail("CPU", "\(cols[0])%"))
                details.append(ProcessDetail("Memory", "\(rssMB) (\(cols[1])%)"))
                details.append(ProcessDetail("Uptime", cols[2]))
            }
        }
        return details
    }
}
