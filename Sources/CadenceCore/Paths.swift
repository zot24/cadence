import Foundation

/// Canonical on-disk locations Cadence uses. Everything lives under
/// `~/Library/Application Support/Cadence` so the app, the recorder shim,
/// and tests all agree on where state is.
public enum CadencePaths {
    /// `~/Library/Application Support/Cadence`
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Cadence", isDirectory: true)
    }

    /// The run-history SQLite database.
    public static var databaseURL: URL {
        supportDirectory.appendingPathComponent("cadence.db")
    }

    /// Directory holding per-run captured stdout/stderr logs.
    public static var logsDirectory: URL {
        supportDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// Where the recorder shim binary is installed so crontab/launchd entries
    /// can reference a stable absolute path.
    public static var recorderURL: URL {
        supportDirectory.appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cadence-rec")
    }

    /// Per-job log directory.
    public static func logDirectory(forJob jobID: String) -> URL {
        logsDirectory.appendingPathComponent(jobID, isDirectory: true)
    }

    /// Ensure the directory tree exists. Safe to call repeatedly.
    @discardableResult
    public static func ensureSupportTree() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: recorderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}
