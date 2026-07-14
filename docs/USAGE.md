# Using the Orchestrator (after setup)

> **Assumes:** you've installed the `orchestrator` Claude Code plugin and run `/orchestrator:setup` in your
> project — see [`GETTING_STARTED.md`](GETTING_STARTED.md) if you haven't. Agents, commands, hooks, and
> scripts ship *with* the plugin; `/orchestrator:setup` scaffolds the repo-specific residue the plugin can't
> carry (`.claude/gates.json`, `CLAUDE.md`, the fan-out workflow, the CI gate workflow). Everything below is
> what you do once that's in place — day-to-day driving, the human checkpoints, and the autonomous loop.

Two ways to drive it: **conversational** (the orchestrator subagent — flexible) or **workflow** (deterministic
fan-out). Plus the human checkpoints that keep you in the loop.

## A. Conversational — the orchestrator subagent
Best for one-off or exploratory tasks where the shape isn't known up front.

**Kick off:**
```
Use the orchestrator agent. Task: <describe the goal>.
Scope it into non-overlapping sub-tasks by module, show me the plan, and WAIT for approval.
```
The orchestrator reads `gates.json` + `CLAUDE.md`, decomposes, and presents a plan in plan mode.

**Approve / adjust the plan** — this is your *planning checkpoint*. Check: are sub-tasks truly independent? Is
each inside one module? Too many workers for the size? Then approve.

**Let it run.** Each sub-task goes to an `implementer` in its own worktree/branch; on "done" the orchestrator
fans the change to `reviewer`s (one per lens); rejects loop back to the implementer until clean.

**Mid-run controls:**
- "Status?" → orchestrator emits the standup block (done/in-progress/blocked, branches, gates, risks).
- "Pause worker B / drop sub-task C / re-scope D."
- "Show me worker A's diff before it opens a PR."

## B. Workflow — deterministic fan-out
Best for repeatable, known-shape work (a feature with clear parts, a migration, a sweep). Token-heavy, so it's
gated behind explicit opt-in.

```
ultracode run the feature-fanout workflow with task: "<your task>"
```
or ask: *"Run the `feature-fanout` workflow, args.task = '…'"*. It runs `Scope → Implement → Review → loop`
(up to 3 iterations/sub-task) and returns approved vs. needs-human results. Watch live with `/workflows`.

Tune `.claude/workflows/feature-fanout.js`: `LENSES`, `MAX_ITERS`, model per stage, worktree isolation.

## Tickets: GitHub Issues (optional)
A clean way to feed the orchestrator one task at a time is a module-labeled **GitHub Issues** backlog. The
template ships `.claude/scripts/seed-issues.sh` as a starting point: it derives `module:<name>` labels from the
`modules` in `gates.json` (plus `type:feature`/`type:infra`), and bulk-creates issues idempotently (re-running
reuses labels and skips titles that already exist). Replace the placeholder `TICKETS` section with your backlog,
then:
```bash
gh auth login                      # once
bash .claude/scripts/seed-issues.sh
```
Drive one issue at a time: *"Use the orchestrator agent. Task: implement issue #N. Scope it within its module,
show the plan, and WAIT for approval."* Keep each ticket scoped to ONE module so workers get non-overlapping
boundaries.

## The human checkpoints (your agile cadence)
| Ceremony | Mechanism | What you do |
|---|---|---|
| **Sprint planning** | Plan mode (`ExitPlanMode`) | Approve/adjust the decomposition before any code |
| **Daily standup** | `/workflows` board · "Status?" · `TodoWrite` list | Glance at progress; unblock |
| **Sprint demo** | PR-per-agent + `/review` + `verify`/`run` skills | Review each branch; see features actually work |
| **Retro** | `npx ccusage` + run notes | Tune routing, worker count, prompts for next run |

## The iteration loop (how "done" is enforced)
```
implementer ──done──▶ gates (build/lint/types/test/coverage via gate.sh + hooks)
                          │ red → implementer keeps working (Stop hook blocks finish)
                          ▼ green
                     reviewers (1 per lens, adversarial)
                          │ any reject → reasons fed back → implementer iterates
                          ▼ consensus approve (per gates.json review.consensus)
                     PR / merge (per gates.json merge.policy)
```

