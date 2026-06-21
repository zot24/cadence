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
                + "privileges. Turn on “Privileged Actions” in Settings to do it from Cadence "
                + "(you'll be asked for your admin password), or run the matching launchctl command "
                + "with sudo in Terminal.")
        }
        return .failed(raw.isEmpty ? "exit \(exitCode)" : raw)
    }

    // MARK: - Privileged (admin-elevated) operations

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Root shell command to enable/disable a job in any domain. Also writes the
    /// plist's `Disabled` key, because that's what Cadence reads to show state —
    /// `launchctl disable` only updates launchd's override DB, so without this the
    /// UI wouldn't reflect the change even when the daemon was actually stopped.
    static func elevatedSetEnabledCommand(label: String, domain: LaunchdDomain,
                                          plistPath: String, enabled: Bool) -> String {
        let target = domainTarget(for: domain)
        let plist = shellQuote(plistPath)
        if enabled {
            return "(/usr/bin/plutil -replace Disabled -bool false \(plist) || /usr/bin/plutil -insert Disabled -bool false \(plist)); "
                 + "/bin/launchctl enable \(target)/\(label); "
                 + "/bin/launchctl bootstrap \(target) \(plist)"
        }
        // disable (prevents KeepAlive restart) → bootout (stop now) → mark plist.
        return "/bin/launchctl disable \(target)/\(label); "
             + "/bin/launchctl bootout \(target)/\(label); "
             + "(/usr/bin/plutil -replace Disabled -bool true \(plist) || /usr/bin/plutil -insert Disabled -bool true \(plist))"
    }

    /// Root shell command to remove a job: boot it out, then delete its plist.
    static func elevatedRemoveCommand(label: String, domain: LaunchdDomain, plistPath: String) -> String {
        "/bin/launchctl bootout \(domainTarget(for: domain))/\(label); "
            + "/bin/rm -f \(shellQuote(plistPath))"
    }

    /// Enable/disable a job in a privileged domain via the admin auth prompt.
    public static func setEnabledElevated(label: String, domain: LaunchdDomain,
                                          plistPath: String, enabled: Bool) throws {
        try PrivilegedExec.runAsRoot(elevatedSetEnabledCommand(
            label: label, domain: domain, plistPath: plistPath, enabled: enabled))
    }

    /// Remove a job in a privileged domain via the admin auth prompt.
    public static func removeElevated(label: String, domain: LaunchdDomain, plistPath: String) throws {
        try PrivilegedExec.runAsRoot(elevatedRemoveCommand(
            label: label, domain: domain, plistPath: plistPath))
    }

    /// Root shell command to run a job immediately (launchd executes it in its
    /// real context; `-k` restarts it if already running).
    static func elevatedKickstartCommand(label: String, domain: LaunchdDomain) -> String {
        "/bin/launchctl kickstart -k \(domainTarget(for: domain))/\(label)"
    }

    /// Run a job now in a privileged domain via the admin auth prompt. The run is
    /// executed by launchd (not the cadence-rec shim), so it is not recorded.
    public static func kickstartElevated(label: String, domain: LaunchdDomain) throws {
        try PrivilegedExec.runAsRoot(elevatedKickstartCommand(label: label, domain: domain))
    }
}
