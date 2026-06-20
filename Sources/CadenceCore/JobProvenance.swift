import Foundation

/// Category of what's behind a job.
public enum JobProvenance: String, Codable, Sendable, CaseIterable {
    case flue        // runs a Flue agent/workflow (model-backed)
    case aiAgent     // runs / was installed by a local AI agent runtime (Claude Code, Hermes, OpenClaw, Codex…)
    case automation  // a non-AI automation tool (Hazel, Keyboard Maestro, Raycast…)
    case packageManager // Homebrew & friends
    case system      // Apple / OS daemon
    case user        // ordinary user-defined job

    public var displayName: String {
        switch self {
        case .flue: return "Flue agent"
        case .aiAgent: return "AI agent"
        case .automation: return "Automation"
        case .packageManager: return "Package manager"
        case .system: return "System"
        case .user: return "User"
        }
    }

    public var symbolName: String {
        switch self {
        case .flue: return "sparkles"
        case .aiAgent: return "brain.head.profile"
        case .automation: return "wand.and.stars"
        case .packageManager: return "shippingbox"
        case .system: return "gearshape"
        case .user: return "person"
        }
    }

    /// A model/agent runs (or installed) the job's logic.
    public var isAgentic: Bool { self == .flue || self == .aiAgent }
}

/// Evidence-based origin of a job: which concrete tool is behind it, *why* we
/// think so, and how confident we are. Detection keys on the invoked binary and
/// known config paths/labels — never on a loose keyword like "agent" appearing
/// in a name (a launchd label such as `com.apple.foo.agent` is NOT agent-made).
public struct JobOrigin: Hashable, Sendable {
    public enum Confidence: String, Sendable { case high, medium, low }
    public var category: JobProvenance
    public var tool: String?        // "Flue", "Claude Code", "Hermes", "OpenClaw", "Homebrew", "Apple", …
    public var evidence: String?    // human-readable reason
    public var confidence: Confidence

    public init(category: JobProvenance = .user, tool: String? = nil,
                evidence: String? = nil, confidence: Confidence = .low) {
        self.category = category
        self.tool = tool
        self.evidence = evidence
        self.confidence = confidence
    }

    public var isAgentic: Bool { category.isAgentic }
    /// What to show on the badge.
    public var label: String { tool ?? category.displayName }
}

public enum JobProvenanceDetector {

    /// Signature for a known tool, matched against the job's real command.
    private struct Sig {
        let tool: String
        let category: JobProvenance
        let binaries: [String]      // exact invoked-binary basenames (e.g. "hermes", "flue")
        let paths: [String]         // substrings indicating config/install dirs
        let evidenceBinary: String  // shown when a binary matches
        let evidencePath: String    // shown when only a path matches
    }

    private static let signatures: [Sig] = [
        Sig(tool: "Flue", category: .flue,
            binaries: ["flue"], paths: ["@flue/", "/flue.config", "flue run", "flue connect", "flue workflow"],
            evidenceBinary: "invokes the Flue CLI", evidencePath: "references a Flue project"),
        Sig(tool: "Hermes", category: .aiAgent,
            binaries: ["hermes"], paths: ["/.hermes/"],
            evidenceBinary: "invokes the Hermes agent", evidencePath: "references ~/.hermes"),
        Sig(tool: "OpenClaw", category: .aiAgent,
            binaries: ["openclaw", "open-claw"], paths: ["/.openclaw/"],
            evidenceBinary: "invokes OpenClaw", evidencePath: "references ~/.openclaw"),
        Sig(tool: "Claude Code", category: .aiAgent,
            binaries: ["claude", "claude-code"], paths: ["/.claude/"],
            evidenceBinary: "invokes the claude CLI", evidencePath: "references ~/.claude"),
        Sig(tool: "Codex", category: .aiAgent,
            binaries: ["codex"], paths: ["@openai/codex", "/.codex/"],
            evidenceBinary: "invokes the Codex CLI", evidencePath: "references Codex config"),
        Sig(tool: "Aider", category: .aiAgent,
            binaries: ["aider"], paths: ["/.aider"],
            evidenceBinary: "invokes the Aider CLI", evidencePath: "references Aider"),
        Sig(tool: "OpenCode", category: .aiAgent,
            binaries: ["opencode"], paths: ["/.opencode/"],
            evidenceBinary: "invokes OpenCode", evidencePath: "references ~/.opencode"),
        Sig(tool: "Goose", category: .aiAgent,
            binaries: ["goose"], paths: ["/.config/goose/"],
            evidenceBinary: "invokes Goose", evidencePath: "references Goose config"),
        Sig(tool: "Hazel", category: .automation, binaries: [], paths: ["hazelnut", "/hazel.app/"],
            evidenceBinary: "", evidencePath: "Hazel automation"),
        Sig(tool: "Keyboard Maestro", category: .automation, binaries: ["keyboard maestro engine"], paths: ["/keyboard maestro"],
            evidenceBinary: "Keyboard Maestro macro", evidencePath: "Keyboard Maestro"),
        Sig(tool: "Raycast", category: .automation, binaries: [], paths: ["/raycast.app/", "raycast script"],
            evidenceBinary: "", evidencePath: "Raycast script command"),
        Sig(tool: "Shortcuts", category: .automation, binaries: ["shortcuts"], paths: [],
            evidenceBinary: "runs an Apple Shortcut", evidencePath: "Shortcuts"),
        Sig(tool: "Homebrew", category: .packageManager, binaries: [],
            paths: ["/opt/homebrew/", "/usr/local/cellar/", "homebrew.mxcl"],
            evidenceBinary: "", evidencePath: "Homebrew-managed service"),
    ]

