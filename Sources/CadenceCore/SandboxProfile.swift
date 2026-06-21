import Foundation

/// Generates a macOS Seatbelt (SBPL) profile to confine a scheduled agent's
/// process, and wraps a command to run under `sandbox-exec`.
///
/// Design (after adversarial review + empirical testing against the kernel):
///  - WRITES are default-deny — confined to the project, ~/Cadence, and node
///    caches/tmp. This is the strong, verified guarantee: the agent can't modify
///    the system, other projects, login items, or plant persistence.
///  - EXEC is allow-listed (the toolchain) with privilege-escalation / GUI-
///    scripting tools (osascript/sudo/launchctl/crontab/security, AppleEvents)
///    denied — closing the classic confinement bypass.
///  - READS stay broad but DENY known credential stores (~/.ssh, ~/.aws,
///    Keychains, browser cookies, AI-tool tokens, …). NOTE: this is best-effort.
///    Full read-isolation via default-deny was tested and SIGABRTs dyld, so it's
///    not viable in-profile; a determined exfil can still read a non-secret file
///    and POST it over an allowed network. The real fix is the Tier-2 localhost
///    egress proxy.
///
/// Complementary to Flue's in-process "virtual" sandbox (just-bash): that only
/// constrains the agent's model-directed shell; Seatbelt confines the whole
/// process (Node, its dependencies, non-shell I/O) at the kernel level.
///
/// Honest Seatbelt limitations (cannot be fixed in-profile): no per-host network
/// filtering; the agent's own project `.env` is readable by an in-process
/// malicious dependency while network is on; `sandbox-exec` is Apple-deprecated
/// but still ships and enforces.
public enum SandboxProfile {

    /// Resolve symlinks so subpath rules match. CRITICAL: Seatbelt matches the
    /// kernel's CANONICAL path at runtime and does NOT re-resolve ours, so a rule
    /// written against a non-canonical path (e.g. /tmp vs /private/tmp) is a
    /// silent no-op. Use realpath(3) — NOT URL.resolvingSymlinksInPath, which
    /// STRIPS /private. Best-effort for paths that don't exist yet.
    public static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Writable roots node CLIs use (project + output + caches + XDG/env-paths).
    static func defaultWritePaths(home: String) -> [String] {
        ["/private/tmp", "/private/var/folders",
         "\(home)/.npm", "\(home)/.cache", "\(home)/.config",
         "\(home)/.local/state", "\(home)/.local/share",
         "\(home)/Library/Application Support", "\(home)/Library/Caches"]
    }

    /// Credential stores denied for reading. Specific paths only (never broad
    /// ~/.config or ~/Library, which would break node). Best-effort, not airtight.
    static func defaultSecretReadDenies(home: String) -> [String] {
        ["\(home)/.ssh", "\(home)/.aws", "\(home)/.gnupg", "\(home)/.kube",
         "\(home)/.config/gh", "\(home)/.config/gcloud", "\(home)/.config/op",
         "\(home)/.codex", "\(home)/.claude.json", "\(home)/.claude",
         "\(home)/.netrc", "\(home)/.git-credentials", "\(home)/.docker/config.json",
         "\(home)/Library/Keychains", "\(home)/Library/Cookies",
         "\(home)/Library/Application Support/1Password",
         "\(home)/Library/Application Support/Google/Chrome",
         "\(home)/Library/Application Support/Firefox",
         "\(home)/Library/Application Support/com.apple.Safari"]
    }

    /// Binaries the agent may exec; escalation tools are denied below.
    static func execRoots(home: String) -> [String] {
        ["/usr", "/bin", "/sbin", "/opt", "\(home)/.local", "\(home)/.hermes", "\(home)/.bun"]
    }
    static let execDenyLiterals = [
        "/usr/bin/osascript", "/usr/bin/sudo", "/bin/launchctl", "/usr/bin/crontab", "/usr/bin/security",
    ]

    /// Build an SBPL profile. All paths are canonicalized (see `canonical`).
    public static func sbpl(projectPath: String, home: String, allowNetwork: Bool,
                            extraWritePaths: [String] = []) -> String {
        let home = canonical(home)
        let project = canonical(projectPath)
        let output = "\(home)/Cadence"
        func dedup(_ xs: [String]) -> [String] {
            var seen = Set<String>(); return xs.filter { seen.insert($0).inserted }
        }
        let writes = dedup([project, output] + defaultWritePaths(home: home) + extraWritePaths.map(canonical))
        let execs = dedup(execRoots(home: home))

        var l: [String] = ["(version 1)", "(allow default)", ""]

        l.append(";; Writes: default-deny; allow project, ~/Cadence, caches, tmp.")
        l.append("(deny file-write*)")
        l.append("(allow file-write*")
        for p in writes { l.append("  (subpath \(q(p)))") }
        l.append(")")
        l.append("(allow file-write-data (literal \"/dev/null\") (literal \"/dev/stdout\") (literal \"/dev/stderr\") (literal \"/dev/dtracehelper\"))")
        l.append("(deny file-write-setugid)")
        l.append("")

        l.append(";; Reads: broad (dyld needs it) but deny known credential stores.")
        l.append("(deny file-read*")
        for s in defaultSecretReadDenies(home: home) { l.append("  (subpath \(q(s)))") }
        l.append(")")
        l.append("")

        l.append(";; Exec: allow the toolchain; block escalation + AppleEvents.")
        l.append("(deny process-exec*)")
        l.append("(allow process-exec*")
        for p in execs { l.append("  (subpath \(q(p)))") }
        l.append(")")
        l.append("(deny process-exec* \(execDenyLiterals.map { "(literal \(q($0)))" }.joined(separator: " ")))")
        l.append("(deny appleevent-send)")
        l.append("")

        l.append(";; Clipboard + IOKit are exfil/escape surfaces an agent never needs.")
        l.append("(deny mach-lookup (global-name \"com.apple.pasteboard.1\"))")
        l.append("(deny iokit-open)")

        if !allowNetwork {
            l.append("")
            l.append(";; No outbound network; keep loopback (local model servers) + DNS.")
            l.append("(deny network*)")
            l.append("(allow network-outbound (remote ip \"localhost:*\") (literal \"/private/var/run/mDNSResponder\"))")
            l.append("(allow network-bind (local ip))")
            l.append("(allow network-inbound (local ip))")
        }
        return l.joined(separator: "\n") + "\n"
    }

    /// Wrap a shell command to run confined under `sandbox-exec`. Also strips the
    /// ssh-agent socket — `~/.ssh` reads are denied, but a live SSH_AUTH_SOCK
    /// would still let the agent sign with loaded keys.
    public static func wrap(command: String, profilePath: String) -> String {
        "/usr/bin/sandbox-exec -f \(shellQuote(profilePath)) "
            + "/usr/bin/env -u SSH_AUTH_SOCK -u SSH_AGENT_PID "
            + "/bin/sh -c \(shellQuote(command))"
    }

    // MARK: - Escaping

    static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
