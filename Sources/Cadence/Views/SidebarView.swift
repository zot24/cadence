import SwiftUI
import CadenceCore

struct SidebarView: View {
    @Bindable var model: AppModel

    private let primary: [JobFilter] = [.all, .source(.cron), .source(.launchd), .source(.flue)]
    private let secondary: [JobFilter] = [.agentCreated, .adopted, .failing, .risky]

    var body: some View {
        List(selection: Binding(
            get: { model.filter },
            set: { if let f = $0 { model.filter = f } }
        )) {
            Section("Sources") {
                ForEach(primary) { row(for: $0) }
            }
            Section("Views") {
                ForEach(secondary) { row(for: $0) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Divider()
                HStack {
                    Image(systemName: "number")
                        .foregroundStyle(.secondary)
                    Text("\(model.totalRunCount) total runs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("Settings")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView(model: model)
        }
    }

    @ViewBuilder
    private func row(for filter: JobFilter) -> some View {
        Label {
            HStack {
                Text(filter.title)
                Spacer()
                let n = model.count(for: filter)
                if n > 0 {
                    Text("\(n)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(filter == .failing ? .red : .secondary)
                }
            }
        } icon: {
            Image(systemName: filter.symbol)
                .foregroundStyle(filter == .failing && model.failingCount > 0 ? .red : .accentColor)
        }
        .tag(filter)
    }
}
