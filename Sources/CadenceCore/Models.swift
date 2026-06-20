import Foundation

/// Where a job is defined / who runs it.
public enum JobSource: String, Codable, CaseIterable, Sendable {
    case cron       // classic Unix crontab (`crontab -l`)
    case launchd    // macOS LaunchAgents / LaunchDaemons
    case flue       // a Flue agent or workflow we schedule + observe

    public var displayName: String {
        switch self {
        case .cron: return "Cron"
        case .launchd: return "launchd"
        case .flue: return "Flue"
        }
    }

    public var symbolName: String {
        switch self {
        case .cron: return "calendar.badge.clock"
        case .launchd: return "gearshape.2"
        case .flue: return "sparkles"
        }
    }
}

/// For launchd jobs, which domain the plist lives in.
public enum LaunchdDomain: String, Codable, Sendable {
    case userAgent          // ~/Library/LaunchAgents
    case globalAgent        // /Library/LaunchAgents
    case systemDaemon       // /Library/LaunchDaemons

    public var displayName: String {
        switch self {
        case .userAgent: return "User Agent"
        case .globalAgent: return "Global Agent"
        case .systemDaemon: return "System Daemon"
        }
    }
}

/// The schedule, normalised across sources. We keep the raw form plus a
/// human-readable summary so the UI never has to re-derive it.
public struct JobSchedule: Codable, Hashable, Sendable {
    /// Raw cron expression, e.g. "*/5 * * * *" (cron jobs).
    public var cronExpression: String?
    /// launchd StartInterval in seconds.
    public var startInterval: Int?
    /// launchd StartCalendarInterval entries (minute/hour/day/weekday/month).
    public var calendarIntervals: [LaunchdCalendarInterval]
    /// True if the job runs at load (RunAtLoad) or on login.
    public var runAtLoad: Bool
    /// True if it's a long-running daemon (KeepAlive) rather than a periodic task.
    public var keepAlive: Bool
    /// A precomputed human description, e.g. "Every 5 minutes".
    public var summary: String

    public init(cronExpression: String? = nil,
                startInterval: Int? = nil,
                calendarIntervals: [LaunchdCalendarInterval] = [],
                runAtLoad: Bool = false,
                keepAlive: Bool = false,
                summary: String = "") {
        self.cronExpression = cronExpression
        self.startInterval = startInterval
        self.calendarIntervals = calendarIntervals
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.summary = summary
    }
}

public struct LaunchdCalendarInterval: Codable, Hashable, Sendable {
    public var minute: Int?
    public var hour: Int?
    public var day: Int?
    public var weekday: Int?
    public var month: Int?

    public init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, weekday: Int? = nil, month: Int? = nil) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.weekday = weekday
        self.month = month
    }
}

/// Live runtime status, where the OS exposes it.
public enum JobRuntimeStatus: String, Codable, Sendable {
    case running        // currently executing (has a PID)
    case idle           // loaded/scheduled, not currently running
    case disabled       // present but disabled / unloaded
    case errored        // last run exited non-zero
    case unknown

    public var displayName: String {
        switch self {
        case .running: return "Running"
        case .idle: return "Idle"
        case .disabled: return "Disabled"
        case .errored: return "Failed"
        case .unknown: return "Unknown"
        }
    }
}

/// The unified job representation the whole app speaks.
public struct Job: Identifiable, Hashable, Sendable {
    /// Stable identity: "<source>:<naturalKey>" (e.g. "launchd:com.foo.bar",
    /// "cron:<sha of line>", "flue:<project>/<agent>"). Used as the DB key.
    public var id: String
    public var source: JobSource
    public var label: String
    /// The command/program the job runs (best-effort, human readable).
    public var command: String
    public var schedule: JobSchedule
    public var enabled: Bool
    public var status: JobRuntimeStatus

    // launchd specifics
    public var launchdDomain: LaunchdDomain?
    public var plistPath: String?
    public var pid: Int?
    public var lastExitCode: Int?

    // cron specifics
    public var cronLine: String?
    public var cronUser: String?

    // flue specifics
    public var flueProjectPath: String?
    public var flueAgentName: String?
    public var flueIsWorkflow: Bool
    public var flueModel: String?     // the agent's model id, read from its source
    public var flueGoal: String?      // the agent's instructions/goal, read from its source

    /// True if Cadence wrapped this job with the recorder shim (so we have
    /// full run-count + log history for it).
    public var isAdopted: Bool
    /// Heuristic: looks like it was created by an AI/automation agent.
    public var isAgentCreated: Bool
    /// Evidence-based origin: which tool is behind the job, why, and confidence.
    public var origin: JobOrigin
    /// Static safety analysis (lethal-trifecta-style flags).
    public var risk: JobRisk
    /// Convenience: the origin's category.
    public var provenance: JobProvenance { origin.category }

