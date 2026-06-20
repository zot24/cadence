import Foundation

/// A ready-to-use, model-backed agent job: a goal + a sensible schedule. Lets a
/// user create a scheduled Flue agent in two clicks instead of from a blank box.
public struct AgentTemplate: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var title: String
    public var name: String          // agent slug
    public var instructions: String
    public var suggestedCron: String
    public var symbol: String

    public init(title: String, name: String, instructions: String, suggestedCron: String, symbol: String) {
        self.title = title
        self.name = name
        self.instructions = instructions
        self.suggestedCron = suggestedCron
        self.symbol = symbol
    }
}

public enum AgentTemplates {
    public static let all: [AgentTemplate] = [
        AgentTemplate(
            title: "News digest",
            name: "news-digest",
            instructions: "Summarize the most important developments in the topics I care about over the last 24 hours. Write a concise, skimmable digest with sources to ~/Cadence/news-digest.md.",
            suggestedCron: "0 8 * * *",
            symbol: "newspaper"),
        AgentTemplate(
            title: "Inbox triage",
            name: "inbox-triage",
            instructions: "Review my unread emails and notifications, group them by urgency, and produce a prioritized action list. Flag anything that needs a reply today.",
            suggestedCron: "0 9 * * 1-5",
            symbol: "tray.and.arrow.down"),
        AgentTemplate(
            title: "Repo watcher",
            name: "repo-watcher",
            instructions: "Check my GitHub repositories for new issues, pull requests, and CI failures that need attention. Summarize what changed and what I should look at first.",
            suggestedCron: "0 */2 * * *",
            symbol: "chevron.left.forwardslash.chevron.right"),
        AgentTemplate(
            title: "Standup summary",
            name: "standup-summary",
            instructions: "Summarize what changed across my active projects since yesterday (commits, merged PRs, closed issues) into a short standup update I can paste into Slack.",
            suggestedCron: "30 8 * * 1-5",
            symbol: "person.3"),
        AgentTemplate(
            title: "Backup verifier",
            name: "backup-verifier",
            instructions: "Verify that last night's backups completed successfully. Check timestamps and sizes, and clearly flag anything missing, stale, or smaller than expected.",
            suggestedCron: "0 7 * * *",
            symbol: "externaldrive.badge.checkmark"),
        AgentTemplate(
            title: "Spend watcher",
            name: "spend-watcher",
            instructions: "Summarize my agent and API spend over the last 24 hours. Warn me if it is trending above budget and identify which job is driving the cost.",
            suggestedCron: "0 21 * * *",
            symbol: "dollarsign.circle"),
    ]
}
