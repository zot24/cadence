import Foundation

/// Builds the prompt + HTTP request and parses the response for the in-app
/// "explain this failure with a model" feature. Layered on top of the
/// deterministic `FailureTriage` (which stays the always-on, zero-cost default).
///
/// All of this is pure and provider-agnostic so it's unit-testable; the actual
/// network call (URLSession) lives in the app layer, keyed on
/// `ModelProvider.triageEndpoint()`. Works against any OpenAI-compatible
/// endpoint (xAI/Grok, Ollama, LM Studio, custom) and Anthropic's native API.
public enum ModelTriage {

    /// Keep prompts bounded — scheduled-job logs can be large.
    static let maxLogChars = 4000

    /// The system + user messages for a triage completion.
    public static func messages(command: String, stderr: String, stdout: String,
                                exitCode: Int?, timedOut: Bool,
                                deterministic: TriageResult?) -> (system: String, user: String) {
        let system = """
        You are an SRE assistant diagnosing why a scheduled job (cron, launchd, or a \
        model-backed agent) failed on macOS. Scheduled jobs run in a minimal environment: \
        no shell profile, a bare PATH, and no interactive TTY. Answer in 2–4 sentences: the \
        single most likely cause, then one concrete, copy-pasteable fix. Be specific and brief.
        """

        var user = "A scheduled job failed.\n\nCommand:\n\(command)\n"
        if timedOut {
            user += "\nOutcome: timed out (Cadence killed the process tree).\n"
        } else if let code = exitCode {
            user += "\nExit code: \(code)\n"
        }
        if let d = deterministic {
            user += "\nCadence's rule-based guess: [\(d.category)] \(d.likelyCause)\n"
        }
        let err = tail(stderr, maxLogChars)
        if !err.isEmpty { user += "\nstderr (tail):\n\(err)\n" }
        let out = tail(stdout, maxLogChars)
        if !out.isEmpty { user += "\nstdout (tail):\n\(out)\n" }
        user += "\nWhat is the most likely cause, and how do I fix it?"
        return (system, user)
    }

    /// JSON request body for the provider. Anthropic uses its messages shape;
    /// everyone else uses the OpenAI chat/completions shape.
    public static func requestBody(provider: ModelProvider, system: String, user: String,
                                   maxTokens: Int = 600) throws -> Data {
        let body: [String: Any]
        switch provider.kind {
        case .anthropic:
            body = [
                "model": provider.modelID,
                "max_tokens": maxTokens,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
        default:
            body = [
                "model": provider.modelID,
                "max_tokens": maxTokens,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    /// Extract the assistant's text from a raw response body.
    public static func parseAnswer(provider: ModelProvider, data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch provider.kind {
        case .anthropic:
            // { content: [ { type: "text", text: "..." } ] }
            if let content = obj["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined()
                return text.isEmpty ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        default:
            // { choices: [ { message: { content: "..." } } ] }
            if let choices = obj["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func tail(_ s: String, _ n: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= n { return trimmed }
        return "…" + String(trimmed.suffix(n))
    }
}
