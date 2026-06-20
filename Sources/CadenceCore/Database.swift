import Foundation
import SQLite3

/// SQLite-backed run-history store. cron and launchd do not persist a per-job
/// execution count or log history, so the recorder shim writes every run here
/// and the app reads aggregates back out. Access is serialised through an
/// internal queue so the app and shim can both touch the file safely.
public final class RunStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.cadence.runstore")
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL = CadencePaths.databaseURL) throws {
        CadencePaths.ensureSupportTree()
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw RunStoreError.openFailed(url.path)
        }
        self.db = handle
        // Concurrent app + shim access: WAL + a busy timeout avoids "database is locked".
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA busy_timeout=5000;")
        exec("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Schema

    private func migrate() throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS jobs (
            id            TEXT PRIMARY KEY,
            source        TEXT NOT NULL,
            label         TEXT NOT NULL,
            command       TEXT,
            adopted       INTEGER NOT NULL DEFAULT 0,
            first_seen    REAL NOT NULL,
            last_seen     REAL NOT NULL,
            notes         TEXT
        );
        CREATE TABLE IF NOT EXISTS runs (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id      TEXT NOT NULL,
            started_at  REAL NOT NULL,
            finished_at REAL,
            exit_code   INTEGER,
            duration_ms INTEGER,
            stdout_path TEXT,
            stderr_path TEXT,
            trigger     TEXT NOT NULL DEFAULT 'schedule'
        );
        CREATE INDEX IF NOT EXISTS idx_runs_job ON runs(job_id, started_at DESC);
        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        try queue.sync {
            try execOrThrow(schema)
            // Semantic agent-usage columns — added in place; ignored if present.
            for col in ["model TEXT", "input_tokens INTEGER", "output_tokens INTEGER", "cost_usd REAL"] {
                sqlite3_exec(db, "ALTER TABLE runs ADD COLUMN \(col);", nil, nil, nil)
            }
        }
    }

    // MARK: - Writes (used mostly by the recorder shim)

    /// Upsert a job's identity row. Returns nothing; idempotent.
    public func touchJob(id: String, source: JobSource, label: String, command: String?, adopted: Bool) {
        queue.sync {
            let now = Date().timeIntervalSince1970
            let sql = """
            INSERT INTO jobs (id, source, label, command, adopted, first_seen, last_seen)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                label=excluded.label,
                command=COALESCE(excluded.command, jobs.command),
                adopted=excluded.adopted,
                last_seen=excluded.last_seen;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id)
            bindText(stmt, 2, source.rawValue)
            bindText(stmt, 3, label)
            bindTextOrNull(stmt, 4, command)
            sqlite3_bind_int(stmt, 5, adopted ? 1 : 0)
            sqlite3_bind_double(stmt, 6, now)
            sqlite3_bind_double(stmt, 7, now)
            sqlite3_step(stmt)
        }
    }

    /// Record the start of a run; returns the new run's id.
    @discardableResult
    public func startRun(jobID: String, startedAt: Date, trigger: String,
                         stdoutPath: String?, stderrPath: String?) -> Int64 {
        queue.sync {
            let sql = """
            INSERT INTO runs (job_id, started_at, trigger, stdout_path, stderr_path)
            VALUES (?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, jobID)
            sqlite3_bind_double(stmt, 2, startedAt.timeIntervalSince1970)
            bindText(stmt, 3, trigger)
            bindTextOrNull(stmt, 4, stdoutPath)
            bindTextOrNull(stmt, 5, stderrPath)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Attach captured log file paths to a run (named by row id, so unique).
    public func setRunLogPaths(id: Int64, stdoutPath: String, stderrPath: String) {
        queue.sync {
            let sql = "UPDATE runs SET stdout_path=?, stderr_path=? WHERE id=?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, stdoutPath)
            bindText(stmt, 2, stderrPath)
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        }
    }

    /// Attach semantic usage (model/tokens/cost) parsed from an agent run.
    public func setRunUsage(id: Int64, usage: Usage) {
        queue.sync {
            let sql = "UPDATE runs SET model=?, input_tokens=?, output_tokens=?, cost_usd=? WHERE id=?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindTextOrNull(stmt, 1, usage.model)
            if let i = usage.inputTokens { sqlite3_bind_int(stmt, 2, Int32(i)) } else { sqlite3_bind_null(stmt, 2) }
            if let o = usage.outputTokens { sqlite3_bind_int(stmt, 3, Int32(o)) } else { sqlite3_bind_null(stmt, 3) }
            if let c = usage.costUSD { sqlite3_bind_double(stmt, 4, c) } else { sqlite3_bind_null(stmt, 4) }
            sqlite3_bind_int64(stmt, 5, id)
            sqlite3_step(stmt)
        }
    }

    /// Record the completion of a run.
    public func finishRun(id: Int64, finishedAt: Date, exitCode: Int, durationMS: Int) {
        queue.sync {
            let sql = "UPDATE runs SET finished_at=?, exit_code=?, duration_ms=? WHERE id=?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, finishedAt.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 2, Int32(exitCode))
            sqlite3_bind_int(stmt, 3, Int32(durationMS))
            sqlite3_bind_int64(stmt, 4, id)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Reads (used by the app)

    /// Aggregate stats for a single job.
    public func stats(forJob jobID: String) -> JobStats {
        queue.sync {
            let sql = """
            SELECT
                COUNT(*),
                SUM(CASE WHEN exit_code = 0 THEN 1 ELSE 0 END),
                SUM(CASE WHEN exit_code IS NOT NULL AND exit_code <> 0 THEN 1 ELSE 0 END),
                MAX(started_at),
                AVG(duration_ms),
                COALESCE(SUM(cost_usd), 0),
                COALESCE(SUM(COALESCE(input_tokens,0) + COALESCE(output_tokens,0)), 0)
            FROM runs WHERE job_id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return JobStats(jobID: jobID)
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, jobID)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return JobStats(jobID: jobID) }
            let total = Int(sqlite3_column_int(stmt, 0))
            let success = Int(sqlite3_column_int(stmt, 1))
            let failure = Int(sqlite3_column_int(stmt, 2))
            let lastRun: Date? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let avg: Int? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil : Int(sqlite3_column_double(stmt, 4))
            let totalCost = sqlite3_column_double(stmt, 5)
            let totalTokens = Int(sqlite3_column_int64(stmt, 6))
            // Pull the most recent exit code separately.
            let lastExit = lastExitCode(forJob: jobID)
            return JobStats(jobID: jobID, totalRuns: total, successCount: success,
                            failureCount: failure, lastRun: lastRun,
                            lastExitCode: lastExit, avgDurationMS: avg,
                            totalCostUSD: totalCost, totalTokens: totalTokens)
        }
    }

    /// Stats for every job that has run history, keyed by job id.
    public func allStats() -> [String: JobStats] {
        let ids = queue.sync { () -> [String] in
            var out: [String] = []
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT DISTINCT job_id FROM runs;", -1, &stmt, nil) == SQLITE_OK else { return out }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
            }
            return out
        }
        var result: [String: JobStats] = [:]
        for id in ids { result[id] = stats(forJob: id) }
        return result
    }

    private func lastExitCode(forJob jobID: String) -> Int? {
        let sql = "SELECT exit_code FROM runs WHERE job_id=? AND exit_code IS NOT NULL ORDER BY started_at DESC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, jobID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Recent runs for a job, newest first.
    public func recentRuns(forJob jobID: String, limit: Int = 100) -> [JobRun] {
        queue.sync {
            let sql = """
            SELECT id, job_id, started_at, finished_at, exit_code, duration_ms, stdout_path, stderr_path, trigger,
                   model, input_tokens, output_tokens, cost_usd
            FROM runs WHERE job_id = ? ORDER BY started_at DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, jobID)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var out: [JobRun] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let usage = Usage(
                    model: columnText(stmt, 9),
                    inputTokens: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 10)),
                    outputTokens: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 11)),
                    costUSD: sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 12)
                )
                out.append(JobRun(
                    id: sqlite3_column_int64(stmt, 0),
                    jobID: columnText(stmt, 1) ?? jobID,
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    finishedAt: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    exitCode: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 4)),
                    durationMS: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5)),
                    stdoutPath: columnText(stmt, 6),
                    stderrPath: columnText(stmt, 7),
                    trigger: columnText(stmt, 8) ?? "schedule",
                    usage: usage
                ))
            }
            return out
        }
    }

    // MARK: - Settings (key/value, readable by the out-of-process shim)

    public func setting(_ key: String, default defaultValue: String) -> String {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM settings WHERE key=?;", -1, &stmt, nil) == SQLITE_OK else { return defaultValue }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return defaultValue }
            return String(cString: c)
        }
    }

    public func setSetting(_ key: String, value: String) {
        queue.sync {
            let sql = "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            bindText(stmt, 2, value)
            sqlite3_step(stmt)
        }
    }

    public func boolSetting(_ key: String, default defaultValue: Bool) -> Bool {
        setting(key, default: defaultValue ? "1" : "0") == "1"
    }

    public func setBoolSetting(_ key: String, value: Bool) {
        setSetting(key, value: value ? "1" : "0")
    }

    public func intSetting(_ key: String, default defaultValue: Int) -> Int {
        Int(setting(key, default: String(defaultValue))) ?? defaultValue
    }

    public func setIntSetting(_ key: String, value: Int) {
        setSetting(key, value: String(value))
    }

    // MARK: - Audit timeline (cross-job activity)

    /// Every recorded run across all jobs, newest first, joined with job identity.
    public func recentActivity(limit: Int = 500) -> [ActivityEntry] {
        queue.sync {
            let sql = """
            SELECT r.id, r.job_id, COALESCE(j.label, r.job_id), j.source,
                   r.started_at, r.finished_at, r.exit_code, r.duration_ms, r.trigger,
                   r.model, r.cost_usd
            FROM runs r LEFT JOIN jobs j ON r.job_id = j.id
            ORDER BY r.started_at DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [ActivityEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let source = columnText(stmt, 3).flatMap { JobSource(rawValue: $0) }
                out.append(ActivityEntry(
                    id: sqlite3_column_int64(stmt, 0),
                    jobID: columnText(stmt, 1) ?? "",
                    label: columnText(stmt, 2) ?? "",
                    source: source,
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    finishedAt: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    exitCode: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6)),
                    durationMS: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 7)),
                    trigger: columnText(stmt, 8) ?? "schedule",
                    model: columnText(stmt, 9),
                    costUSD: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 10)
                ))
            }
            return out
        }
    }

    // MARK: - Low-level helpers

    private func exec(_ sql: String) {
        queue.sync { _ = sqlite3_exec(db, sql, nil, nil, nil) }
    }

    private func execOrThrow(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw RunStoreError.execFailed(message)
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, Self.SQLITE_TRANSIENT)
    }

    private func bindTextOrNull(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value { bindText(stmt, idx, value) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }
}

public enum RunStoreError: Error, CustomStringConvertible {
    case openFailed(String)
    case execFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let p): return "Failed to open database at \(p)"
        case .execFailed(let m): return "SQL error: \(m)"
        }
    }
}