## The PR feedback loop (ticket → PR → review → merge)
With `pr-per-agent`, the standing loop per ticket looks like:
1. **Plan** — tickets are the backlog (GitHub Issues work well — see the seeder example), planned with the
   orchestrator or added manually.
2. **Build** — orchestrator scopes → implementers (isolated worktrees) → reviewer lenses → gates green.
3. **PR** — created with `.claude/scripts/bot-gh.sh pr create …` so the PR author is a **bot machine
   account**, not the repo owner. GitHub hard-blocks PR authors from approving their own PRs, so PRs created
   under the owner's `gh` auth can never receive a formal Approve. One-time setup lives at the top of
   `bot-gh.sh` (free machine account → collaborator → classic `repo`-scope PAT → `GH_BOT_TOKEN` in `.env`).
   Reuse ONE generically-named bot across all your repos — GitHub ToS allows one free machine account per
   person. Only `pr create` uses the bot; commits/pushes stay on the owner's auth.
   **Per-repo grant (easy to miss):** the bot must be a **collaborator on every (private) repo** it opens PRs
   in — adding it once to one repo does *not* cover the rest. Without it, `gh` fails with an opaque
   `Could not resolve to a Repository with the name '<owner>/<repo>'` (looks like a typo, is actually a
   missing grant). `bot-gh.sh` preflights this and prints the fix; the one-time setup is, as the **owner**:
   `gh api -X PUT repos/<owner>/<repo>/collaborators/<bot> -f permission=push`, then **accept as the bot**:
   `bot-gh.sh api -X PATCH user/repository_invitations/<id>` (private-repo invites require acceptance).
   **Owner notification:** `bot-gh.sh pr create` auto-assigns the new PR to the repo owner (unless the
   caller already passed `--assignee`/`-a`) so the owner gets a GitHub notification that review is awaited.
   The owner login comes from `$OWNER_LOGIN` if set, else — for cross-repo calls — from the `--repo`/`-R`
   target's owner, else it's parsed from the local `origin` git remote. If it can't be resolved, the PR is
   still created — just unassigned.
4. **Review** — the owner reviews on GitHub. To address comments, feed them back through the orchestrator
   (*"address the comments on PR #N"*): same implementer loop, same branch, push updates the PR in place.
5. **Merge** — owner approves, merge per `gates.json.merge`, clean the worktree (below).

