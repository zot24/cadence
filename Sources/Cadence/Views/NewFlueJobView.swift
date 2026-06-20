import SwiftUI
import CadenceCore

struct NewFlueJobView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var projects: [FlueProject] = []
    @State private var loading = true
    @State private var selectedProjectID: String?
    @State private var selectedAgentID: String?
    @State private var cronExpr = "0 9 * * *"

    private var selectedProject: FlueProject? { projects.first { $0.id == selectedProjectID } }
    private var agents: [FlueAgent] { selectedProject?.agents ?? [] }
    private var selectedAgent: FlueAgent? { agents.first { $0.id == selectedAgentID } }
    private var isValid: Bool { selectedAgent != nil && CronExpression(cronExpr) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Schedule Flue Agent", systemImage: "sparkles").font(.headline)
                Spacer()
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if loading {
                        HStack { ProgressView().controlSize(.small); Text("Scanning for Flue projects…") }
                            .foregroundStyle(.secondary)
                    } else if projects.isEmpty {
                        emptyState
                    } else {
                        projectPicker
                        agentPicker
                        if selectedAgent != nil { schedulePicker; commandPreview }
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Button("Manage Folders…") { model.showingSettings = true }
                    .buttonStyle(.link)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Schedule") {
                    if let agent = selectedAgent {
                        model.scheduleFlue(agent, schedule: cronExpr)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 520, height: 540)
        .task { await loadProjects() }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView(model: model)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            ContentUnavailableView {
                Label("No Flue Projects Found", systemImage: "sparkles")
            } description: {
                Text("Cadence looks for folders with a flue.config.ts or an agents/ directory in your code folders. Add a folder to search in Settings.")
            }
            Button("Choose Folder…") { model.showingSettings = true }
        }
    }

    private var projectPicker: some View {
        field("Project") {
            Picker("", selection: $selectedProjectID) {
                ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .onChange(of: selectedProjectID) { _, _ in selectedAgentID = agents.first?.id }
        }
    }

    private var agentPicker: some View {
        field("Agent / Workflow") {
            if agents.isEmpty {
                Text("No agents or workflows in this project.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("", selection: $selectedAgentID) {
                    ForEach(agents) { agent in
                        Text(agent.name + (agent.isWorkflow ? "  (workflow)" : "")).tag(Optional(agent.id))
                    }
                }
                .labelsHidden()
            }
        }
    }

    private var schedulePicker: some View {
        field("Schedule") {
            VStack(alignment: .leading, spacing: 8) {
                PresetChips(selected: cronExpr) { cronExpr = $0 }
                TextField("0 9 * * *", text: $cronExpr)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                SchedulePreview(cronExpr: cronExpr)
            }
        }
    }

    @ViewBuilder
    private var commandPreview: some View {
        if let agent = selectedAgent {
            field("Will run") {
                Text(FlueSource.command(for: agent))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                Text("Scheduled as a tracked cron job — Cadence records runs; Flue keeps its own durable logs too.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func loadProjects() async {
        loading = true
        // Grab the Sendable repository on the main actor, then scan off-thread.
        let repo = model.repo
        let found = await Task.detached(priority: .userInitiated) {
            repo?.discoverFlueProjects() ?? []
        }.value
        self.projects = found
        self.selectedProjectID = found.first?.id
        self.selectedAgentID = found.first?.agents.first?.id
        self.loading = false
    }

    @ViewBuilder
    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
