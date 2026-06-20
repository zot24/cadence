import Foundation

/// A Flue agent or workflow available to schedule.
public struct FlueAgent: Identifiable, Hashable, Sendable {
    public var id: String { projectPath + "/" + name + (isWorkflow ? "#wf" : "") }
    public var name: String
    public var isWorkflow: Bool
    public var projectPath: String
    public var projectName: String

    public init(name: String, isWorkflow: Bool, projectPath: String, projectName: String) {
        self.name = name
        self.isWorkflow = isWorkflow
        self.projectPath = projectPath
        self.projectName = projectName
    }
}

public struct FlueProject: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var agents: [FlueAgent]
}

/// Detects Flue projects (by `flue.config.ts` + an `agents/` directory),
/// enumerates their agents & workflows, and reclassifies scheduled cron/launchd
/// jobs that invoke the Flue CLI as first-class Flue jobs.
public enum FlueSource {

    /// Find Flue projects under a set of root directories (shallow scan: the
    /// roots themselves plus their immediate children).
    public static func discoverProjects(in roots: [URL]) -> [FlueProject] {
        var seen = Set<String>()
        var projects: [FlueProject] = []
        let fm = FileManager.default

        var candidates = roots
        for root in roots {
            if let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
                candidates.append(contentsOf: children.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                })
            }
        }

        for dir in candidates {
            guard isFlueProject(dir), !seen.contains(dir.path) else { continue }
            seen.insert(dir.path)
            projects.append(FlueProject(
                path: dir.path,
                name: dir.lastPathComponent,
                agents: enumerateAgents(in: dir)
            ))
        }
        return projects
    }

    public static func isFlueProject(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let configs = ["flue.config.ts", "flue.config.js"]
        let hasConfig = configs.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        let hasAgentsDir = fm.fileExists(atPath: dir.appendingPathComponent("agents").path)
        return hasConfig || hasAgentsDir
    }

    private static func enumerateAgents(in dir: URL) -> [FlueAgent] {
        let fm = FileManager.default
        let projectName = dir.lastPathComponent
        var agents: [FlueAgent] = []

        func scan(_ subdir: String, isWorkflow: Bool) {
            let url = dir.appendingPathComponent(subdir)
            guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
            for file in files where file.pathExtension == "ts" || file.pathExtension == "js" {
                let name = file.deletingPathExtension().lastPathComponent
                guard !name.hasPrefix("_"), name != "index" else { continue }
                agents.append(FlueAgent(name: name, isWorkflow: isWorkflow,
                                        projectPath: dir.path, projectName: projectName))
            }
        }
        scan("agents", isWorkflow: false)
        scan("workflows", isWorkflow: true)
        return agents
    }

    /// If a scheduled job's command invokes the Flue CLI, return an enriched
    /// copy classified as a Flue job (with the agent name pulled out).
    public static func enrich(_ job: Job) -> Job {
        let cmd = job.command.lowercased()
        guard cmd.contains("flue run") || cmd.contains("flue connect")
            || cmd.contains("flue workflow") || cmd.contains("@flue/cli") else {
            return job
        }
        var enriched = job
        enriched.source = .flue
        enriched.flueIsWorkflow = cmd.contains("workflow")
        enriched.flueAgentName = extractAgentName(from: job.command)
        enriched.flueProjectPath = extractProjectPath(from: job.command)
        if let name = enriched.flueAgentName { enriched.label = name }
        // Read the agent's source to surface what it actually does.
        if let proj = enriched.flueProjectPath, let name = enriched.flueAgentName,
           let info = readAgentInfo(projectPath: proj, agentName: name, isWorkflow: enriched.flueIsWorkflow) {
            enriched.flueModel = info.model
            enriched.flueGoal = info.instructions
        }
        return enriched
    }

    /// Extract the project path from a `cd '<path>' && npx flue …` command.
    public static func extractProjectPath(from command: String) -> String? {
        guard let cdRange = command.range(of: "cd ") else { return nil }
        let rest = command[cdRange.upperBound...]
        // Quoted path: cd '....' && ...
        if let first = rest.first, first == "'" || first == "\"" {
            let q = first
            if let close = rest.dropFirst().firstIndex(of: q) {
                return String(rest[rest.index(after: rest.startIndex)..<close])
                    .replacingOccurrences(of: "'\\''", with: "'")
            }
        }
        // Unquoted: up to the next space or &&.
        let token = rest.prefix(while: { $0 != " " })
        return token.isEmpty ? nil : String(token)
    }

    public struct AgentInfo: Sendable, Hashable {
        public var model: String?
        public var instructions: String?
    }

    /// Read a Flue agent/workflow's source and pull out its model + instructions.
    public static func readAgentInfo(projectPath: String, agentName: String, isWorkflow: Bool) -> AgentInfo? {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: projectPath)
        // Try the expected dir first, then the other, for .ts/.js.
        let dirs = isWorkflow ? ["workflows", "agents"] : ["agents", "workflows"]
        var src: String?
        for dir in dirs {
            for ext in ["ts", "js"] {
                let url = base.appendingPathComponent(dir).appendingPathComponent("\(agentName).\(ext)")
                if fm.fileExists(atPath: url.path), let s = try? String(contentsOf: url, encoding: .utf8) {
                    src = s; break
                }
            }
            if src != nil { break }
        }
        guard let source = src else { return nil }
        return AgentInfo(model: stringLiteral(after: "model:", in: source),
                         instructions: stringLiteral(after: "instructions:", in: source))
    }

    /// Find the first string literal (backtick, single, or double quoted)
    /// following `key` in `source`.
    static func stringLiteral(after key: String, in source: String) -> String? {
        guard let keyRange = source.range(of: key) else { return nil }
        var idx = keyRange.upperBound
        // Skip whitespace.
        while idx < source.endIndex, source[idx] == " " || source[idx] == "\t" || source[idx] == "\n" {
            idx = source.index(after: idx)
        }
        guard idx < source.endIndex else { return nil }
        let quote = source[idx]
        guard quote == "`" || quote == "'" || quote == "\"" else { return nil }
        var result = ""
        var cursor = source.index(after: idx)
        while cursor < source.endIndex {
            let ch = source[cursor]
            if ch == "\\" {
                let next = source.index(after: cursor)
                if next < source.endIndex { result.append(source[next]); cursor = source.index(after: next); continue }
            }
            if ch == quote { break }
            result.append(ch)
            cursor = source.index(after: cursor)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractAgentName(from command: String) -> String? {
        // Look for the token following `run` / `connect` / `workflow`.
        let tokens = command.split(separator: " ").map(String.init)
        let verbs: Set<String> = ["run", "connect", "workflow"]
        for (i, tok) in tokens.enumerated() where verbs.contains(tok) {
            if i + 1 < tokens.count {
                let candidate = tokens[i + 1]
                if !candidate.hasPrefix("-") { return candidate }
            }
        }
        return nil
    }

    /// Build the command line that schedules a Flue agent/workflow.
    public static func command(for agent: FlueAgent) -> String {
        let verb = agent.isWorkflow ? "workflow run" : "run"
        // `cd` into the project so flue picks up its config, then invoke.
        return "cd \(shellQuote(agent.projectPath)) && npx flue \(verb) \(agent.name)"
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
