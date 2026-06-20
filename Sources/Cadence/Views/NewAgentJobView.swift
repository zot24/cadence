import SwiftUI
import CadenceCore
import AppKit

/// Create a *new* model-backed Flue agent and schedule it as a local cron job —
/// a scheduled task whose logic is an LLM agent running on a schedule.
struct NewAgentJobView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var modelID = FlueScaffold.defaultModel
    @State private var instructions = ""
    @State private var cronExpr = "0 9 * * *"

    @State private var projects: [FlueProject] = []
    @State private var loading = true
    @State private var targetPath: String?       // a discovered project
    @State private var customURL: URL?            // a folder the user picked

    private var targetURL: URL? {
        customURL ?? targetPath.map { URL(fileURLWithPath: $0) }
    }
    private var needsSetup: Bool {
        guard let url = targetURL else { return false }
        return !FlueSource.isFlueProject(url)
    }
    private var isValid: Bool {
        !FlueScaffold.sanitize(name: name).isEmpty
        && !instructions.trimmingCharacters(in: .whitespaces).isEmpty
        && !modelID.trimmingCharacters(in: .whitespaces).isEmpty
        && targetURL != nil
        && CronExpression(cronExpr) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("New Agent Job", systemImage: "brain.head.profile").font(.headline)
                Spacer()
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Cadence scaffolds a Flue agent (a model + instructions) and schedules it to run locally on a cron schedule. Each run is tracked.")
                        .font(.caption).foregroundStyle(.secondary)

                    Menu {
                        ForEach(AgentTemplates.all) { t in
                            Button { apply(t) } label: { Label(t.title, systemImage: t.symbol) }
                        }
                    } label: {
                        Label("Start from a template", systemImage: "sparkles.rectangle.stack")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    field("Agent name") {
                        TextField("daily-news-digest", text: $name).textFieldStyle(.roundedBorder)
                        if !name.isEmpty {
                            Text("Runs as: npx flue run \(FlueScaffold.sanitize(name: name))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    field("Model") {
                        Picker("", selection: $modelID) {
                            ForEach(FlueScaffold.suggestedModels, id: \.self) { Text($0).tag($0) }
                            if !FlueScaffold.suggestedModels.contains(modelID) {
                                Text(modelID).tag(modelID)
                            }
                        }
                        .labelsHidden()
                        TextField("provider/model-id", text: $modelID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }

                    field("Instructions (what the agent should do)") {
                        TextEditor(text: $instructions)
                            .font(.system(.callout))
                            .frame(height: 90)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        if instructions.isEmpty {
                            Text("e.g. “Summarize my unread GitHub notifications and write the digest to ~/news.md.”")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    field("Project") {
                        projectControls
                    }

                    field("Schedule") {
                        VStack(alignment: .leading, spacing: 8) {
                            PresetChips(selected: cronExpr) { cronExpr = $0 }
                            TextField("0 9 * * *", text: $cronExpr)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                            SchedulePreview(cronExpr: cronExpr)
                        }
                    }

                    if needsSetup, let url = targetURL {
                        setupNotice(url)
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Agent Job") {
                    if let url = targetURL {
                        model.createAgentJob(project: url, name: name, model: modelID,
                                             instructions: instructions, schedule: cronExpr,
                                             scaffoldWorkspace: needsSetup)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 560, height: 640)
        .task { await loadProjects() }
    }

    @ViewBuilder
    private var projectControls: some View {
        if loading {
            HStack { ProgressView().controlSize(.small); Text("Finding Flue projects…").foregroundStyle(.secondary) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !projects.isEmpty {
                    Picker("", selection: Binding(
                        get: { customURL == nil ? targetPath : nil },
                        set: { targetPath = $0; customURL = nil }
                    )) {
                        ForEach(projects) { Text($0.name).tag(Optional($0.path)) }
                    }
                    .labelsHidden()
                }
                HStack {
                    Button(projects.isEmpty ? "Choose Folder…" : "Use Another Folder…") { pickFolder() }
                    if let customURL {
                        Text(customURL.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func setupNotice(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("New workspace — one-time setup needed", systemImage: "info.circle")
                .font(.caption.weight(.medium)).foregroundStyle(.orange)
            Text("Cadence will create a Flue project here. Before the first run, install deps and set your API key:")
                .font(.caption2).foregroundStyle(.secondary)
            Text(FlueScaffold.setupCommand(for: url))
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(8)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            customURL = url
        }
    }

    private func apply(_ t: AgentTemplate) {
        name = t.name
        instructions = t.instructions
        cronExpr = t.suggestedCron
    }

    private func loadProjects() async {
        let repo = model.repo
        let found = await Task.detached(priority: .userInitiated) { repo?.discoverFlueProjects() ?? [] }.value
        self.projects = found
        self.targetPath = found.first?.path
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
