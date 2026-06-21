# Changelog

All notable changes to Cadence are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/). Install/upgrade via
`brew install --cask zot24/tap/cadence`.

## [Unreleased]

## [0.1.9] - 2026-06-21
### Added
- "Process" section in the job detail view: live `launchctl print` detail (state, PID, last exit,
  run count, program) plus CPU / memory / uptime from `ps` for the running process.

## [0.1.8] - 2026-06-21
### Added
- Tooling: this CHANGELOG and a GitHub Actions CI pipeline (build, test, SwiftLint).
### Fixed
- Classify `ai.hermes.*` jobs as AI agents via the reverse-DNS vendor label (e.g.
  `ai.hermes.gateway-residencyos`), even when the command shows no `hermes` binary evidence.

## [0.1.7] - 2026-06-21
### Added
- Group the job list by vendor org derived from the reverse-DNS label (`com.docker` → Docker,
  `com.adobe` → Adobe, …) under section headers, with a "Group by org" toolbar toggle.

## [0.1.6] - 2026-06-21
### Fixed
- Privileged disable now persists the plist `Disabled` key (what the UI reads) and runs
  `launchctl disable` before `bootout`, so a stopped system daemon actually shows as stopped.

## [0.1.5] - 2026-06-21
### Fixed
- Settings window content is scrollable; the Cancel/Save bar no longer gets pushed off-screen.

## [0.1.4] - 2026-06-21
### Fixed
- App version shown in the About panel (the bundle version was stuck at 0.1.0).
### Added
- README "Sandboxing approaches for local agents" comparison table.

## [0.1.3] - 2026-06-21
### Added
- Opt-in **Seatbelt sandbox** for scheduled agents (Tier 1): write-confinement to the project +
  `~/Cadence` + caches, credential read-denylist, exec hardening (block osascript/sudo/launchctl/
  crontab), and ssh-agent socket stripping. Verified against the kernel in build-time tests.

## [0.1.2] - 2026-06-21
### Added
- "Run Now" elevation for privileged launchd jobs (opt-in), via `launchctl kickstart` as root.

## [0.1.1] - 2026-06-21
### Added
- Opt-in **privileged launchd actions** — enable/disable/delete system daemons & global agents via
  the native macOS admin prompt.
- README "How it compares" table vs other macOS cron/launchd managers.

## [0.1.0] - 2026-06-21
### Added
- Initial public release: unified **cron + launchd + Flue** job manager with per-job **run-count
  tracking** (the `cadence-rec` shim), logs, status, cost, risk, and an audit trail — menu bar + window.
- Evidence-based provenance, "lethal trifecta" risk flags, reversible run-tracking adoption.
- **Multi-provider model layer** (Anthropic, xAI/Grok, Ollama, LM Studio, OpenAI-compatible).
- **agentcn-style recipe registry** + runtime abstraction (Flue; Eve gated as experimental).
- Model-backed **"Explain with AI"** failure triage (key stored in the Keychain).
- Homebrew tap distribution (`zot24/homebrew-tap`).

[Unreleased]: https://github.com/zot24/cadence/compare/v0.1.9...HEAD
[0.1.9]: https://github.com/zot24/cadence/releases/tag/v0.1.9
[0.1.8]: https://github.com/zot24/cadence/releases/tag/v0.1.8
[0.1.7]: https://github.com/zot24/cadence/releases/tag/v0.1.7
[0.1.6]: https://github.com/zot24/cadence/releases/tag/v0.1.6
[0.1.5]: https://github.com/zot24/cadence/releases/tag/v0.1.5
[0.1.4]: https://github.com/zot24/cadence/releases/tag/v0.1.4
[0.1.3]: https://github.com/zot24/cadence/releases/tag/v0.1.3
[0.1.2]: https://github.com/zot24/cadence/releases/tag/v0.1.2
[0.1.1]: https://github.com/zot24/cadence/releases/tag/v0.1.1
[0.1.0]: https://github.com/zot24/cadence/releases/tag/v0.1.0
