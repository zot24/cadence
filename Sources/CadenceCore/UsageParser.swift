import Foundation

/// Semantic usage for one agent run — what the model actually did/cost, not just
/// the process exit code. Agent observability needs this; exit codes don't carry it.
public struct Usage: Sendable, Hashable {
    public var model: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var costUSD: Double?

    public init(model: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }

    public var isEmpty: Bool { model == nil && inputTokens == nil && outputTokens == nil && costUSD == nil }
    public var totalTokens: Int? {
        guard inputTokens != nil || outputTokens != nil else { return nil }
        return (inputTokens ?? 0) + (outputTokens ?? 0)
    }
}

/// Extracts `Usage` from an agent's captured output. Two paths:
///  1. Canonical, opt-in: a line containing `CADENCE_USAGE {json}` — any agent
///     (Flue, Claude, Hermes…) can print it to report exactly what it spent.
///  2. Best-effort: regex for common token/cost/model patterns in free text.
public enum UsageParser {

    public static func parse(_ text: String) -> Usage? {
        if let u = parseCanonical(text), !u.isEmpty { return u }
        let u = parseBestEffort(text)
        return u.isEmpty ? nil : u
    }

    // MARK: - Canonical CADENCE_USAGE {json}

    static func parseCanonical(_ text: String) -> Usage? {
        for line in text.components(separatedBy: "\n") where line.contains("CADENCE_USAGE") {
            guard let start = line.firstIndex(of: "{"),
                  let end = line.lastIndex(of: "}"), start < end else { continue }
            let json = String(line[start...end])
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var u = Usage()
            u.model = obj["model"] as? String
            u.inputTokens = intValue(obj["input_tokens"]) ?? intValue(obj["inputTokens"]) ?? intValue(obj["prompt_tokens"])
            u.outputTokens = intValue(obj["output_tokens"]) ?? intValue(obj["outputTokens"]) ?? intValue(obj["completion_tokens"])
            u.costUSD = doubleValue(obj["cost_usd"]) ?? doubleValue(obj["costUsd"]) ?? doubleValue(obj["cost"]) ?? doubleValue(obj["usd"])
            if let total = intValue(obj["total_tokens"]), u.inputTokens == nil, u.outputTokens == nil {
                u.outputTokens = total   // record the only number we have
            }
            if !u.isEmpty { return u }
        }
        return nil
    }

    // MARK: - Best-effort free-text parsing

    static func parseBestEffort(_ text: String) -> Usage {
        var u = Usage()
        u.inputTokens = firstInt(in: text, pattern: #"(?:input[_ ]?tokens|prompt[_ ]?tokens)["':= ]+([0-9,]+)"#)
        u.outputTokens = firstInt(in: text, pattern: #"(?:output[_ ]?tokens|completion[_ ]?tokens)["':= ]+([0-9,]+)"#)
        if u.inputTokens == nil && u.outputTokens == nil {
            u.outputTokens = firstInt(in: text, pattern: #"(?:total[_ ]?tokens|tokens[_ ]?used)["':= ]+([0-9,]+)"#)
        }
        u.costUSD = firstDouble(in: text, pattern: #"(?:cost[_ ]?usd|cost|usd)["':= ]+\$?([0-9]+\.[0-9]+)"#)
        u.model = firstMatch(in: text, pattern: #"((?:anthropic|openai|cloudflare|google|xai|ollama)/[A-Za-z0-9._-]+)"#)
        return u
    }

    // MARK: - Helpers

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s.replacingOccurrences(of: ",", with: "")) }
        return nil
    }
    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s.replacingOccurrences(of: "$", with: "")) }
        return nil
    }
    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
    private static func firstInt(in text: String, pattern: String) -> Int? {
        firstMatch(in: text, pattern: pattern).flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }
    }
    private static func firstDouble(in text: String, pattern: String) -> Double? {
        firstMatch(in: text, pattern: pattern).flatMap { Double($0) }
    }
}
