import Foundation
import CadenceCore

/// Headless inventory report — `Cadence --report` / `--json`. Lets you inspect
/// or script the scheduled-job fleet (including agent provenance + risk) without
/// opening the GUI; also doubles as a smoke test of the full load pipeline.
enum CadenceCLI {
    static let version = "0.1.0"

    static func run(json: Bool) {
        guard let repo = try? JobRepository() else {
            FileHandle.standardError.write(Data("cadence: could not open store\n".utf8)); exit(1)
        }
        let records = repo.loadAll()
        json ? printJSON(records) : printText(records)
    }

    /// Health check for scripting/monitoring: prints a one-line summary and
    /// exits non-zero if any job is failing. Compose into a cron/launchd job.
    static func check() -> Never {
        guard let repo = try? JobRepository() else {
            FileHandle.standardError.write(Data("cadence: could not open store\n".utf8)); exit(2)
        }
        let records = repo.loadAll()
        let failing = records.filter {
            $0.job.status == .errored || (($0.stats.lastExitCode ?? 0) != 0 && $0.stats.totalRuns > 0)
        }
        if failing.isEmpty {
            print("OK — \(records.count) jobs, none failing")
            exit(0)
        }
        print("FAIL — \(failing.count) of \(records.count) jobs failing: " + failing.map(\.job.label).joined(separator: ", "))
        exit(1)
    }

    static func printUsage() {
        print("""
        Cadence — scheduled-job manager
        Usage:
          Cadence              launch the app
          Cadence --report     print the job inventory (text)
          Cadence --json       print the job inventory (JSON)
          Cadence --check      health check; exits 1 if any job is failing
          Cadence --help       this message
        """)
    }

    private static func printText(_ records: [JobRecord]) {
        let jobs = records.map(\.job)
        func count(_ s: JobSource) -> Int { jobs.filter { $0.source == s }.count }
        let agents = jobs.filter { $0.provenance.isAgentic }
        let risky = jobs.filter { $0.risk.isRisky }
        let tracked = jobs.filter(\.isAdopted).count
        let totalRuns = records.reduce(0) { $0 + $1.stats.totalRuns }
        let totalCost = records.reduce(0.0) { $0 + $1.stats.totalCostUSD }

        print("Cadence — job inventory")
        print(String(repeating: "─", count: 40))
        print("Jobs:       \(jobs.count)  (cron \(count(.cron)) · launchd \(count(.launchd)) · flue \(count(.flue)))")
        print("AI agents:  \(agents.count)")
        print("At risk:    \(risky.count)")
        print("Tracked:    \(tracked)")
        print("Runs:       \(totalRuns)" + (totalCost > 0 ? String(format: "   Spend: $%.4f", totalCost) : ""))

        // Tool breakdown.
        var tools: [String: Int] = [:]
        for j in jobs where j.origin.tool != nil { tools[j.origin.tool!, default: 0] += 1 }
        if !tools.isEmpty {
            print("\nDetected tools:")
            for (tool, n) in tools.sorted(by: { $0.value > $1.value }) { print("  \(tool): \(n)") }
        }

        if !agents.isEmpty {
            print("\nAgent jobs:")
            for j in agents.sorted(by: { $0.label < $1.label }) {
                let risk = j.risk.isRisky ? "  ⚠️ \(j.risk.severity.label) risk" : ""
                print("  • \(j.label)  [\(j.origin.label)]  \(j.schedule.summary)\(risk)")
            }
        }
        if !risky.isEmpty {
            print("\nAt-risk jobs:")
            for j in risky.sorted(by: { $0.risk.severity > $1.risk.severity }) {
                print("  • \(j.label): \(j.risk.flags.map(\.label).joined(separator: ", "))")
            }
        }
    }

    private static func printJSON(_ records: [JobRecord]) {
        let items: [[String: Any]] = records.map { r in
            var d: [String: Any] = [
                "id": r.job.id,
                "label": r.job.label,
                "source": r.job.source.rawValue,
                "schedule": r.job.schedule.summary,
                "enabled": r.job.enabled,
                "adopted": r.job.isAdopted,
                "provenance": r.job.provenance.rawValue,
                "agentic": r.job.provenance.isAgentic,
                "totalRuns": r.stats.totalRuns,
            ]
            if let tool = r.job.origin.tool { d["tool"] = tool }
            if r.job.risk.isRisky {
                d["risk"] = ["severity": r.job.risk.severity.label, "flags": r.job.risk.flags.map(\.rawValue)]
            }
            if r.stats.totalCostUSD > 0 { d["costUSD"] = r.stats.totalCostUSD }
            return d
        }
        let payload: [String: Any] = ["jobs": items, "count": items.count]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    }
}
