import Foundation

/// One concrete agent runtime (Flue, Eve, …). Knows how to detect/scaffold a
/// project, synthesize an agent's entry source, install deps, run an agent, and
/// preflight readiness. This is the seam that lets Cadence schedule jobs for
/// multiple frameworks behind a single installer + UI.
public protocol AgentRuntime: Sendable {
    var id: RecipeRuntime { get }
    var displayName: String { get }

    /// Experimental runtimes can be scaffolded/browsed but NOT scheduled — the
    /// installer refuses them so a broken cron line is never written.
    var isExperimental: Bool { get }
    var experimentalNote: String? { get }

    /// Curated model ids for the picker (provider/model format).
    var suggestedModels: [String] { get }
    var defaultModel: String { get }

    /// Is `dir` already a project of this runtime? (cheap filesystem check)
    func isProject(_ dir: URL) -> Bool

    /// Create the minimal project skeleton if `dir` isn't already one. Files
    /// only — deps are installed separately via `setupCommand`.
    func scaffoldWorkspaceIfNeeded(at dir: URL, provider: ModelProvider) throws

    /// Source for a `.agentEntry` file, synthesized from model + instructions.
    func agentEntrySource(slug: String, model: String, instructions: String) -> String

    /// One-time shell command to install deps in `project`.
    func setupCommand(for project: URL) -> String

    /// The scheduled (cron) command line that runs `slug` in `project`.
    func runCommand(project: URL, slug: String) -> String

    /// Data-driven readiness for a scheduled agent of this runtime.
    func readiness(project: URL, slug: String, provider: ModelProvider) -> [ReadinessCheck]
}

public extension AgentRuntime {
    var isExperimental: Bool { false }
    var experimentalNote: String? { nil }
}

/// Resolves a runtime conformer from a recipe's declared runtime.
public enum AgentRuntimes {
    public static func runtime(for r: RecipeRuntime) -> any AgentRuntime {
        switch r {
        case .flue: return FlueRuntime()
        case .eve:  return EveRuntime()
        }
    }

    public static let all: [any AgentRuntime] = [FlueRuntime(), EveRuntime()]
}
