import Foundation

/// Minimal `.env` reader/writer. Flue (and most agent runtimes) load secrets
/// from a project `.env`, so editing that file is the idiomatic, safe way to
/// give a scheduled Flue agent its API keys — no crontab surgery required.
public enum DotEnv {

    /// Parse `KEY=value` lines (tolerates `export `, quotes, comments).
    public static func read(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var env: [String: String] = [:]
        for raw in text.components(separatedBy: "\n") {
            guard let (k, v) = parseLine(raw) else { continue }
            env[k] = v
        }
        return env
    }

    /// Write `env` into the file, preserving comments/blank lines and the order
    /// of existing keys; updates keys in place, drops removed keys, appends new.
    public static func write(_ env: [String: String], to url: URL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var written = Set<String>()
        var out: [String] = []

        for raw in existing.components(separatedBy: "\n") {
            if let (k, _) = parseLine(raw) {
                if let newVal = env[k] {
                    out.append(serialize(k, newVal))
                    written.insert(k)
                }
                // else: key removed — drop the line.
            } else {
                out.append(raw)   // keep comments / blanks / other content
            }
        }
        // Append new keys not already present.
        for key in env.keys.sorted() where !written.contains(key) {
            out.append(serialize(key, env[key]!))
        }
        // Trim trailing blank lines, ensure a single trailing newline.
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        let payload = out.joined(separator: "\n") + "\n"
        try payload.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    static func parseLine(_ raw: String) -> (String, String)? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { return nil }
        if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }

    private static func serialize(_ key: String, _ value: String) -> String {
        let needsQuote = value.contains(" ") || value.contains("#") || value.contains("\t")
        return needsQuote ? "\(key)=\"\(value)\"" : "\(key)=\(value)"
    }
}
