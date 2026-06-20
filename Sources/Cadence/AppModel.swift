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

    // Sheets
    var showingNewCron = false
    var showingNewLaunchd = false
    var showingNewFlue = false
    var showingNewAgent = false
    var showingSettings = false
    var showingActivity = false

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
        Task.detached(priority: .userInitiated) {
            repository.runNow(job)
            await MainActor.run { self.refresh() }
        }
    }

    func toggleEnabled(_ job: Job) {
        perform { try $0.setEnabled(job, enabled: !job.enabled) }
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
        perform { try $0.delete(job) }
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
                        schedule: String, scaffoldWorkspace: Bool) {
        perform {
            _ = try $0.createAgentJob(project: project, name: name, model: model,
                                      instructions: instructions, schedule: schedule,
                                      scaffoldWorkspace: scaffoldWorkspace)
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
}
