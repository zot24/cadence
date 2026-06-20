import Foundation

/// A parsed standard 5-field cron expression: minute hour day-of-month month
/// day-of-week. Supports `*`, `*/n`, ranges `a-b`, steps `a-b/n`, and lists `a,b,c`.
/// Used to humanise schedules and predict upcoming run times in the UI.
public struct CronExpression: Sendable {
    public let minutes: Set<Int>
    public let hours: Set<Int>
    public let daysOfMonth: Set<Int>
    public let months: Set<Int>
    public let daysOfWeek: Set<Int>   // 0 or 7 = Sunday, normalised to 0
    public let raw: String
    /// True when day-of-month and day-of-week are both restricted (cron ORs them).
    private let domRestricted: Bool
    private let dowRestricted: Bool

    public init?(_ expression: String) {
        let fields = expression.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5 else { return nil }
        guard
            let mins = Self.parseField(fields[0], min: 0, max: 59),
            let hrs = Self.parseField(fields[1], min: 0, max: 23),
            let doms = Self.parseField(fields[2], min: 1, max: 31),
            let mons = Self.parseField(fields[3], min: 1, max: 12, names: Self.monthNames),
            let dowsRaw = Self.parseField(fields[4], min: 0, max: 7, names: Self.weekdayNames)
        else { return nil }
        self.minutes = mins
        self.hours = hrs
        self.daysOfMonth = doms
        self.months = mons
        // Normalise 7 -> 0 for Sunday.
        self.daysOfWeek = Set(dowsRaw.map { $0 == 7 ? 0 : $0 })
        self.raw = expression
        self.domRestricted = fields[2] != "*"
        self.dowRestricted = fields[4] != "*"
    }

    /// Does the given date match this schedule (to the minute)?
    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = c.minute, let hour = c.hour, let day = c.day,
              let month = c.month, let weekday = c.weekday else { return false }
        let dow = weekday - 1   // Calendar weekday is 1...7 (Sun=1) -> 0...6 (Sun=0)
        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else { return false }

        let domMatch = daysOfMonth.contains(day)
        let dowMatch = daysOfWeek.contains(dow)
        // Cron rule: if both DOM and DOW are restricted, match if EITHER matches.
        if domRestricted && dowRestricted {
            return domMatch || dowMatch
        }
        return domMatch && dowMatch
    }

    /// Compute the next `count` run times after `date`. Bounded scan (~13 months).
    public func nextRuns(after date: Date, count: Int = 5, calendar: Calendar = .current) -> [Date] {
        var results: [Date] = []
        // Start at the next whole minute.
        guard var cursor = calendar.date(bySetting: .second, value: 0, of: date) else { return [] }
        cursor = cursor.addingTimeInterval(60)
        let limit = date.addingTimeInterval(60 * 60 * 24 * 400)
        while results.count < count && cursor < limit {
            if matches(cursor, calendar: calendar) {
                results.append(cursor)
            }
            cursor = cursor.addingTimeInterval(60)
        }
        return results
    }

    // MARK: - Field parsing

    private static let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                     "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let weekdayNames = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]

    private static func parseField(_ field: String, min: Int, max: Int, names: [String: Int] = [:]) -> Set<Int>? {
        var values = Set<Int>()
        for part in field.split(separator: ",") {
            guard let parsed = parsePart(String(part), min: min, max: max, names: names) else { return nil }
            values.formUnion(parsed)
        }
        return values.isEmpty ? nil : values
    }

    private static func parsePart(_ part: String, min: Int, max: Int, names: [String: Int]) -> Set<Int>? {
        // Step syntax: base/step
        var base = part
        var step = 1
        if let slash = part.firstIndex(of: "/") {
            base = String(part[part.startIndex..<slash])
            guard let s = Int(part[part.index(after: slash)...]), s > 0 else { return nil }
            step = s
        }

        var lower = min
        var upper = max
        if base == "*" || base == "" {
            // full range
        } else if let dash = base.firstIndex(of: "-") {
            guard let lo = value(String(base[base.startIndex..<dash]), names: names),
                  let hi = value(String(base[base.index(after: dash)...]), names: names) else { return nil }
            lower = lo; upper = hi
        } else {
            guard let v = value(base, names: names) else { return nil }
            // A single number with no step is just that number.
            if step == 1 { return [v] }
            lower = v; upper = max
        }
        guard lower >= min, upper <= max, lower <= upper else { return nil }
        var out = Set<Int>()
        var v = lower
        while v <= upper { out.insert(v); v += step }
        return out
    }

    private static func value(_ token: String, names: [String: Int]) -> Int? {
        if let n = Int(token) { return n }
        return names[token.lowercased()]
    }
}

/// Produce a friendly description for a cron expression.
public enum CronHumanizer {
    public static func describe(_ expression: String) -> String {
        let fields = expression.split(separator: " ").map(String.init)
        guard fields.count == 5 else { return expression }
        let (min, hour, dom, mon, dow) = (fields[0], fields[1], fields[2], fields[3], fields[4])

        // A few high-value common patterns first.
        if expression == "* * * * *" { return "Every minute" }
        if min.hasPrefix("*/"), hour == "*", dom == "*", mon == "*", dow == "*",
           let n = Int(min.dropFirst(2)) { return "Every \(n) minute\(n == 1 ? "" : "s")" }
        if min == "0", hour == "*", dom == "*", mon == "*", dow == "*" { return "Every hour" }
        if hour.hasPrefix("*/"), min == "0", dom == "*", mon == "*", dow == "*",
           let n = Int(hour.dropFirst(2)) { return "Every \(n) hours" }

        var parts: [String] = []
        // Time component
        if let m = Int(min), let h = Int(hour) {
            parts.append("at " + timeString(hour: h, minute: m))
        } else {
            if min != "*" { parts.append("minute \(min)") }
            if hour != "*" { parts.append("hour \(hour)") }
        }
        // Day of week
        if dow != "*" {
            parts.append("on " + weekdayString(dow))
        }
        // Day of month
        if dom != "*" {
            parts.append("on day \(dom) of the month")
        }
        // Month
        if mon != "*" {
            parts.append("in month \(mon)")
        }
        if parts.isEmpty { return expression }
        let base = dow == "*" && dom == "*" ? "Daily " : ""
        return (base + parts.joined(separator: ", ")).trimmingCharacters(in: .whitespaces).capitalizingFirst()
    }

    private static func timeString(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    private static func weekdayString(_ field: String) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let map: [String: Int] = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
        let tokens = field.split(separator: ",").map(String.init)
        let resolved: [String] = tokens.compactMap { tok in
            if let n = Int(tok) { let i = n == 7 ? 0 : n; return (0...6).contains(i) ? names[i] : nil }
            if let n = map[tok.lowercased()] { return names[n] }
            return tok
        }
        return resolved.isEmpty ? field : resolved.joined(separator: ", ")
    }
}

extension String {
    func capitalizingFirst() -> String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
