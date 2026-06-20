import SwiftUI
import CadenceCore

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.records.isEmpty {
                Text(model.loading ? "Loading jobs…" : "No scheduled jobs found.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sortedRecords) { record in
                            MenuBarRow(model: model, record: record) {
                                openMain()
                            }
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear { model.refresh() }
    }

    /// Failing first, then by most-recently-run.
    private var sortedRecords: [JobRecord] {
        model.records.sorted { a, b in
            if (a.job.status == .errored) != (b.job.status == .errored) {
                return a.job.status == .errored
            }
            return (a.stats.lastRun ?? .distantPast) > (b.stats.lastRun ?? .distantPast)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Cadence").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(10)
    }

    private var summary: String {
        var parts = ["\(model.records.count) jobs"]
        if model.failingCount > 0 { parts.append("\(model.failingCount) failing") }
        parts.append("\(model.totalRunCount) runs")
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            Button {
                openMain()
            } label: {
                Label("Open Cadence", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)
            Button {
                model.showingActivity = true
                openMain()
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .buttonStyle(.borderless)
            .help("Activity timeline")
            Spacer()
            Menu {
                Button("New Cron Job…") { model.showingNewCron = true; openMain() }
                Button("New launchd Job…") { model.showingNewLaunchd = true; openMain() }
                Button("New Agent Job…") { model.showingNewAgent = true; openMain() }
                Button("Schedule Flue Agent…") { model.showingNewFlue = true; openMain() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct MenuBarRow: View {
    @Bindable var model: AppModel
    let record: JobRecord
    let onOpen: () -> Void

    private var job: Job { record.job }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: job.status, enabled: job.enabled)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.label).font(.callout).lineLimit(1)
                Text(job.schedule.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if record.stats.totalRuns > 0 {
                Text("\(record.stats.totalRuns)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button { model.runNow(job) } label: {
                Image(systemName: "play.fill").font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Run now")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedJobID = job.id
            onOpen()
        }
    }
}
