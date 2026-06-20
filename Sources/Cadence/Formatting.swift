import SwiftUI
import CadenceCore

/// Shared formatting helpers and small reusable views.
enum Fmt {
    static func relative(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func absolute(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }

    static func duration(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        if ms < 1000 { return "\(ms) ms" }
        let s = Double(ms) / 1000.0
        if s < 60 { return String(format: "%.1f s", s) }
        let m = Int(s) / 60, rem = Int(s) % 60
        return "\(m)m \(rem)s"
    }

    static func percent(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return String(format: "%.0f%%", rate * 100)
    }

    static func cost(_ usd: Double) -> String {
        if usd == 0 { return "$0" }
        return usd >= 1 ? String(format: "$%.2f", usd) : String(format: "$%.4f", usd)
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

/// A coloured status dot for a job's runtime state.
struct StatusDot: View {
    let status: JobRuntimeStatus
    let enabled: Bool

    var color: Color {
        if !enabled { return .secondary }
        switch status {
        case .running: return .blue
        case .idle: return .green
        case .errored: return .red
        case .disabled: return .secondary
        case .unknown: return .yellow
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(
                Circle().stroke(color.opacity(0.35), lineWidth: 3)
                    .scaleEffect(status == .running ? 1.6 : 1.0)
            )
            .help(enabled ? status.displayName : "Disabled")
    }
}

/// A pill badge for a job source.
struct SourceBadge: View {
    let source: JobSource
    var body: some View {
        Label(source.displayName, systemImage: source.symbolName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

extension JobProvenance {
    var color: Color {
        switch self {
        case .flue: return .purple
        case .aiAgent: return .pink
        case .automation: return .teal
        case .packageManager: return .orange
        case .system: return .gray
        case .user: return .secondary
        }
    }
}

extension RiskSeverity {
    var color: Color {
        switch self {
        case .high: return .red
        case .medium: return .orange
        case .low: return .yellow
        case .none: return .secondary
        }
    }
}

/// A capsule tag showing what's behind a job — the detected tool name
/// (e.g. "Hermes", "Homebrew") with the category's color.
struct ProvenanceTag: View {
    let origin: JobOrigin
    var body: some View {
        Label(origin.label, systemImage: origin.category.symbolName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(origin.category.color)
            .background(origin.category.color.opacity(0.12), in: Capsule())
    }
}

/// A small labelled stat used in the detail header.
struct StatTile: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
