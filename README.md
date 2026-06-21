# Cadence

A native macOS menu-bar app to **visualize, edit, monitor, and track** the scheduled
jobs on your Mac — classic **cron**, **launchd** LaunchAgents/Daemons, and **Flue**
agents/workflows — in one place, with per-job **run counts**, **logs**, **status**, and
**run history**.

Built because nothing existing covers all of it at once: the maintained tools manage
*either* cron *or* launchd, almost none capture logs, and **no native menu-bar app tracks
how many times each job has run** — because neither cron nor launchd persists that. Cadence
fills the gap.

## How it compares

No existing macOS tool combines all of: manage native **cron** *and* **launchd**, capture **logs**,
track a per-job **run count**, run from the **menu bar**, *and* govern model-agent **cost/risk**.

| Tool | cron | launchd | Logs | Run count | Menu-bar | Agent cost/risk |
|------|:----:|:-------:|:----:|:---------:|:--------:|:---------------:|
| **Cadence** | ✅ | ✅ ¹ | ✅ | ✅ | ✅ | ✅ |
| LaunchControl (~$17) | — | ✅ (best editor) | ✅ | — | — | — |
| Lingon 10 / Pro (free/$24) | — | ✅ | Pro only | — | — | — |
| Orchard Ops (free/$15) | read-only | ✅ | ✅ (history) | — | ? | — |
| CronniX / Macron | ✅ ² | — | — | — | — | — |
| crontab-ui / Cronmaster | ✅ (web) | — | ✅ | — | — (web) | — |
| Cronitor / Healthchecks | — ³ | — ³ | partial | ✅ | — | — |

¹ User LaunchAgents are tracked directly; system daemons / global agents via an opt-in admin prompt.
² Unmaintained / 32-bit (CronniX is dead; Macron stale since 2022).
³ Hosted monitoring or their own scheduler — not managers of the OS's native cron/launchd.

**Why the run count is rare:** cron and launchd only persist a job's *last* exit status, never a
cumulative count — so tracking it structurally requires wrapping each job. That's exactly what
Cadence's `cadence-rec` shim does.

## Features

- **Unified view** of cron + launchd + Flue jobs with live status dots (running / idle /
  failed / disabled) and a menu-bar glance, topped by a **fleet summary bar** — tappable
  at-a-glance chips for total Jobs, AI Agents, Failing, At-risk, and total Spend.
- **Evidence-based provenance.** Every job is classified by the *actual tool* behind it —
  **Flue**, **Claude Code**, **Hermes**, **OpenClaw**, **Codex**, **Homebrew**, **Apple**, etc. —
  detected from the invoked binary and config paths (never from a name keyword), with the
  evidence and a confidence level. Shown as a colored badge; an "AI agents" filter surfaces only
  genuinely agent-driven jobs.
- **Metadata panel.** Per-job details: plist internals (working dir, env vars, stdout/stderr
  paths, KeepAlive/RunAtLoad), file owner + created/modified dates, crontab line, Flue project/
  agent — so you can see exactly what a job is and who set it up.
- **Agent safety flags.** Static "lethal trifecta" analysis flags risky unattended jobs — holds
  secrets, network access, privileged, destructive, or the high-severity **exfiltration risk**
  (secrets + network). Shown as a shield badge with an "At risk" filter — governance for the
  fleet of scheduled agents on your Mac.
- **Run-count & history tracking.** Because cron/launchd don't keep a run counter, Cadence
  uses a tiny recorder shim (`cadence-rec`) that wraps a job to record every execution —
  start/finish, exit code, duration, and captured stdout/stderr — into a local SQLite DB.
- **Hybrid adoption model.** Every job is shown read-only by default; opt in to *Track Runs*
  on a per-job basis to start recording history without touching jobs you'd rather leave alone.
  A one-click **Track All Agent Jobs** bulk action (toolbar ▸ More) adopts every adoptable
  AI-agent job at once — instant onboarding for existing agent sprawl.
- **Edit & manage:** create **cron** jobs (visual builder with presets + live "what this means" +
  next-run preview) and **launchd** jobs (interval / daily / weekly, run-at-login, writes the
  LaunchAgent and loads it); enable/disable, run-now, delete, reveal plist, and **edit a job's
  environment variables** (the in-app fix for the #1 agent failure — API keys that live in your
  shell profile, which schedulers never load). For **launchd** jobs it edits the plist's
  `EnvironmentVariables`; for **Flue agent** jobs it edits the project's `.env` (the idiomatic way
  Flue loads keys), preserving comments and untouched keys; for plain **cron** jobs it edits inline
  `KEY=val` prefixes — so every job type can get its API keys in-app.
