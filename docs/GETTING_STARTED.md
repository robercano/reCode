# Getting Started

From an existing project to a working orchestrator, installed as a **Claude Code plugin**, in 6 steps.
Budget ~20 minutes.

> **Prefer to be guided?** Once the plugin is enabled (Step 1), run **`/orchestrator:setup`** in Claude Code.
> It interviews you (project basics, module boundaries, gate commands, review/merge config), then scaffolds
> the files a plugin can't carry into your repo — `.claude/gates.json` + `CLAUDE.md` + the fan-out workflow +
> the CI gate workflow — fixes `.gitignore`, creates the `module:*` labels, verifies the bot, checks the CI
> gates, and offers to arm the PR loop and (last) `/orchestrator:harden`. This page is the manual reference
> behind that command — read it to understand what it's doing, or to configure by hand.

## Prerequisites
- Claude Code installed and authenticated (`claude` runs).
- `node` and `git` on PATH (the gate script uses `node` to read `gates.json`).
- Your project's actual build/test tooling installed (so the gate commands work).

## Step 1 — Install the `orchestrator` plugin
This template ships as a Claude Code plugin named `orchestrator` (plugin root `.claude/`). Two ways to add it:

**GitHub source (no local clone needed).** Declare the marketplace straight from GitHub in your project's
`.claude/settings.json`:
```json
{
  "extraKnownMarketplaces": {
    "recode": {
      "source": { "source": "github", "repo": "robercano/reCode" }
    }
  },
  "enabledPlugins": { "orchestrator@recode": true }
}
```
This works because a thin `.claude-plugin/marketplace.json` at the repo **root** (where Claude Code's
`"source": "github"` resolution looks) points at the actual plugin payload under `.claude/` via a relative
path (`"source": "./.claude"`) — see `.claude-plugin/README.md` for why there are two `marketplace.json`
files in this repo.

**Local clone (alternative, e.g. if you want a pinned/offline copy).** Claude Code's `/plugin marketplace add`
also accepts a plain filesystem path, using `.claude/` directly as the marketplace root:
```bash
git clone https://github.com/robercano/reCode.git ../reCode
```
Then, in Claude Code, inside **your own project**:
```
/plugin marketplace add ../reCode/.claude
/plugin install orchestrator@recode
```
(`/plugin` alone opens an interactive picker if you'd rather browse marketplaces/plugins than type the
commands above.)

Enabling the plugin here is what lets you run `/orchestrator:setup` in Step 2, and — unlike an earlier version
of this template (issue #128) — **keep the plugin enabled afterward too**: this repo does not vendor a local
copy of its own runtime harness into your repo (issue #134), so `agents/`, `commands/`, `hooks/`, `scripts/`,
`skills/` are read straight from the plugin cache on every session, not just during
`/orchestrator:setup`/`/orchestrator:sync`. See Step 2.

## Step 2 — Onboard: run `/orchestrator:setup`
With the plugin enabled, run:
```
/orchestrator:setup
```
It interviews you, then writes the files a plugin **cannot** carry into your repo — it does **not** copy the
plugin's own `agents/commands/hooks/scripts/skills` into your repo (issue #134: an earlier version of this
template vendored those wholesale into your local `.claude/` so a session could read them off disk with the
plugin disabled, issue #128 — that model was reverted because nothing kept an unmanaged vendored copy updated,
and a stale local copy permanently shadows a fresh plugin install; see `resolve-roots.sh`). It also creates a
**`.claude/settings.json`** from a template *if you don't already have one*, wiring the runtime hooks to
`${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR/.claude}/scripts/...` — the plugin cache while the plugin is
enabled, falling back to a local `.claude/scripts/` only if you're self-hosting this template directly (no
distinct plugin install). **Keep the `orchestrator` plugin enabled for everyday sessions** — its own
`hooks/hooks.json` and, unless you drop the block, this file's `hooks` both need it loaded. What the interview
collects and scaffolds:

