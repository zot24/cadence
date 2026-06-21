import Foundation

/// The bundled, offline-first recipe catalog. Derived from `AgentTemplates`
/// (the existing curated set) plus a gated Eve example, all expressed as
/// `Recipe`s. Kept in-code rather than JSON resources to stay zero-dep and avoid
/// bundle-path pitfalls; `Recipe` is `Codable`, so a remote/JSON source can be
/// added later without changing the model or the install pipeline.
public enum RecipeCatalog {
    public static let all: [Recipe] = flueRecipes + eveRecipes

    /// Recipes safe to schedule today (non-experimental runtimes) — the default
    /// gallery contents.
    public static var shippable: [Recipe] {
        all.filter { !AgentRuntimes.runtime(for: $0.runtime).isExperimental }
    }

    public static func recipe(id: String) -> Recipe? { all.first { $0.id == id } }

    static let flueRecipes: [Recipe] = AgentTemplates.all.map { t in
        Recipe(
            id: "flue/\(t.name)",
            title: t.title,
            description: t.instructions,
            runtime: .flue,
            symbol: t.symbol,
            slug: t.name,
            model: FlueScaffold.defaultModel,
            instructions: t.instructions,
            files: [RecipeFile(target: "agents/\(t.name).ts", generated: .agentEntry)],
            suggestedCron: t.suggestedCron,
            dependencies: ["@flue/runtime", "@flue/cli"],
            envVars: [RecipeEnvVar(key: "ANTHROPIC_API_KEY", prompt: "Anthropic API key",
                                   url: "https://console.anthropic.com/settings/keys", required: true)]
        )
    }

    static let eveRecipes: [Recipe] = [
        Recipe(
            id: "eve/weather-watch",
            title: "Weather Watch (Eve)",
            description: "An Eve agent that checks the forecast and writes a morning briefing. Experimental — requires Node ≥ 24.",
            runtime: .eve,
            symbol: "cloud.sun",
            slug: "weather-watch",
            model: "anthropic/claude-sonnet-4.6",
            instructions: "Check today's weather for my city and write a one-paragraph briefing.",
            files: [
                RecipeFile(target: "agent/agent.ts", generated: .agentEntry),
                RecipeFile(target: "agent/instructions.md",
                           content: "Check today's weather and write a one-paragraph briefing."),
            ],
            suggestedCron: "0 7 * * *",
            dependencies: ["eve"],
            envVars: []
        )
    ]
}
