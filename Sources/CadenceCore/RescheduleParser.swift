import Foundation

/// A cadence change an agent requested for itself. Adaptive scheduling: an agent
/// that finds nothing can ask to run less often; one that finds a problem can ask
/// to run more often — by printing a `CADENCE_NEXT` directive in its output.
public struct RescheduleRequest: Sendable, Hashable {
    public var cron: String?       // explicit 5-field cron the agent wants
    public var inMinutes: Int?     // or "check again every N minutes"

    public init(cron: String? = nil, inMinutes: Int? = nil) {
        self.cron = cron
        self.inMinutes = inMinutes
    }

    /// A concrete cron expression to apply, if we can derive one.
    public var normalizedCron: String? {
        if let cron, CronExpression(cron) != nil { return cron }
        return Self.cron(fromMinutes: inMinutes)
    }

    /// An interval in seconds, for launchd `StartInterval`. Derives from
    /// `in_minutes` or a simple "every N" cron (`*/N`, `0 */H`, daily).
    public var intervalSeconds: Int? {
        if let inMinutes, inMinutes > 0 { return inMinutes * 60 }
        if let cron { return Self.interval(fromCron: cron) }
        return nil
    }

    /// True when this request can be expressed for a launchd job.
    public var hasInterval: Bool { intervalSeconds != nil }

    static func interval(fromCron cron: String) -> Int? {
        let f = cron.split(separator: " ").map(String.init)
        guard f.count == 5 else { return nil }
        if f[0].hasPrefix("*/"), f[1...].allSatisfy({ $0 == "*" }), let n = Int(f[0].dropFirst(2)) { return n * 60 }
        if f[0] == "0", f[1].hasPrefix("*/"), f[2] == "*", f[3] == "*", f[4] == "*", let h = Int(f[1].dropFirst(2)) { return h * 3600 }
        if f[0] == "0", f[1] == "*", f[2...].allSatisfy({ $0 == "*" }) { return 3600 }
        if f[0] == "0", f[1] == "0", f[2] == "*", f[3] == "*", f[4] == "*" { return 86400 }
        return nil
    }

    static func cron(fromMinutes m: Int?) -> String? {
        guard let m, m > 0 else { return nil }
        if m < 60, 60 % m == 0 { return "*/\(m) * * * *" }
        if m == 60 { return "0 * * * *" }
        if m == 1440 { return "0 0 * * *" }
        if m % 60 == 0 {
            let h = m / 60
            if h < 24, 24 % h == 0 { return "0 */\(h) * * *" }
        }
        return nil
    }
}

/// Parses a `CADENCE_NEXT {json}` directive from an agent's output. Accepts
/// `{"cron":"…"}` or `{"in_minutes":N}` (also `inMinutes` / `every_minutes`).
public enum RescheduleParser {
    public static func parse(_ text: String) -> RescheduleRequest? {
        for line in text.components(separatedBy: "\n") where line.contains("CADENCE_NEXT") {
            guard let start = line.firstIndex(of: "{"),
                  let end = line.lastIndex(of: "}"), start < end,
                  let data = String(line[start...end]).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            var req = RescheduleRequest()
            req.cron = obj["cron"] as? String
            req.inMinutes = intValue(obj["in_minutes"]) ?? intValue(obj["inMinutes"]) ?? intValue(obj["every_minutes"])
            if req.normalizedCron != nil { return req }
        }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
