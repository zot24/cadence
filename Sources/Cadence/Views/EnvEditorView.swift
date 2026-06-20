import SwiftUI
import CadenceCore

/// Edit a launchd job's environment variables — the fix for the most common
/// scheduled-agent failure: API keys that live in the shell profile (which
/// launchd never loads), so the job runs without them.
struct EnvEditorView: View {
    @Bindable var model: AppModel
    let job: Job
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [Row] = []
    @State private var revealed = false

    struct Row: Identifiable { let id = UUID(); var key: String; var value: String }

    private var isFlue: Bool { job.flueProjectPath != nil }
    private var isCron: Bool { job.flueProjectPath == nil && job.source == .cron }
    private var backendNote: String {
        if isFlue {
            return "Set keys this agent needs at run time (e.g. ANTHROPIC_API_KEY). Written to the project’s .env — how Flue loads keys."
        }
        if isCron {
            return "Set keys the job needs at run time (e.g. ANTHROPIC_API_KEY). Prepended to the cron command as KEY=val (cron doesn’t read your shell profile). Values with spaces aren’t supported inline."
        }
        return "Set keys the job needs at run time (e.g. ANTHROPIC_API_KEY). launchd doesn’t read your shell profile, so keys must live here."
    }
    private var storageNote: String {
        JobRepository.envBackend(job).map { "Stored in \($0) (plaintext)." } ?? "Plaintext."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Environment — \(job.label)", systemImage: "key.fill").font(.headline)
                Spacer()
                Toggle("Reveal values", isOn: $revealed).toggleStyle(.checkbox).font(.caption)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(backendNote)
                        .font(.caption).foregroundStyle(.secondary)

                    if rows.isEmpty {
                        Text("No environment variables set.").font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach($rows) { $row in
                        HStack(spacing: 8) {
                            TextField("KEY", text: $row.key)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                                .frame(width: 180)
                            Group {
                                if revealed {
                                    TextField("value", text: $row.value)
                                } else {
                                    SecureField("value", text: $row.value)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            Button(role: .destructive) {
                                rows.removeAll { $0.id == row.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button { rows.append(Row(key: "", value: "")) } label: {
                        Label("Add Variable", systemImage: "plus")
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Text(storageNote).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var env: [String: String] = [:]
                    for r in rows {
                        let k = r.key.trimmingCharacters(in: .whitespaces)
                        if !k.isEmpty { env[k] = r.value }
                    }
                    model.setJobEnvironment(job, env: env)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 460)
        .onAppear {
            rows = model.jobEnvironment(job)
                .sorted { $0.key < $1.key }
                .map { Row(key: $0.key, value: $0.value) }
        }
    }
}
