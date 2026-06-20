import Foundation

/// Installs the `cadence-rec` shim to a stable absolute path
/// (`~/Library/Application Support/Cadence/bin/cadence-rec`) so adopted
/// crontab/launchd entries can reference it regardless of where the app lives.
public enum RecorderInstaller {

    /// Locate the bundled/built recorder binary.
    public static func sourceURL() -> URL? {
        let fm = FileManager.default
        // 1) Alongside the running executable (covers `swift run` and the .app's MacOS dir).
        if let exe = Bundle.main.executableURL {
            let sibling = exe.deletingLastPathComponent().appendingPathComponent("cadence-rec")
            if fm.fileExists(atPath: sibling.path) { return sibling }
        }
        // 2) As a bundled resource.
        if let res = Bundle.main.url(forResource: "cadence-rec", withExtension: nil) {
            return res
        }
        // 3) Dev fallback: argv[0] directory.
        let argv0 = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidate = argv0.appendingPathComponent("cadence-rec")
        if fm.fileExists(atPath: candidate.path) { return candidate }
        return nil
    }

    /// Copy the recorder into place if missing or out of date. Returns the
    /// installed path on success.
    @discardableResult
    public static func ensureInstalled() -> URL? {
        CadencePaths.ensureSupportTree()
        let dest = CadencePaths.recorderURL
        guard let src = sourceURL() else {
            return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
        }
        let fm = FileManager.default
        // Re-copy if missing or source is newer.
        let shouldCopy: Bool = {
            guard fm.fileExists(atPath: dest.path) else { return true }
            let srcDate = (try? src.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            let dstDate = (try? dest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return srcDate > dstDate
        }()
        if shouldCopy {
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: src, to: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            } catch {
                return fm.fileExists(atPath: dest.path) ? dest : nil
            }
        }
        return dest
    }
}
