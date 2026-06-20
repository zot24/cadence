import Foundation

/// Control operations for launchd jobs via `launchctl`. User agents work
/// without elevation; global agents and system daemons generally require root,
/// which we surface as an error rather than silently failing.
public enum LaunchdControl {

    public enum ControlError: Error, CustomStringConvertible {
        case needsPrivileges(String)
        case failed(String)
        public var description: String {
            switch self {
            case .needsPrivileges(let m): return "Requires administrator privileges: \(m)"
            case .failed(let m): return "launchctl error: \(m)"
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
        try check(result, domain: domain)
    }

    /// Enable (bootstrap) or disable (bootout) a job and persist the Disabled key.
    public static func setEnabled(label: String, domain: LaunchdDomain, plistPath: String, enabled: Bool) throws {
        let target = domainTarget(for: domain)
        if enabled {
            _ = Shell.run("/bin/launchctl", ["enable", "\(target)/\(label)"])
            let result = Shell.run("/bin/launchctl", ["bootstrap", target, plistPath])
            // bootstrap returns error 5 if already loaded — tolerate that.
            if !result.ok && !result.stderr.contains("already") && result.exitCode != 5 {
                try check(result, domain: domain)
            }
            setDisabledKey(plistPath: plistPath, disabled: false)
        } else {
            let result = Shell.run("/bin/launchctl", ["bootout", "\(target)/\(label)"])
            if !result.ok && !result.stderr.lowercased().contains("no such process") {
                try check(result, domain: domain)
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

    private static func check(_ result: Shell.Result, domain: LaunchdDomain) throws {
        guard !result.ok else { return }
        let msg = result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr
        if domain != .userAgent && (msg.contains("Permission") || msg.contains("denied") || result.exitCode == 1) {
            throw ControlError.needsPrivileges(msg)
        }
        throw ControlError.failed(msg)
    }
}