**Closing the loop automatically:** webhooks rarely reach a dev box, so poll. Two firing sources exist — the
**cron-less loop daemon** (`systemd --user`, recommended — see [below](#cron-less-loop-daemon)) or the
**legacy session-scoped cron** (`/orchestrator:pr-loop`, kept as a fallback for environments without
systemd). Both ultimately run the same three loop scripts in order — each a single stable command to
pre-approve in `settings.json`, since an inline compound command (loops, `$()`, redirects) never matches a
permission rule and would block on a prompt every firing:

1. **`bash .claude/scripts/notify-poll.sh`** — prints new issues and PR comments/reviews since a cursor file
   (`.claude/state/notify-cursor`, gitignored), plus a cursor-independent **`open pr status`** section (per
   open PR: latest owner review, CI rollup, mergeable) so the loop sees merge-readiness, which is a *state*,
   not an event. Summarize new items.
2. **`bash .claude/scripts/pr-feedback.sh`** — lists open bot PRs with *unaddressed* `CHANGES_REQUESTED`
   feedback (deduped via a `<!-- claude-addressed -->` marker). For each, dispatch the orchestrator to
   address the comments on the same branch and push — the implementer posts the marker after pushing.
3. **`bash .claude/scripts/merge-ready.sh`** — merges every open PR the owner has **APPROVED** that is
   mergeable and CI-green, then deletes the branch. The human Approve is the only merge gate; the script
   never approves. **Safety:** it merges only if the approval was submitted *at/after* the PR's last commit,
   so a free private repo (no branch protection to dismiss stale approvals) never auto-merges commits you
   haven't reviewed — pushing after approval requires re-approval. Uses ambient `gh` auth (merging is an
   owner action; only PR *creation* uses the bot).

**Or run it as one script:** `.claude/scripts/loop-tick.sh` runs the census (`loop-census.sh`) plus all three
scripts above, IN ORDER, with their full output preserved, and prints exactly one machine-readable verdict line
at the end — `action=none`, `action=advance issue=N`, or `action=feedback pr=N` — collapsing the whole tick
into a single pre-approvable command. It also owns a self-healing spawn lock
(`.claude/state/loop-advance.lock`) so a second tick fired before the first ADVANCE has even reached PR stage
never double-spawns an orchestrator for the same issue: the lock is released once the issue's branch exists
(work has reached PR-race stage) or an open PR exists, OR — if neither ever happens because the spawn
crashed before pushing a branch — once the lock is older than its 15-minute TTL, so a crashed spawn cannot
wedge the issue forever. The read-check-write around the lock is additionally serialized with `flock` so two
overlapping ticks can't both pass the check and double-spawn; see the script's header comment for the full
contract.

With all three wired, the loop runs hands-off: **add issues → review → approve → it merges and advances**.
A natural step 4 is to start the next `module:*` issue only when **no PRs are open**, so work stays
serialized (one issue in flight) and bounded. **How it actually fires** — the recommended cron-less daemon
vs. the legacy session-scoped cron, adaptive cadence, the run ledger, and the one non-self-healing failure
state — is covered in [Cron-less loop (daemon)](#cron-less-loop-daemon) below.

**Running it fully hands-off?** Polling still leaves a human approving each tool call. To let the loop
run unattended (Claude Code `bypassPermissions`), first harden the environment so the prompt is replaced
by always-enforced guardrails — see **[`HARDENING.md`](HARDENING.md)** (deny list + OS sandbox + host
isolation). Don't enable bypass without it — this applies equally to the daemon's headless driver spawns,
which have no interactive tty to prompt at all.

## Cron-less loop (daemon)
**Recommended default (issue #102).** Two `systemd --user` services replace the session-scoped cron:

- **`pr-loop-<repo>.service`** → `.claude/scripts/loop-daemon.sh`, `Restart=always`. A genuine forever loop
  supervised by `systemd`, not a Claude Code session — it survives Claude Code restarting or exiting
  entirely. Each iteration runs **`.claude/scripts/loop-event.sh`**, which runs the deterministic tick
  (`loop-tick.sh`) and parses its LAST-line verdict byte-identical (issue #81 contract: the verdict is
  computed once, in shell, never re-derived by a model). On `action=none` the daemon sleeps and loops —
  **no model/driver process is ever touched**, so a quiet repo costs nothing beyond the tick's own `gh`
  calls. On an actionable verdict (`action=advance issue=N` / `action=feedback pr=N`) it spawns exactly
  **one** contained driver: `setsid timeout --kill-after=30s <LOOP_DRIVER_TIMEOUT, default 90m> claude
  --model <model> -p "<verdict-obeying prompt>" --output-format json`. `setsid` gives the driver (and any
  bash children it spawns) its own process group, independent of the daemon's; on timeout the whole group
  is targeted, not just the immediate child, so a driver's own children can never be orphaned by a bare
  `SIGTERM`. The daemon itself never runs two drivers concurrently (it's a single-threaded loop), and
  `loop-tick.sh`'s own spawn lock additionally guards against a second overlapping tick anywhere else
  (e.g. the legacy cron armed at the same time) double-firing the same ADVANCE.
- **`claude-rc-<repo>.service`** → `claude remote-control` inside a detached tmux session (`rc-<repo>`), for
  spawning **new planning sessions remotely** — from claude.ai or the Claude Code mobile app — decoupled
  from the loop's own ticking. `arm-loop.sh --capacity N --permission-mode <mode>` controls its
  concurrency/permission posture.

**Cadence.** The daemon's sleep between ticks is read straight off `loop-tick.sh`'s own census, whose
`cadence=FAST|WATCH|IDLE cron=<expr>` line already encodes the loop's desired attentiveness (FAST only when
there's something actionable *now*). `loop-daemon.sh`'s `cadence_to_sleep_seconds()` maps that line to:

| Census cadence | Sleep |
|---|---|
| `FAST` | 60s |
| `WATCH` | 300s |
| `IDLE` | 900s |
| *(unparseable / missing)* | 300s (fallback) |

Override any of the four via `LOOP_DAEMON_SLEEP_FAST` / `_WATCH` / `_IDLE` / `_FALLBACK` (seconds, test/debug
hooks).

**Ledger.** Every driver spawn — successful, timed out, or refused-to-spawn — appends one line to
`.claude/state/loop-runs.log` (gitignored, never committed):
```
pid=<pgid> session=<session_id|unknown> verdict=<advance issue=N|feedback pr=N> ts=<ISO8601> [result=exit|timeout|spawn-error rc=N]
```
`session_id` is parsed out of the driver's own `--output-format json` stdout, which is what makes a
hung or already-finished driver resumable later.

**Supervision.** Three read-only windows into a driver, cheapest first:
1. `tail -f .claude/state/loop-runs.log` — the ledger line above, one per spawn.
2. The live transcript: `~/.claude/projects/<proj>/<session-id>.jsonl` (`<session-id>` from the ledger
   line) — this file is **append-only**, so `tail -f` it (or read it directly) to watch a driver's tool
   calls as they happen without disturbing it.
3. `claude --resume <session_id> --fork-session` — a full interactive replay/continuation. Safe to run
   **while the driver is still executing**: `--fork-session` never mutates the original session, it only
   reads the append-only transcript and branches a new one.

**Intervention is kill-and-let-it-re-advance, never steer.** A driver is a headless `claude -p` process with
no attach point — there is no "type into it and redirect it" option. To stop one: find its `pid=` (a
process **group** id) in the ledger and `kill -TERM -- -<pgid>` (the same target `timeout --kill-after`
would eventually use anyway). Do **not** try to nudge a running driver's behavior. Instead, let
`loop-tick.sh`'s own pre-branch spawn lock (`.claude/state/loop-advance.lock`, 15-minute TTL) self-heal so a
later tick can re-advance the same issue cleanly, or fix forward with a normal orchestrator pass once
whatever state the killed driver left behind (a branch, a PR) is visible to a fresh tick.

**Remote planning sessions.** `claude-rc-<repo>.service` keeps a `claude remote-control` process alive in a
detached tmux session, independent of the loop daemon's own ticking, so you can spawn a **new** planning
session from claude.ai or the Claude Code mobile app against this checkout at any time — useful for filing
or scoping work from your phone without a terminal open. `tmux attach -t rc-<repo>` to see its QR/status
locally, or restart it with `systemctl --user restart claude-rc-<repo>.service`.

**Linux vs WSL2.** Both need `systemd`, `tmux`, and `node`/`git` on `PATH`. WSL2 does **not** run systemd by
default — add (or verify) a `[boot]` section with `systemd=true` in `/etc/wsl.conf`, then `wsl --shutdown`
from **Windows** (not WSL) and reopen the WSL terminal; re-check with `systemctl --version` inside WSL2.
Both platforms: installing units under `~/.config/systemd/user/`, `loginctl enable-linger`, and starting the
detached tmux session all touch `$HOME`/systemd, which the Claude Code sandbox blocks — **run**
```bash
bash .claude/scripts/arm-loop.sh [--gates-file <path>] [--permission-mode <mode>] [--capacity N]
```
**in a real terminal outside Claude Code.** It's idempotent (safe to re-run any time). Self-hosting: add
`--gates-file .claude/self/gates.json`. WSL2-only extra: optionally make the loop survive a Windows reboot
**unattended** — i.e. WSL2 boots at system startup, before anyone logs in, not just at logon. From an
**elevated Windows PowerShell** (Run as Administrator — required by `-RunLevel Highest`), substituting
`<distro>` from `wsl -l` and `<user>` for your Linux username:
```powershell
$action    = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d <distro> -u <user> -- true"
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType S4U -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName "Start WSL <distro>" -Action $action -Trigger $trigger `
  -Principal $principal -Settings $settings `
  -Description "Boots WSL2 <distro> unattended at system startup so pr-loop/planner autostart"
```
`-LogonType S4U` runs the task whether or not anyone is logged on, without storing a Windows password — it
needs the "Log on as a batch job" right, which admin accounts have by default (grant it via `secpol.msc` for
a non-admin account). WSL2 also idles its VM down after inactivity, which would stop the daemon even though
the task fired — add `vmIdleTimeout=-1` under `[wsl2]` in `%UserProfile%\.wslconfig`, then run `wsl --shutdown`
once from Windows so it takes effect. Opening a WSL terminal afterward attaches to this same already-running
instance rather than starting a second one — WSL2 only ever runs one instance per distro, so there's no
duplicate-daemon risk.

Skipping this is safe: GitHub is the loop's only source of truth, so anything that happened while WSL2 was
stopped is simply picked up by the first tick after the next manual WSL2 start.

Inspect what's armed:
```bash
systemctl --user status pr-loop-<repo>.service
journalctl --user -u pr-loop-<repo>.service -f
tail -f .claude/state/loop-runs.log
tmux attach -t rc-<repo>
```

**Failure contract.**

| Failure | Detected as | Self-heals? | Manual fix |
|---|---|---|---|
| Driver exits non-zero (gate failure, crash mid-run, …) | ledger `result=exit rc=N` | Yes — the next tick's fresh census decides the next action from scratch | none |
| Driver runs past `LOOP_DRIVER_TIMEOUT` (default 90m) | ledger `result=timeout rc=124\|137`; `timeout --kill-after=30s` plus an explicit process-group kill | Yes — same as above | none, unless it left a half-finished branch behind — inspect and fix forward |
| `claude` CLI not found on `PATH` (nor via the `nvm` fallback) | ledger `result=spawn-error rc=127`, logged before any spawn attempt | Partially — the pre-branch spawn lock's 15-minute TTL clears and lets a later tick retry, but every retry hits the same missing-`PATH` wall | fix `PATH`/`nvm` in the daemon's environment (e.g. the systemd unit's `Environment=`), then `systemctl --user restart pr-loop-<repo>.service` |
| `loop-tick.sh` / `loop-event.sh` itself exits non-zero (broken tick) | daemon logs "not spawning a driver on a broken tick", sleeps the fallback cadence, retries | Yes — retried automatically every tick | investigate only if it persists across many ticks |
| **Driver pushed `feat/issue-N-*` but died before opening the PR** | census reports `N` as `in_flight`; `loop-tick.sh`'s advance check refuses (`# advance refused: issue=N is in_flight`, logged every single tick) and emits `action=none` | **No** — unlike the pre-branch spawn lock, `in_flight` has no TTL/self-heal; it refuses forever until the branch or a PR's state changes | **delete the abandoned branch** (frees the issue back to `advance_ready`), **or** open the PR by hand for that branch (moves it into the normal review/merge or feedback flow) |
| `claude-rc-<repo>.service`'s inner `claude remote-control` process crashes | **not detected by systemd** — the unit is `Type=oneshot`/`RemainAfterExit=yes`; systemd only observes `tmux new -d`'s own (successful) exit, never the health of the process running *inside* that tmux session | No | `tmux attach -t rc-<repo>` to check, then `systemctl --user restart claude-rc-<repo>.service` |

**Never run the daemon and the legacy `/pr-loop` cron against the same repo at the same time** —
`loop-tick.sh`'s spawn lock makes double-firing *safe* (no double-spawn), just wasteful (two firing sources
burning ticks against identical state).

**Legacy cron (`/pr-loop` / `/orchestrator:pr-loop`).** Kept as the fallback for environments without
systemd: session-scoped `CronCreate`, dies with the Claude Code session that armed it, so it must be
re-armed at the start of each session (**`/orchestrator:pr-loop`** does that plus runs one tick
immediately). Same adaptive cadence, same `loop-tick.sh` mechanics underneath — it just fires from inside a
Claude Code cron instead of `loop-daemon.sh`.

## Autonomous loop & the issue queue
Each tick — whether fired by the daemon's `loop-event.sh`/`loop-tick.sh` or the legacy `/orchestrator:pr-loop`
cron — runs, in order: **poll → merge → address-feedback → advance** — this per-tick order, canonically
defined in `.claude/commands/pr-loop.md` and `.claude/scripts/loop-tick.sh`, is authoritative; the poll /
address-feedback / merge scripts described above are the mechanism it runs. Two human control points
decide what the loop actually touches:

- **Issue approval is a two-label workflow: `backlog` → `planned`.** An issue enters the loop's work
  queue only when it carries **both** the `planned` label **and** a `module:<name>` label:
  - **`backlog`** — filed but *not approved*. This is the default state for every new issue, including
    issues the bot/agents file themselves (agents MUST label their own issues `backlog`, never
    `planned`). The loop never touches a `backlog` issue.
  - **`planned`** — the owner's formal approval: "scoped, reviewed, do it." **Only the repo owner
    assigns `planned`** — no agent, subagent, or bot may ever add this label, to an issue it filed or
    to anyone else's. Removing `planned` (or closing) is the owner's way to pull work back out of the
    queue.
  - **`module:<name>`** — routing, not approval. It maps issue → module → the worker's `path` boundary
    (`gates.json.modules[]`). No module ⇒ no boundary ⇒ nothing safe to hand a worker, `planned` or not.

  The ADVANCE step picks the **lowest-numbered open issue labelled `planned` + `module:*`** with no
  existing `feat/issue-<n>-*` branch — one at a time, and only when there are zero open PRs. Tracking
  issues (plans split into `Blocked by` sub-issue chains) stay `backlog` forever so the loop works the
  chain, never the tracker.
- **Owner-approval merge gate.** Workers author PRs as the **bot** (`bot-gh.sh`); the MERGE step (above)
  only merges PRs the repo **owner** has Approved on GitHub that are CI-green and mergeable. It never
  approves on the owner's behalf.

**Corollary:** work is not loop-eligible until (a) its area exists as a module in
`gates.json.modules[]`, (b) the issue carries the matching `module:*` label, and (c) the **owner** has
labelled it `planned`. Commenting "approved" on an issue does nothing — nothing watches issue text; the
`planned` label is the only approval signal.

**Model selection.** Drive the loop's tick sessions with **Sonnet**. Ticks are cheap but highly
repetitive, and repetition is where smaller models degrade: a Haiku-driven tick session has been observed
to stop invoking the step scripts entirely — fabricating census/merge output from the pattern of earlier
quiet ticks (missing an owner approval and a `planned` issue for hours) — and to misread an in-flight
orchestration as hung, double-spawning orchestrators for the same issue. Reserve **Fable or Opus** for
the owner-side judgment work: scoping, planning, and filing issues. (Script-side hardening that reduces
the tick's model-dependence landed in issue #81 as `.claude/scripts/loop-tick.sh`: it computes the
census/feedback/advance verdict and the spawn lock in shell, rather than leaving that arithmetic to be
re-derived from a prompt every firing — Sonnet remains the recommended driver for the session that invokes
it, since the driving session still has to read the verdict and act on it, e.g. spawning the orchestrator.)

> Historical note: before the `planned` label existed, the `module:*` label alone was the opt-in queue.
> If a repo predates the split, treat `module:*`-only issues as `backlog` until the owner adds `planned`.

**Self-hosting this repo's own backlog?** **`.claude/self/pr-loop-self.md`** runs the same loop mechanics
self-hosted, against this repo's own `.claude`/`docs`/`examples`/`.github` backlog, using
**`.claude/self/gates.json`** as the adapter (module map, gates, review lenses) instead of the placeholder
`.claude/gates.json` above. It lives under `.claude/self/` (not `.claude/commands/`), so it is self-hosting-only
— not a registered slash command and never packaged to downstream installs of the plugin; ask Claude to read and
follow it directly. See `.claude/self/README.md` for the self-adapter contract.

New project? Wire this up with the **[new-project configuration
checklist](GETTING_STARTED.md#new-project-configuration-checklist)**.

## Updating the plugin
When a new version of the `orchestrator` plugin ships (new agents, commands, gate fixes, etc.), refresh the
marketplace listing and let Claude Code update the installed plugin:
```
/plugin marketplace update recode
```
Then re-stamp the files `/orchestrator:setup` scaffolded into **your** repo (`gates.json`, `CLAUDE.md`, the
fan-out workflow, the CI gate workflow) so they pick up any changes shipped in the update:
```
/orchestrator:sync
```
This compares the version markers `/orchestrator:setup` already scaffolded against what the current plugin
ships and re-stamps anything behind — flagging local edits instead of clobbering them (see
`.claude/skills/sync/SKILL.md`) — so an update refreshes managed files (e.g. `feature-fanout.js`) without
re-running the whole interview, and never touches your own `gates.json`/`CLAUDE.md` (those are created once
and left alone on every re-run).

> **Maintainer note: bump `plugin.json`'s `version` on every real change.** `/plugin marketplace update` only
> re-fetches plugin content when the plugin's version string actually changes (`.claude/.claude-plugin/plugin.json`
> and, for the local-clone method, `.claude/.claude-plugin/marketplace.json`'s matching entry). Merging a fix to
> `main` without bumping that version means every existing installer's cached copy — at
> `~/.claude/plugins/cache/recode/orchestrator/<version>/` — silently never updates, even
> after `/plugin marketplace update`. Caught 2026-07-06: a `hooks/hooks.json` schema fix merged to `main` but
> didn't reach an already-installed consumer until the version string was bumped too.

## Merge discipline
- **`pr-per-agent`** (default): each worker → branch → PR. You (or a merge step) integrate; conflicts surface
  at PR time. Cleanest/auditable.
- **`orchestrated-sequential-merge`**: a coordinator merges branches in dependency order, re-running gates
  after each. Faster when many finish together, but needs careful ordering.

After merging a branch, clean its worktree:
```bash
git worktree list
git worktree remove <path>
```

## Scaling up
Start at `max_parallel_workers: 1–2`. Raise it only when your review+merge throughput proves it can keep up.
If workers stall or collide, the fix is almost always a sharper **module map** in `gates.json`, not more agents.

## When NOT to orchestrate
Trivial or single-file changes: just do them directly. The 15× token multiplier isn't worth it. The
orchestrator itself is told to use one worker and no parallelism for small tasks — hold it to that.

## Testing a PR locally (`/orchestrator:test-pr <n>`)

The owner reviews bot PRs by actually running the change. Doing that by hand is error-prone — the classic failure
is testing from the main working tree (which does NOT contain the unmerged PR), concluding "the fix doesn't work",
and bouncing the PR back. `/orchestrator:test-pr <pr-number>` removes that footgun:

1. Resolves the PR's head branch and fetches the latest pushed commit.
2. Creates a **detached** git worktree at `humanTest.worktreeDir/pr-<n>` (default `.worktrees/pr-<n>`) — isolated
   from your main checkout and from any agent worktree on the same branch.
3. Runs `humanTest.prepare` inside it (install + build) and prints `humanTest.launch` for you to run.

Configure the commands once in `.claude/gates.json`:

```json
"humanTest": {
  "prepare": "pnpm install --prefer-offline && pnpm -r build",
  "launch": "pnpm dev",
  "launchPhone": "sh -c 'pnpm dev & devpid=$!; trap \"kill $devpid 2>/dev/null\" EXIT INT TERM; cloudflared tunnel --url http://localhost:5173 --http-host-header localhost'",
  "worktreeDir": ".worktrees"
}
```

Add `humanTest.worktreeDir` to `.gitignore`. Re-running `/orchestrator:test-pr` on the same PR fast-forwards the
worktree to the latest commit (idempotent). Tear down with `git worktree remove <path>`.

### Testing on a phone (`/orchestrator:test-pr <n> --phone`)

To iterate on a UI from a phone (touch gestures, small-screen layout) rather than a desktop browser, configure
`humanTest.launchPhone` and run `/orchestrator:test-pr <n> --phone`. It prepares the worktree exactly as above but
prints `launchPhone` instead of `launch`. `launchPhone` starts the dev server(s) **and** opens a public tunnel (e.g.
a `cloudflared` quick tunnel) to the running app, printing a `https://<random>.trycloudflare.com` URL you open in
the phone's own browser. The `--http-host-header localhost` flag makes the tunnel send `Host: localhost`, so a dev
server with a strict host allow-list (e.g. Vite) accepts it with no config change.

This is opt-in and attended, because the tunnel is **public** while up: anyone with the link reaches the app and
whatever backend/API it proxies, using the credentials in the worktree's `.env`. It's ephemeral — Ctrl-C tears down
the tunnel and the dev servers together. Don't leave it running unattended. Without `--phone`, behavior is
unchanged; if `launchPhone` isn't configured, `--phone` falls back to printing `launch`.