- **Sandboxed agents (opt-in, default on for new agent jobs).** A scheduled agent can be confined
  with macOS **Seatbelt** (`sandbox-exec`): **writes** are restricted to its project, `~/Cadence`, and
  node caches; **reads** of credential stores (`~/.ssh`, `~/.aws`, Keychains, browser cookies, AI-tool
  tokens) are denied; privilege-escalation / GUI-scripting tools (`osascript`, `sudo`, `launchctl`,
  `crontab`) can't be exec'd; and the **ssh-agent socket is stripped**. Zero dependencies —
  `sandbox-exec` ships with macOS — and `cadence-rec` stays *outside* the sandbox so runs are still
  recorded. The profile is generated per-agent and verified against the kernel (build-time tests run
  real `sandbox-exec`). Honest limits: reads are broad-with-a-credential-denylist (default-deny reads
  abort dyld), and Seatbelt can't restrict network to a single host — full egress control is roadmapped
  via a localhost proxy. Directly hardens the "exfiltration risk" the app already flags.
- **Privileged actions (opt-in).** System daemons and global agents (in `/Library/Launch*`) need
  root, so by default Cadence declines to touch them with a clear message. Turn on **Privileged
  Actions** in Settings and enable/disable/delete runs as root via the native macOS admin prompt
  (Touch ID / password) — no Developer ID needed. Apple's SIP-protected daemons still can't be
  changed even as root.
- **Flue integration:** discover Flue projects in your code folders and schedule any agent or
  workflow as a tracked job — Cadence records runs while Flue keeps its own durable logs.
- **Agent readiness pre-flight.** For a scheduled Flue agent, Cadence checks *before* the schedule
  fires whether it will actually run — node on PATH, deps installed, the agent file exists, and an
  API key is set in `.env` — and shows the one-line fix for whatever's missing. Turns a silent
  scheduled failure into an obvious checklist.
- **Model-backed Agent Jobs.** Create a *new* scheduled job whose logic is an LLM agent: name it,
  pick a **provider** (Anthropic, xAI/Grok, or a **local model** via Ollama / LM Studio), choose
  the model, write its instructions, and Cadence scaffolds a Flue agent and schedules it locally as
  a tracked cron job — a cron job with an agent behind it. Local models need no API key and cost
  nothing; key-based providers get the right key seeded into the project `.env` automatically.
- **Recipe gallery (shadcn/agentcn-style).** A browsable catalog of agent **recipes** (news digest,
  inbox triage, repo watcher, standup summary, backup verifier, spend watcher, fleet monitor…). Pick
  one and it prefills the New Agent Job sheet — model, instructions, cadence, env requirements — so
  you go from catalog to a scheduled, tracked local agent in a couple of clicks. Built on a
  runtime-agnostic `AgentRuntime` layer (Flue today; **Eve** scaffolding present but gated as
  experimental until its cron-friendly run path is verified).
- **Failure diagnosis (triage).** When a tracked run fails, the detail view shows a **Diagnosis**:
  the likely category (command-not-found, permission denied, auth/API-key missing, rate limited,
  network error, timeout, missing dependency…) with a concrete fix — tuned for the minimal
  cron/launchd environment where scheduled agents actually break. This deterministic, zero-cost
  diagnosis is always on; an **"Explain with AI"** button layers a model on top — it sends the
  failed run's command + logs to your configured provider (Anthropic, xAI/Grok, or a **local
  model** via Ollama/LM Studio) and writes a plain-English cause + fix. Configure the triage
  provider in Settings; the API key is stored in the macOS **Keychain**, and local models make it
  free to run.
- **Failure notifications.** When a tracked job exits non-zero, the recorder posts a macOS
  notification (with the failing stderr line) so agent-triggered, unattended jobs don't fail
  silently. Toggle in Settings.
- **Runaway protection.** A configurable max runtime kills a hung job's *entire process tree*
  (the recorder runs it as a process-group leader) — so a stuck agent and any subprocesses it
  spawned stop making API calls, instead of orphaned grandchildren billing forever. Records the
  run as a timeout (exit 124).
- **Adaptive scheduling.** An agent can change its *own* cadence: print
  `CADENCE_NEXT {"cron":"0 */4 * * *"}` (or `{"in_minutes":120}`) and Cadence surfaces a one-click
  **Apply** banner on the job — so a model-backed agent that finds nothing can ask to run less
  often, and one that finds a problem can ask to run more often. Works for **cron** jobs (rewrites
  the expression) and **launchd** jobs (rewrites `StartInterval`).
- **Semantic agent run records.** Agent runs are about what the model did, not just exit codes.
  The recorder parses **model, tokens, and cost** from a run's output — a canonical
  `CADENCE_USAGE {"model":…,"input_tokens":…,"output_tokens":…,"cost_usd":…}` line any agent can
  print, plus best-effort patterns — and surfaces per-run cost and per-job **Total Cost / Tokens /
  Avg Cost-per-Run** stats. So you can see what your scheduled agents are spending.
- **Audit timeline.** An Activity view (⌘L) showing every recorded run across *all* jobs in
  chronological order — job, source, trigger, exit code, duration, **cost/model**, success/failure
  — with a failures-only filter, a **running total spend**, and **CSV export** (now including model
  + cost_usd). The "if you can't trace it, you can't govern it" answer to agent sprawl.
