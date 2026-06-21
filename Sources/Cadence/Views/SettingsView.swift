import SwiftUI
import CadenceCore
import AppKit

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var roots: [URL] = JobRepository.flueRoots()
    @State private var notifyOnFail = true
    @State private var timeoutMinutes = 0
    @State private var confirmingClear = false
    @State private var triageKind: ProviderKind = .ollama
    @State private var triageModel = ""
    @State private var triageKey = ""
    @State private var triageBaseURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Settings", systemImage: "gearshape").font(.headline)
                Spacer()
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Flue Project Folders")
                    .font(.subheadline.weight(.semibold))
                Text("Folders Cadence scans (one level deep) for Flue projects to schedule.")
                    .font(.caption).foregroundStyle(.secondary)

                List {
                    ForEach(roots, id: \.self) { url in
                        HStack {
                            Image(systemName: "folder")
                            Text(url.path).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) {
                                roots.removeAll { $0 == url }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if roots.isEmpty {
                        Text("No folders configured.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button { addFolder() } label: {
                    Label("Add Folder…", systemImage: "plus")
                }

                Divider().padding(.vertical, 4)

                Text("Notifications")
                    .font(.subheadline.weight(.semibold))
                Toggle(isOn: $notifyOnFail) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notify when a tracked job fails")
                        Text("Tracked jobs post a macOS notification on a non-zero exit — so agent-triggered jobs don’t fail silently.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Send Test Notification") {
                    Notifier.post(title: "Cadence", subtitle: "Test", message: "Notifications are working.")
                }
                .font(.caption)

                Divider().padding(.vertical, 4)

                Text("Runaway Protection")
                    .font(.subheadline.weight(.semibold))
                Stepper(value: $timeoutMinutes, in: 0...720, step: 5) {
                    Text(timeoutMinutes == 0
                         ? "Max runtime: off"
                         : "Stop tracked jobs after \(timeoutMinutes) min")
                }
                Text("Kills the job’s whole process tree on timeout — so a hung agent and any subprocesses it spawned stop making calls. Applies to tracked jobs.")
                    .font(.caption).foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)

                Text("AI Triage")
                    .font(.subheadline.weight(.semibold))
                Text("Powers the “Explain with AI” button on a failed run. Local models (Ollama/LM Studio) need no key and cost nothing; xAI/Anthropic need an API key (stored in the Keychain).")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Provider", selection: $triageKind) {
                    ForEach(ProviderKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: triageKind) { _, kind in
                    if let first = ModelProvider.suggestedModels(for: kind).first { triageModel = first }
                    triageKey = model.triageKey(for: kind)
                }
                TextField("model id (e.g. grok-4, llama3.2:3b)", text: $triageModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                if !triageKind.isLocal {
                    SecureField(triageKind == .anthropic ? "ANTHROPIC_API_KEY" : "API key", text: $triageKey)
                        .textFieldStyle(.roundedBorder)
                }
                if triageKind == .openAICompatible {
                    TextField("base URL (http://host:port/v1)", text: $triageBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }
                Text(triageKind == .xai
                     ? "Tip: an xAI key is created at console.x.ai (pay-per-token). A SuperGrok subscription is separate."
                     : (triageKind.isLocal ? "No key needed — just make sure the local server is running." : ""))
                    .font(.caption2).foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)

                Text("Storage")
                    .font(.subheadline.weight(.semibold))
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([CadencePaths.supportDirectory])
                } label: {
                    Label("Reveal Data Folder", systemImage: "folder")
                }
                .font(.caption)
                Text("Run history (cadence.db), the recorder shim, and per-run logs live here.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button(role: .destructive) { confirmingClear = true } label: {
                    Label("Clear Run History…", systemImage: "trash")
                }
                .font(.caption)
            }
            .padding()

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    JobRepository.setFlueRoots(roots)
                    model.setNotifyOnFail(notifyOnFail)
                    model.setTimeoutMinutes(timeoutMinutes)
                    model.triageProviderKind = triageKind   // set kind first…
                    model.triageModelID = triageModel
                    model.triageBaseURL = triageBaseURL
                    model.triageAPIKey = triageKey          // …so the key stores under it
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 760)
        .confirmationDialog("Clear all run history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { model.clearRunHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes recorded runs and captured logs. Your jobs and schedules are not affected.")
        }
        .onAppear {
            notifyOnFail = model.getNotifyOnFail()
            timeoutMinutes = model.getTimeoutMinutes()
            triageKind = model.triageProviderKind
            triageModel = model.triageModelID
            triageBaseURL = model.triageBaseURL
            triageKey = model.triageAPIKey
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !roots.contains(url) {
                roots.append(url)
            }
        }
    }
}
