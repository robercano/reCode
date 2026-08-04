# Changelog

All notable changes to the `orchestrator` plugin are documented in this file. Format is loosely
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); versions track `plugin.json` /
`marketplace.json`.

## [Unreleased]
Entries land here as work merges; `.claude/scripts/release.sh` (issue #176) turns this into a dated
`## [X.Y.Z] - YYYY-MM-DD` section — ahead of the prior release, below this scaffold — at cut time. See
`docs/USAGE.md` → "Release cycle".

### Added
- **`/orchestrator:provision`** (issue #204): guided, resumable walkthrough of `docs/HARDENING.md`'s
  dedicated-Linux-server worked example — interview once, then nine checkpointed phases (agent user,
  fresh credentials, clone, managed settings, harden + arm, optional nftables egress / auditd
  detection / remote-SSH per `docs/REMOTE_SSH_RUNBOOK.md`) with per-phase verification and progress
  persisted in `.claude/state/provision-progress.json`.
- **Explicit GitHub-token mint walkthroughs** in the credential steps: `docs/HARDENING.md` worked
  example step 2 now carries the fine-grained-PAT click-path and exact permission table (Contents/
  Issues/Pull-requests read-write, Metadata read, Workflows only if the loop pushes CI files) plus the
  classic `repo`-scope bot-token recipe; `/orchestrator:provision` Phase 3 prints it, and
  `/orchestrator:setup` step 7's "action needed" path spells out the same bot-account walkthrough.

### Changed
- **`BOT_LOGIN` default is now derived from the bot token** instead of a hardcoded personal login:
  `pr-ci-fix.sh` / `pr-comment-fix.sh` / `pr-rebase.sh` / `pr-feedback.sh` fall back to
  `bot-gh.sh api user --jq .login` when `BOT_LOGIN` is unset, so consumer repos no longer silently
  filter for PRs authored by the plugin author's bot. Set `BOT_LOGIN` in `.env` to skip the extra
  API call; behavior is unchanged when it's set.

## [0.3.0] - 2026-08-04

### Changed
- #202: chore/ntfy-notify
- #203: feat/issue-138-packaging-exclude
- #199: feat/issue-177-feedback-skill
- #198: feat/issue-175-roadmap-generator
- #196: feat/issue-140-hooks-parity
- #195: feat/issue-181-census-plus-worktree-marker
- #194: feat/issue-174-milestone-scoped-census
- #193: feat/issue-176-release-rollout-conventions
- #191: feat/issue-141-sync-v2-checks
- #189: feat/issue-87-go-public-docs
- #183: chore/brand-v1.9-logo
- #186: claude/shared-statusbar-header
- #180: feat/issue-173-priority-labels-census
- #179: feat/issue-94-protected-paths
- #172: feat/issue-94-fence-driver-prompts
- #171: feat/issue-169-needs-human-rest-labels
- #168: feat/issue-158-census-stale-merged-remote
- #167: feat/issue-130-arm-loop-placeholder-guard
- #162: feat/issue-94-sanitize-untrusted
- #161: feat/issue-154-resume-dispatch
- #160: feat/issue-96-rebase
- #159: feat/issue-96-comment-fix
- #156: feat/issue-134-stop-vendoring
- #152: feat/issue-106-git-state-guard
- #155: feat/issue-129-gate-hygiene
- #153: feat/issue-96-ci-fix
- #151: feat/issue-128-vendor-runtime
- #150: feat/issue-124-rc-supervision
- #149: feat/issue-116-cockpit-staleness-badge
- #148: feat/issue-100-plan-gate
- #147: feat/issue-99-needs-human-signal
- #146: feat/issue-98-stall-resume
- #135: feat/issue-97-census-blocking-graph
- #131: fix/loop-driver-working-directory
- #127: feat/issue-95-loop-spend-ceilings
- #126: fix/cockpit-accurate-live-state
- #125: fix/worktree-env-bootstrap
- #122: feat/issue-119-driver-lifetime-decouple
- #121: fix/bot-gh-assign-review-notify
- #120: feat/issue-113-release-0.2.1
- #118: feat/issue-111-driver-oneshot-contract
- #117: feat/issue-107-harden-runtime-env
- #114: feat/issue-92-live-progress-groups
- #112: feat/issue-91-worktree-hygiene
- #110: feat/issue-109-release-0.2.0
- #108: feat/issue-90-pnpm-cockpit
- #105: feat/issue-86-rebrand-recode
- #104: feat/issue-85-loop-health-panel
- #103: feat/issue-102-cronless-loop-daemon
- #101: feat/issue-84-tool-mirror-activity
- #93: feat/issue-83-loop-tick-step0
- #89: feat/issue-88-consolidate-setup-commands
- #82: feat/issue-81-harden-loop-tick
- #80: feat/issue-78-bump-version-0.1.4
- #77: feat/issue-76-self-cmd-isolation
- #75: feat/issue-71-tool-mirror
- #74: feat/issue-70-worker-inspector
- #73: feat/issue-69-cockpit-serve-sse
- #72: feat/issue-approval-labels
- #67: chore/bump-0.1.3
- #66: feat/issue-63-plugin-root-derivation
- #65: feat/issue-64-fanout-smoke
- #61: chore/gitignore-pycache
- #62: feat/loop-post-merge-local-sync
- #60: fix/bump-plugin-version-for-hooks-fix
- #58: feat/issue-52-live-progress-events
- #57: fix/bump-plugin-version-for-hooks-fix
- #56: fix/plugin-hooks-json-schema
- #53: feat/issue-51-cockpit-dashboard
- #54: fix/bot-gh-assign-scope-fallback
- #55: feat/root-marketplace-alias
- #50: chore/gate-pnpm-freshness-preflight
- #49: feat/token-usage-optimization
- #48: feat/issue-39-packaging-phase4
merge main into feat/issue-39-packaging-phase4; resolve docs/USAGE.md; sync is now shipped (#46)
- #46: feat/issue-38-orchestrator-sync
- #47: feat/phone-testing-tunnel
- #45: feat/issue-37-orchestrator-setup
- #44: fix/hook-gate-path-project-dir
- #43: feat/issue-36-plugin-skeleton
- #42: feat/issue-25-ci-self-gates
- #41: feat/test-pr-command
- #40: feat/issue-24-pr-loop-self
- #34: feat/issue-33-auto-assign-pr-owner
- #35: docs/setup-orchestrator-pointers
- #32: feat/issue-19-onboarding-loop-docs
- #31: feat/issue-10-cockpit-evaluation
- #30: feat/issue-9-worktree-lifecycle-rebased
- #28: feat/issue-6-mixed-stack-example
- #27: feat/issue-5-concurrency-doc
- #26: feat/issue-4-test-affected-guidance
- #23: feat/issue-11-self-adapter
- #22: docs/setup-orchestrator-pointers
- #21: chore/harden-hygiene
- #20: chore/bot-identity-and-setup-orchestrator
- #18: chore/backport-sandbox-hardening
- #17: chore/backport-pr-loop
Merge branch 'main' into chore/backport-pr-loop
- #16: feat/auto-merge-loop
Merge branch 'main' into feat/auto-merge-loop
- #15: feat/pr-feedback-loop
- #14: feat/bot-gh-preflight
- #13: feat/ci-gates-workflow
- #7: docs/pr-feedback-loop
- #3: feat/seed-issues-example
- #2: docs/bootstrap-first
- #1: feat/permission-allowlist-hardening

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
