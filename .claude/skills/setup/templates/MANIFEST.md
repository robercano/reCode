# Template → destination map

Read by humans (and `scaffold.sh`, informally) to see where each template lands in a
consumer repo. None of these paths are distributable inside the plugin package itself
(workflows and CI YAML aren't carried by a Claude Code plugin), so `/orchestrator:setup`
materializes them into the consumer repo on first run.

| Template file    | Destination in consumer repo         | Ownership | Re-run behavior                          |
|-------------------|---------------------------------------|-----------|-------------------------------------------|
| `gates.json`       | `.claude/gates.json`                  | user      | created only if absent; never overwritten |
| `CLAUDE.md`         | `CLAUDE.md`                            | user      | created only if absent; never overwritten |
| `feature-fanout.js` | `.claude/workflows/feature-fanout.js` | managed   | re-stamped when the `@orchestrator-managed feature-fanout vN` marker is older than the version scaffold.sh ships; left alone if same/newer |
| `pr-loop.service`   | `.claude/systemd/pr-loop.service`     | managed   | (issue #102) systemd user unit TEMPLATE for the cron-less loop daemon — `__WORKDIR__`/`__REPO_SLUG__`/`__GATES_ENV__` placeholders are substituted at ARM time by `.claude/scripts/arm-loop.sh`, not by scaffold.sh. Re-stamped like `feature-fanout.js` via its own `@orchestrator-managed pr-loop-service vN` marker. |
| `claude-rc.service` | `.claude/systemd/claude-rc.service`   | managed   | (issue #102) systemd user unit TEMPLATE that starts `claude remote-control` inside a detached tmux session. Same placeholder-at-arm-time / marker-restamp behavior as `pr-loop.service`, marker `@orchestrator-managed claude-rc-service vN`. |
| `arm-loop.sh`       | `.claude/scripts/arm-loop.sh`         | managed   | (issue #102) installs both systemd units above (with placeholders substituted for THIS checkout) + `loginctl enable-linger` + starts the remote-control tmux session. MUST be run in a real terminal outside Claude Code (sandbox caveat — see `docs/HARDENING.md`). Marker `@orchestrator-managed arm-loop vN`; copied with the executable bit preserved. |
| `gates.yml`         | `.github/workflows/gates.yml`         | ci        | created only if absent; never overwritten |
| `action.yml`        | `.github/actions/setup/action.yml`    | ci        | created only if absent; never overwritten |
| `settings.json`     | `.claude/settings.json`               | user      | created only if absent; never overwritten. Wires the runtime hooks (`PostToolUse` lint + log-worker-tool, `Stop` test_affected, `PreToolUse` guard-git-add) to `${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR/.claude}/scripts/...`, plus baseline `permissions`/`sandbox`. Deliberately carries **no** `enabledPlugins`/`extraKnownMarketplaces` — those belong only in a settings.json the user maintains themselves while installing/updating the plugin. If a settings.json already exists, setup leaves it untouched and the setup SKILL instructs merging the runtime hooks in by hand. |

The three `managed` rows added by issue #102 (`pr-loop.service`, `claude-rc.service`, `arm-loop.sh`)
follow exactly the same ownership class and marker convention as `feature-fanout.js` — `scaffold.sh`
creates them on first setup and re-stamps them on a plugin upgrade if their installed marker is
behind, `sync.sh` re-stamps them going forward, and neither ever touches a copy whose content has
locally diverged from the last pristine version it was stamped from (that's a `conflict`, left for a
human — see `.claude/skills/sync/SKILL.md`).

## Stopped vendoring the runtime harness (issue #134)
Issue #128 used to vendor the plugin's own `agents/`, `commands/`, `hooks/`, `scripts/`, `skills/`
subtrees wholesale into a consumer's `.claude/`, gated by a single top-level marker
`.claude/.orchestrator-vendor`, so a session could read them off local disk with the plugin disabled.
That model was reverted by issue #134: consumer repos no longer carry local copies of these
directories at all. `agents/commands/hooks/scripts/skills` are read straight from the plugin cache
(`${CLAUDE_PLUGIN_ROOT}`) instead — **the `orchestrator` plugin must now stay enabled for everyday
sessions**, not just to run `/orchestrator:setup`/`/orchestrator:sync`. Reasoning: nothing kept the
old vendored copy updated outside of `/orchestrator:sync`, and `resolve-roots.sh` deliberately makes a
repo-tracked `.claude/scripts` layout win over `${CLAUDE_PLUGIN_ROOT}` (correct for the self-hosting
and worktree-gate-run cases) — so a consumer who forgot to `sync` regularly ended up permanently
shadowing a fresh plugin install with a stale vendored copy (see the reDeploy incident that prompted
#134).

`sync.sh` does **not** delete a repo's leftover vendored copy from before this change (a local copy
might be a deliberate override, not just staleness) — it only **detects and warns**: for each of
`agents/commands/hooks/scripts/skills` still present locally, it diffs against the plugin's own
shipped copy and reports either `stale-vendor: ... safe to delete` (content identical — just shadowing
the plugin cache) or `stale-vendor conflict: ...` (content diverges — treat as a possible deliberate
override and review the diff before deleting). It also calls out a leftover
`.claude/.orchestrator-vendor` marker file specifically. See `.claude/skills/sync/sync.sh`'s
`detect_stale_vendor_copies` and `.claude/skills/sync/SKILL.md`.

**Migration caveat:** deleting/refreshing files on disk is not enough for a repo with the loop already
armed — a running `pr-loop`/`claude-rc` systemd unit holds its OLD script **in memory** until its unit
restarts. After cleaning up a stale vendored copy, restart the units:
`systemctl --user restart pr-loop-<repo-slug>.service claude-rc-<repo-slug>.service` (cf. the
2026-07-16 reCode deploy-lag incident, issue #131).

See `.claude/skills/setup/scaffold.sh` for the implementation, and `.claude/skills/setup/SKILL.md`
for the full onboarding flow this scaffold step is one part of.
