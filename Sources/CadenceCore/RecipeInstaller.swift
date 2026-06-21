import Foundation

/// Materializes a `Recipe` into a project and schedules it as a tracked job,
/// via the runtime abstraction. Refuses experimental runtimes so a broken cron
/// line is never written.
public enum RecipeInstaller {
    public enum InstallError: Error, CustomStringConvertible, Equatable {
        case experimentalRuntime(String)
        case writeFailed(String)
        public var description: String {
            switch self {
            case .experimentalRuntime(let m): return m
            case .writeFailed(let m): return "Could not install recipe: \(m)"
            }
        }
    }

    /// Resolve the files a recipe writes, without touching disk — used by tests
    /// and previews. Returns (project-relative target, content) pairs.
    public static func resolvedFiles(_ recipe: Recipe, provider: ModelProvider,
                                     instructions: String?) -> [(target: String, content: String)] {
        let runtime = AgentRuntimes.runtime(for: recipe.runtime)
        let model = provider.flueModelSpecifier
        let instr = instructions ?? recipe.instructions ?? ""
        return recipe.files.map { file in
            if file.generated == .agentEntry {
                return (file.target, runtime.agentEntrySource(slug: recipe.slug, model: model, instructions: instr))
            }
            return (file.target, file.content ?? "")
        }
    }

    /// Write a recipe's files into `project` (scaffolding the workspace first if
    /// asked), WITHOUT scheduling — the disk-only half, safe to unit-test.
    /// Returns the URLs written.
    @discardableResult
    public static func materialize(_ recipe: Recipe, into project: URL, provider: ModelProvider,
                                   instructions: String?, scaffoldWorkspace: Bool) throws -> [URL] {
        let runtime = AgentRuntimes.runtime(for: recipe.runtime)
        var written: [URL] = []
        do {
            if scaffoldWorkspace {
                try runtime.scaffoldWorkspaceIfNeeded(at: project, provider: provider)
            }
            for file in resolvedFiles(recipe, provider: provider, instructions: instructions) {
                let dest = project.appendingPathComponent(file.target)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try file.content.write(to: dest, atomically: true, encoding: .utf8)
                written.append(dest)
            }
            // Seed the provider's key into .env if a value was supplied.
            let envEntries = provider.dotEnvEntries()
            if !envEntries.isEmpty {
                try DotEnv.write(envEntries, to: project.appendingPathComponent(".env"))
            }
        } catch {
            throw InstallError.writeFailed("\(error.localizedDescription)")
        }
        return written
    }

    /// Install (materialize) + schedule. Returns the scheduled (tracked) job id.
    /// Refuses experimental runtimes so a broken cron line is never written.
    @discardableResult
    public static func install(_ recipe: Recipe, into project: URL, provider: ModelProvider,
                               instructions: String?, schedule: String, scaffoldWorkspace: Bool,
                               repository: JobRepository) throws -> String {
        let runtime = AgentRuntimes.runtime(for: recipe.runtime)
        guard !runtime.isExperimental else {
            throw InstallError.experimentalRuntime(
                runtime.experimentalNote ?? "\(runtime.displayName) is experimental and can't be scheduled yet.")
        }
        try materialize(recipe, into: project, provider: provider,
                        instructions: instructions, scaffoldWorkspace: scaffoldWorkspace)
        let command = runtime.runCommand(project: project, slug: recipe.slug)
        return try repository.scheduleTrackedCommand(command: command, label: recipe.slug, schedule: schedule)
    }
}
