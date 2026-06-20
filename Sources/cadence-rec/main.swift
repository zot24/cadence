import Foundation
import Darwin
import CadenceCore

// cadence-rec — the recorder shim.
//
// Adopted jobs have their command rewritten to:
//   cadence-rec --job <id> --label <label> --source <cron|launchd|flue> [--trigger <t>] -- <real command...>
//
// It records the run (start/finish/exit code/duration) into the Cadence run
// store, captures stdout+stderr to per-run log files, and exits with the
// child's exit code so cron/launchd observe the true result.

struct Args {
    var jobID: String?
    var label: String?
    var source: String = "cron"
    var trigger: String = "schedule"
    var timeout: Int = 0   // seconds; 0 = use the configured default (or none)
    var command: [String] = []
}

func parseArgs() -> Args {
    var args = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--job": args.jobID = it.next()
        case "--label": args.label = it.next()
        case "--source": args.source = it.next() ?? "cron"
        case "--trigger": args.trigger = it.next() ?? "schedule"
        case "--timeout": args.timeout = it.next().flatMap { Int($0) } ?? 0
        case "--":
            // Everything after `--` is the command to run.
            while let c = it.next() { args.command.append(c) }
        default:
            break
        }
    }
    return args
}

let args = parseArgs()

guard let jobID = args.jobID, !args.command.isEmpty else {
    FileHandle.standardError.write(Data("cadence-rec: usage: --job <id> [--label <l>] [--source <s>] [--trigger <t>] -- <command...>\n".utf8))
    exit(64)
}

let store: RunStore
do {
    store = try RunStore()
} catch {
    // Never block the real job because our bookkeeping failed — run it raw.
    FileHandle.standardError.write(Data("cadence-rec: store unavailable (\(error)); running unrecorded\n".utf8))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", args.command.joined(separator: " ")]
    try? p.run()
    p.waitUntilExit()
    exit(p.terminationStatus)
}

let source = JobSource(rawValue: args.source) ?? .cron
let label = args.label ?? jobID
let commandString = args.command.joined(separator: " ")

store.touchJob(id: jobID, source: source, label: label, command: commandString, adopted: true)

// Start the run first so we can name log files by the unique run id — wall-clock
// seconds collide when a job runs twice in the same second.
let started = Date()
let runID = store.startRun(jobID: jobID, startedAt: started, trigger: args.trigger,
                           stdoutPath: nil, stderrPath: nil)

// Per-run log files: ~/Library/Application Support/Cadence/logs/<jobID>/<runID>.{out,err}
let logDir = CadencePaths.logDirectory(forJob: jobID)
try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
let stdoutURL = logDir.appendingPathComponent("\(runID).out")
let stderrURL = logDir.appendingPathComponent("\(runID).err")
FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
store.setRunLogPaths(id: runID, stdoutPath: stdoutURL.path, stderrPath: stderrURL.path)

// Effective timeout: explicit --timeout wins, else the configured default.
let effectiveTimeout = args.timeout > 0
    ? args.timeout
    : store.intSetting(CadenceSettingsKey.defaultTimeoutSeconds, default: 0)
let guarded = effectiveTimeout > 0

let process = Process()
if guarded {
    // Run the command as a process-group LEADER (via Perl's setpgrp) so a
    // timeout can kill the WHOLE tree — orphaned grandchildren that keep making
    // API calls are the real cost/safety leak for unattended agent jobs.
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = ["-e", "setpgrp(0,0); exec @ARGV or die \"exec failed: $!\"",
                         "--", "/bin/sh", "-c", commandString]
} else {
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", commandString]
}
if let out = try? FileHandle(forWritingTo: stdoutURL) { process.standardOutput = out }
if let err = try? FileHandle(forWritingTo: stderrURL) { process.standardError = err }

let stateLock = NSLock()
var finishedFlag = false
var timedOut = false
var exitCode: Int32 = -1
do {
    try process.run()
    let pid = process.processIdentifier
    if guarded {
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(effectiveTimeout)) {
            stateLock.lock(); let done = finishedFlag; if !done { timedOut = true }; stateLock.unlock()
            guard !done else { return }
            kill(-pid, SIGTERM)   // negative pid = the whole process group
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                stateLock.lock(); let escalated = finishedFlag; stateLock.unlock()
                if !escalated { kill(-pid, SIGKILL) }
            }
        }
    }
    process.waitUntilExit()
    stateLock.lock(); finishedFlag = true; let didTimeout = timedOut; stateLock.unlock()
    exitCode = didTimeout ? 124 : process.terminationStatus   // 124 = conventional timeout code
} catch {
    let msg = "cadence-rec: failed to launch command: \(error)\n"
    try? msg.data(using: .utf8)?.write(to: stderrURL)
}

stateLock.lock(); let wasTimeout = timedOut; stateLock.unlock()
let finished = Date()
let durationMS = Int(finished.timeIntervalSince(started) * 1000)
store.finishRun(id: runID, finishedAt: finished, exitCode: Int(exitCode), durationMS: durationMS)

// Keep this job's log directory bounded (current run is the newest, so kept).
LogPruner.prune(directory: logDir, keepRuns: 100)

// Parse semantic usage (model / tokens / cost) the agent may have reported —
// agent runs are about what the model did, not just the exit code.
let outText = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
let errText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
if let usage = UsageParser.parse(outText + "\n" + errText) {
    store.setRunUsage(id: runID, usage: usage)
}

// Notify on failure so unattended/agent-triggered jobs don't fail silently.
if exitCode != 0, store.boolSetting(CadenceSettingsKey.notifyOnFail, default: true) {
    let detail = wasTimeout ? "Timed out after \(effectiveTimeout)s — process tree killed." : errText
    Notifier.jobFailed(label: label, exitCode: Int(exitCode), detail: detail)
}

exit(exitCode)
