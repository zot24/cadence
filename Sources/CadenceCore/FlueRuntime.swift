import Foundation

/// The Flue runtime conformer. Delegates to the existing, well-tested
/// `FlueScaffold` / `FlueSource` / `FlueReadiness` so adopting the runtime
/// abstraction doesn't regress current behavior — it only generalizes it.
public struct FlueRuntime: AgentRuntime {
    public init() {}

    public var id: RecipeRuntime { .flue }
    public var displayName: String { "Flue" }
    public var suggestedModels: [String] { FlueScaffold.suggestedModels }
    public var defaultModel: String { FlueScaffold.defaultModel }

    public func isProject(_ dir: URL) -> Bool { FlueSource.isFlueProject(dir) }

    public func scaffoldWorkspaceIfNeeded(at dir: URL, provider: ModelProvider) throws {
        let keys = provider.envKeyName.map { [$0] } ?? []
        try FlueScaffold.scaffoldWorkspaceIfNeeded(at: dir, envKeys: keys)
    }

    public func agentEntrySource(slug: String, model: String, instructions: String) -> String {
        FlueScaffold.agentSource(name: slug, model: model, instructions: instructions)
    }

    public func setupCommand(for project: URL) -> String {
        FlueScaffold.setupCommand(for: project)
    }

    public func runCommand(project: URL, slug: String) -> String {
        FlueSource.command(for: FlueAgent(name: slug, isWorkflow: false,
                                          projectPath: project.path,
                                          projectName: project.lastPathComponent))
    }

    public func readiness(project: URL, slug: String, provider: ModelProvider) -> [ReadinessCheck] {
        FlueReadiness.check(projectPath: project.path, agentName: slug, isWorkflow: false, provider: provider)
    }
}
