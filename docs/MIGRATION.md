# Migrating a hand-copied install to the plugin

If you adopted this template *before* it was packaged as a Claude Code plugin, you likely copied the whole
`.claude/` directory (agents, commands, hooks, scripts, and all) straight into your repo. This guide moves
that repo onto the plugin install, so the generic harness is maintained upstream instead of frozen in your
own git history.

If you haven't installed the plugin yet, do that first — see [`GETTING_STARTED.md` → Step 1 — Install the
`orchestrator` plugin](GETTING_STARTED.md#step-1--install-the-orchestrator-plugin).

## What to delete
Remove the copied harness that the plugin now carries — it's generic, not project-specific, and staying on a
frozen copy means you never get fixes/improvements:
- `.claude/agents/` — orchestrator, implementer, reviewer, test-runner.
- `.claude/commands/` — `pr-loop.md`, `harden.md`, `test-pr.md`, etc. (they resolve
  as namespaced `/orchestrator:*` commands once the plugin is enabled). Note: `pr-loop-self.md` is **not**
  among these — it lives under `.claude/self/` (not `.claude/commands/`) and is not plugin-distributed; see
  `.claude/self/README.md` if your repo has a self-hosting setup of its own.
- `.claude/skills/` — e.g. the `setup` skill.
- `.claude/hooks/` — `hooks.json` (the lint/test-affected wiring is now shipped by the plugin and resolves via
  `${CLAUDE_PLUGIN_ROOT}` automatically).
- `.claude/scripts/` — the generic ones (`gate.sh`, `bot-gh.sh`, `notify-poll.sh`, `pr-feedback.sh`,
  `merge-ready.sh`, `seed-issues.sh`, `worktree.sh`, `prepare-pr.sh`, etc.). If you added project-specific
  scripts of your own alongside these, keep only those.
- `.claude/.claude-plugin/` — if you'd copied this too (it's this repo's own plugin manifest, not something a
  consumer needs locally).

### Before you delete: check for local patches
The list above assumes your copy of each generic file is identical to (or just staler than) what the plugin
ships. That's not always true — a hand-copied install can accumulate real, load-bearing local fixes (e.g. a
bot-token-scope workaround in `bot-gh.sh`, an extra retry in `notify-poll.sh`). Deleting one of those silently
loses the fix, and it can be a while before anyone notices it's gone.

Before deleting each file, diff it against the plugin's shipped copy (`${CLAUDE_PLUGIN_ROOT}/<same-relpath>`
once the plugin is enabled, or the sibling clone's `.claude/<same-relpath>` if you're using the local-clone
install method) rather than assuming they match. For anything that diverges:
- **It's a generic improvement** (would help any consumer, not just this repo) — upstream it: open a PR
  against `ai-project-orchestrator` with the fix, then delete your local copy once it's merged and the plugin
  picks it up. No consumer-side sync step is needed for scripts/agents/commands (see "Enabling in a consuming
  project" above) — once the fix lands upstream, everyone with the plugin enabled gets it immediately.
- **It's genuinely project-specific** (tied to something only your repo has — a different bot account's token
  scopes, a stack-specific quirk) — don't delete it. Keep it as a locally-named override (e.g. rename it so it
  doesn't collide with the plugin's file, and repoint whichever command/prompt referenced it), and note in
  `CLAUDE.md` why the override exists so a future reader doesn't "clean it up" by mistake.

## What to keep
These are repo-specific — a plugin, by design, cannot carry them, so they stay yours regardless of the
install method:
- **`.claude/gates.json`** — your adapter (module map, gate commands, model routing, merge policy).
- **`CLAUDE.md`** — your project's context, conventions, and definition of done.
- **`.claude/workflows/feature-fanout.js`** — the deterministic fan-out workflow, tuned for your repo. This
  one is *managed*: `/orchestrator:setup` re-stamps it on future updates if its version marker is behind (see
  "Re-stamping managed files" below) — don't hand-edit it into something unrecognizable if you want that to
  keep working, or accept that you'll reconcile by hand.
- **Your CI gate workflow** under `.github/` (`.github/workflows/gates.yml` +
  `.github/actions/setup/action.yml`) — scaffolded once for your stack, and adapter-driven from there.

## How to enable the plugin
Follow [`GETTING_STARTED.md` → Step 1](GETTING_STARTED.md#step-1--install-the-orchestrator-plugin): add the
`ai-project-orchestrator` marketplace (local clone today; the GitHub-source snippet is the target flow, with
a documented resolution gap — see that section) and enable the `orchestrator` plugin. Do this **before**
deleting the copied files above, so you're never without a working `/agents` list or hooks mid-migration.

## Re-stamping managed files after an update
Once installed, updating the plugin and re-stamping managed files (`.claude/workflows/feature-fanout.js`,
mainly) is the **`/orchestrator:sync`** command — see [`USAGE.md` → "Updating the
plugin"](USAGE.md#updating-the-plugin).

`/orchestrator:sync` compares the version markers `/orchestrator:setup` already scaffolded against what the
current plugin ships and re-stamps anything behind — flagging local edits instead of clobbering them — while
leaving your `gates.json` and `CLAUDE.md` untouched (they're created once, never overwritten by re-runs).

## Verification checklist
- [ ] The `orchestrator` plugin shows as **enabled** (`/plugin`).
- [ ] `/agents` lists orchestrator, implementer, reviewer, test-runner, and `/orchestrator:*` commands resolve
      (e.g. `/orchestrator:pr-loop`, `/orchestrator:harden`).
- [ ] The old `.claude/agents/`, `.claude/commands/`, `.claude/skills/`, `.claude/hooks/`, and generic
      `.claude/scripts/` are gone from your repo (only your own project-specific scripts remain, if any).
- [ ] Gates still run: `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/gate.sh build|lint|test` behave the same
      as before.
- [ ] `.claude/gates.json` and `CLAUDE.md` are intact and unchanged (they're yours; the migration shouldn't
      have touched them).
- [ ] A pilot task still runs end-to-end (orchestrator → implementer → reviewers → PR) — see
      [`GETTING_STARTED.md` Step 3](GETTING_STARTED.md#step-3--pilot-run).
