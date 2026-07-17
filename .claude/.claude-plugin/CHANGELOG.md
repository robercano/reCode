# Changelog

All notable changes to the `orchestrator` plugin are documented in this file. Format is loosely
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); versions track `plugin.json` /
`marketplace.json`.

## [0.2.2] - 2026-07-17

### Changed
- **Stopped vendoring the runtime harness (issue #134, reverting issue #128).** `/orchestrator:setup`/
  `/orchestrator:sync` no longer copy the plugin's own `agents/`, `commands/`, `hooks/`, `scripts/`,
  `skills/` into a consumer repo's local `.claude/` — those now resolve at runtime via
  `${CLAUDE_PLUGIN_ROOT}`, so **the plugin must stay enabled for everyday sessions**, not just to run
  setup/sync. Nothing kept an unmanaged vendored copy updated, and `resolve-roots.sh` deliberately makes
  a repo-tracked `.claude/scripts` layout win over `${CLAUDE_PLUGIN_ROOT}`, so a stale vendored copy
  permanently shadowed a fresh plugin install (the reDeploy incident that prompted this issue). The
  `.claude/.orchestrator-vendor` marker and the vendor copy machinery are removed.
- **`pr-loop.service` → v2**: `ExecStart` now resolves `loop-daemon.sh` at unit-start time — prefers a
  repo-tracked `.claude/scripts/loop-daemon.sh` (self-hosting), else the newest
  `~/.claude/plugins/cache/*/orchestrator/*/scripts/loop-daemon.sh` — instead of assuming a vendored
  repo-local copy.
- **`.claude/settings.json` template**: hook commands now resolve via
  `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR/.claude}/scripts/...` instead of a hardcoded
  `$CLAUDE_PROJECT_DIR/.claude/scripts/...` path, matching the no-longer-vendored layout.

### Added
- **`/orchestrator:sync` detects and warns about stale/unmanaged local copies** of the
  now-unvendored `agents/commands/hooks/scripts/skills` directories instead of silently deleting or
  restamping them — flags byte-identical leftovers as safe to delete, diverging copies as a possible
  deliberate override, and calls out a leftover `.claude/.orchestrator-vendor` marker.

### Notes for downstream installs
- If your repo onboarded while vendoring was active (between #128 and #134), run `/orchestrator:sync`
  to get the stale-vendor report, then see `docs/MIGRATION.md` → "If you onboarded between issues #128
  and #134" for cleanup steps. **Keep the plugin enabled** after cleaning up.
- **Migration caveat:** deleting/refreshing files on disk is not enough for a repo with the loop already
  armed — a running `pr-loop`/`claude-rc` systemd unit holds its OLD script in memory until its unit
  restarts: `systemctl --user restart pr-loop-<repo-slug>.service claude-rc-<repo-slug>.service`.

## [0.2.1] - 2026-07-15

Everything shipped since 0.2.0. Headline: the driver now enforces a one-shot contract (no turn
ends before a PR exists, with post-exit verification and debris cleanup), worker worktrees and
branches auto-clean themselves after merge, and the cockpit groups live progress by task.

### Added
- **Cockpit live-progress grouping by task** (issue #92, PRs #101/#94): groups worker progress by
  task with issue/PR links and sortable columns.
- **Worker worktree + branch auto-cleanup after merge** (PRs #112/#91): once a worker's PR merges,
  its worktree and branch are cleaned up automatically.

### Changed
- **`arm-loop.sh` → v5** (`fd81eeb`): explicit `--spawn` flag, defaulting to `same-dir`; fixes
  remote-control blocking on its interactive first-run question inside a detached tmux pane.
  `claude-rc.service` → v5 in lockstep, consuming the new `--spawn` mode.

### Fixed
- **Driver one-shot contract** (commit `d37e951`, PRs #111/#118): driver orchestration is
  foreground-only — the driver's turn does not end before a PR exists — with post-exit
  verification and a debris classifier that cleans up stray branches/worktrees on failure.
- **Merged-ness check before worktree cleanup** (`933f202`): auto-cleanup now checks
  origin-ancestry before deleting a worker's worktree/branch, closing a gap where a locally-merged
  but not-yet-pushed branch could be deleted prematurely.
- **Daemon hardening + docs** (issues #106/#107, PRs #117/#119): daemon test scenarios 1/2 made
  deterministic under claude-less CI; resolved node/claude `PATH` baked into `pr-loop.service`;
  new WSL2 unattended-autostart docs and driver-death / classify-then-recover unwedge docs.

### Notes for downstream installs
- Run `/orchestrator:sync` after upgrading to 0.2.1 to pick up the managed-template bumps above —
  in particular `arm-loop.sh` v5 and `claude-rc.service` v5. Sync reconciles each file
  independently by its own `@orchestrator-managed <name> vN` marker — it does not key off this
  plugin version number, so a same-version reinstall is always a no-op and a behind-version
  install restamps cleanly as long as the local file has no hand-edits.
- After syncing, re-arm the loop (`arm-loop.sh`) and restart `claude-rc` so the v5 templates take
  effect.

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
