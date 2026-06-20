import SwiftUI
import CadenceCore
import AppKit

/// Cross-job audit timeline — every recorded run across all jobs, newest first.
/// The "if you can't trace what an agent did, you can't govern it" surface.
struct ActivityView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ActivityEntry] = []
    @State private var failuresOnly = false

    private var shown: [ActivityEntry] {
        failuresOnly ? entries.filter { ($0.exitCode ?? 0) != 0 && $0.succeeded != nil } : entries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Activity", systemImage: "list.bullet.rectangle").font(.headline)
                Spacer()
                Toggle("Failures only", isOn: $failuresOnly).toggleStyle(.checkbox).font(.caption)
                Button { exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .controlSize(.small)
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
            }
            .padding()
            Divider()

            if shown.isEmpty {
                ContentUnavailableView {
                    Label("No recorded runs yet", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Tracked jobs record every run here — a chronological audit trail across cron, launchd, and Flue agents.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { entry in
                            ActivityRow(entry: entry)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selectJob(entry.jobID)
                                    dismiss()
                                }
                            Divider().opacity(0.4)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text("\(shown.count) run\(shown.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                let totalCost = shown.compactMap(\.costUSD).reduce(0, +)
                if totalCost > 0 {
                    Label(Fmt.cost(totalCost), systemImage: "dollarsign.circle")
                        .font(.caption.monospacedDigit()).foregroundStyle(.purple)
                }
                let fails = entries.filter { ($0.exitCode ?? 0) != 0 && $0.succeeded != nil }.count
                if fails > 0 {
                    Label("\(fails) failed", systemImage: "xmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 640, height: 560)
        .task { entries = model.recentActivity(limit: 1000) }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "cadence-activity.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            try? model.activityCSV().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.label).font(.callout.weight(.medium)).lineLimit(1)
                    if let s = entry.source { SourceBadge(source: s) }
                    if entry.trigger == "manual" {
                        Text("manual").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(Fmt.absolute(entry.startedAt)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if let cost = entry.costUSD {
                Text(Fmt.cost(cost))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.purple)
                    .help(entry.model ?? "model usage")
            }
            if let code = entry.exitCode {
                Text("exit \(code)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(code == 0 ? Color.secondary : Color.red)
            }
            Text(Fmt.duration(entry.durationMS))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private var icon: String {
        guard let ok = entry.succeeded else { return "circle.dotted" }
        return ok ? "checkmark.circle.fill" : "xmark.circle.fill"
    }
    private var color: Color {
        guard let ok = entry.succeeded else { return .secondary }
        return ok ? .green : .red
    }
}
