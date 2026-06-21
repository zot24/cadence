import Foundation

/// A model-provider choice for scheduled agents and the in-app "explain this
/// failure" triage feature. `kind` decides auth + transport; the rest is config.
///
/// On xAI "SuperGrok" subscription OAuth: we could not verify that xAI exposes a
/// Claude-Max-style OAuth login for SuperGrok subscribers usable by third-party
/// tools. Until that's confirmed against primary xAI docs, the supported xAI path
/// is an API key from console.x.ai (`XAI_API_KEY`). Local models (Ollama / LM
/// Studio) need no key at all and are the zero-cost way to test the model paths.
public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case anthropic          // ANTHROPIC_API_KEY,  Flue catalog id "anthropic"
    case xai                // XAI_API_KEY,        Flue catalog id "xai", https://api.x.ai/v1
    case ollama             // local,  http://localhost:11434/v1  (no key)
    case lmStudio           // local,  http://localhost:1234/v1   (no key)
    case openAICompatible   // user-supplied baseURL (+ optional key)

    public var displayName: String {
        switch self {
        case .anthropic:        return "Anthropic (API key)"
        case .xai:              return "xAI / Grok (API key)"
        case .ollama:           return "Ollama (local)"
        case .lmStudio:         return "LM Studio (local)"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    /// Local servers run on the user's machine and need no API key.
    public var isLocal: Bool { self == .ollama || self == .lmStudio }
}

/// A concrete provider selection: a kind plus the model id and any auth/endpoint
/// config. Produces the strings Cadence needs (Flue model specifier, `.env`
/// entries, and the in-app triage HTTP endpoint).
public struct ModelProvider: Codable, Hashable, Sendable {
    public var kind: ProviderKind
    public var modelID: String          // bare model id, e.g. "claude-sonnet-4-6", "grok-4", "llama3.2:3b"
    public var baseURLOverride: URL?    // openAICompatible only (others derive it)
    public var apiKeyValue: String?     // for writing .env / in-app HTTP; never logged

    public init(kind: ProviderKind, modelID: String,
                baseURLOverride: URL? = nil, apiKeyValue: String? = nil) {
        self.kind = kind
        self.modelID = modelID
        self.baseURLOverride = baseURLOverride
        self.apiKeyValue = apiKeyValue
    }

    // MARK: - Flue mapping

    /// The Flue/Pi catalog provider id used in the "provider/model" specifier.
    public var flueProviderID: String {
        switch kind {
        case .anthropic:        return "anthropic"   // built-in catalog id
        case .xai:              return "xai"         // built-in catalog id
        case .ollama:           return "ollama"      // requires registerProvider(...)
        case .lmStudio:         return "lmstudio"    // requires registerProvider(...)
        case .openAICompatible: return "custom"      // requires registerProvider(...)
        }
    }

    /// The `model:` specifier for `createAgent(() => ({ model: ... }))`.
    public var flueModelSpecifier: String { "\(flueProviderID)/\(modelID)" }

    /// True when Flue needs an explicit `registerProvider(...)` call (the id is
    /// NOT a built-in catalog provider). Verified that `registerProvider` is a
    /// real `@flue/runtime` export; its exact call-site placement is left to the
    /// runtime conformer.
    public var needsFlueRegistration: Bool {
        switch kind {
        case .anthropic, .xai:                       return false
        case .ollama, .lmStudio, .openAICompatible:  return true
        }
    }

    // MARK: - Endpoints & keys

    /// Base URL for the provider's OpenAI-compatible `/v1` surface
    /// (nil for Anthropic, which uses its native messages endpoint).
    public var openAIBaseURL: URL? {
        switch kind {
        case .anthropic:        return nil
        case .xai:              return URL(string: "https://api.x.ai/v1")
        case .ollama:           return URL(string: "http://localhost:11434/v1")
        case .lmStudio:         return URL(string: "http://localhost:1234/v1")
        case .openAICompatible: return baseURLOverride
        }
    }

    /// The env-var name Flue reads for this provider's key (nil = no key needed).
    public var envKeyName: String? {
        switch kind {
        case .anthropic:        return "ANTHROPIC_API_KEY"
        case .xai:              return "XAI_API_KEY"
        case .ollama, .lmStudio: return nil
        case .openAICompatible: return "CUSTOM_API_KEY"
        }
    }

    /// A throwaway key that local servers accept but ignore.
    public var localPlaceholderKey: String? {
        switch kind {
        case .ollama:   return "ollama"
        case .lmStudio: return "lm-studio"
        default:        return nil
        }
    }

    /// Entries to merge into a project `.env` (via `DotEnv.write`). Local
    /// providers need none; key providers get KEY=value only if a value is set.
    public func dotEnvEntries() -> [String: String] {
        guard let name = envKeyName, let val = apiKeyValue,
              !val.trimmingCharacters(in: .whitespaces).isEmpty else { return [:] }
        return [name: val]
    }

    /// A liveness URL for a local provider (used by readiness to ping it).
    /// Ollama has a dedicated version route; LM Studio uses /v1/models.
    public var localHealthURL: URL? {
        switch kind {
        case .ollama:   return URL(string: "http://localhost:11434/api/version")
        case .lmStudio: return URL(string: "http://localhost:1234/v1/models")
        case .openAICompatible:
            return baseURLOverride.flatMap { URL(string: $0.absoluteString + "/models") }
        default:        return nil
        }
    }

    /// Endpoint + headers for a one-shot triage completion. Anthropic uses its
    /// native messages API; everyone else is OpenAI-compatible chat/completions.
    public func triageEndpoint() -> (url: URL, headers: [String: String])? {
        switch kind {
        case .anthropic:
            guard let key = apiKeyValue, !key.isEmpty,
                  let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
            return (url, ["x-api-key": key,
                          "anthropic-version": "2023-06-01",
                          "content-type": "application/json"])
        default:
            guard let base = openAIBaseURL else { return nil }
            let url = base.appendingPathComponent("chat/completions")
            var headers = ["content-type": "application/json"]
            let key = apiKeyValue ?? localPlaceholderKey ?? ""
            if !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
            return (url, headers)
        }
    }

    /// Curated model ids for the picker. xAI ids verified against api.x.ai;
    /// local lists are illustrative (the real list comes from the live server).
    public static func suggestedModels(for kind: ProviderKind) -> [String] {
        switch kind {
        case .anthropic:
            return ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5", "claude-fable-5"]
        case .xai:
            return ["grok-4", "grok-4-heavy", "grok-4-fast", "grok-code-fast-1", "grok-3", "grok-3-mini"]
        case .ollama:
            return ["llama3.2:3b", "qwen2.5:7b", "gpt-oss:20b"]
        case .lmStudio:
            return []   // read from GET /v1/models at runtime
        case .openAICompatible:
            return []
        }
    }

    public static let `default` = ModelProvider(kind: .anthropic, modelID: "claude-sonnet-4-6")
}
