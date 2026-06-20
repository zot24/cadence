import SwiftUI
import AppKit
import CadenceCore

struct JobListView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.records.isEmpty {
                SummaryBar(model: model)
                Divider()
            }
            listContent
        }
    }

    @ViewBuilder
    private var listContent: some View {
        Group {
            if model.filtered.isEmpty {
                ContentUnavailableView {
                    Label(model.loading ? "Loading…" : "No Jobs", systemImage: "calendar.badge.clock")
                } description: {
                    Text(model.loading ? "Reading cron, launchd, and Flue jobs." : "Nothing matches this filter.")
                }
            } else {
                List(selection: $model.selectedJobID) {
                    ForEach(model.filtered) { record in
                        JobRow(record: record)
                            .tag(record.id)
                            .contextMenu { rowMenu(record.job) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(model.filter.title)
        .overlay(alignment: .top) {
            if model.loading && !model.records.isEmpty {
                ProgressView().controlSize(.small).padding(6)
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ job: Job) -> some View {
        Button("Run Now", systemImage: "play.fill") { model.runNow(job) }
        Button(job.enabled ? "Disable" : "Enable",
               systemImage: job.enabled ? "pause.circle" : "play.circle") {
            model.toggleEnabled(job)
        }
        if JobRepository.canAdopt(job) {
            Button(job.isAdopted ? "Stop Tracking" : "Track Runs",
                   systemImage: job.isAdopted ? "record.circle.fill" : "record.circle") {
                model.toggleAdopted(job)
            }
        }
        if job.plistPath != nil {
            Button("Reveal in Finder", systemImage: "folder") { model.revealInFinder(job) }
        }
        Button("Copy Command", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(job.command, forType: .string)
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { model.delete(job) }
    }
}

struct JobRow: View {
    let record: JobRecord
    private var job: Job { record.job }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: job.status, enabled: job.enabled)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.label)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if job.origin.category != .user || job.origin.tool != nil {
                        Image(systemName: job.origin.category.symbolName)
                            .font(.caption2)
                            .foregroundStyle(job.origin.category.color)
                            .help(job.origin.tool.map { "\($0) — \(job.origin.evidence ?? "")" } ?? job.origin.category.displayName)
                    }
                    if job.isAdopted {
                        Image(systemName: "record.circle")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .help("Run tracking on")
                    }
                    if job.risk.isRisky {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.caption2)
                            .foregroundStyle(job.risk.severity.color)
                            .help("\(job.risk.severity.label) risk: " + job.risk.flags.map(\.label).joined(separator: ", "))
                    }
                }
                Text(job.schedule.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                SourceBadge(source: job.source)
                if record.stats.totalRuns > 0 {
                    Text("\(record.stats.totalRuns) runs")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
