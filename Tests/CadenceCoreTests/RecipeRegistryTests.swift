import XCTest
@testable import CadenceCore

// MARK: - ModelProvider

final class ModelProviderTests: XCTestCase {
    func testFlueModelSpecifier() {
        XCTAssertEqual(ModelProvider(kind: .anthropic, modelID: "claude-sonnet-4-6").flueModelSpecifier,
                       "anthropic/claude-sonnet-4-6")
        XCTAssertEqual(ModelProvider(kind: .xai, modelID: "grok-4").flueModelSpecifier, "xai/grok-4")
        XCTAssertEqual(ModelProvider(kind: .ollama, modelID: "llama3.2:3b").flueModelSpecifier,
                       "ollama/llama3.2:3b")
    }

    func testEnvKeyNameAndRegistration() {
        XCTAssertEqual(ModelProvider(kind: .anthropic, modelID: "x").envKeyName, "ANTHROPIC_API_KEY")
        XCTAssertEqual(ModelProvider(kind: .xai, modelID: "x").envKeyName, "XAI_API_KEY")
        XCTAssertNil(ModelProvider(kind: .ollama, modelID: "x").envKeyName)
        XCTAssertFalse(ModelProvider(kind: .anthropic, modelID: "x").needsFlueRegistration)
        XCTAssertFalse(ModelProvider(kind: .xai, modelID: "x").needsFlueRegistration)
        XCTAssertTrue(ModelProvider(kind: .ollama, modelID: "x").needsFlueRegistration)
    }

    func testOpenAIBaseURL() {
        XCTAssertNil(ModelProvider(kind: .anthropic, modelID: "x").openAIBaseURL)
        XCTAssertEqual(ModelProvider(kind: .xai, modelID: "x").openAIBaseURL?.absoluteString,
                       "https://api.x.ai/v1")
        XCTAssertEqual(ModelProvider(kind: .ollama, modelID: "x").openAIBaseURL?.absoluteString,
                       "http://localhost:11434/v1")
    }

    func testDotEnvEntries() {
        XCTAssertEqual(ModelProvider(kind: .xai, modelID: "grok-4", apiKeyValue: "k").dotEnvEntries(),
                       ["XAI_API_KEY": "k"])
        XCTAssertTrue(ModelProvider(kind: .xai, modelID: "grok-4").dotEnvEntries().isEmpty,
                      "no value ⇒ no entry")
        XCTAssertTrue(ModelProvider(kind: .ollama, modelID: "x", apiKeyValue: "ignored").dotEnvEntries().isEmpty,
                      "local providers need no key")
    }

    func testTriageEndpointAnthropicVsOpenAICompat() {
        let anthropic = ModelProvider(kind: .anthropic, modelID: "claude-sonnet-4-6", apiKeyValue: "sk")
            .triageEndpoint()
        XCTAssertEqual(anthropic?.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(anthropic?.headers["x-api-key"], "sk")

        let xai = ModelProvider(kind: .xai, modelID: "grok-4", apiKeyValue: "xk").triageEndpoint()
        XCTAssertEqual(xai?.url.absoluteString, "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(xai?.headers["Authorization"], "Bearer xk")

        // Anthropic with no key can't form an endpoint.
        XCTAssertNil(ModelProvider(kind: .anthropic, modelID: "x").triageEndpoint())
    }
}

// MARK: - Recipe catalog

final class RecipeCatalogTests: XCTestCase {
    func testIdsUnique() {
        let ids = RecipeCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "recipe ids must be unique")
    }

    func testEveryRecipeIsWellFormed() {
        for r in RecipeCatalog.all {
            XCTAssertFalse(r.files.isEmpty, "\(r.id) has no files")
            XCTAssertNotNil(CronExpression(r.suggestedCron), "\(r.id) cron doesn't parse: \(r.suggestedCron)")
            XCTAssertTrue(r.id.hasPrefix("\(r.runtime.rawValue)/"), "\(r.id) id should be <runtime>/<slug>")
        }
    }

    func testFlueRecipesMirrorTemplates() {
        XCTAssertEqual(RecipeCatalog.flueRecipes.count, AgentTemplates.all.count)
    }

    func testShippableExcludesExperimentalEve() {
        XCTAssertFalse(RecipeCatalog.shippable.contains { $0.runtime == .eve },
                       "experimental Eve recipes must not be in the default gallery")
        XCTAssertTrue(RecipeCatalog.all.contains { $0.runtime == .eve },
                      "but they still exist in the full catalog")
    }

    func testLookup() {
        XCTAssertEqual(RecipeCatalog.recipe(id: "flue/news-digest")?.title, "News digest")
        XCTAssertNil(RecipeCatalog.recipe(id: "nope/nope"))
    }
}

// MARK: - Runtime abstraction

final class AgentRuntimeTests: XCTestCase {
    func testFlueRuntimeRunCommandIsOneShot() {
        let cmd = FlueRuntime().runCommand(project: URL(fileURLWithPath: "/tmp/proj"), slug: "digest")
        XCTAssertTrue(cmd.contains("npx flue run digest"), "got: \(cmd)")
        XCTAssertTrue(cmd.contains("/tmp/proj"))
    }

    func testFlueRuntimeAgentSource() {
        let src = FlueRuntime().agentEntrySource(slug: "x", model: "xai/grok-4", instructions: "do it")
        XCTAssertTrue(src.contains("xai/grok-4"))
        XCTAssertTrue(src.contains("createAgent"))
    }

