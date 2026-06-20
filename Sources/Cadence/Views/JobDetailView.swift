import SwiftUI
import CadenceCore

struct JobDetailView: View {
    @Bindable var model: AppModel
    let record: JobRecord

    @State private var runs: [JobRun] = []
    @State private var selectedRunID: Int64?
    @State private var logStream: LogStream = .stdout
    @State private var confirmingDelete = false
    @State private var showingEnv = false
    @State private var readiness: [ReadinessCheck] = []
    @State private var triage: TriageResult?
    @State private var reschedule: RescheduleRequest?

    enum LogStream: String, CaseIterable { case stdout = "Output", stderr = "Errors" }

    private var job: Job { record.job }
    private var stats: JobStats { record.stats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actionBar
                if let req = reschedule { rescheduleBanner(req) }
                statsGrid
                if job.source == .cron, let expr = job.schedule.cronExpression {
                    nextRunsSection(expr)
                }
                if job.flueGoal != nil || job.flueModel != nil { agentSection }
                if !readiness.isEmpty { readinessSection }
                if job.risk.isRisky { safetySection }
                commandSection
                detailsSection
                runHistorySection
                if let triage { triageSection(triage) }
                if selectedRunID != nil { logSection }
            }
            .padding(20)
        }
        .navigationTitle(job.label)
        .task(id: job.id) { reload() }
        .onChange(of: selectedRunID) { _, _ in triage = computeTriage() }
        .sheet(isPresented: $showingEnv) {
            EnvEditorView(model: model, job: job)
        }
        .confirmationDialog("Delete “\(job.label)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Job", role: .destructive) { model.delete(job) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(job.source == .launchd
                 ? "This removes the launchd plist (user agents only)."
                 : "This removes the job from your crontab.")
        }
    }

    private func reload() {
        runs = model.runs(for: job, limit: 200)
        selectedRunID = runs.first?.id
        readiness = (job.source == .flue && job.flueProjectPath != nil) ? model.flueReadiness(job) : []
        reschedule = computeReschedule()
        triage = computeTriage()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusDot(status: job.status, enabled: job.enabled)
                Text(job.label).font(.title2.weight(.semibold))
                SourceBadge(source: job.source)
                if job.origin.category != .user || job.origin.tool != nil {
                    ProvenanceTag(origin: job.origin)
                }
                if job.isAdopted {
                    Label("Tracking", systemImage: "record.circle")
                        .font(.caption2).foregroundStyle(.red)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(job.schedule.summary).fontWeight(.medium)
                if !job.enabled {
                    Text("• Disabled").foregroundStyle(.secondary)
                }
                if let domain = job.launchdDomain {
                    Text("• \(domain.displayName)").foregroundStyle(.secondary)
                }
                if job.flueAgentName != nil {
                    Text("• Flue \(job.flueIsWorkflow ? "workflow" : "agent")").foregroundStyle(.purple)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { model.runNow(job); reloadSoon() } label: {
                Label("Run Now", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Button { model.toggleEnabled(job) } label: {
                Label(job.enabled ? "Disable" : "Enable",
                      systemImage: job.enabled ? "pause.circle" : "play.circle")
            }

            if JobRepository.canAdopt(job) {
                Button { model.toggleAdopted(job) } label: {
                    Label(job.isAdopted ? "Stop Tracking" : "Track Runs",
                          systemImage: job.isAdopted ? "record.circle.fill" : "record.circle")
                }
                .help(job.isAdopted
                      ? "Remove the recorder wrapper"
                      : "Wrap this job so Cadence records every run, its logs, and exit code")
            }

            Spacer()

            if JobRepository.canEditEnv(job) {
                Button { showingEnv = true } label: {
                    Image(systemName: "key")
                }.help("Edit environment variables (API keys, etc.)")
            }
            if job.plistPath != nil {
                Button { model.revealInFinder(job) } label: {
                    Image(systemName: "folder")
                }.help("Reveal plist in Finder")
            }
            Button(role: .destructive) { confirmingDelete = true } label: {
                Image(systemName: "trash")
            }.help("Delete job")
        }
    }

    // MARK: - Adaptive scheduling (agent-requested cadence)

    /// The most recent run's `CADENCE_NEXT` directive, if the job is reschedulable
    /// and the request differs from the current schedule. Computed in `reload()`
    /// (reads a log file) so it doesn't hit disk on every re-render.
    private func computeReschedule() -> RescheduleRequest? {
        guard JobRepository.canReschedule(job), let latest = runs.first else { return nil }
        guard let req = RescheduleParser.parse(model.logText(at: latest.stdoutPath)) else { return nil }
        if job.launchdDomain != nil {
            guard let secs = req.intervalSeconds, secs != job.schedule.startInterval else { return nil }
            return req
        }
        guard let cron = req.normalizedCron, cron != job.schedule.cronExpression else { return nil }
        return req
    }

    private func rescheduleDescription(_ req: RescheduleRequest) -> String {
        if job.launchdDomain != nil, let s = req.intervalSeconds {
            if s % 86400 == 0 { return "Every \(s/86400) day\(s/86400 == 1 ? "" : "s")" }
            if s % 3600 == 0 { return "Every \(s/3600) hour\(s/3600 == 1 ? "" : "s")" }
            if s % 60 == 0 { return "Every \(s/60) minute\(s/60 == 1 ? "" : "s")" }
            return "Every \(s) seconds"
        }
        return CronHumanizer.describe(req.normalizedCron ?? "")
    }

    @ViewBuilder
    private func rescheduleBanner(_ req: RescheduleRequest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.rays").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("This agent asked to change its cadence").font(.caption.weight(.medium))
                Text("New schedule: \(rescheduleDescription(req))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Apply") { model.applyReschedule(job, request: req) }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(10)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Stats

    private var statsGrid: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                StatTile(title: "Total Runs", value: "\(stats.totalRuns)", tint: .accentColor)
                StatTile(title: "Success Rate",
                         value: Fmt.percent(stats.successRate),
                         tint: (stats.successRate ?? 1) >= 0.999 ? .green : .orange)
                StatTile(title: "Last Run", value: Fmt.relative(stats.lastRun))
                StatTile(title: "Avg Duration", value: Fmt.duration(stats.avgDurationMS))
            }
            if stats.totalCostUSD > 0 || stats.totalTokens > 0 {
                GridRow {
                    StatTile(title: "Total Cost", value: Fmt.cost(stats.totalCostUSD), tint: .purple)
                    StatTile(title: "Total Tokens", value: Fmt.tokens(stats.totalTokens))
                    StatTile(title: "Avg Cost / Run",
                             value: Fmt.cost(stats.totalRuns > 0 ? stats.totalCostUSD / Double(stats.totalRuns) : 0))
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !job.isAdopted && stats.totalRuns == 0 && JobRepository.canAdopt(job) {
                Text("Enable tracking to count runs")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
    }

    // MARK: - Next runs

    @ViewBuilder
    private func nextRunsSection(_ expr: String) -> some View {
        if let parsed = CronExpression(expr) {
            let upcoming = parsed.nextRuns(after: Date(), count: 4)
            if !upcoming.isEmpty {
                section("Next Runs") {
                    HStack(spacing: 8) {
                        ForEach(Array(upcoming.enumerated()), id: \.offset) { _, date in
                            VStack(spacing: 2) {
                                Text(Fmt.relative(date)).font(.caption.weight(.medium))
                                Text(date, format: .dateTime.weekday().hour().minute())
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Readiness (will this Flue agent actually run?)

    @ViewBuilder
    private var readinessSection: some View {
        let allReady = FlueReadiness.ready(readiness)
        section("Readiness") {
            VStack(alignment: .leading, spacing: 6) {
                Label(allReady ? "Ready to run" : "Not ready — this scheduled run will fail",
                      systemImage: allReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(allReady ? .green : .orange)
                ForEach(readiness) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.passed ? Color.green : Color.red)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.name).font(.caption.weight(.medium))
                            Text(check.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if !allReady, let proj = job.flueProjectPath {
                    Text(FlueScaffold.setupCommand(for: URL(fileURLWithPath: proj)))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((allReady ? Color.green : Color.orange).opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Agent (Flue model + goal)

    private var agentSection: some View {
        section("Agent") {
            VStack(alignment: .leading, spacing: 8) {
                if let model = job.flueModel {
                    Label(model, systemImage: "cpu")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.purple.opacity(0.12), in: Capsule())
                        .foregroundStyle(.purple)
                }
                if let goal = job.flueGoal, !goal.isEmpty {
                    Text(goal)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Safety

    private var safetySection: some View {
        section("Safety") {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(job.risk.severity.label) risk", systemImage: "shield.lefthalf.filled")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(job.risk.severity.color)
                ForEach(job.risk.flags, id: \.self) { flag in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: flag.symbol)
                            .foregroundStyle(flag.severity.color)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(flag.label).font(.caption.weight(.medium))
                            Text(flag.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(job.risk.severity.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Command

    private var commandSection: some View {
        section("Command") {
            Text(job.command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Details / metadata

    private var detailsSection: some View {
        let rows = JobMetadata.rows(for: job)
        return Group {
            if !rows.isEmpty {
                section("Details") {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(alignment: .top, spacing: 10) {
                                Text(row.key)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 110, alignment: .leading)
                                Text(row.value)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(3)
                                    .truncationMode(.middle)
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            Divider().opacity(0.4)
                        }
                    }
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Run history

    private var runHistorySection: some View {
        section("Run History") {
            if runs.isEmpty {
                Text(job.isAdopted
                     ? "No runs recorded yet. They’ll appear here after the next scheduled or manual run."
                     : "Not tracked. Use “Track Runs” (cron/Flue) or “Run Now” to record executions.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(runs.prefix(40)) { run in
                        RunRow(run: run, selected: run.id == selectedRunID)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedRunID = run.id }
                        Divider()
                    }
                }
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Diagnosis (failure triage)

    /// Diagnose the selected run if it failed. Computed in `reload()` and on
    /// run-selection change (reads log files) — not on every re-render.
    private func computeTriage() -> TriageResult? {
        guard let run = runs.first(where: { $0.id == selectedRunID }) else { return nil }
        guard let code = run.exitCode, code != 0 else { return nil }
        let stderr = model.logText(at: run.stderrPath)
        let stdout = model.logText(at: run.stdoutPath)
        return FailureTriage.diagnose(exitCode: code, stderr: stderr, stdout: stdout,
                                      command: job.command, timedOut: code == 124)
    }

    @ViewBuilder
    private func triageSection(_ t: TriageResult) -> some View {
        section("Diagnosis") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "stethoscope")
                    Text(t.category).font(.callout.weight(.semibold))
                    Text(t.confidence.rawValue).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                }
                .foregroundStyle(.orange)
                Text(t.likelyCause).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label(t.suggestedFix, systemImage: "wrench.and.screwdriver")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Logs

    @ViewBuilder
    private var logSection: some View {
        let run = runs.first { $0.id == selectedRunID }
        let path = logStream == .stdout ? run?.stdoutPath : run?.stderrPath
        let text = model.logText(at: path)
        section("Logs") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $logStream) {
                    ForEach(LogStream.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)

                ScrollView {
                    Text(text.isEmpty ? "— no output —" : text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(text.isEmpty ? Color.secondary : (logStream == .stderr ? Color.red : Color.primary))
                }
                .frame(height: 200)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func reloadSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { reload() }
    }
}

struct RunRow: View {
    let run: JobRun
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(Fmt.absolute(run.startedAt))
                .font(.caption.monospacedDigit())
            if run.trigger == "manual" {
                Text("manual").font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            if let cost = run.usage.costUSD {
                Text(Fmt.cost(cost))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.purple)
                    .help(usageTooltip(run.usage))
            } else if let tokens = run.usage.totalTokens {
                Text(Fmt.tokens(tokens) + " tok")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.purple)
                    .help(usageTooltip(run.usage))
            }
            if let code = run.exitCode {
                Text("exit \(code)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(code == 0 ? Color.secondary : Color.red)
            }
            Text(Fmt.duration(run.durationMS))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear)
    }

    private var icon: String {
        guard let ok = run.succeeded else { return "circle.dotted" }
        return ok ? "checkmark.circle.fill" : "xmark.circle.fill"
    }
    private var color: Color {
        guard let ok = run.succeeded else { return .secondary }
        return ok ? .green : .red
    }

    private func usageTooltip(_ u: Usage) -> String {
        var parts: [String] = []
        if let m = u.model { parts.append(m) }
        if let i = u.inputTokens { parts.append("in \(i)") }
        if let o = u.outputTokens { parts.append("out \(o)") }
        if let c = u.costUSD { parts.append(Fmt.cost(c)) }
        return parts.isEmpty ? "usage" : parts.joined(separator: " · ")
    }
}
