import SwiftUI
import CadenceCore

struct MainWindowView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } content: {
            JobListView(model: model)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
        } detail: {
            if let record = model.selectedRecord {
                JobDetailView(model: model, record: record)
                    .id(record.id)
            } else {
                ContentUnavailableView(
                    "No Job Selected",
                    systemImage: "calendar.badge.clock",
                    description: Text("Pick a job to see its schedule, run history, and logs.")
                )
            }
        }
        .navigationTitle("Cadence")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("New Cron Job…", systemImage: "calendar.badge.plus") { model.showingNewCron = true }
                    Button("New launchd Job…", systemImage: "gearshape.2") { model.showingNewLaunchd = true }
                    Button("New Agent Job…", systemImage: "brain.head.profile") { model.showingNewAgent = true }
                    Button("Schedule Flue Agent…", systemImage: "sparkles") { model.showingNewFlue = true }
                } label: {
                    Label("Add Job", systemImage: "plus")
                }
                .help("Add a new scheduled job")

                Menu {
                    let n = model.untrackedAgentJobs.count
                    Button("Track All Agent Jobs (\(n))") { model.bulkTrackAgents() }
                        .disabled(n == 0)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Bulk actions")

                Button {
                    model.showingActivity = true
                } label: {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }
                .help("Audit timeline of all runs")

                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload jobs")
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search jobs")
        .sheet(isPresented: $model.showingNewCron) {
            NewCronJobView(model: model)
        }
        .sheet(isPresented: $model.showingNewFlue) {
            NewFlueJobView(model: model)
        }
        .sheet(isPresented: $model.showingNewLaunchd) {
            NewLaunchdJobView(model: model)
        }
        .sheet(isPresented: $model.showingNewAgent) {
            NewAgentJobView(model: model)
        }
        .sheet(isPresented: $model.showingActivity) {
            ActivityView(model: model)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.lastError ?? "")
        }
        .onAppear { model.refresh() }
    }
}
