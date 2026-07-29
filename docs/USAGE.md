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
  **one** contained driver, as a **transient `systemd --user` unit, decoupled from the daemon's own
  lifetime** (issue #119): `systemd-run --user --wait --collect --unit="pr-loop-driver-issue<N>"
  -p RuntimeMaxSec=<LOOP_DRIVER_TIMEOUT, default 90m> -- bash -c 'claude --model <model> -p "<prompt>"
  --output-format json > <out-file> 2> <err-file>'` (unit is `pr-loop-driver-pr<N>` for a `feedback`
  verdict). `--wait` makes the daemon's own invocation a **disposable waiter**: it blocks and relays the
  unit's exit code exactly like a backgrounded `wait` would, but the driver's REAL parent is the user
  manager, which lives in its own scope outside the daemon's cgroup — so `systemctl --user restart
  pr-loop-<repo>`, a daemon crash (`Restart=always` bounce), or the daemon dying for any other reason kills
  only that disposable waiter, **never the driver itself**. `RuntimeMaxSec` (a systemd time-span — `90m`
  works as-is) replaces `timeout` as the hard wall-clock ceiling, now enforced by the user manager instead
  of the daemon, so an orphaned driver still has a real ceiling even if the daemon never restarts.
  **Restart is now driver-safe** — a host reboot/sleep or `wsl --shutdown` still kills the driver along with
  everything else (nothing can prevent that), but a plain daemon bounce no longer does. `run_driver`'s
  ledger + issue #111's post-exit verification are unchanged; only the spawn+wait step branches. **Fallback**
  (legacy-cron / non-systemd environments, detected via `command -v systemd-run`): the exact `setsid timeout
  --kill-after=30s <LOOP_DRIVER_TIMEOUT> claude ...` spawn from before #119, unchanged — `setsid` gives the
  driver (and any bash children it spawns) its own process group, independent of the daemon's; on timeout
  the whole group is targeted, not just the immediate child, so a driver's own children can never be
  orphaned by a bare `SIGTERM`. That fallback path still has the pre-#119 caveat: a process group is not a
  cgroup, so it dies WITH the daemon's own service cgroup on a restart/crash/reboot. **Startup re-attach**:
  before the first tick, `main()` checks `systemctl --user list-units 'pr-loop-driver-*'` (no-op when
  systemd is unavailable) — if a driver unit from a previous, now-dead daemon process is still active, the
  daemon WAITS for it instead of ticking (no duplicate spawn, no premature debris classification), then runs
  the same post-exit verification + ledger write a fresh spawn would have. `loop-census.sh`'s ADVANCE check
  additionally never picks an issue whose driver unit is currently active, even before that driver has
  reached `git checkout -b` (so it has no branch yet for the `in_flight` check to catch). **Ops helper**:
  `.claude/scripts/loop-halt.sh` stops one driver (`loop-halt.sh issue106` / `loop-halt.sh pr42`), all
  drivers (`loop-halt.sh --drivers`), or the daemon + all drivers together (`loop-halt.sh --all`) — see the
  failure contract below for when you'd want each. The daemon itself never runs two drivers concurrently
  (it's a single-threaded loop), and `loop-tick.sh`'s own spawn lock additionally guards against a second
  overlapping tick anywhere else (e.g. the legacy cron armed at the same time) double-firing the same
  ADVANCE.
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

**Ledger.** Every driver spawn — successful, timed out, refused-to-spawn, or re-attached at startup —
appends one line to `.claude/state/loop-runs.log` (gitignored, never committed):
```
pid=<pgid|unknown> session=<session_id|unknown> verdict=<advance issue=N|feedback pr=N> ts=<ISO8601> [result=exit|timeout|spawn-error rc=N] [pr=N] [debris=... [action=deleted]] [reattached=true]
```
`session_id` is parsed out of the driver's own `--output-format json` stdout, which is what makes a
hung or already-finished driver resumable later. A `reattached=true` line (issue #119) means the daemon
found this driver already running as a systemd unit at startup — left behind by a previous, now-dead
daemon process — waited for it instead of spawning a new one, and ledgered its real outcome; `pid=unknown`
on that line because the daemon that actually spawned it is gone.

**Supervision.** Three read-only windows into a driver, cheapest first:
1. `tail -f .claude/state/loop-runs.log` — the ledger line above, one per spawn.
2. The live transcript: `~/.claude/projects/<proj>/<session-id>.jsonl` (`<session-id>` from the ledger
   line) — this file is **append-only**, so `tail -f` it (or read it directly) to watch a driver's tool
   calls as they happen without disturbing it.
3. `claude --resume <session_id> --fork-session` — a full interactive replay/continuation. Safe to run
   **while the driver is still executing**: `--fork-session` never mutates the original session, it only
   reads the append-only transcript and branches a new one.

**Intervention is kill-and-let-it-re-advance, never steer.** A driver is a headless `claude -p` process with
no attach point — there is no "type into it and redirect it" option. To stop one: **`bash
.claude/scripts/loop-halt.sh issue<N>`** (or `pr<N>` for a feedback driver) — `systemctl --user stop
pr-loop-driver-issue<N>` under the hood (issue #119). This is now the right tool on the systemd path: the
ledger's `pid=` is the daemon's own disposable `systemd-run --wait` waiter, not the driver, so killing that
pid does nothing to the actual driver. `loop-halt.sh --drivers` stops every active driver at once;
`loop-halt.sh --all` also stops the daemon unit. On the legacy fallback path (no `systemd-run` on `PATH`),
`pid=` is still a real process **group** id and `kill -TERM -- -<pgid>` (the same target `timeout
--kill-after` would eventually use anyway) still works, same as before #119. Do **not** try to nudge a
running driver's behavior either way. Instead, let `loop-tick.sh`'s own pre-branch spawn lock
(`.claude/state/loop-advance.lock`, 15-minute TTL) self-heal so a later tick can re-advance the same issue
cleanly, or fix forward with a normal orchestrator pass once whatever state the killed driver left behind (a
branch, a PR) is visible to a fresh tick.

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

**WSL2 caveat — going down is safe for the QUEUE and for a plain daemon restart, not for a HOST-level
shutdown while a driver is mid-run.** Issue #119 made a `systemctl --user restart pr-loop-<repo>` (or a
daemon crash) driver-safe: the transient driver unit lives under the `--user` manager, outside the daemon's
own cgroup, so bouncing the daemon no longer kills it (this is what actually killed five of six drivers on
2026-07-14/15, and is now fixed). What #119 can NOT fix: a Windows reboot, sleep/hibernate, or `wsl
--shutdown` tears down the WHOLE WSL2 VM — user manager included — so a driver mid-run at that moment still
dies, now with **no ledger line** the same way a hard `kill -9` on any process would. Check
`systemctl --user list-units 'pr-loop-driver-*'` (or `tail -1 .claude/state/loop-runs.log` for the last
spawn's completion) before a host-level reboot/shutdown; `bash .claude/scripts/loop-halt.sh --drivers` stops
any in-flight drivers cleanly first if you'd rather not wait.

Inspect what's armed:
```bash
systemctl --user status pr-loop-<repo>.service
journalctl --user -u pr-loop-<repo>.service -f
systemctl --user list-units 'pr-loop-driver-*'   # active driver units (issue #119)
tail -f .claude/state/loop-runs.log
tmux attach -t rc-<repo>
```

Stop things by hand (issue #119 — see `.claude/scripts/loop-halt.sh`):
```bash
bash .claude/scripts/loop-halt.sh issue106     # stop one driver: systemctl --user stop pr-loop-driver-issue106
bash .claude/scripts/loop-halt.sh pr42         # stop one driver: systemctl --user stop pr-loop-driver-pr42
bash .claude/scripts/loop-halt.sh --drivers    # stop ALL driver units: systemctl --user stop 'pr-loop-driver-*'
bash .claude/scripts/loop-halt.sh --all        # stop the daemon unit AND all driver units
```
Degrades cleanly (logs and exits 0) when `systemctl --user` is unavailable — the legacy fallback path's
drivers are plain daemon children, already covered by stopping the daemon itself.

**Failure contract.**

| Failure | Detected as | Self-heals? | Manual fix |
|---|---|---|---|
| Driver exits non-zero (gate failure, crash mid-run, …) | ledger `result=exit rc=N` | Yes — the next tick's fresh census decides the next action from scratch | none |
| Driver runs past `LOOP_DRIVER_TIMEOUT` (default 90m) | ledger `result=timeout rc=124\|137`; `RuntimeMaxSec` (systemd path) or `timeout --kill-after=30s` plus an explicit process-group kill (fallback path) | Yes — same as above | none, unless it left a half-finished branch behind — inspect and fix forward |
| `claude` CLI not found on `PATH` (nor via the `nvm` fallback) | ledger `result=spawn-error rc=127`, logged before any spawn attempt | Partially — the pre-branch spawn lock's 15-minute TTL clears and lets a later tick retry, but every retry hits the same missing-`PATH` wall | fix `PATH`/`nvm` in the daemon's environment (e.g. the systemd unit's `Environment=`), then `systemctl --user restart pr-loop-<repo>.service` |
| `loop-tick.sh` / `loop-event.sh` itself exits non-zero (broken tick) | daemon logs "not spawning a driver on a broken tick", sleeps the fallback cadence, retries | Yes — retried automatically every tick | investigate only if it persists across many ticks |
| **Driver created `feat/issue-N-*` but died before opening the PR** | census reports `N` as `in_flight`; `loop-tick.sh`'s advance check refuses (`# advance refused: issue=N is in_flight`, logged every single tick) and emits `action=none` | **No** — unlike the pre-branch spawn lock, `in_flight` has no TTL/self-heal; it refuses forever until the branch or a PR's state changes | **Classify first, never blind-delete** (`git log main..<branch>` + worktree status): **empty** (no commits, clean) → delete the branch/worktree, freeing the issue back to `advance_ready`; **publishable** (commits ahead, clean, reviews/gates were green) → re-run the test gate, push, open the PR by hand via `bot-gh.sh` (proven: #107 → PR #117); **half-done or dirty worktree** → never delete — `wip:`-commit to preserve, then finish via a normal orchestrator pass on the existing branch. Issues #111 (classify + mechanical paths) and #98 (resume half-done work) automate this. |
| **Daemon killed mid-driver** (service restart, daemon crash) — **fixed by issue #119** | ledger shows a `reattached=true` line once the daemon restarts and re-attaches, with the driver's real outcome (not a missing/phantom line) | **Yes** — the transient driver unit outlives the daemon's own cgroup; `main()`'s startup re-attach waits for it and runs the same post-exit verify + ledger write a fresh spawn would have | none — this is now self-healing. On the legacy fallback path (no `systemd-run` on `PATH`) the pre-#119 behavior still applies: **no** `result=` completion line, driver dies with the daemon's cgroup; recover debris via the row above |
| **Host-level kill while a driver is in flight** (reboot, sleep/hibernate, `wsl --shutdown`) — the one case #119 can't fix, since it tears down the `--user` manager too | ledger shows a spawn with **no `result=` completion line**; `events.jsonl`/`worker-tools.jsonl` activity for the task stops abruptly | **No** — there is no process left anywhere to re-attach to; the restarted daemon just ticks on, and any branch the driver created wedges as `in_flight` per the row above | check `systemctl --user list-units 'pr-loop-driver-*'` (or the ledger's last spawn) before a host-level reboot/shutdown, or `loop-halt.sh --drivers` first; recover debris per the `in_flight` row above |
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

  The ADVANCE step picks the **highest-priority, then lowest-numbered, open issue labelled
  `planned` + `module:*`** with no existing `feat/issue-<n>-*` branch — one at a time, and only when
  there are zero open PRs. Tracking issues (plans split into `Blocked by` sub-issue chains) stay
  `backlog` forever so the loop works the chain, never the tracker. **"Blocked by #N" in an issue body
  is load-bearing for this selection, not merely cosmetic for the cockpit graph** (`loop-census.sh`,
  issue #97): the census skips a `planned` candidate while any issue it declares "Blocked by" is still
  open, emits a `blocked=<n> by=<N>` line explaining the skip, and picks the next unblocked candidate
  instead — a blocker closing makes the skipped issue eligible again on the very next tick, no extra
  bookkeeping required. A "Blocked by" cycle falls back to the lowest-numbered candidate rather than
  wedging the loop. Only the explicit "Blocked by" phrase gates; task-list/parent-child refs (`- [ ] #N`)
  do not.
  - **Priority labels (`priority:critical|high|medium|low`, issue #173).** The owner sets one of these
    four labels in the GitHub UI on any `planned` issue; nothing else about the workflow changes. The
    census orders candidates by (priority rank, then issue number): `critical` < `high` < `medium` <
    `low` < unlabeled, with issue number as the tiebreaker within a rank — so a label-free backlog
    behaves exactly as before (lowest-numbered first). The blocking-graph gate above still overrides
    priority: a blocked candidate is skipped regardless of how high its priority is — priority is
    preference, "Blocked by" edges are semantics. The cockpit shows a priority chip on each prioritized
    issue row.
- **Owner-approval merge gate.** Workers author PRs as the **bot** (`bot-gh.sh`); the MERGE step (above)
  only merges PRs the repo **owner** has Approved on GitHub that are CI-green and mergeable. It never
  approves on the owner's behalf.

**Corollary:** work is not loop-eligible until (a) its area exists as a module in
`gates.json.modules[]`, (b) the issue carries the matching `module:*` label, and (c) the **owner** has
labelled it `planned`. Commenting "approved" on an issue does nothing — nothing watches issue text; the
`planned` label is the only approval signal.

**Optional spec/plan gate (`plan.gate`, issue #100).** By default the ADVANCE step goes straight from a
`planned` issue to implementation (one driver turn: scope → worktree implementer → gates → reviewers →
bot PR). `gates.json`'s `plan` block can insert a reviewable **plan artifact** — a structured issue
comment — before any code is written:
- **`plan.gate: "off"`** (default) — today's single-pass behavior, unchanged.
- **`plan.gate: "label"`** — gate only the `planned` candidates that ALSO carry a `plan-first` label.
- **`plan.gate: "always"`** — gate every `planned` + `module:*` candidate, no extra label needed.

Label lifecycle for a gated issue:
1. The owner adds `plan-first` (label mode only; `always` mode needs nothing extra).
2. The loop's next ADVANCE turn is **PLAN-ONLY**: it reads the issue, scopes it (module, expected files,
   approach, acceptance-criteria mapping), and posts **one** structured comment on the issue beginning with
   the marker `<!-- plan-gate:plan -->` — implementing nothing, opening no branch, no PR. It then labels the
   issue `plan-review` (awaiting the owner) and `needs-human` (issue #99's signal — see below).
3. The owner reviews the plan comment on GitHub. **To approve:** replace `plan-review` with `plan-approved`
   — the next tick implements the issue, with the plan comment's contents injected verbatim into the
   implementer's prompt and every reviewer's prompt as the **authoritative scope** (a diff that exceeds the
   plan's declared files/approach is a valid reviewer reject: "exceeds approved scope"). **To request
   changes:** remove `plan-review` — the issue drops back to needing a fresh plan, and a later tick re-plans
   it from scratch.

While an issue sits in `plan-review` (posted, not yet approved), `loop-census.sh` treats it like a `Blocked
by` dependency: it is skipped for `advance_ready` entirely — the loop will not implement a plan the owner
hasn't signed off on.

**Owner-only approval, same caveat as `planned`:** the loop only checks whether the `plan-approved` label is
present, not *who* added it — GitHub identity is not enforced here any more than it is for `planned` itself
(see the two-label workflow above). Treat `plan-approved` as an owner-only convention, not a
technically-enforced gate.

This reuses issue #99's `needs-human` signal (label + one-time comment + throttled notification) as the
"plan is ready for your review" ping, rather than inventing a second escalation channel.

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
fan-out workflow, the loop-daemon systemd unit templates + `arm-loop.sh`, the CI gate workflow) so they pick
up any changes shipped in the update:
```
/orchestrator:sync
```
This compares the version markers `/orchestrator:setup` already scaffolded against what the current plugin
ships and re-stamps anything behind — flagging local edits instead of clobbering them (see
`.claude/skills/sync/SKILL.md`) — so an update refreshes managed files (e.g. `feature-fanout.js`) without
re-running the whole interview, and never touches your own `gates.json`/`CLAUDE.md`/`settings.json` (those are
created once and left alone on every re-run). It also detects and warns about local leftovers from an old
vendored install (issue #134, see below) instead of silently deleting or restamping them.

**The `orchestrator` plugin must stay *enabled* for everyday sessions**, not just to run
`/orchestrator:setup`/`/orchestrator:sync` — this repo does **not** vendor a local copy of `agents/`,
`commands/`, `hooks/`, `scripts/`, `skills/` into your `.claude/` (issue #134 reverted issue #128's vendoring
model). `agents/commands/hooks/scripts/skills` are read straight from the plugin cache
(`${CLAUDE_PLUGIN_ROOT}`) on every session; disabling the plugin between updates now breaks everyday sessions,
not just setup/sync. (Vendoring was reverted because nothing kept an unmanaged vendored copy updated outside
`/orchestrator:sync`, and `resolve-roots.sh` deliberately makes a repo-tracked `.claude/scripts` layout win
over `${CLAUDE_PLUGIN_ROOT}` — correct for self-hosting/worktree gate runs, but it meant a stale vendored copy
permanently shadowed a fresh plugin install; see the reDeploy incident that prompted #134.)

**If your repo was onboarded before #134 and still carries a local `.claude/{agents,commands,hooks,scripts,skills}`
copy** (and possibly a `.claude/.orchestrator-vendor` marker), `/orchestrator:sync` flags it —
`stale-vendor: ... safe to delete` if it's byte-identical to the plugin's shipped copy (just shadowing the
plugin cache), or `stale-vendor conflict: ...` if it diverges (review before deleting — it may be a deliberate
local override). Sync never deletes it for you. **Migration caveat:** if you've already armed the loop,
deleting/refreshing files on disk is not enough — a running `pr-loop`/`claude-rc` systemd unit holds its OLD
script in memory until its unit restarts, so restart both after cleaning up:
`systemctl --user restart pr-loop-<repo-slug>.service claude-rc-<repo-slug>.service` (cf. the 2026-07-16
reCode deploy-lag incident, issue #131).

> **Maintainer note: bump `plugin.json`'s `version` on every real change.** `/plugin marketplace update` only
> re-fetches plugin content when the plugin's version string actually changes (`.claude/.claude-plugin/plugin.json`
> and, for the local-clone method, `.claude/.claude-plugin/marketplace.json`'s matching entry). Merging a fix to
> `main` without bumping that version means every existing installer's cached copy — at
> `~/.claude/plugins/cache/recode/orchestrator/<version>/` — silently never updates, even
> after `/plugin marketplace update`. Caught 2026-07-06: a `hooks/hooks.json` schema fix merged to `main` but
> didn't reach an already-installed consumer until the version string was bumped too.

## Release cycle
The maintainer note above says to bump `plugin.json`'s version "on every real change" — issue #176
formalizes WHEN and HOW that bump actually happens for a planned batch of work, replacing the ad-hoc
process from issue #136 (closed; treat this section as its successor).

**The milestone IS the release unit.** Each release milestone (e.g. "v0.3.0 — consumer rollout") contains
one special issue, titled `Release vX.Y.Z` (template: `.github/ISSUE_TEMPLATE/release.md`), whose body
declares **"Blocked by #…, #…, #…"** listing every OTHER open issue currently in that milestone. This
reuses issue #97's blocking-graph gate — already load-bearing for the loop's ADVANCE step (see
"Autonomous loop & the issue queue" above) — as the release gate itself: **no new state machine.** The
census will not advance the release issue until every sibling in the milestone has merged, so as long as
that "Blocked by" line is kept current (a one-line `bot-gh.sh issue list --milestone ... --state open`
query — see the template), the release issue self-schedules for whenever the milestone is actually done.

**The cut.** Once unblocked and labelled `planned`, the release issue is implemented like any other issue
— its implementer runs `bash .claude/scripts/release.sh vX.Y.Z --issue <N>`, which:
1. bumps the `version` field in both `.claude/.claude-plugin/plugin.json` and
   `.claude/.claude-plugin/marketplace.json`,
2. generates a dated, Keep-a-Changelog-style entry in `.claude/.claude-plugin/CHANGELOG.md` from merged PR
   titles since the last git tag (falling back to the full commit history when there is no prior tag —
   e.g. this repo's very first release),
3. tags `vX.Y.Z`, commits the bumps + changelog, and pushes both,
4. "publishes" per the runbook above — the driver cannot run the interactive `/plugin marketplace update`
   slash command, and package-publish commands are policy-denied, so it prints that command as the
   **manual owner follow-up** instead of attempting it,
5. closes the milestone,
6. auto-files a `Rollout & feedback: vX.Y.Z` companion issue (below).

Supports `--dry-run` for testability: it performs the real file transforms (version bump + changelog
generation) so they can be inspected, but only PRINTS every git/gh side effect (tag, push, milestone
close, issue file) instead of executing it — see `.claude/scripts/release.test.sh`.

**The rollout & feedback companion.** The auto-filed `Rollout & feedback: vX.Y.Z` issue is deliberately
**census-invisible**: no milestone, and no `planned` label, until the owner triages it — the loop will
never pick it up on its own. It carries:
- a consumer-sync checklist for reDeploy and reDeFi via `/orchestrator:sync` (sync v2's offline checks —
  deploy-lag, environment, labels, observability — issue #141),
- test-focus areas derived from the released milestone's issue titles,
- a running section to accumulate feedback back-references as consumers report issues.

**Label conventions.** The companion issue is labelled `feedback`; incoming feedback that traces back to a
specific consumer is additionally tagged `from:redeploy` or `from:redefi` (both labels, plus `feedback`
itself, are created idempotently by `release.sh` at file time if they don't already exist). The version
being rolled out is always noted in the issue body. Owner triage — adding `planned` and, if warranted, a
milestone — is what turns a piece of feedback into loop-eligible work; until then it just sits in the
inbox.

**Hotfix path.** A bug found after release doesn't reopen the old milestone — file a `vX.Y.Z+1`
micro-milestone containing just that one bug issue, label it `planned`, let the loop fix it normally, then
cut the patch release through the exact same `Release vX.Y.Z+1` → `release.sh` machinery above (its
"Blocked by" list will just be the one bug issue).

## Roadmap (`docs/ROADMAP.md`, issue #175)

**`docs/ROADMAP.md` is GENERATED — never hand-edit it.** The single source of truth is GitHub itself (open
milestones, issue labels/bodies, PR state); the file is a read-only rendering of that data, produced by
`bash .claude/scripts/roadmap.sh --write`. A manual edit to `docs/ROADMAP.md` survives only until the next
regeneration, at which point it's silently overwritten — the file itself carries a
`GENERATED FILE — DO NOT EDIT BY HAND` marker at the very top as a reminder. To change what the roadmap
shows, change the underlying GitHub state instead: relabel/reassign a milestone, adjust a
`priority:critical|high|medium|low` label, or edit an issue's "Blocked by #N" line — then re-run the
generator (or just wait for the next post-merge regen, see below).

**What it renders**, per open milestone (in natural version order — v1.0.0 < v1.2.0 < v1.10.0, not a plain
string sort):
- every issue attached to that milestone, each with its priority chip (same label set as the census/cockpit
  above), a derived **state** — `open` / `in_flight` (a `feat`/`fix`/`work`/issue-`<N>`-\* branch exists, no
  PR yet) / `PR#N open` / `closed` — mirroring `loop-census.sh`'s own ADVANCE/in_flight logic so the roadmap
  never disagrees with what the loop itself would report,
- a Mermaid graph of the "Blocked by" edges among that milestone's issues (the SAME parser `cockpit.sh
  --parse-blocking` uses — one implementation, reused, not re-derived).

A trailing **Feedback inbox** section lists open `feedback`-labeled issues that carry **no milestone yet** —
exactly the census-invisible state described in "The rollout & feedback companion" above, before owner
triage assigns a milestone and turns it into loop-eligible work.

**Regeneration.** `bash .claude/scripts/roadmap.sh --write` regenerates it on demand (default, no `--write`,
prints the same Markdown to stdout instead — a preview that touches no file). `merge-ready.sh` also calls it
automatically after every successful merge, best-effort: a roadmap generator failure (missing gh
auth/network, a crash) is logged to stderr and never blocks, fails, or rolls back the merge that triggered
it. Every `gh` call the generator makes is REST-only and gh-2.4.0-safe, routed through `bot-gh.sh` like every
other script in this repo; the regenerated file's own commit/push (when the local checkout is cleanly on the
base branch) runs as plain `git`, the same as every other git operation in this repo.

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
