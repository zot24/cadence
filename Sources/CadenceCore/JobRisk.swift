import Foundation

/// Static safety analysis of a job's command — surfaces the risk an unattended,
/// scheduled (often agent-driven) job carries. Grounded in the "lethal trifecta"
/// framing: a job that holds secrets AND can reach the network AND runs
/// autonomously can exfiltrate those secrets if its inputs are ever poisoned.
public enum RiskFlag: String, Sendable, CaseIterable, Hashable {
    case secrets       // credentials/keys embedded in the command or env
    case network       // makes outbound network calls
    case privileged    // runs as root / system daemon / sudo
    case destructive   // rm -rf, dd, mkfs, disk erase, shutdown…
    case exfiltration  // secrets + network (the lethal-trifecta shape)

    public var label: String {
        switch self {
        case .secrets: return "Holds secrets"
        case .network: return "Network access"
        case .privileged: return "Privileged"
        case .destructive: return "Destructive command"
        case .exfiltration: return "Exfiltration risk"
        }
    }

    public var detail: String {
        switch self {
        case .secrets: return "Credentials or API keys appear in the command/environment."
        case .network: return "Sends data over the network (curl/wget/ssh/…)."
        case .privileged: return "Runs with elevated privileges (root / system daemon)."
        case .destructive: return "Contains a potentially destructive command."
        case .exfiltration: return "Holds secrets AND can reach the network — poisoned input could exfiltrate them."
        }
    }

    public var symbol: String {
        switch self {
        case .secrets: return "key.fill"
        case .network: return "network"
        case .privileged: return "lock.shield"
        case .destructive: return "trash.fill"
        case .exfiltration: return "exclamationmark.shield.fill"
        }
    }

    public var severity: RiskSeverity {
        switch self {
        case .exfiltration, .destructive: return .high
        case .privileged: return .medium
        case .secrets, .network: return .low
        }
    }
}

public enum RiskSeverity: Int, Sendable, Comparable {
    case none = 0, low = 1, medium = 2, high = 3
    public static func < (lhs: RiskSeverity, rhs: RiskSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
    public var label: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

public struct JobRisk: Sendable, Hashable {
    public var flags: [RiskFlag]
    public var severity: RiskSeverity { flags.map(\.severity).max() ?? .none }
    public var isRisky: Bool { !flags.isEmpty }
    public init(flags: [RiskFlag]) { self.flags = flags }
}

public enum JobRiskAnalyzer {

    private static let secretPatterns = [
        "sk-", "ghp_", "github_pat_", "akia", "xoxb-", "xoxp-", "aiza",
        "api_key", "apikey", "api-key", "secret", "password=", "passwd",
        "token=", "bearer ", "-----begin",
    ]
    private static let networkPatterns = [
        "curl ", "wget ", "http://", "https://", "nc ", "netcat", "ssh ",
        "scp ", "rsync ", "ftp ", "/dev/tcp/", "telnet ",
    ]
    private static let destructivePatterns = [
        "rm -rf", "rm -fr", "rm -r ", "rm  -r", "dd if=", "mkfs", ">/dev/",
        "> /dev/", "diskutil erase", "shutdown", "killall ", ":(){:|:&};:",
    ]
    private static let privilegedPatterns = ["sudo ", "as root", "/usr/bin/sudo"]

    public static func analyze(_ job: Job) -> JobRisk {
        let text = job.command.lowercased()
        var flags: [RiskFlag] = []

        var hasSecrets = secretPatterns.contains { text.contains($0) }
        // launchd jobs: also inspect EnvironmentVariables key names.
        if !hasSecrets, let path = job.plistPath, let env = launchdEnvKeys(path) {
            hasSecrets = env.contains { k in
                let lk = k.lowercased()
                return lk.contains("key") || lk.contains("token") || lk.contains("secret") || lk.contains("password")
            }
        }
        let hasNetwork = networkPatterns.contains { text.contains($0) }
        let isPrivileged = privilegedPatterns.contains { text.contains($0) } || job.launchdDomain == .systemDaemon
        let isDestructive = destructivePatterns.contains { text.contains($0) }

        if hasSecrets { flags.append(.secrets) }
        if hasNetwork { flags.append(.network) }
        if isPrivileged { flags.append(.privileged) }
        if isDestructive { flags.append(.destructive) }
        if hasSecrets && hasNetwork { flags.append(.exfiltration) }

        return JobRisk(flags: flags)
    }

    private static func launchdEnvKeys(_ path: String) -> [String]? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let env = plist["EnvironmentVariables"] as? [String: Any] else { return nil }
        return Array(env.keys)
    }
}
