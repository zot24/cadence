import SwiftUI
import CadenceCore

struct SchedulePreset: Identifiable {
    let id = UUID()
    let title: String
    let expr: String
}

let schedulePresets: [SchedulePreset] = [
    .init(title: "Every minute", expr: "* * * * *"),
    .init(title: "Every 5 min", expr: "*/5 * * * *"),
    .init(title: "Every 15 min", expr: "*/15 * * * *"),
    .init(title: "Hourly", expr: "0 * * * *"),
    .init(title: "Daily 9am", expr: "0 9 * * *"),
    .init(title: "Weekdays 8am", expr: "0 8 * * 1-5"),
    .init(title: "Weekly Mon", expr: "0 9 * * 1"),
    .init(title: "Monthly 1st", expr: "0 0 1 * *"),
]

/// Wrapping grid of schedule preset chips.
struct PresetChips: View {
    let selected: String
    let onPick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(schedulePresets) { p in
                Button { onPick(p.expr) } label: {
                    Text(p.title).font(.caption).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(p.expr == selected ? .accentColor : .secondary)
            }
        }
    }
}

/// Live "this is what your cron expression means + next runs" preview.
struct SchedulePreview: View {
    let cronExpr: String

    var body: some View {
        if let parsed = CronExpression(cronExpr) {
            VStack(alignment: .leading, spacing: 4) {
                Label(CronHumanizer.describe(cronExpr), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                let next = parsed.nextRuns(after: Date(), count: 3)
                if !next.isEmpty {
                    Text("Next: " + next.map { Fmt.relative($0) }.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            Label("Not a valid 5-field cron expression", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

struct NewCronJobView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var cronExpr = "*/15 * * * *"
    @State private var command = ""
    @State private var label = ""
    @State private var adopt = true

    private var isValid: Bool {
        CronExpression(cronExpr) != nil && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("New Cron Job", systemImage: "calendar.badge.plus").font(.headline)
                Spacer()
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Command") {
                        TextField("/usr/local/bin/backup.sh", text: $command, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .onChange(of: command) { _, new in
                                if label.isEmpty { label = CronSource.deriveLabel(new) }
                            }
                    }
                    field("Name (optional)") {
                        TextField("Backup", text: $label).textFieldStyle(.roundedBorder)
                    }
                    field("Schedule") {
                        VStack(alignment: .leading, spacing: 8) {
                            PresetChips(selected: cronExpr) { cronExpr = $0 }
                            TextField("*/15 * * * *", text: $cronExpr)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                            SchedulePreview(cronExpr: cronExpr)
                        }
                    }
                    Toggle(isOn: $adopt) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Track runs (recommended)")
                            Text("Wrap the command so Cadence records run count, logs, and exit codes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Job") {
                    let name = label.trimmingCharacters(in: .whitespaces)
                    model.addCronJob(schedule: cronExpr, command: command,
                                     label: name.isEmpty ? nil : name, adopt: adopt)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }

    @ViewBuilder
    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
