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
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
        .confirmationDialog("Clear all run history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { model.clearRunHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes recorded runs and captured logs. Your jobs and schedules are not affected.")
        }
        .onAppear {
            notifyOnFail = model.getNotifyOnFail()
            timeoutMinutes = model.getTimeoutMinutes()
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
