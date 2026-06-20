import Foundation

/// A job paired with its aggregated run statistics — the unit the UI renders.
public struct JobRecord: Identifiable, Hashable, Sendable {
    public var job: Job
    public var stats: JobStats
    public var id: String { job.id }

    public init(job: Job, stats: JobStats) {
        self.job = job
        self.stats = stats
    }
}

/// The central facade the app talks to: aggregates all job sources, merges run
/// history, and performs management actions. Foundation-only and synchronous;
/// the app calls it off the main thread.
public final class JobRepository: @unchecked Sendable {
    private let store: RunStore

    public init(store: RunStore? = nil) throws {
        self.store = try store ?? RunStore()
        RecorderInstaller.ensureInstalled()
    }

    // MARK: - Flue project roots (persisted in UserDefaults)

    private static let flueRootsKey = "com.cadence.flueRoots"

    public static func flueRoots() -> [URL] {
        let defaults = UserDefaults.standard
        if let paths = defaults.stringArray(forKey: flueRootsKey), !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        // Sensible defaults: common code locations.
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Desktop/code"),
            home.appendingPathComponent("code"),
            home.appendingPathComponent("Developer"),
            home.appendingPathComponent("Projects"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func setFlueRoots(_ urls: [URL]) {
        UserDefaults.standard.set(urls.map(\.path), forKey: flueRootsKey)
    }

    // MARK: - Loading

    /// Load every job from every source, enrich Flue jobs, and attach run stats.
    public func loadAll() -> [JobRecord] {
        var jobs: [Job] = []
        jobs.append(contentsOf: CronSource.load().jobs)
        jobs.append(contentsOf: LaunchdSource.load())
        jobs = jobs.map { job in
            var enriched = FlueSource.enrich(job)
            enriched.origin = JobProvenanceDetector.detect(enriched)
            enriched.risk = JobRiskAnalyzer.analyze(enriched)
            return enriched
        }

        let allStats = store.allStats()
        return jobs.map { job in
            JobRecord(job: job, stats: allStats[job.id] ?? store.stats(forJob: job.id))
        }
        .sorted { lhs, rhs in
            if lhs.job.source != rhs.job.source {
                return lhs.job.source.rawValue < rhs.job.source.rawValue
            }
            return lhs.job.label.localizedCaseInsensitiveCompare(rhs.job.label) == .orderedAscending
        }
    }

    public func discoverFlueProjects() -> [FlueProject] {
        FlueSource.discoverProjects(in: Self.flueRoots())
    }

    /// Pre-flight readiness for a scheduled Flue agent job.
    public func flueReadiness(_ job: Job) -> [ReadinessCheck] {
        guard let proj = job.flueProjectPath else { return [] }
        return FlueReadiness.check(projectPath: proj, agentName: job.flueAgentName, isWorkflow: job.flueIsWorkflow)
    }

    // MARK: - Settings

    public func getNotifyOnFail() -> Bool {
        store.boolSetting(CadenceSettingsKey.notifyOnFail, default: true)
    }
    public func setNotifyOnFail(_ value: Bool) {
        store.setBoolSetting(CadenceSettingsKey.notifyOnFail, value: value)
    }

    /// Default max-runtime for tracked jobs, in minutes (0 = no limit).
    public func getDefaultTimeoutMinutes() -> Int {
        store.intSetting(CadenceSettingsKey.defaultTimeoutSeconds, default: 0) / 60
    }
    public func setDefaultTimeoutMinutes(_ minutes: Int) {
        store.setIntSetting(CadenceSettingsKey.defaultTimeoutSeconds, value: max(0, minutes) * 60)
    }

    public func recentRuns(for job: Job, limit: Int = 100) -> [JobRun] {
        store.recentRuns(forJob: job.id, limit: limit)
    }

    /// The cross-job audit timeline.
    public func recentActivity(limit: Int = 500) -> [ActivityEntry] {
        store.recentActivity(limit: limit)
    }

    /// Wipe all run history (DB rows + captured log files).
    public func clearRunHistory() {
        store.clearAllRuns()
        let fm = FileManager.default
        try? fm.removeItem(at: CadencePaths.logsDirectory)
        try? fm.createDirectory(at: CadencePaths.logsDirectory, withIntermediateDirectories: true)
    }

    /// Render the audit timeline as CSV for export/governance.
    public func activityCSV(limit: Int = 5000) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["started_at,job,source,trigger,exit_code,duration_ms,result,model,cost_usd"]
        for e in store.recentActivity(limit: limit) {
            let result = e.succeeded == nil ? "running" : (e.succeeded! ? "success" : "failure")
            let fields = [
                iso.string(from: e.startedAt),
                csvEscape(e.label),
                e.source?.rawValue ?? "",
                e.trigger,
                e.exitCode.map(String.init) ?? "",
                e.durationMS.map(String.init) ?? "",
                result,
                csvEscape(e.model ?? ""),
                e.costUSD.map { String(format: "%.6f", $0) } ?? "",
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    public func stats(for job: Job) -> JobStats {
        store.stats(forJob: job.id)
    }

    /// Read a captured log file (stdout/stderr) for a run, truncated to `maxBytes`.
    public func logText(at path: String?, maxBytes: Int = 200_000) -> String {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxBytes)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Actions

    /// Run a job immediately through the recorder so the execution is recorded.
    public func runNow(_ job: Job) {
        guard let rec = RecorderInstaller.ensureInstalled() else { return }
        _ = Shell.run(rec.path, [
            "--job", job.id,
            "--label", job.label,
            "--source", job.source.rawValue,
            "--trigger", "manual",
            "--", job.command,
        ])
    }

    public func setEnabled(_ job: Job, enabled: Bool) throws {
        // launchd-backed jobs (incl. Flue scheduled via launchd) carry a plist.
        if let domain = job.launchdDomain, let plist = job.plistPath {
            try LaunchdControl.setEnabled(label: job.label, domain: domain, plistPath: plist, enabled: enabled)
        } else {
            try CronWriter.setEnabled(id: job.id, enabled: enabled)
        }
    }

    public func delete(_ job: Job) throws {
        switch job.source {
        case .cron:
            try CronWriter.removeJob(id: job.id)
        case .flue where job.cronLine != nil:
            try CronWriter.removeJob(id: job.id)
        case .launchd, .flue:
            // Removing a launchd job: bootout + delete the plist (user agents only).
            if let domain = job.launchdDomain, domain == .userAgent,
               let plist = job.plistPath {
                try? LaunchdControl.setEnabled(label: job.label, domain: domain, plistPath: plist, enabled: false)
                try FileManager.default.removeItem(atPath: plist)
            } else {
                throw CronWriter.WriteError.installFailed("Deleting global/system launchd jobs requires removing \(job.plistPath ?? "the plist") with administrator privileges.")
            }
        }
    }

    /// Wrap (adopt) or unwrap a job so Cadence records its runs. Cron/Flue jobs
    /// are rewritten in the crontab; launchd jobs have their plist rewritten.
    public func setAdopted(_ job: Job, adopted: Bool) throws {
        if let domain = job.launchdDomain, let plist = job.plistPath {
            if adopted {
                try LaunchdWriter.adopt(label: job.label, plistPath: plist, domain: domain)
            } else {
                try LaunchdWriter.unadopt(label: job.label, plistPath: plist, domain: domain)
            }
        } else {
            try CronWriter.setAdopted(id: job.id, adopted: adopted, label: job.label)
        }
    }

    /// Whether this job can be adopted for run tracking in-place.
    public static func canAdopt(_ job: Job) -> Bool {
        if let domain = job.launchdDomain { return domain == .userAgent }
        return job.source == .cron || (job.source == .flue && job.cronLine != nil)
    }

    /// Agent-driven jobs that are adoptable but not yet tracked — the set the
    /// bulk "track all agent jobs" action operates on.
    public static func trackableAgentJobs(_ jobs: [Job]) -> [Job] {
        jobs.filter { $0.provenance.isAgentic && canAdopt($0) && !$0.isAdopted }
    }

    /// Adopt many jobs for run tracking; returns how many succeeded.
    @discardableResult
    public func bulkAdopt(_ jobs: [Job]) -> Int {
        var ok = 0
        for job in jobs where Self.canAdopt(job) && !job.isAdopted {
            if (try? setAdopted(job, adopted: true)) != nil { ok += 1 }
        }
        return ok
    }

    // MARK: - Environment variables (launchd user agents)

    public static func canEditEnv(_ job: Job) -> Bool {
        job.launchdDomain == .userAgent
            || job.flueProjectPath != nil
            || (job.source == .cron && job.cronLine != nil)
    }

    /// Where a job's environment lives — used to label the editor.
    public static func envBackend(_ job: Job) -> String? {
        if let proj = job.flueProjectPath { return "\(proj)/.env" }
        if job.launchdDomain == .userAgent { return job.plistPath }
        if job.source == .cron { return "crontab (inline KEY=val)" }
        return nil
    }

    public func jobEnvironment(_ job: Job) -> [String: String] {
        if let proj = job.flueProjectPath {
            return DotEnv.read(URL(fileURLWithPath: proj).appendingPathComponent(".env"))
        }
        if job.source == .cron, let line = job.cronLine {
            return CronWriter.envFromLine(line)
        }
        guard let path = job.plistPath else { return [:] }
        return LaunchdWriter.readEnv(plistPath: path)
    }

    public func setJobEnvironment(_ job: Job, env: [String: String]) throws {
        if let proj = job.flueProjectPath {
            try DotEnv.write(env, to: URL(fileURLWithPath: proj).appendingPathComponent(".env"))
            return
        }
        if job.source == .cron, job.cronLine != nil {
            try CronWriter.setInlineEnv(id: job.id, env: env)
            return
        }
        guard let domain = job.launchdDomain, let path = job.plistPath else {
            throw CronWriter.WriteError.installFailed("Environment editing is supported for launchd, cron, and Flue jobs.")
        }
        try LaunchdWriter.setEnv(label: job.label, plistPath: path, domain: domain, env: env)
    }

    @discardableResult
    public func addCronJob(schedule: String, command: String, label: String?, adopt: Bool) throws -> String {
        try CronWriter.addJob(schedule: schedule, command: command, label: label, adopt: adopt)
    }

    /// Whether a job's schedule can be changed in place (adaptive scheduling).
    public static func canReschedule(_ job: Job) -> Bool {
        if let domain = job.launchdDomain { return domain == .userAgent }
        return job.cronLine != nil || job.source == .cron
    }

    /// Apply an agent-requested cadence. Cron jobs take a cron expression;
    /// launchd jobs take a StartInterval derived from the request.
    public func applyReschedule(_ job: Job, request: RescheduleRequest) throws {
        if let domain = job.launchdDomain, let plist = job.plistPath {
            guard let secs = request.intervalSeconds else {
                throw CronWriter.WriteError.installFailed("That cadence can't be expressed as a launchd interval.")
            }
            try LaunchdWriter.setInterval(label: job.label, plistPath: plist, domain: domain, seconds: secs)
            return
        }
        guard let cron = request.normalizedCron else {
            throw CronWriter.WriteError.installFailed("Could not derive a schedule from the request.")
        }
        try CronWriter.setSchedule(id: job.id, cron: cron)
    }

    /// Create a new user LaunchAgent (launchd) job and load it.
    @discardableResult
    public func addLaunchdJob(label: String, command: String,
                              spec: LaunchdWriter.ScheduleSpec, adopt: Bool) throws -> String {
        try LaunchdWriter.createUserAgent(label: label, command: command, spec: spec, adopt: adopt)
    }

    /// Schedule a Flue agent/workflow as a cron job (always adopted so we get
    /// run history; Flue's own durable logs complement ours).
    @discardableResult
    public func scheduleFlueAgent(_ agent: FlueAgent, schedule: String) throws -> String {
        let command = FlueSource.command(for: agent)
        return try CronWriter.addJob(schedule: schedule, command: command, label: agent.name, adopt: true)
    }

    /// Create a *new* model-backed Flue agent (scaffold its source) and schedule
    /// it as a tracked local cron job — a scheduled job whose logic is an LLM agent.
    @discardableResult
    public func createAgentJob(project: URL, name: String, model: String,
                               instructions: String, schedule: String,
                               scaffoldWorkspace: Bool) throws -> String {
        if scaffoldWorkspace {
            try FlueScaffold.scaffoldWorkspaceIfNeeded(at: project)
        }
        try FlueScaffold.writeAgent(intoProject: project, name: name, model: model, instructions: instructions)
        let slug = FlueScaffold.sanitize(name: name)
        let agent = FlueAgent(name: slug, isWorkflow: false,
                              projectPath: project.path, projectName: project.lastPathComponent)
        return try scheduleFlueAgent(agent, schedule: schedule)
    }
}