    /// Reverse-DNS launchd label vendors (reliable when present).
    private static let labelVendors: [(prefix: String, tool: String, category: JobProvenance)] = [
        ("com.apple.", "Apple", .system),
        ("homebrew.mxcl.", "Homebrew", .packageManager),
        ("com.google.", "Google", .user),
        ("com.microsoft.", "Microsoft", .user),
        ("com.docker.", "Docker", .user),
        ("org.mozilla.", "Mozilla", .user),
    ]

    public static func detect(_ job: Job) -> JobOrigin {
        let cmd = job.command
        let lower = cmd.lowercased()
        let basenames = Set(cmd.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { ($0 as Substring).split(separator: "/").last.map(String.init)?.lowercased() ?? "" })

        // 1) Strongest: launchd label is com.apple.* (definitively Apple/system).
        let label = job.label.lowercased()
        if label.hasPrefix("com.apple.") {
            return JobOrigin(category: .system, tool: "Apple",
                             evidence: "Apple system label (\(job.label))", confidence: .high)
        }

        // 2) Command-level tool signatures (the reliable signal).
        for sig in signatures {
            if !sig.binaries.isEmpty, sig.binaries.contains(where: { basenames.contains($0) }) {
                return JobOrigin(category: sig.category, tool: sig.tool,
                                 evidence: sig.evidenceBinary, confidence: .high)
            }
            if let hit = sig.paths.first(where: { lower.contains($0) }) {
                let conf: JobOrigin.Confidence = sig.binaries.isEmpty ? .high : .medium
                return JobOrigin(category: sig.category, tool: sig.tool,
                                 evidence: "\(sig.evidencePath) (\(hit.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))",
                                 confidence: conf)
            }
        }
        // Flue can also be flagged by the source classifier upstream.
        if job.source == .flue || job.flueAgentName != nil {
            return JobOrigin(category: .flue, tool: "Flue",
                             evidence: "scheduled Flue agent", confidence: .high)
        }

        // 3) Other launchd vendor labels.
        for v in labelVendors where label.hasPrefix(v.prefix) {
            return JobOrigin(category: v.category, tool: v.tool,
                             evidence: "vendor label (\(v.prefix)…)", confidence: .medium)
        }

        // 4) System daemon domain (not a named vendor) — plausibly system.
        if job.launchdDomain == .systemDaemon || lower.contains("/system/library/") || lower.contains("/usr/libexec/") {
            return JobOrigin(category: .system, tool: nil,
                             evidence: "system daemon", confidence: .medium)
        }

        // Default: user job, no agent claim.
        return JobOrigin(category: .user, confidence: .low)
    }

    /// Back-compat: just the category.
    public static func classify(_ job: Job) -> JobProvenance { detect(job).category }
}

// Keep the old call site working.
public extension JobProvenance {
    static func classify(_ job: Job) -> JobProvenance { JobProvenanceDetector.classify(job) }
}
