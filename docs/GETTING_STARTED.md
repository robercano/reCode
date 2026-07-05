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
This template ships as a Claude Code plugin named `orchestrator` (plugin root `.claude/`), with a
`marketplace.json` alongside it. Two ways to add it — lead with the one that works today:

**The reliable method today — a local clone.** Claude Code's `/plugin marketplace add` accepts a plain
filesystem path, and this repo's marketplace root is `.claude/`:
```bash
git clone https://github.com/robercano/ai-project-orchestrator.git ../ai-project-orchestrator
```
Then, in Claude Code, inside **your own project**:
```
/plugin marketplace add ../ai-project-orchestrator/.claude
/plugin install orchestrator@ai-project-orchestrator
```
(`/plugin` alone opens an interactive picker if you'd rather browse marketplaces/plugins than type the
commands above.)

**The target flow — a GitHub source (has a known gap today).** The eventual "no local clone" install is to
declare the marketplace straight from GitHub in your project's `.claude/settings.json`:
```json
{
  "extraKnownMarketplaces": {
    "ai-project-orchestrator": {
      "source": { "source": "github", "repo": "robercano/ai-project-orchestrator" }
    }
  },
  "enabledPlugins": { "orchestrator@ai-project-orchestrator": true }
}
```
> **Known limitation.** Claude Code's `"source": "github"` marketplace source resolves `marketplace.json` at
> the repo **root** (`.claude-plugin/marketplace.json`). This repo's manifest instead lives at
> `.claude/.claude-plugin/marketplace.json`, because the plugin root is `.claude/`, not the repo root — so the
> bare GitHub shorthand above may not resolve for you yet. Use the local-clone method until this repo ships a
> dedicated, standalone marketplace repo at its root (a deferred follow-up — it can't be created from inside
> this repo). See `.claude/.claude-plugin/README.md` (once cloned) for the up-to-date detail on this gap.

## Step 2 — Onboard: run `/orchestrator:setup`
With the plugin enabled, run:
```
/orchestrator:setup
```
It interviews you, then writes the files a plugin **cannot** carry into your repo — agents, commands, hooks,
and scripts ship *with* the plugin, so there's nothing to copy or wire by hand for those. What the interview
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
- **`module:*` GitHub labels**, a **bot-account check** (`GH_BOT_TOKEN`), and offers to arm **`/orchestrator:pr-loop`**
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
`test_affected` runs on the `Stop` hook (shipped by the plugin's `hooks/hooks.json`, no `settings.json` edits
needed) after every change, so it should be *fast* — ideally only the tests touched by the diff. But "test
only what changed" isn't free in every stack. Sensible options:

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
7. **Arm the loop** — run **`/orchestrator:pr-loop`**. It self-adjusts cadence (FAST when there's ≥1 open PR or
   ≥1 open `module:*` issue, else IDLE) but the cron is session-scoped, so re-run it at the start of each session.
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
