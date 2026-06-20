import Foundation

/// Setting keys shared between the app and the out-of-process recorder shim.
public enum CadenceSettingsKey {
    public static let notifyOnFail = "notify_on_fail"
    public static let defaultTimeoutSeconds = "default_timeout_seconds"
}

/// Posts macOS notifications. Uses `osascript` because the recorder shim runs
/// out-of-process (launched by cron/launchd), where the app's notification
/// center isn't available — osascript reaches the logged-in user's GUI session.
public enum Notifier {
    public static func post(title: String, subtitle: String?, message: String) {
        let t = escape(title)
        let m = escape(message)
        var script = "display notification \"\(m)\" with title \"\(t)\""
        if let subtitle, !subtitle.isEmpty {
            script += " subtitle \"\(escape(subtitle))\""
        }
        _ = Shell.run("/usr/bin/osascript", ["-e", script])
    }

    /// Notify that a job run failed.
    public static func jobFailed(label: String, exitCode: Int, detail: String?) {
        let snippet = detail?
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        post(
            title: "Cadence: \(label) failed",
            subtitle: "Exited with code \(exitCode)",
            message: snippet?.isEmpty == false ? snippet! : "Tap to view logs in Cadence."
        )
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