- **`.claude/gates.json`** (the adapter — the *only* file that makes the generic agents work on YOUR stack). Set:
  - **`project`** — name, language, package manager.
  - **`modules`** — the map of independent areas + their paths. This is what the orchestrator uses to give each
    worker a non-overlapping boundary. Get this right and clashes mostly disappear.
  - **`gates`** — the exact shell commands for `build`, `lint`, `typecheck`, `test`, `test_affected`,
    `coverage`, `e2e`, `security`. Leave any you don't have as `""` (it's skipped, not failed).
  - **`coverage_threshold`**, **`review.lenses`**, **`budget`** (model routing + `max_parallel_workers`),
    **`merge.policy`**.
- **`CLAUDE.md`** — project-wide context every agent reads (what the project is, stack & layout, conventions,
  definition of done, merge policy). Kept lean by design.
- **`.claude/workflows/feature-fanout.js`** — the deterministic fan-out workflow (managed; re-stamped on
  updates, see [`USAGE.md` → "Updating the plugin"](USAGE.md#updating-the-plugin)).
- **`.github/workflows/gates.yml`** + **`.github/actions/setup/action.yml`** — the CI gate workflow (Step 4
  below).
- **`module:*` GitHub labels**, a **bot-account check** (`GH_BOT_TOKEN`), and offers to arm the loop — the
  **cron-less loop daemon** (recommended, `systemd --user`) or the legacy **`/orchestrator:pr-loop`** cron —
  and, last, **`/orchestrator:harden`**.

**Sanity-check the gates once it's written** (ask Claude Code to run these, so `${CLAUDE_PLUGIN_ROOT}`
resolves correctly whether the plugin is installed or you're dogfooding this repo directly):
```bash
bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/gate.sh build
bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/gate.sh lint
bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/gate.sh test
```
Each should run the right command (or say "not configured — skipping").

> **Bootstrap first.** On a brand-new project there's usually no build system yet, so *real* gate commands
> will **fail** (not skip) — e.g. `pnpm -r build` with no workspace, `forge test` with no `foundry.toml`. Pick
> one:
> - **Scaffold a minimal buildable skeleton first** (workspace manifest + empty buildable packages/stubs that
>   build and pass a trivial test), *then* wire the real gate commands. This makes the pilot run (Step 3) work
>   immediately and gives parallel workers a green baseline to branch from. Recommended.
> - **Or keep the gates empty** (`""` = skipped) until your first task is an explicit "bootstrap the workspace"
>   ticket, and only fill in real gate commands once that lands.
>
> Either way, don't point a gate at a command that can't pass yet — a red `test_affected` will block the
> `Stop` hook and every agent's "done".

### Choosing `test_affected` per stack
`test_affected` runs on the `Stop` hook — wired both by the plugin's own `hooks/hooks.json` and by the
`.claude/settings.json` `/orchestrator:setup` scaffolds (Step 2 above; it calls
`${CLAUDE_PLUGIN_ROOT:-$CLAUDE_PROJECT_DIR/.claude}/scripts/gate.sh test_affected`) — after every change, so it
should be *fast* — ideally only the tests touched by the diff. But "test only what changed" isn't free in every
stack. Sensible options:

| Stack | Cheap `test_affected` | Notes |
|---|---|---|
| turbo | `turbo run test --filter='...[origin/main]'` | needs turbo |
| nx | `nx affected -t test --base=origin/main` | needs nx |
| pnpm (no turbo/nx) | `pnpm --filter '...[origin/main]' test` | flaky in worktrees unless `origin/main` is fetched first — see #9 |
| cargo | `cargo test` (or `cargo nextest run`) | no cheap since-base; full suite is fine |
| go | `go test ./...` | already fast; no filter needed |
| Foundry | `forge test` | **no** native since-base — run all |
| gradle | `./gradlew test` | full suite |

**`test_affected` = your full `test` command is a perfectly good default** whenever the suite is fast — only
reach for affected-filtering when the full run is too slow to gate on every `Stop`. And note the worktree
gotcha: any filter that diffs against `origin/main` needs that ref present in the worktree, so `git fetch
origin main` first (or fall back to the full suite) — the per-worktree setup hook in #9 is the place for that.

Agents (`/agents` in Claude Code lists orchestrator, implementer, reviewer, test-runner) and hooks ship
generic and read `gates.json`, so they typically need no edits. Adjust `model:` per agent if your routing
differs, or add project review skills (e.g. a security/audit skill) and reference them in `gates.json` →
`review.skills`.

## Step 3 — Pilot run
Don't unleash the whole army first. Run ONE real task end-to-end:

```
Use the orchestrator agent. Task: <one small, real, self-contained feature/fix>.
Scope it, show me the plan, and wait for my approval before writing code.
```

Approve the plan, let one implementer run in its worktree, watch the reviewers gate it, review the PR. Then
read [`USAGE.md`](USAGE.md) to scale up, and [`TOKEN_BUDGET.md`](TOKEN_BUDGET.md) before you go parallel.

## Step 4 — Enforce gates in CI (server-side)
The hooks and `gate.sh` enforce gates *locally*, and the orchestrator runs them before opening a PR — but
nothing stops a human (or a bot) merging a PR whose gates never ran. `/orchestrator:setup` scaffolds
[`.github/workflows/gates.yml`](../.github/workflows/gates.yml) + a `.github/actions/setup` composite action
that run **the same `gate.sh` gates** on every `pull_request`, reading commands from `gates.json`. It's
adapter-driven — you configure `gates.json`, not the YAML.

1. **It works out of the box for JS/TS.** For other stacks, add the toolchain at the *Extension point* comment
   in `.github/actions/setup/action.yml` (e.g. `foundry-rs/foundry-toolchain` for Solidity,
   `actions/setup-python`), keyed off `project.language`. Empty gates skip, so unconfigured checks stay green.
2. **Make the checks required** — this is the actual enforcement. On the base branch (`merge.baseBranch`):
   **Settings → Branches → Add branch protection rule** → *Require status checks to pass before merging*, then
   select the gate checks (`build`, `lint`, `typecheck`, `test`, `coverage`, `security`). Or via CLI:
   ```bash
   gh api -X PUT repos/<owner>/<repo>/branches/<base>/protection \
     -f 'required_status_checks[strict]=true' \
     -f 'required_status_checks[checks][][context]=build' \
     -f 'required_status_checks[checks][][context]=lint' \
     -f 'required_status_checks[checks][][context]=typecheck' \
     -f 'required_status_checks[checks][][context]=test' \
     -f 'required_status_checks[checks][][context]=coverage' \
     -f 'enforce_admins=true' -F 'required_pull_request_reviews=null' -F 'restrictions=null'
   ```
   Without this step the workflow only *reports* pass/fail; required checks are what block the merge button.

   > **Free private repos can't enforce.** Required status checks (and branch protection) need a paid plan
   > on a private repo — GitHub will reject the call above with *"upgrade to GitHub Team/Enterprise"*. Options:
   > make the repo **public** (enforcement is free), upgrade the plan, or run **convention-based**: the checks
   > still run and are visible on every PR, and `merge-ready.sh` only merges a PR once the owner has approved
   > it *and* CI is green — so the approval+green gate holds even though GitHub doesn't hard-block the button.

## New-project configuration checklist
A copy-pasteable checklist for wiring a new project into the autonomous loop. See
[`USAGE.md` → "Autonomous loop & the issue queue"](USAGE.md#autonomous-loop--the-issue-queue) for the mental
model (the `module:*` opt-in queue + the owner-approval merge gate) that this checklist wires up.

1. **Install the plugin and run `/orchestrator:setup`** (Steps 1–2 above) — it writes everything below except
   the two GitHub-side actions (4, 6).
2. **`.claude/gates.json`** — the only per-project file that must be filled: `project.{name,language,packageManager}`;
   `modules[]` (one entry per independently-ownable area, each with a non-overlapping `path` — these become
   both the worker boundaries and the `module:<name>` labels the loop understands; include non-code areas
   like `docs` if you want them automatable); `gates.*` (real shell commands, `""` = skip); `coverage_threshold`;
   `review.{lenses,consensus}`; `budget.*` (model routing, `max_parallel_workers`); `merge.{policy,baseBranch}`.
3. **`CLAUDE.md`** — project context, conventions, definition of done, merge policy.
4. **Bot machine account** — create it, add as a write collaborator, put `GH_BOT_TOKEN` in `.env` (gitignored).
   All agent/loop `gh` calls run as the bot via `bot-gh.sh`; only `git` commits/pushes stay on the owner's
   auth, so the owner can approve bot PRs. Setup notes live at the top of `.claude/scripts/bot-gh.sh`.
5. **Create the `module:*` labels** matching your `modules[]` names — see the bootstrap note at the top of
   `.claude/scripts/seed-issues.sh`. Without the label, ADVANCE can never queue the issue.
6. **Server-side gates** — confirm `.github/workflows/gates.yml` runs your gate commands (Step 4 above), and
   set branch protection / required status checks on `merge.baseBranch` if your plan supports it.
7. **Arm the loop** — recommended: **`bash .claude/scripts/arm-loop.sh`** (run in a real terminal *outside*
   Claude Code — installing systemd units, `loginctl enable-linger`, and a detached tmux session all touch
   `$HOME`, which the sandbox blocks). This installs `pr-loop-<repo>.service` (the cron-less daemon —
   supervised by `systemd --user`, survives Claude Code restarts, adaptive FAST/WATCH/IDLE sleep read
   straight off the census) and `claude-rc-<repo>.service` (`claude remote-control` in a detached tmux
   session, for spawning planning sessions remotely). Self-hosting: add `--gates-file
   self/gates.json`. See [`USAGE.md` → "Cron-less loop
   (daemon)"](USAGE.md#cron-less-loop-daemon) for the full architecture, cadence, run ledger, and
   failure-contract details, including WSL2's `systemd=true` prerequisite.
   Fallback (no systemd available): **`/orchestrator:pr-loop`** — the legacy session-scoped cron. It
   self-adjusts cadence the same way (FAST when there's ≥1 open PR or ≥1 open `module:*` issue, else IDLE)
   but dies with the Claude Code session that armed it, so it must be re-run at the start of each session.
   **Never run both against the same repo at once** — `loop-tick.sh`'s spawn lock makes it *safe* (no
   double-spawn), just wasteful.
   **Pick the right model for each side of the loop:** the daemon's driver sessions default to **Sonnet**
   (`LOOP_MODEL` env, read by `loop-event.sh`) — the ticks are repetitive, and that repetition is exactly
   where smaller models drift (a Haiku-driven tick session has been observed to stop running the step
   scripts and fabricate their output, and to double-spawn orchestrators for one issue).
   `.claude/scripts/loop-tick.sh` hardens the tick itself — one script computes the census/feedback/advance
   verdict and a self-healing spawn lock, instead of a model re-deriving it from a prompt every firing (see
   [`USAGE.md`](USAGE.md) → "Model selection") — but a driving cron session still needs Sonnet to read that
   verdict and act on it. Use **Fable or Opus** for the owner-side judgment work — scoping, planning, and
   filing issues — then let the loop execute the approved queue.
8. *(optional)* **Hardening** — `/orchestrator:harden` for the bypass + strict-sandbox profile, see
   [`HARDENING.md`](HARDENING.md).

## Step 5 — Keep the plugin up to date
When a new version of `orchestrator` ships, update it and re-stamp the files it scaffolded into your repo —
see [`USAGE.md` → "Updating the plugin"](USAGE.md#updating-the-plugin).

## Verification checklist
- [ ] The `orchestrator` plugin shows as enabled (`/plugin`).
- [ ] `CLAUDE.md` describes the project and lists modules.
- [ ] `.claude/gates.json` has real commands; `gate.sh build|lint|test` behave correctly.
- [ ] `/agents` lists orchestrator, implementer, reviewer, test-runner; `/orchestrator:*` commands resolve.
- [ ] A pilot task produced a branch/PR that passed gates + review.
- [ ] CI gates run on PRs and are set as **required** status checks on the base branch (Step 4).
- [ ] You've checked spend with `/cost` or `npx ccusage`.

## Migrating an existing hand-copied install
Already have `.claude/` copied wholesale into a repo from before this was packaged as a plugin? See
[`MIGRATION.md`](MIGRATION.md) — it covers what to delete (now carried by the plugin), what to keep
(your adapter/`CLAUDE.md`/workflow/CI files), and how to switch to the plugin install above.
