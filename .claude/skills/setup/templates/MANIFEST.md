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
| *(live plugin tree, not a template file)* `agents/`, `commands/`, `hooks/`, `scripts/`, `skills/` | `.claude/agents/`, `.claude/commands/`, `.claude/hooks/`, `.claude/scripts/`, `.claude/skills/` | managed (whole-tree, issue #128) | Vendored wholesale from the plugin ROOT (not from `templates/` — this is the only vendored row that copies the plugin's own live directories) so consumer sessions read the runtime harness off local disk without the plugin loaded. Gated as ONE unit by the top-level marker `.claude/.orchestrator-vendor` (`@orchestrator-managed runtime-vendor vN`), re-stamped/re-vendored on the same behind/never-downgrade ladder as every other managed row. **Exception:** `.claude/scripts/arm-loop.sh` is skipped by this copy — it is already its own row below with a different canonical source (`templates/arm-loop.sh`), and double-managing the same destination path from two pristine sources would make the two mechanisms disagree about what "up to date" means for that one file. |
| `.orchestrator-vendor` | `.claude/.orchestrator-vendor`      | managed (marker only) | The single version-stamp file that governs the whole-tree row above. Copied last, after the tree copy succeeds, so a failure mid-copy never leaves a stamped-but-partial vendor tree. |
| `settings.json`     | `.claude/settings.json`               | user      | created only if absent; never overwritten. Wires the runtime hooks (`PostToolUse` lint + log-worker-tool, `Stop` test_affected, `PreToolUse` guard-git-add) to `$CLAUDE_PROJECT_DIR/.claude/scripts/...`, plus baseline `permissions`/`sandbox`. Deliberately carries **no** `enabledPlugins`/`extraKnownMarketplaces` — those belong only in a settings.json the user maintains themselves while installing/updating the plugin. If a settings.json already exists, setup leaves it untouched and the setup SKILL instructs merging the runtime hooks in by hand. |

The three `managed` rows added by issue #102 (`pr-loop.service`, `claude-rc.service`, `arm-loop.sh`)
follow exactly the same ownership class and marker convention as `feature-fanout.js` — `scaffold.sh`
creates them on first setup and re-stamps them on a plugin upgrade if their installed marker is
behind, `sync.sh` re-stamps them going forward, and neither ever touches a copy whose content has
locally diverged from the last pristine version it was stamped from (that's a `conflict`, left for a
human — see `.claude/skills/sync/SKILL.md`).

The runtime-vendor row added by issue #128 reuses this exact same marker ladder, just applied to a
directory-tree copy instead of a single `cp` — see `.claude/scripts/arm-loop.sh` above for why it's
carved out as an exception rather than folded into the tree copy. Once vendored, the `orchestrator`
plugin only needs to stay **enabled** to run `/orchestrator:setup`/`/orchestrator:sync` (the
install/update channel) — not for everyday sessions, which is what removes the plugin's session-start
load cost from time-sensitive paths like headless `claude remote-control` spawns.

See `.claude/skills/setup/scaffold.sh` for the implementation, and `.claude/skills/setup/SKILL.md`
for the full onboarding flow this scaffold step is one part of.