    public init(id: String,
                source: JobSource,
                label: String,
                command: String,
                schedule: JobSchedule,
                enabled: Bool,
                status: JobRuntimeStatus = .unknown,
                launchdDomain: LaunchdDomain? = nil,
                plistPath: String? = nil,
                pid: Int? = nil,
                lastExitCode: Int? = nil,
                cronLine: String? = nil,
                cronUser: String? = nil,
                flueProjectPath: String? = nil,
                flueAgentName: String? = nil,
                flueIsWorkflow: Bool = false,
                flueModel: String? = nil,
                flueGoal: String? = nil,
                isAdopted: Bool = false,
                isAgentCreated: Bool = false,
                origin: JobOrigin = JobOrigin(),
                risk: JobRisk = JobRisk(flags: [])) {
        self.id = id
        self.source = source
        self.label = label
        self.command = command
        self.schedule = schedule
        self.enabled = enabled
        self.status = status
        self.launchdDomain = launchdDomain
        self.plistPath = plistPath
        self.pid = pid
        self.lastExitCode = lastExitCode
        self.cronLine = cronLine
        self.cronUser = cronUser
        self.flueProjectPath = flueProjectPath
        self.flueAgentName = flueAgentName
        self.flueIsWorkflow = flueIsWorkflow
        self.flueModel = flueModel
        self.flueGoal = flueGoal
        self.isAdopted = isAdopted
        self.isAgentCreated = isAgentCreated
        self.origin = origin
        self.risk = risk
    }
}

/// One recorded execution of a job (written by the recorder shim).
public struct JobRun: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var jobID: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var exitCode: Int?
    public var durationMS: Int?
    public var stdoutPath: String?
    public var stderrPath: String?
    public var trigger: String   // "schedule" | "manual"
    public var usage: Usage

    public init(id: Int64,
                jobID: String,
                startedAt: Date,
                finishedAt: Date? = nil,
                exitCode: Int? = nil,
                durationMS: Int? = nil,
                stdoutPath: String? = nil,
                stderrPath: String? = nil,
                trigger: String = "schedule",
                usage: Usage = Usage()) {
        self.id = id
        self.jobID = jobID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.durationMS = durationMS
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
        self.trigger = trigger
        self.usage = usage
    }

    public var succeeded: Bool? {
        guard let exitCode else { return nil }
        return exitCode == 0
    }
}

/// One row in the cross-job audit timeline (a run joined with its job identity).
public struct ActivityEntry: Identifiable, Hashable, Sendable {
    public var id: Int64          // run id
    public var jobID: String
    public var label: String
    public var source: JobSource?
    public var startedAt: Date
    public var finishedAt: Date?
    public var exitCode: Int?
    public var durationMS: Int?
    public var trigger: String
    public var model: String?
    public var costUSD: Double?

    public init(id: Int64, jobID: String, label: String, source: JobSource?,
                startedAt: Date, finishedAt: Date?, exitCode: Int?, durationMS: Int?, trigger: String,
                model: String? = nil, costUSD: Double? = nil) {
        self.id = id
        self.jobID = jobID
        self.label = label
        self.source = source
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.durationMS = durationMS
        self.trigger = trigger
        self.model = model
        self.costUSD = costUSD
    }

    public var succeeded: Bool? { exitCode.map { $0 == 0 } }
}

/// Aggregated run statistics for a job, surfaced in the UI.
public struct JobStats: Hashable, Sendable {
    public var jobID: String
    public var totalRuns: Int
    public var successCount: Int
    public var failureCount: Int
    public var lastRun: Date?
    public var lastExitCode: Int?
    public var avgDurationMS: Int?
    public var totalCostUSD: Double
    public var totalTokens: Int

    public init(jobID: String,
                totalRuns: Int = 0,
                successCount: Int = 0,
                failureCount: Int = 0,
                lastRun: Date? = nil,
                lastExitCode: Int? = nil,
                avgDurationMS: Int? = nil,
                totalCostUSD: Double = 0,
                totalTokens: Int = 0) {
        self.jobID = jobID
        self.totalRuns = totalRuns
        self.successCount = successCount
        self.failureCount = failureCount
        self.lastRun = lastRun
        self.lastExitCode = lastExitCode
        self.avgDurationMS = avgDurationMS
        self.totalCostUSD = totalCostUSD
        self.totalTokens = totalTokens
    }

    public var successRate: Double? {
        guard totalRuns > 0 else { return nil }
        return Double(successCount) / Double(totalRuns)
    }
}
