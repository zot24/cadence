import Foundation

/// Control operations for launchd jobs via `launchctl`. User agents work
/// without elevation; global agents and system daemons generally require root,
/// which we surface as an error rather than silently failing.
public enum LaunchdControl {

    public enum ControlError: Error, CustomStringConvertible, Equatable {
        case needsPrivileges(String)
        case failed(String)
        public var description: String {
            switch self {
            case .needsPrivileges(let m): return m
            case .failed(let m): return "launchctl error: \(m)"
            }
        }
    }

    /// The control action being attempted — used to phrase clear error messages.
    public enum Operation: Sendable {
        case enable, disable, run, remove
        var verb: String {
            switch self {
            case .enable: return "enabling"
            case .disable: return "disabling"
            case .run: return "running"
            case .remove: return "removing"
            }
        }
    }

    private static var uid: String { String(getuid()) }

    /// gui/<uid> for user agents; system for daemons.
    private static func domainTarget(for domain: LaunchdDomain) -> String {
        switch domain {
        case .userAgent: return "gui/\(uid)"
        case .globalAgent: return "gui/\(uid)"
        case .systemDaemon: return "system"
        }
    }

    /// Kickstart (run immediately). `-k` kills+restarts if already running.
    public static func kickstart(label: String, domain: LaunchdDomain) throws {
        let target = "\(domainTarget(for: domain))/\(label)"
        let result = Shell.run("/bin/launchctl", ["kickstart", "-k", target])
        if !result.ok {
            throw explainFailure(operation: .run, label: label, domain: domain,
                                 exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Enable (bootstrap) or disable (bootout) a job and persist the Disabled key.
    public static func setEnabled(label: String, domain: LaunchdDomain, plistPath: String, enabled: Bool) throws {
        let target = domainTarget(for: domain)
        if enabled {
            _ = Shell.run("/bin/launchctl", ["enable", "\(target)/\(label)"])
            let result = Shell.run("/bin/launchctl", ["bootstrap", target, plistPath])
            // bootstrap returns error 5 if already loaded — tolerate that.
            if !result.ok && !result.stderr.lowercased().contains("already") && result.exitCode != 5 {
                throw explainFailure(operation: .enable, label: label, domain: domain,
                                     exitCode: result.exitCode, stderr: result.stderr)
            }
            setDisabledKey(plistPath: plistPath, disabled: false)
        } else {
            let result = Shell.run("/bin/launchctl", ["bootout", "\(target)/\(label)"])
            if !result.ok && !result.stderr.lowercased().contains("no such process") {
                throw explainFailure(operation: .disable, label: label, domain: domain,
                                     exitCode: result.exitCode, stderr: result.stderr)
            }
            _ = Shell.run("/bin/launchctl", ["disable", "\(target)/\(label)"])
            setDisabledKey(plistPath: plistPath, disabled: true)
        }
    }

    /// Persist the Disabled flag in the plist using plutil.
    private static func setDisabledKey(plistPath: String, disabled: Bool) {
        // Replace if present, else insert.
        let value = disabled ? "true" : "false"
        let replace = Shell.run("/usr/bin/plutil", ["-replace", "Disabled", "-bool", value, plistPath])
        if !replace.ok {
            _ = Shell.run("/usr/bin/plutil", ["-insert", "Disabled", "-bool", value, plistPath])
        }
    }

    /// Maps a failed `launchctl` invocation to a clear, user-facing error.
    /// Privileged (global/system) failures get a plain-English explanation instead of
    /// leaking raw launchctl text like "Boot-out failed: 1: Operation not permitted".
    public static func explainFailure(operation: Operation, label: String, domain: LaunchdDomain,
                                      exitCode: Int32, stderr: String) -> ControlError {
        let raw = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        let looksPrivileged = lower.contains("not permitted")
            || lower.contains("permission")
            || lower.contains("denied")
        if domain != .userAgent && (looksPrivileged || exitCode == 1) {
            let kind = domain == .systemDaemon ? "a system daemon" : "a system-managed agent"
            return .needsPrivileges(
                "“\(label)” is \(kind). \(operation.verb.capitalized) it requires administrator "
                + "privileges, which Cadence won’t request on your behalf. To change it yourself, "
                + "run the matching launchctl command with sudo in Terminal.")
        }
        return .failed(raw.isEmpty ? "exit \(exitCode)" : raw)
    }
}