- **Logs viewer** with per-run stdout/stderr, success rate, average duration, and a run timeline.
- **Toolbar icon + full window** — quick access from the menu bar, full detail in the app.

- **Headless report.** `Cadence --report` (or `--json`) prints the whole job fleet — counts by
  source, detected agent tools, at-risk jobs, runs, and spend — without opening the GUI, for
  scripting and governance.

## Build & Run

Requirements: macOS 14+, Xcode 16+ (Swift 6).

```bash
# Build a double-clickable app bundle:
scripts/build_app.sh release
open build/Cadence.app

# Or run from source during development:
swift run Cadence

# Tests:
swift test
```

## Install

### Homebrew (tap)

```bash
brew install --cask zot24/tap/cadence
```

This installs the latest release `.dmg` from [`zot24/homebrew-tap`](https://github.com/zot24/homebrew-tap).
The app is **ad-hoc signed** (not yet notarized), so on first launch use right-click → **Open**
(or `xattr -dr com.apple.quarantine /Applications/Cadence.app`).

## Distribution

```bash
scripts/make_dmg.sh release      # → build/Cadence.dmg (drag-to-Applications)
```

The app is **ad-hoc signed**, so it runs on this machine and on others via
right-click → **Open** (first launch only). For frictionless distribution to
other Macs:

1. Set `DEV_ID="Developer ID Application: Your Name (TEAMID)"` and re-run
   `scripts/make_dmg.sh` — it re-signs the app with that identity.
2. Notarize the `.dmg`: `xcrun notarytool submit build/Cadence.dmg --apple-id … --team-id … --password …`, then `xcrun stapler staple build/Cadence.dmg`.

Both steps require an Apple Developer account (no identity is configured on this
machine, so the current build is ad-hoc only).

## Architecture

A SwiftPM package with three targets:

| Target          | What it is                                                                 |
|-----------------|-----------------------------------------------------------------------------|
| **CadenceCore** | Foundation-only library: models, SQLite run store, and the cron/launchd/Flue parsers + writers. No SwiftUI, so the shim can link it too. |
| **cadence-rec** | The recorder shim. Adopted jobs are rewritten to call it; it records each run and re-exits with the child's exit code so cron/launchd see the true result. |
| **Cadence**     | The SwiftUI app — `MenuBarExtra` (menu-bar popover) + a main `Window` (3-column: filters · job list · detail). |

```
Sources/
  CadenceCore/
    Models.swift          Job, JobRun, JobStats, schedules, enums
    Database.swift        SQLite run-history store (WAL, shared by app + shim)
    CronSchedule.swift    5-field cron parser, humanizer, next-run prediction
    CronSource.swift      crontab -l discovery + parsing
    CronWriter.swift      crontab edits (add/remove/enable/adopt) with stable id markers
    LaunchdSource.swift   plist discovery + launchctl runtime status
    LaunchdControl.swift  enable/disable/kickstart via launchctl
    FlueSource.swift      Flue project/agent discovery + job reclassification
    FlueScaffold.swift    generate Flue agent source + project skeletons (Agent Jobs)
    JobRepository.swift   the aggregator façade the UI talks to
    RecorderInstaller.swift  installs cadence-rec to a stable path
    Shell.swift, Paths.swift
  cadence-rec/main.swift  the shim
  Cadence/                the SwiftUI app
```

### Data locations

```
~/Library/Application Support/Cadence/
  cadence.db              run history (SQLite)
  bin/cadence-rec         installed recorder shim
  logs/<job-id>/<run>.out captured stdout/stderr per run
```

### How run tracking works

cron and launchd only expose a job's *last* exit status — never a cumulative count. When you
*Track* a cron/Flue job, Cadence rewrites its command from:

```
*/15 * * * * /usr/local/bin/backup.sh
```

to (identity preserved via a `# cadence:<id>` marker):

```
*/15 * * * * '~/Library/Application Support/Cadence/bin/cadence-rec' --job cron:… --label Backup --source cron --trigger schedule -- /usr/local/bin/backup.sh
```

The shim records the run and exits with the script's real exit code, so cron behaves
identically — you just gain run counts, logs, and history.

## Status

v0.1 — working foundation. cron is fully manageable (create/edit/enable/adopt/delete);
launchd is discovered with enable/disable/run-now/reveal and **reversible run-tracking adoption
for user agents** (`~/Library/LaunchAgents`) — Cadence rewrites `ProgramArguments` to wrap the
recorder and reloads the job; Flue agents can be discovered, scheduled, and created across multiple
model providers (Anthropic, xAI/Grok, local Ollama/LM Studio), browsable via the recipe gallery,
with a model-backed "Explain with AI" failure triage. Roadmap: launchd job creation/plist editing,
privileged adoption for global/system jobs, verified **Eve** runtime support (needs Node ≥ 24 + a
cron-friendly one-shot run command), and Flue durable-run log integration.
