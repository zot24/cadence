import SwiftUI
import CadenceCore

/// A compact, always-on strip of tappable fleet stats above the job list —
/// the control-plane glance: how many jobs, how many are AI agents, how many
/// are failing or risky, and total spend.
struct SummaryBar: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                chip("Jobs", "\(model.records.count)", .accentColor, "tray.full") { model.filter = .all }
                chip("Agents", "\(model.agentCount)", .pink, "brain.head.profile") { model.filter = .agentCreated }
                if model.failingCount > 0 {
                    chip("Failing", "\(model.failingCount)", .red, "exclamationmark.triangle.fill") { model.filter = .failing }
                }
                if model.atRiskCount > 0 {
                    chip("Risk", "\(model.atRiskCount)", .orange, "exclamationmark.shield.fill") { model.filter = .risky }
                }
                if model.totalSpendUSD > 0 {
                    chip("Spend", Fmt.cost(model.totalSpendUSD), .purple, "dollarsign.circle.fill") { model.showingActivity = true }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func chip(_ title: String, _ value: String, _ tint: Color, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption2).foregroundStyle(tint)
                Text(value).font(.callout.weight(.semibold).monospacedDigit())
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Show \(title)")
    }
}
