import Foundation

/// A diagnosis of why a job failed plus how to fix it. The point (per agent
/// observability practice) is to collapse the gap between *detecting* a failure
/// and *understanding* it — especially for unattended, agent-triggered jobs.
public struct TriageResult: Sendable, Hashable {
    public enum Confidence: String, Sendable { case high, medium, low }
    public var category: String
    public var likelyCause: String
    public var suggestedFix: String
    public var confidence: Confidence

    public init(category: String, likelyCause: String, suggestedFix: String, confidence: Confidence) {
        self.category = category
        self.likelyCause = likelyCause
        self.suggestedFix = suggestedFix
        self.confidence = confidence
    }
}

/// Deterministic, dependency-free failure diagnosis. Cron/launchd run jobs in a
/// minimal environment, so the same handful of causes dominate; matching them
/// is high-value and instant. (A model-backed triage agent can layer on top.)
public enum FailureTriage {

    public static func diagnose(exitCode: Int?, stderr: String, stdout: String,
                                command: String, timedOut: Bool) -> TriageResult? {
        // Only diagnose actual failures.
        if !timedOut, let code = exitCode, code == 0 { return nil }
        let err = stderr.lowercased()
        let all = (stderr + "\n" + stdout).lowercased()

        if timedOut || exitCode == 124 {
            return TriageResult(
                category: "Timed out",
                likelyCause: "The job exceeded its max runtime and Cadence killed its process tree.",
                suggestedFix: "Raise the timeout in Settings, or investigate why the job hangs (a stuck network call or an agent loop that never converges).",
                confidence: .high)
        }
        if exitCode == 127 || err.contains("command not found") || err.contains(": not found") {
            return TriageResult(
                category: "Command not found",
                likelyCause: "A binary in the command isn't on PATH. cron and launchd use a minimal PATH that usually omits /opt/homebrew/bin, /usr/local/bin, and your shell's additions.",
                suggestedFix: "Use an absolute path (e.g. /opt/homebrew/bin/node), or prepend `PATH=…` to the command / add it to the launchd plist.",
                confidence: .high)
        }
        if exitCode == 126 || err.contains("permission denied") || err.contains("not permitted") {
            return TriageResult(
                category: "Permission denied",
                likelyCause: "The script isn't executable, or macOS blocked file access (cron often needs Full Disk Access).",
                suggestedFix: "Run `chmod +x` on the script, or grant /usr/sbin/cron Full Disk Access in System Settings → Privacy.",
                confidence: .high)
        }
        if matchesAny(all, ["401", "403", "unauthorized", "invalid api key", "authentication", "no api key", "anthropic_api_key", "openai_api_key", "missing credentials"]) {
            return TriageResult(
                category: "Authentication failed",
                likelyCause: "An API key or token is missing or invalid. Scheduled jobs don't load your shell profile, so keys exported in ~/.zshrc aren't visible.",
                suggestedFix: "Set the key in the job's own environment (the launchd plist EnvironmentVariables, or inline `KEY=… command`) rather than relying on your shell.",
                confidence: .high)
        }
        if matchesAny(all, ["429", "rate limit", "overloaded", "too many requests"]) {
            return TriageResult(
                category: "Rate limited",
                likelyCause: "The model/API provider throttled the request (429 / overloaded).",
                suggestedFix: "Lower the schedule frequency, add backoff/retry in the agent, or upgrade the provider tier.",
                confidence: .high)
        }
        if matchesAny(err, ["could not resolve host", "connection refused", "network is unreachable", "ssl", "curl:", "getaddrinfo", "econnrefused", "etimedout"]) {
            return TriageResult(
                category: "Network error",
                likelyCause: "The job couldn't reach a host (DNS, connectivity, TLS, or the endpoint is down).",
                suggestedFix: "Check connectivity and the URL; if it runs on wake-from-sleep, ensure the network is up first.",
                confidence: .medium)
        }
        if matchesAny(all, ["cannot find module", "module not found", "modulenotfounderror", "npm err", "no module named", "command not staged"]) {
            return TriageResult(
                category: "Missing dependency",
                likelyCause: "A required package/module isn't installed in the environment the job runs in.",
                suggestedFix: "Install deps in the job's working directory (e.g. `npm install`), or `cd` into the project before running.",
                confidence: .medium)
        }
        if err.contains("no such file or directory") {
            return TriageResult(
                category: "File or path not found",
                likelyCause: "A file or directory the command references doesn't exist from the job's working directory.",
                suggestedFix: "Use absolute paths; cron/launchd don't run from your usual working directory.",
                confidence: .medium)
        }

        // Generic fallback: surface the last stderr line.
        let lastLine = stderr.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        return TriageResult(
            category: "Failed (exit \(exitCode.map(String.init) ?? "?"))",
            likelyCause: lastLine.map { "Last error: \($0)" } ?? "The command exited non-zero with no captured stderr.",
            suggestedFix: "Open the logs above and re-run with “Run Now” to reproduce.",
            confidence: .low)
    }

    private static func matchesAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
