import Foundation

/// One readiness check for a Flue agent job.
public struct ReadinessCheck: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    public var passed: Bool
    public var detail: String   // fix hint when failed, or confirmation when passed

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

/// Pre-flight checks for whether a scheduled Flue agent will actually run.
/// Scheduled jobs fail silently when the workspace isn't set up — no deps, no
/// API key, or node missing from cron/launchd's minimal PATH. Surfacing this
/// before the schedule fires turns a silent failure into a one-line fix.
public enum FlueReadiness {

    /// Provider-blind check (kept for back-compat): "API key" passes if *any*
    /// key-looking var is set. Prefer the provider-aware overload below.
    public static func check(projectPath: String, agentName: String?, isWorkflow: Bool) -> [ReadinessCheck] {
        var checks = baseChecks(projectPath: projectPath, agentName: agentName, isWorkflow: isWorkflow)
        let env = DotEnv.read(URL(fileURLWithPath: projectPath).appendingPathComponent(".env"))
        let hasKey = env.contains { (k, v) in
            !v.isEmpty && (k.uppercased().contains("API_KEY") || k.uppercased().contains("TOKEN") || k.uppercased().hasSuffix("KEY"))
        }
        checks.append(ReadinessCheck(
            name: "API key",
            passed: hasKey,
            detail: hasKey ? "a key is set in .env" : "No API key in .env — add it via the key button (e.g. ANTHROPIC_API_KEY)."))
        return checks
    }

    /// Provider-aware check: requires the *specific* key the chosen provider
    /// needs (not just "some key"), and for local providers pings the model
    /// server instead of looking for a key.
    public static func check(projectPath: String, agentName: String?, isWorkflow: Bool,
                             provider: ModelProvider) -> [ReadinessCheck] {
        var checks = baseChecks(projectPath: projectPath, agentName: agentName, isWorkflow: isWorkflow)
        if provider.kind.isLocal {
            let up = provider.localHealthURL.map { localServerUp($0.absoluteString) } ?? false
            let name = provider.kind.displayName
            checks.append(ReadinessCheck(
                name: "Local model server",
                passed: up,
                detail: up ? "\(name) is responding"
                           : "\(name) isn't responding — start it before the schedule fires (the model runs locally)."))
        } else if let key = provider.envKeyName {
            let env = DotEnv.read(URL(fileURLWithPath: projectPath).appendingPathComponent(".env"))
            let has = !(env[key] ?? "").isEmpty
            checks.append(ReadinessCheck(
                name: "API key",
                passed: has,
                detail: has ? "\(key) is set in .env"
                            : "No \(key) in .env — the chosen model's provider needs it."))
        }
        return checks
    }

    /// Whether all checks pass.
    public static func ready(_ checks: [ReadinessCheck]) -> Bool {
        checks.allSatisfy(\.passed)
    }

    // MARK: - Shared checks (node / project / deps / agent file)

    private static func baseChecks(projectPath: String, agentName: String?, isWorkflow: Bool) -> [ReadinessCheck] {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: projectPath)
        var checks: [ReadinessCheck] = []

        // 1. node / npx available (the #1 PATH gotcha).
        let node = nodeAvailable()
        checks.append(ReadinessCheck(
            name: "Node runtime",
            passed: node,
            detail: node ? "node is installed" : "Install Node, and reference it by absolute path — cron/launchd don't see your shell PATH."))

        // 2. Flue config present (is this really a Flue project?).
        let hasConfig = ["flue.config.ts", "flue.config.js"].contains { fm.fileExists(atPath: base.appendingPathComponent($0).path) }
        checks.append(ReadinessCheck(
            name: "Flue project",
            passed: hasConfig,
            detail: hasConfig ? "flue.config found" : "No flue.config.ts — run `npx flue init` in this folder."))

        // 3. Dependencies installed.
        let hasNodeModules = fm.fileExists(atPath: base.appendingPathComponent("node_modules").path)
        let hasFlue = fm.fileExists(atPath: base.appendingPathComponent("node_modules/@flue").path)
        checks.append(ReadinessCheck(
            name: "Dependencies",
            passed: hasNodeModules && hasFlue,
            detail: (hasNodeModules && hasFlue) ? "node_modules present" : "Run `npm install` in the project (the @flue runtime isn't installed)."))

        // 4. Agent file exists.
        if let agentName {
            let dirs = isWorkflow ? ["workflows", "agents"] : ["agents", "workflows"]
            let found = dirs.contains { dir in
                ["ts", "js"].contains { ext in
                    fm.fileExists(atPath: base.appendingPathComponent("\(dir)/\(agentName).\(ext)").path)
                }
            }
            checks.append(ReadinessCheck(
                name: "Agent file",
                passed: found,
                detail: found ? "\(agentName) found" : "No agents/\(agentName).ts — the scheduled agent doesn't exist."))
        }

        return checks
    }

    static func nodeAvailable() -> Bool {
        let home = NSHomeDirectory()
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node",
                          "\(home)/.local/bin/node", "/usr/bin/node"]
        if candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return true }
        return Shell.run("/usr/bin/which", ["node"]).ok
    }

    /// A short-timeout liveness probe for a local model server (Ollama / LM
    /// Studio / custom). Uses curl to stay Foundation-only and bounded.
    static func localServerUp(_ url: String, timeoutMs: Int = 800) -> Bool {
        let secs = String(format: "%.1f", Double(timeoutMs) / 1000.0)
        return Shell.run("/usr/bin/curl", ["-sf", "-o", "/dev/null", "--max-time", secs, url]).ok
    }
}
