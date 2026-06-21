import Foundation

/// Which agent runtime a recipe targets. Its own enum (rather than `JobSource`)
/// so the catalog format stays independent of internal job modeling.
public enum RecipeRuntime: String, Codable, Sendable, CaseIterable {
    case flue
    case eve
}

/// One file a recipe drops into the target project. Either `content` (verbatim)
/// or `generated` (synthesized by the runtime from model + instructions).
/// `target` is a project-relative path, e.g. "agents/news.ts".
public struct RecipeFile: Codable, Sendable, Hashable {
    public var target: String
    public var content: String?
    public var generated: GeneratedKind?

    public enum GeneratedKind: String, Codable, Sendable { case agentEntry }

    public init(target: String, content: String? = nil, generated: GeneratedKind? = nil) {
        self.target = target
        self.content = content
        self.generated = generated
    }
}

/// A required (or optional) environment variable, with where to obtain it — so
/// readiness can tell the user exactly what's missing and the UI can link out.
public struct RecipeEnvVar: Codable, Sendable, Hashable {
    public var key: String
    public var prompt: String
    public var url: String?
    public var required: Bool

    public init(key: String, prompt: String, url: String? = nil, required: Bool = true) {
        self.key = key
        self.prompt = prompt
        self.url = url
        self.required = required
    }
}

/// A self-contained agent recipe (shadcn/agentcn-style): enough to scaffold
/// files, install deps, preflight env, and schedule a tracked job — for either
/// runtime. `Codable` so the same type serves a bundled catalog today and a
/// remote registry later.
public struct Recipe: Codable, Sendable, Identifiable, Hashable {
    public var id: String              // "<runtime>/<slug>", e.g. "flue/news-digest"
    public var title: String
    public var description: String
    public var runtime: RecipeRuntime
    public var symbol: String          // SF Symbol for the gallery

    public var slug: String            // agent id / filename stem
    public var model: String?          // suggested "provider/model" specifier (overridable)
    public var instructions: String?   // used when an entry file is `.agentEntry`
    public var files: [RecipeFile]     // verbatim + generated files

    public var suggestedCron: String
    public var dependencies: [String]
    public var devDependencies: [String]?
    public var envVars: [RecipeEnvVar]

    public init(id: String, title: String, description: String, runtime: RecipeRuntime,
                symbol: String, slug: String, model: String? = nil, instructions: String? = nil,
                files: [RecipeFile], suggestedCron: String,
                dependencies: [String] = [], devDependencies: [String]? = nil,
                envVars: [RecipeEnvVar] = []) {
        self.id = id
        self.title = title
        self.description = description
        self.runtime = runtime
        self.symbol = symbol
        self.slug = slug
        self.model = model
        self.instructions = instructions
        self.files = files
        self.suggestedCron = suggestedCron
        self.dependencies = dependencies
        self.devDependencies = devDependencies
        self.envVars = envVars
    }
}