    func testEveRuntimeIsExperimentalAndGated() {
        XCTAssertTrue(EveRuntime().isExperimental)
        XCTAssertTrue(AgentRuntimes.runtime(for: .eve).isExperimental)
        XCTAssertFalse(AgentRuntimes.runtime(for: .flue).isExperimental)
        // Eve's run command must NOT be an executable line.
        let cmd = EveRuntime().runCommand(project: URL(fileURLWithPath: "/tmp"), slug: "x")
        XCTAssertTrue(cmd.hasPrefix("#"), "experimental run command should be an inert comment: \(cmd)")
    }
}

// MARK: - RecipeInstaller (disk-only materialize; never touches the live crontab)

final class RecipeInstallerTests: XCTestCase {
    private func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadence-recipe-\(UUID().uuidString)")
    }

    func testMaterializeFlueRecipeWritesFilesAndProviderEnv() throws {
        let tmp = tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recipe = try XCTUnwrap(RecipeCatalog.recipe(id: "flue/news-digest"))
        let provider = ModelProvider(kind: .xai, modelID: "grok-4", apiKeyValue: "test-key")

        try RecipeInstaller.materialize(recipe, into: tmp, provider: provider,
                                        instructions: nil, scaffoldWorkspace: true)

        let agent = tmp.appendingPathComponent("agents/news-digest.ts")
        let agentSrc = try String(contentsOf: agent, encoding: .utf8)
        XCTAssertTrue(agentSrc.contains("xai/grok-4"), "agent should use the chosen provider/model")
        XCTAssertTrue(agentSrc.contains("createAgent"))

        // Bug-fix coverage: config import path + pinned beta deps land on disk.
        let config = try String(contentsOf: tmp.appendingPathComponent("flue.config.ts"), encoding: .utf8)
        XCTAssertTrue(config.contains("@flue/cli/config"), "config must import from the /config subpath")
        let pkg = try String(contentsOf: tmp.appendingPathComponent("package.json"), encoding: .utf8)
        XCTAssertTrue(pkg.contains("1.0.0-beta.2"), "deps must pin the published beta")
        XCTAssertFalse(pkg.contains("^1.0.0\""), "the unresolvable ^1.0.0 range must be gone")

        // .env seeded with the provider's specific key + value.
        let env = DotEnv.read(tmp.appendingPathComponent(".env"))
        XCTAssertEqual(env["XAI_API_KEY"], "test-key")
        XCTAssertNil(env["ANTHROPIC_API_KEY"], "shouldn't seed the wrong provider's key")
    }

    func testMaterializeEveRecipeWritesVerifiedLayout() throws {
        let tmp = tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recipe = try XCTUnwrap(RecipeCatalog.recipe(id: "eve/weather-watch"))
        let provider = ModelProvider(kind: .anthropic, modelID: "claude-sonnet-4.6")

        try RecipeInstaller.materialize(recipe, into: tmp, provider: provider,
                                        instructions: nil, scaffoldWorkspace: true)

        let agent = try String(contentsOf: tmp.appendingPathComponent("agent/agent.ts"), encoding: .utf8)
        XCTAssertTrue(agent.contains("defineAgent"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("agent/instructions.md").path))
    }
}

// MARK: - Flue provider mapping + provider-aware readiness

final class FlueProviderTests: XCTestCase {
    func testProviderEnvKeyFromSpecifier() {
        XCTAssertEqual(FlueScaffold.providerEnvKey(forModelSpecifier: "anthropic/claude"), "ANTHROPIC_API_KEY")
        XCTAssertEqual(FlueScaffold.providerEnvKey(forModelSpecifier: "xai/grok-4"), "XAI_API_KEY")
        XCTAssertNil(FlueScaffold.providerEnvKey(forModelSpecifier: "ollama/llama3.2:3b"))
        XCTAssertNil(FlueScaffold.providerEnvKey(forModelSpecifier: "custom/whatever"))
    }

    func testProviderAwareReadinessNamesTheRightKey() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadence-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FlueScaffold.scaffoldWorkspaceIfNeeded(at: tmp, envKeys: ["XAI_API_KEY"])
        try FlueScaffold.writeAgent(intoProject: tmp, name: "a", model: "xai/grok-4", instructions: "x")

        // xAI provider, but no key value set yet ⇒ the API-key check fails and
        // names XAI_API_KEY specifically.
        let checks = FlueReadiness.check(projectPath: tmp.path, agentName: "a", isWorkflow: false,
                                         provider: ModelProvider(kind: .xai, modelID: "grok-4"))
        let keyCheck = try XCTUnwrap(checks.first { $0.name == "API key" })
        XCTAssertFalse(keyCheck.passed)
        XCTAssertTrue(keyCheck.detail.contains("XAI_API_KEY"))
    }

    func testLocalProviderReadinessPingsServerInsteadOfKey() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadence-ready-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let checks = FlueReadiness.check(projectPath: tmp.path, agentName: nil, isWorkflow: false,
                                         provider: ModelProvider(kind: .ollama, modelID: "llama3.2:3b"))
        XCTAssertTrue(checks.contains { $0.name == "Local model server" },
                      "local providers should get a server-liveness check, not a key check")
        XCTAssertFalse(checks.contains { $0.name == "API key" })
    }
}
