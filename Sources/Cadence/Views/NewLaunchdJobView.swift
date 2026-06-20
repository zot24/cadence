import SwiftUI
import CadenceCore

struct NewLaunchdJobView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var command = ""
    @State private var mode: Mode = .interval
    @State private var intervalN = 1
    @State private var intervalUnit: Unit = .hours
    @State private var time = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    @State private var weekday = 1   // Monday
    @State private var runAtLoad = false
    @State private var adopt = true

    enum Mode: String, CaseIterable, Identifiable { case interval = "Every", daily = "Daily", weekly = "Weekly"; var id: String { rawValue } }
    enum Unit: String, CaseIterable, Identifiable { case minutes = "minutes", hours = "hours"; var id: String { rawValue } }

    private let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private var sanitizedLabel: String { LaunchdWriter.sanitizeLabel(label) }
    private var isValid: Bool {
        !sanitizedLabel.isEmpty && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("New launchd Job", systemImage: "gearshape.2").font(.headline)
                Spacer()
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Creates a user LaunchAgent in ~/Library/LaunchAgents and loads it. Runs via /bin/sh -c.")
                        .font(.caption).foregroundStyle(.secondary)

                    field("Label") {
                        TextField("com.you.my-task", text: $label).textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                        if !label.isEmpty, sanitizedLabel != label {
                            Text("Will be saved as: \(sanitizedLabel)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    field("Command") {
                        TextField("/usr/local/bin/sync.sh", text: $command, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .onChange(of: command) { _, new in
                                if label.isEmpty {
                                    label = "com.cadence." + FlueScaffold.sanitize(name: CronSource.deriveLabel(new))
                                }
                            }
                    }
                    field("Schedule") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("", selection: $mode) {
                                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()

                            switch mode {
                            case .interval:
                                HStack {
                                    Stepper(value: $intervalN, in: 1...999) { Text("Every \(intervalN)") }
                                        .frame(width: 160)
                                    Picker("", selection: $intervalUnit) {
                                        ForEach(Unit.allCases) { Text($0.rawValue).tag($0) }
                                    }.labelsHidden().frame(width: 120)
                                }
                            case .daily:
                                DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                                    .frame(width: 180)
                            case .weekly:
                                HStack {
                                    Picker("On", selection: $weekday) {
                                        ForEach(0..<7, id: \.self) { Text(weekdayNames[$0]).tag($0) }
                                    }.frame(width: 180)
                                    DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                                        .frame(width: 140)
                                }
                            }
                            Label(scheduleSummary, systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Also run at login (RunAtLoad)", isOn: $runAtLoad)
                    Toggle(isOn: $adopt) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Track runs (recommended)")
                            Text("Wrap with the recorder so Cadence counts runs, captures logs, and notifies on failure.")
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
                    model.addLaunchdJob(label: label, command: command, spec: makeSpec(), adopt: adopt)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }

    private func makeSpec() -> LaunchdWriter.ScheduleSpec {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        switch mode {
        case .interval:
            let seconds = intervalN * (intervalUnit == .minutes ? 60 : 3600)
            return .init(startInterval: seconds, runAtLoad: runAtLoad)
        case .daily:
            return .init(calendar: LaunchdCalendarInterval(minute: comps.minute, hour: comps.hour), runAtLoad: runAtLoad)
        case .weekly:
            return .init(calendar: LaunchdCalendarInterval(minute: comps.minute, hour: comps.hour, weekday: weekday), runAtLoad: runAtLoad)
        }
    }

    private var scheduleSummary: String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hm = String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
        switch mode {
        case .interval: return "Every \(intervalN) \(intervalUnit.rawValue)"
        case .daily: return "Daily at \(hm)"
        case .weekly: return "\(weekdayNames[weekday]) at \(hm)"
        }
    }

    @ViewBuilder
    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
