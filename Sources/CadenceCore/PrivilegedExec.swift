import Foundation

/// Runs a command as root via the native macOS admin authentication prompt
/// (AppleScript `do shell script … with administrator privileges`). This is the
/// only in-app elevation that works for an ad-hoc-signed app — a signed
/// `SMAppService` helper would require a Developer ID. Each call shows the system
/// auth dialog (Touch ID / password); macOS may cache the grant briefly.
///
/// Used only for explicit, user-initiated actions on privileged launchd jobs
/// (system daemons / global agents), and only when the user has opted in.
public enum PrivilegedExec {
    public enum ExecError: Error, CustomStringConvertible, Equatable {
        case cancelled
        case failed(String)
        public var description: String {
            switch self {
            case .cancelled: return "Authorization was cancelled."
            case .failed(let m): return "Privileged command failed: \(m)"
            }
        }
    }

    /// Run `command` as root. Throws `.cancelled` if the user dismisses the prompt.
    public static func runAsRoot(_ command: String) throws {
        let script = "do shell script \"\(escapeForAppleScript(command))\" with administrator privileges"
        let r = Shell.run("/usr/bin/osascript", ["-e", script])
        if r.ok { return }
        let combined = (r.stderr + " " + r.stdout).lowercased()
        if combined.contains("-128") || combined.contains("user canceled") || combined.contains("user cancelled") {
            throw ExecError.cancelled
        }
        let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw ExecError.failed(msg.isEmpty ? "exit \(r.exitCode)" : msg)
    }

    /// Escape a shell command for embedding in an AppleScript double-quoted string.
    static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
