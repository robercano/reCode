# reCode

**Orchestrated multi-agent development for [Claude Code](https://claude.com/claude-code).** reCode ships as a
Claude Code plugin that turns a lead agent into a small engineering team: an **orchestrator** scopes a task
into non-overlapping sub-tasks, hands each to a worktree-isolated **implementer**, gates the result against
your project's real build/lint/typecheck/test/coverage commands, and routes it through adversarial
**reviewers** (one per lens — correctness, tests, security, …) before it becomes a PR. Run it conversationally
for one-off work, or arm the **autonomous PR loop** so it drives your GitHub issue backlog hands-off: poll for
work → build → gate → review → open a bot-authored PR → wait for your approval → merge → repeat.

> Status: **v0** — a starting point to iterate on. The underlying Claude Code features (plugins, subagents,
> worktree isolation) are evolving; treat your first runs as calibration.

## What you get
- **The orchestrator pattern.** `orchestrator` (Opus) → `implementer` × N (Sonnet, each in its own git
  worktree + branch) → `reviewer` × N (one per lens, adversarial) → `test-runner`. See
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full topology and the reasoning behind it.
- **Gates as code.** `.claude/gates.json` is a versioned, per-project adapter (module map + real shell
  commands for build/lint/typecheck/test/coverage) that every agent must satisfy before it can call anything
  "done" — enforced by a `Stop` hook, not by asking the model nicely.
- **Worktree isolation.** Every implementer works in its own `git worktree`, so parallel workers physically
  cannot clash on the same files.
- **The autonomous PR loop.** A cron-less `systemd --user` daemon (or a session-scoped cron fallback) polls
  your repo, advances one `planned` + `module:*`-labelled issue at a time through the full
  scope → implement → gate → review → PR pipeline, and merges once **you** approve — see
  [`docs/USAGE.md`](docs/USAGE.md) → "Autonomous loop & the issue queue".
- **The cockpit.** A read-only dashboard — static snapshot or a live, auto-refreshing local server — showing
  open issues by module, PR review/CI state, and active worker worktrees in real time. See
  [below](#the-cockpit).

## Quickstart (5 minutes)
This is the actual supported path per [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) — reCode is added
to an **existing** project as a plugin, not created by cloning/templating a new repo.

**1. Install the `orchestrator` plugin** into your project. Either declare the marketplace straight from
GitHub (no local clone needed) in your project's `.claude/settings.json`:
```json
{
  "extraKnownMarketplaces": {
    "recode": { "source": { "source": "github", "repo": "robercano/reCode" } }
  },
  "enabledPlugins": { "orchestrator@recode": true }
}
```
...or clone it locally and add it as a filesystem marketplace:
```bash
git clone https://github.com/robercano/reCode.git ../reCode
```
then, inside **your own project**, in Claude Code:
```
/plugin marketplace add ../reCode/.claude
/plugin install orchestrator@recode
```

**2. Onboard: run `/orchestrator:setup`.** With the plugin enabled, run it in Claude Code. It interviews you
(project basics, module boundaries, gate commands, review/merge config) and scaffolds the files a plugin
can't carry into your repo — `.claude/gates.json`, `CLAUDE.md`, the fan-out workflow, the CI gate workflow —
plus a bot-account check and an offer to arm the loop.

**3. Arm the loop (optional but recommended).** Outside Claude Code, in a real terminal:
```bash
bash .claude/scripts/arm-loop.sh
```
This installs the `systemd --user` daemon that polls your repo and drives approved issues through the
pipeline unattended. See [`docs/USAGE.md`](docs/USAGE.md) → "Cron-less loop (daemon)" for the mechanics, and
[`docs/HARDENING.md`](docs/HARDENING.md) before running it with `bypassPermissions`.

Full walkthrough, prerequisites, and a new-project configuration checklist:
[`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md).

## The cockpit
`.claude/scripts/cockpit.sh` renders a static local HTML snapshot of your repo's orchestration state: open
issues by module with their blocking graph, PR review/CI status, per-role model routing, and active worker
worktrees. For a live, auto-refreshing view with a **worker inspector drawer** (click a live worker row to see
its timeline, breadcrumbs, worktree diff/forensics, and recent tool activity), run the serve mode:
```bash
pnpm cockpit            # http://127.0.0.1:8090
pnpm cockpit -- 9000     # custom port
```
It's a tiny Node HTTP server (no dependencies, node built-ins only, bound to `127.0.0.1`) wrapping the same
renderer used by the static snapshot. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#cockpit-read-only-dashboard)
and [`docs/COCKPIT_EVALUATION.md`](docs/COCKPIT_EVALUATION.md) for the design rationale.

<!-- TODO(#87): cockpit demo GIF — live workers + inspector drawer; pending screen capture (no agent can record a screen) -->
*(Demo pending: a short capture of the cockpit serve mode showing live worker rows updating in real time, and
the inspector drawer opening to show one worker's timeline/worktree/tool activity.)*

## What's in here
```
.claude/
  agents/         orchestrator · implementer (worktree) · reviewer · test-runner   ← shipped with the plugin
  commands/       /orchestrator:harden · /orchestrator:pr-loop · /orchestrator:test-pr
  skills/         setup, sync — onboarding + plugin-update reconciliation
  scripts/        gate.sh, cockpit.sh / cockpit-serve.sh, the loop daemon + its helpers
  self/           this repo's OWN self-hosted adapter (dogfooding — see docs/USAGE.md → "Self-hosting")
  gates.json      ★ PROJECT ADAPTER placeholder — module map, gate commands, model routing ← you fill this
CLAUDE.md         ★ project context placeholder                                            ← you fill this
CONTRIBUTING.md   how contributions to reCode itself work
LICENSE           MIT
.github/          CI gate workflow template
docs/
  GETTING_STARTED.md   setup, step by step
  ARCHITECTURE.md      the mental model & the three levers
  USAGE.md             how to drive the orchestrator day to day, incl. the autonomous loop
  PROMPTS.md           copy-paste prompts to populate files & kick off work
  TOKEN_BUDGET.md       cost control & measurement
  HARDENING.md         running the loop hands-off safely (bypass + sandbox)
  COCKPIT_EVALUATION.md design notes on the cockpit vs. third-party GUIs
```
★ = the only two files you must fill in per project once the plugin is installed.

## Installing / publishing
The supported install path is the **Claude Code plugin marketplace**, either via GitHub source
(`extraKnownMarketplaces`, no clone) or a local clone added as a filesystem marketplace — both shown in
[Quickstart](#quickstart-5-minutes) above, with the full rationale for having two `marketplace.json` files in
[`.claude-plugin/README.md`](.claude-plugin/README.md).

**npm: not published — name is squatted-dead (decision pending).** reCode is not currently published to npm.
The obvious package name is already registered by an unrelated, apparently abandoned/dead package, so an npm
release isn't a plain `npm publish` — the open options are (a) publish under a scope (e.g. `@robercano/recode`)
or (b) file an [npm name dispute](https://docs.npmjs.com/policies/disputes) against the squatted name. Neither
has been decided yet; this note exists so a contributor who wants to pick this up knows where the decision
stands. If you want to drive it, open an issue (`backlog` label — see [`CONTRIBUTING.md`](CONTRIBUTING.md))
proposing one option with the tradeoffs, and the repo owner will label it `planned` if approved.

## Docs
[`GETTING_STARTED.md`](docs/GETTING_STARTED.md) · [`ARCHITECTURE.md`](docs/ARCHITECTURE.md) ·
[`USAGE.md`](docs/USAGE.md) · [`PROMPTS.md`](docs/PROMPTS.md) · [`TOKEN_BUDGET.md`](docs/TOKEN_BUDGET.md) ·
[`HARDENING.md`](docs/HARDENING.md) · [`COCKPIT_EVALUATION.md`](docs/COCKPIT_EVALUATION.md)

## Contributing
See [`CONTRIBUTING.md`](CONTRIBUTING.md) — how issues move from `backlog` to `planned`, what the PR pipeline
enforces, and what's off-limits for external contributors.

## The one thing to remember
The orchestrator-worker pattern is powerful but costs **~15× the tokens of a single chat** (per Anthropic's
own research system). Scale effort to task complexity, route cheap models to cheap work, and measure spend.
See [`docs/TOKEN_BUDGET.md`](docs/TOKEN_BUDGET.md).

## License
[MIT](LICENSE) — Copyright (c) 2026 Roberto Cano.
