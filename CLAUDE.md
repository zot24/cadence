# Cadence — agent context

Native macOS **menu-bar + window** app to visualize, edit, monitor, and govern scheduled jobs —
**cron**, **launchd** (LaunchAgents/Daemons), and **Flue** model-backed agents — in one place, with
per-job run counts, logs, status, cost, risk, and an audit trail. Positioned as the **local control
plane for the fleet of scheduled agents on your Mac**. SwiftUI, SwiftPM, zero external deps.

## Build / test / run

```bash
swift build                       # build all targets
swift test                        # run CadenceCoreTests (74+ tests, keep green)
scripts/build_app.sh release      # assemble build/Cadence.app (icon + Info.plist + ad-hoc sign)
open build/Cadence.app            # launch the GUI
.build/debug/Cadence --report     # headless inventory (also --json) — smoke-tests the load pipeline
swift scripts/make_icon.swift Sources/Cadence/Resources/AppIcon.icns   # regenerate the icon
```

Toolchain: macOS 14+, Swift 6 (targets use `.swiftLanguageMode(.v5)`). No Xcode project — the
`.app` is assembled by `scripts/build_app.sh`.

## Targets (Package.swift)

- **CadenceCore** — Foundation-only library: models, SQLite store, all parsers/writers/analyzers.
  No SwiftUI, so the recorder shim links it too. Links system `sqlite3`.
- **cadence-rec** — the recorder shim. Adopted jobs are rewritten to call it; it records each run
  (start/finish/exit/duration/stdout/stderr) and re-exits with the child's code. Also: timeout
  process-group kill, failure notification, and `CADENCE_USAGE` parsing.
- **Cadence** — the SwiftUI app (`MenuBarExtra` + `Window`, 3-column split). `@main CadenceEntry`
  dispatches `--report`/`--json` to `CadenceCLI` before the GUI.

## Core model

`Job` (unified across sources) carries: source, schedule, status, `isAdopted`, `origin: JobOrigin`
(evidence-based provenance — tool/category/confidence), `risk: JobRisk`, and Flue fields
(`flueProjectPath`/`flueAgentName`/`flueModel`/`flueGoal`). `JobRepository` is the façade the UI
and CLI call: `loadAll()` aggregates cron+launchd+flue, enriches, classifies origin, analyzes risk.

Data lives in `~/Library/Application Support/Cadence/`: `cadence.db` (SQLite run history + settings),
`bin/cadence-rec` (installed shim), `logs/<job-id>/<run-id>.{out,err}`.

## How run tracking works (the differentiator)

cron/launchd only expose a job's *last* exit status, never a count. "Adopting" a job rewrites its
command to wrap `cadence-rec`, which records every run into SQLite. Identity is stable via a
`# cadence:<id>` marker (cron) or the label (launchd). Adoption: cron rewrites the line; launchd
rewrites `ProgramArguments`; both reversible.

## Conventions (follow these)

- **Verify end-to-end, not just compile.** Every iteration: `swift build` green → run the relevant
  recorder/CLI path against real state or a temp dir → `swift test` → rebuild bundle → relaunch.
  This has caught real bugs (log-filename collision, isAdopted regression, ugly cron normalization).
- **Extract pure helpers for anything that mutates crontab/plist**, and test the pure helper — never
  test against the live crontab/launchctl. Examples: `CronWriter.rewriteScheduleOnLine`/`rewriteEnvOnLine`,
  `LaunchdWriter.plistWithEnv`/`plistWithInterval`/`buildPlistDict`.
- **Provenance is evidence-based** (invoked binary + config paths + reverse-DNS label), never a name
  keyword — a label containing "agent" must NOT be classified as agent-created. See `JobProvenance.swift`.
- Privileged (global/system launchd) edits are declined with a clear error, not attempted.

## Agent integration surface (model-backed Flue agents)

- **Create**: NewAgentJobView scaffolds a Flue agent (`FlueScaffold`) and schedules `npx flue run` as
  a tracked cron job. Templates in `AgentTemplates.swift`.
- **Readiness**: `FlueReadiness` pre-flights node/deps/agent-file/API-key before the schedule fires.
- **Env**: editor routes to plist `EnvironmentVariables` (launchd), project `.env` (Flue, via `DotEnv`),
  or inline `KEY=val` (cron).
- **Agents can self-report**: print `CADENCE_USAGE {"model":…,"cost_usd":…}` (parsed by `UsageParser`)
  and `CADENCE_NEXT {"cron":…|"in_minutes":N}` (parsed by `RescheduleParser`) to record cost and
  request a cadence change (one-click Apply; cron rewrites expression, launchd rewrites StartInterval).
- **Failure triage** (`FailureTriage`) diagnoses common cron/launchd failures (PATH, perms, missing
  API key, 429, network, timeout) with fixes.

## Known gotchas

- `screencapture` from the agent terminal returns black (no Screen Recording permission) — can't
  screenshot-verify UI here; rely on build + tests.
- `Date.now()`/`Math.random()` are unavailable in Workflow scripts (not relevant to the Swift app).
- Don't put per-render file I/O in SwiftUI body-evaluated computed props — memoize into `@State` in
  `reload()` (see JobDetailView triage/reschedule/readiness).

Status: ~21 feature iterations, 74+ tests, clean build. Remaining backlog is credential/network-gated
(model-backed triage agent, `npm install` runner). Work is currently **uncommitted** in git.
