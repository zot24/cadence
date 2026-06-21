import SwiftUI
import Observation
import CadenceCore

/// Job-list sort options.
enum JobSort: String, CaseIterable, Identifiable {
    case name = "Name", source = "Source", lastRun = "Last Run", runs = "Runs", cost = "Cost"
    var id: String { rawValue }
}

/// Sidebar filter categories.
enum JobFilter: Hashable, Identifiable {
    case all
    case source(JobSource)
    case agentCreated
    case adopted
    case failing
    case risky

    var id: String {
        switch self {
        case .all: return "all"
        case .source(let s): return "source-\(s.rawValue)"
        case .agentCreated: return "agent"
        case .adopted: return "adopted"
        case .failing: return "failing"
        case .risky: return "risky"
        }
    }

    var title: String {
        switch self {
        case .all: return "All Jobs"
        case .source(let s): return s.displayName
        case .agentCreated: return "AI agents"
        case .adopted: return "Tracked"
        case .failing: return "Failing"
        case .risky: return "At risk"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .source(let s): return s.symbolName
        case .agentCreated: return "brain.head.profile"
        case .adopted: return "record.circle"
        case .failing: return "exclamationmark.triangle"
        case .risky: return "exclamationmark.shield"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var records: [JobRecord] = []
    private(set) var loading = false
    private(set) var lastError: String?

    var filter: JobFilter = .all
    var selectedJobID: String?
    var searchText: String = ""
    private static let sortKeyDefault = "com.cadence.sortKey"
    var sortKey: JobSort = JobSort(rawValue: UserDefaults.standard.string(forKey: AppModel.sortKeyDefault) ?? "") ?? .name {
        didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: Self.sortKeyDefault) }
    }
    private static let groupByOrgKey = "com.cadence.groupByOrg"
    var groupByOrg: Bool = (UserDefaults.standard.object(forKey: AppModel.groupByOrgKey) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(groupByOrg, forKey: Self.groupByOrgKey) }
    }

    // Sheets
    var showingNewCron = false
    var showingNewLaunchd = false
    var showingNewFlue = false
    var showingNewAgent = false
    var showingSettings = false
    var showingActivity = false
    var showingRecipeGallery = false
    /// A recipe chosen in the gallery, consumed by NewAgentJobView to prefill.
    var pendingRecipe: Recipe?

    private let repository: JobRepository?

    init() {
        do {
            self.repository = try JobRepository()
        } catch {
            self.repository = nil
            self.lastError = "Could not initialise: \(error)"
        }
        startAutoRefresh()
    }

    /// Reload jobs/stats periodically so status and run counts stay current.
    private func startAutoRefresh() {
        refresh()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.refresh()
            }
        }
    }

    var repo: JobRepository? { repository }

    // MARK: - Derived collections

    var filtered: [JobRecord] {
        var items = records
        switch filter {
        case .all: break
        case .source(let s): items = items.filter { $0.job.source == s }
        case .agentCreated: items = items.filter { $0.job.provenance.isAgentic }
        case .adopted: items = items.filter { $0.job.isAdopted }
        case .failing: items = items.filter { $0.job.status == .errored || ($0.stats.lastExitCode ?? 0) != 0 && $0.stats.totalRuns > 0 }
        case .risky: items = items.filter { $0.job.risk.isRisky }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            items = items.filter {
                $0.job.label.lowercased().contains(q)
                    || $0.job.command.lowercased().contains(q)
                    || ($0.job.origin.tool?.lowercased().contains(q) ?? false)
            }
        }
        switch sortKey {
        case .name:    items.sort { $0.job.label.localizedCaseInsensitiveCompare($1.job.label) == .orderedAscending }
        case .source:  items.sort { ($0.job.source.rawValue, $0.job.label) < ($1.job.source.rawValue, $1.job.label) }
        case .lastRun: items.sort { ($0.stats.lastRun ?? .distantPast) > ($1.stats.lastRun ?? .distantPast) }
        case .runs:    items.sort { $0.stats.totalRuns > $1.stats.totalRuns }
        case .cost:    items.sort { $0.stats.totalCostUSD > $1.stats.totalCostUSD }
        }
        return items
    }

    /// `filtered` grouped by vendor org (from the reverse-DNS label), ordered
    /// alphabetically with "Other" last. Records keep the active sort within groups.
    var grouped: [(org: String, records: [JobRecord])] {
        var map: [String: [JobRecord]] = [:]
        var order: [String] = []
        for r in filtered {
            var org = JobOrg.organization(forLabel: r.job.label)
            if org == JobOrg.other, let tool = r.job.origin.tool { org = tool }
            if map[org] == nil { order.append(org) }
            map[org, default: []].append(r)
        }
        let sorted = order.sorted { a, b in
            if a == JobOrg.other { return false }
            if b == JobOrg.other { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return sorted.map { ($0, map[$0]!) }
    }

    var selectedRecord: JobRecord? {
        guard let id = selectedJobID else { return nil }
        return records.first { $0.id == id }
    }

    func count(for filter: JobFilter) -> Int {
        switch filter {
        case .all: return records.count
        case .source(let s): return records.filter { $0.job.source == s }.count
        case .agentCreated: return records.filter { $0.job.provenance.isAgentic }.count
        case .adopted: return records.filter { $0.job.isAdopted }.count
        case .failing: return records.filter { $0.job.status == .errored }.count
        case .risky: return records.filter { $0.job.risk.isRisky }.count
        }
    }

    var failingCount: Int { records.filter { $0.job.status == .errored }.count }
    var totalRunCount: Int { records.reduce(0) { $0 + $1.stats.totalRuns } }
    var agentCount: Int { records.filter { $0.job.provenance.isAgentic }.count }
    var atRiskCount: Int { records.filter { $0.job.risk.isRisky }.count }
    var totalSpendUSD: Double { records.reduce(0) { $0 + $1.stats.totalCostUSD } }

    // MARK: - Loading

    func refresh() {
        guard let repository else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let loaded = repository.loadAll()
            await MainActor.run {
                self.records = loaded
                self.loading = false
                if self.selectedJobID == nil { self.selectedJobID = loaded.first?.id }
            }
        }
    }

    func runs(for job: Job, limit: Int = 100) -> [JobRun] {
        repository?.recentRuns(for: job, limit: limit) ?? []
    }

    func logText(at path: String?) -> String {
        repository?.logText(at: path) ?? ""
    }

    // MARK: - Actions

    private func perform(_ action: @escaping (JobRepository) throws -> Void) {
        guard let repository else { return }
        Task.detached(priority: .userInitiated) {
            do {
                try action(repository)
            } catch {
                await MainActor.run { self.lastError = "\(error)" }
            }
            await MainActor.run { self.refresh() }
        }
    }

    func runNow(_ job: Job) {
        guard let repository else { return }
        if needsElevation(job) {
            // Privileged daemon/agent: kickstart via launchd as root (prompts).
            perform { try $0.runNowElevated(job) }
            return
        }
        Task.detached(priority: .userInitiated) {
            repository.runNow(job)
            await MainActor.run { self.refresh() }
        }
    }

    private static let allowPrivilegedKey = "com.cadence.allowPrivileged"
    /// Opt-in: allow managing system/global launchd jobs via a native admin prompt.
    var allowPrivilegedActions: Bool {
        get { UserDefaults.standard.bool(forKey: Self.allowPrivilegedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.allowPrivilegedKey) }
    }
    /// True when a job needs root and the user has opted into elevation.
    private func needsElevation(_ job: Job) -> Bool {
        allowPrivilegedActions && (job.launchdDomain.map { $0 != .userAgent } ?? false)
    }

    func toggleEnabled(_ job: Job) {
        let elevate = needsElevation(job)
        perform { try $0.setEnabled(job, enabled: !job.enabled, elevated: elevate) }
    }

    func toggleAdopted(_ job: Job) {
        perform { try $0.setAdopted(job, adopted: !job.isAdopted) }
    }

    /// Agent jobs that are adoptable but not yet tracked.
    var untrackedAgentJobs: [Job] {
        JobRepository.trackableAgentJobs(records.map(\.job))
    }

    /// Adopt all untracked agent jobs in one go.
    func bulkTrackAgents() {
        guard let repository else { return }
        let jobs = untrackedAgentJobs
        guard !jobs.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            repository.bulkAdopt(jobs)
            await MainActor.run { self.refresh() }
        }
    }

    func delete(_ job: Job) {
        if selectedJobID == job.id { selectedJobID = nil }
        let elevate = needsElevation(job)
        perform { try $0.delete(job, elevated: elevate) }
    }

    func addCronJob(schedule: String, command: String, label: String?, adopt: Bool) {
        perform { _ = try $0.addCronJob(schedule: schedule, command: command, label: label, adopt: adopt) }
    }

    func addLaunchdJob(label: String, command: String, spec: LaunchdWriter.ScheduleSpec, adopt: Bool) {
        perform { _ = try $0.addLaunchdJob(label: label, command: command, spec: spec, adopt: adopt) }
    }

    func scheduleFlue(_ agent: FlueAgent, schedule: String) {
        perform { _ = try $0.scheduleFlueAgent(agent, schedule: schedule) }
    }

    func applyReschedule(_ job: Job, request: RescheduleRequest) {
        perform { try $0.applyReschedule(job, request: request) }
    }

    func createAgentJob(project: URL, name: String, model: String, instructions: String,
                        schedule: String, scaffoldWorkspace: Bool,
                        sandbox: Bool = false, sandboxAllowNetwork: Bool = true) {
        perform {
            _ = try $0.createAgentJob(project: project, name: name, model: model,
                                      instructions: instructions, schedule: schedule,
                                      scaffoldWorkspace: scaffoldWorkspace,
                                      sandbox: sandbox, sandboxAllowNetwork: sandboxAllowNetwork)
        }
    }

    func discoverFlueProjects() -> [FlueProject] {
        repository?.discoverFlueProjects() ?? []
    }

    func flueReadiness(_ job: Job) -> [ReadinessCheck] {
        repository?.flueReadiness(job) ?? []
    }

    func getNotifyOnFail() -> Bool { repository?.getNotifyOnFail() ?? true }
    func setNotifyOnFail(_ value: Bool) { repository?.setNotifyOnFail(value) }
    func getTimeoutMinutes() -> Int { repository?.getDefaultTimeoutMinutes() ?? 0 }
    func setTimeoutMinutes(_ m: Int) { repository?.setDefaultTimeoutMinutes(m) }

    func recentActivity(limit: Int = 500) -> [ActivityEntry] {
        repository?.recentActivity(limit: limit) ?? []
    }
    func clearRunHistory() {
        repository?.clearRunHistory()
        refresh()
    }
    func activityCSV() -> String { repository?.activityCSV() ?? "" }

    func selectJob(_ id: String) { selectedJobID = id }

    func jobEnvironment(_ job: Job) -> [String: String] { repository?.jobEnvironment(job) ?? [:] }
    func setJobEnvironment(_ job: Job, env: [String: String]) {
        perform { try $0.setJobEnvironment(job, env: env) }
    }

    func revealInFinder(_ job: Job) {
        guard let path = job.plistPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func dismissError() { lastError = nil }

    // MARK: - Recipe registry

    /// Recipes shown in the gallery (non-experimental runtimes).
    var shippableRecipes: [Recipe] { RecipeCatalog.shippable }

    /// Install a recipe into a project with the chosen provider + cadence, then
    /// schedule it as a tracked job.
    func installRecipe(_ recipe: Recipe, project: URL, provider: ModelProvider,
                       instructions: String?, schedule: String, scaffoldWorkspace: Bool) {
        guard let repository else { return }
        Task.detached(priority: .userInitiated) {
            do {
                _ = try RecipeInstaller.install(recipe, into: project, provider: provider,
                                                instructions: instructions, schedule: schedule,
                                                scaffoldWorkspace: scaffoldWorkspace, repository: repository)
            } catch {
                await MainActor.run { self.lastError = "\(error)" }
            }
            await MainActor.run { self.refresh() }
        }
    }

    // MARK: - AI triage provider ("Explain this failure with a model")

    private static let triageKindKey = "com.cadence.triage.kind"
    private static let triageModelKey = "com.cadence.triage.model"
    private static let triageBaseURLKey = "com.cadence.triage.baseURL"

    var triageProviderKind: ProviderKind {
        get { ProviderKind(rawValue: UserDefaults.standard.string(forKey: Self.triageKindKey) ?? "") ?? .ollama }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.triageKindKey) }
    }
    var triageModelID: String {
        get { UserDefaults.standard.string(forKey: Self.triageModelKey) ?? "llama3.2:3b" }
        set { UserDefaults.standard.set(newValue, forKey: Self.triageModelKey) }
    }
    var triageBaseURL: String {
        get { UserDefaults.standard.string(forKey: Self.triageBaseURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.triageBaseURLKey) }
    }
    /// Stored in the Keychain, keyed per provider so switching providers keeps keys.
    var triageAPIKey: String {
        get { Keychain.get("triage-\(triageProviderKind.rawValue)") ?? "" }
        set { Keychain.set(newValue, for: "triage-\(triageProviderKind.rawValue)") }
    }
    /// The stored key for a specific provider — used by Settings when switching.
    func triageKey(for kind: ProviderKind) -> String { Keychain.get("triage-\(kind.rawValue)") ?? "" }

    var triageProvider: ModelProvider {
        ModelProvider(kind: triageProviderKind, modelID: triageModelID,
                      baseURLOverride: triageBaseURL.isEmpty ? nil : URL(string: triageBaseURL),
                      apiKeyValue: triageAPIKey.isEmpty ? nil : triageAPIKey)
    }

    enum TriageError: LocalizedError {
        case notConfigured, http(String), unparseable
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No triage model is configured (Settings → AI triage)."
            case .http(let m): return "The model API returned an error — \(m)"
            case .unparseable: return "Couldn't read the model's response."
            }
        }
    }

    /// Ask the configured model to explain a failed run. The prompt-building and
    /// response-parsing are pure CadenceCore helpers; this performs the call.
    func explainFailure(job: Job, run: JobRun) async throws -> String {
        let provider = triageProvider
        guard let endpoint = provider.triageEndpoint() else { throw TriageError.notConfigured }
        let stderr = logText(at: run.stderrPath)
        let stdout = logText(at: run.stdoutPath)
        let timedOut = run.exitCode == 124
        let det = FailureTriage.diagnose(exitCode: run.exitCode, stderr: stderr, stdout: stdout,
                                         command: job.command, timedOut: timedOut)
        let (system, user) = ModelTriage.messages(command: job.command, stderr: stderr, stdout: stdout,
                                                   exitCode: run.exitCode, timedOut: timedOut, deterministic: det)
        var req = URLRequest(url: endpoint.url)
        req.httpMethod = "POST"
        for (k, v) in endpoint.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try ModelTriage.requestBody(provider: provider, system: system, user: user)
        req.timeoutInterval = 60
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TriageError.http("HTTP \(code): \(body.prefix(200))")
        }
        guard let answer = ModelTriage.parseAnswer(provider: provider, data: data) else {
            throw TriageError.unparseable
        }
        return answer
    }
}
