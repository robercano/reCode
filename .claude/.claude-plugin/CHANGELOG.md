# Changelog

All notable changes to the `orchestrator` plugin are documented in this file. Format is loosely
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); versions track `plugin.json` /
`marketplace.json`.

## [0.2.0] - 2026-07-10

Everything shipped since 0.1.4. Headline: a cron-less loop daemon replaces the cron-based
`pr-loop` scheduling path, plus the managed-file/env fixes that came out of running it live in
this repo.

### Added
- **Cron-less PR-loop daemon** (issue #102, PR #103): systemd-driven `pr-loop` daemon +
  `arm-loop.sh` replace the cron trigger. Docs added in `42a96e3`.
- **Loop health panel + tick records** (issue #85, PR #104): cockpit surfaces daemon health;
  `loop-tick.sh` gains tick-record coverage and a verdict-history cap with rotation.
- **Worker-tool mirror / live activity in drawer** (issue #84, PR #101).
- **Root `pnpm cockpit` alias** (issue #90, PR #108): new root `package.json` exposes
  `pnpm cockpit`; `packageManager` pinned for Node 20 CI compatibility, plus a smoke test.
- **`--rc-name` for the remote-control session** (`cd3fbce`): pre-created RC tmux session is now
  named explicitly, defaulting to `<slug>-planner`.

### Changed
- **reCode rebrand** (issue #86, PR #105): plugin identity, docs, and product name rebranded from
  the previous name to reCode (`ea8d9e2`, `8486c71`).
- **Loop-tick hardening** (issue #81, PR #82): closed a spawn-lock deadlock, a TOCTOU race, and a
  census `SIGPIPE`; both `pr-loop` prompts now adopt `loop-tick.sh` as STEP 0 (issue #83, PR #93).
- **Setup commands consolidated** (issue #88, PR #89): removed the redundant
  `setup-orchestrator` / `sync-orchestrator` pointer stubs.

### Fixed
- **Arm-time env fixes for the daemon**, landing as managed-template version bumps:
  - `claude-rc.service` → v2 → v3 → v4: bake the absolute `claude` path into the unit at arm
    time (`e4f35f6`), then export the full `PATH` inside the RC tmux pane so spawned sessions
    survive (`da586c5`).
  - `arm-loop.sh` → v3 → v4: name the pre-created RC session via `--rc-name` (`cd3fbce`); PATH
    export fix above also lands here.
  - `pr-loop.service` → v1: introduced with the cron-less daemon (issue #102).
  - `feature-fanout.js` → v2: re-stamped to the managed v2 marker (`9c24ef7`).
  - nvm-managed `node`/`claude` resolved at daemon startup, not only inside `run_driver`
    (`4bf7dbb`).

### Notes for downstream installs
- Run `/orchestrator:sync` after upgrading to 0.2.0 to pick up the managed-template bumps above
  (`arm-loop.sh` v4, `claude-rc.service` v4, `pr-loop.service` v1, `feature-fanout.js` v2). Sync
  reconciles each file independently by its own `@orchestrator-managed <name> vN` marker — it does
  not key off this plugin version number, so a same-version reinstall is always a no-op and a
  behind-version install restamps cleanly as long as the local file has no hand-edits.

## [0.1.4] - prior release

See git history prior to this file's introduction (`b061087` and earlier) for changes up to and
including the 0.1.4 bump (issue #78).
