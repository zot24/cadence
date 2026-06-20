import Foundation

/// Keeps per-job log directories bounded. A job that runs every minute would
/// otherwise accumulate thousands of `<runID>.out/.err` files; the recorder
/// prunes to the most recent N runs after each execution.
public enum LogPruner {
    public static func prune(directory: URL, keepRuns: Int) {
        let fm = FileManager.default
        guard keepRuns > 0,
              let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        // Files are named "<runID>.out" / "<runID>.err"; runID is an increasing int.
        func runID(_ url: URL) -> Int? { Int(url.lastPathComponent.split(separator: ".").first ?? "") }
        let ids = Set(files.compactMap(runID)).sorted(by: >)
        guard ids.count > keepRuns else { return }
        let doomed = Set(ids.dropFirst(keepRuns))
        for f in files where runID(f).map(doomed.contains) == true {
            try? fm.removeItem(at: f)
        }
    }
}
