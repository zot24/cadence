import SwiftUI
import CadenceCore

/// Entry point: a `--report`/`--json` flag runs the headless inventory and exits;
/// otherwise the SwiftUI app launches normally.
@main
enum CadenceEntry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") { CadenceCLI.printUsage(); exit(0) }
        if args.contains("--check") { CadenceCLI.check() }   // exits with health status
        if args.contains("--report") || args.contains("--json") {
            CadenceCLI.run(json: args.contains("--json"))
            exit(0)
        }
        CadenceApp.main()
    }
}

struct CadenceApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Cadence", id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 900, minHeight: 580)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Cron Job…") { model.showingNewCron = true; openMain() }
                    .keyboardShortcut("n")
                Button("New Agent Job…") { model.showingNewAgent = true; openMain() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Schedule Flue Agent…") { model.showingNewFlue = true; openMain() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Activity…") { model.showingActivity = true; openMain() }
                    .keyboardShortcut("l")
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // Show the failing-job count in the menu bar when something needs attention.
            if model.failingCount > 0 {
                Label("\(model.failingCount)", systemImage: "calendar.badge.exclamationmark")
            } else {
                Image(systemName: "calendar.badge.clock")
            }
        }
        .menuBarExtraStyle(.window)
    }

    private func openMain() {
        // Best-effort: bring the app forward so the sheet is visible.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
