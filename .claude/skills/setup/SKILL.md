---
name: setup
description: First-time onboarding for the orchestrator plugin in a NEW or unconfigured repo. Interviews the user, scaffolds the project adapter (.claude/gates.json), CLAUDE.md, the fan-out workflow, CI gate workflows, module:* labels, and .gitignore hygiene, verifies the bot identity, and offers to arm the PR loop and hardening. Use this whenever a repo has the orchestrator plugin installed but hasn't been set up yet, or when the user asks to "set up the orchestrator", "onboard this repo", or run `/orchestrator:setup`.
---

You are running **first-time setup** for the orchestrator plugin in the user's project. Goal: take a fresh
install from placeholder to a fully working autonomous state — a filled adapter, module labels, a working bot
identity, server-side gates, the PR loop armed, and (optionally) hardened hands-off mode. You *interview* the
user, then materialize the files and GitHub state the loop depends on.

A Claude Code plugin can carry generic agents/scripts/hooks, but it CANNOT carry things that must live and be
version-controlled inside the consumer's own repo: the project-specific adapter, `CLAUDE.md`, the fan-out
workflow file, and GitHub Actions YAML. This skill's job is to scaffold exactly that non-distributable residue,
on top of the interview below.

**Also (issue #128): this skill vendors the plugin's own runtime harness** — `agents/`, `commands/`, `hooks/`,
`scripts/`, `skills/` — wholesale into the consumer's local `.claude/`, plus a `.claude/settings.json` that
wires the runtime hooks locally. A plugin loads (and pays its load cost) on every session start while it's
enabled, no matter how its hooks are wired, so the only way to remove that cost from the runtime path is to
stop depending on the plugin being loaded at all once setup is done. **The `orchestrator` plugin only needs to
stay enabled to RUN `/orchestrator:setup`/`/orchestrator:sync`** (the install/update channel) — not for
everyday sessions. See step 4 below.

Be conversational but efficient. Use the `AskUserQuestion` tool for discrete choices; ask for free-text
(names, paths, shell commands) in plain prose. **Never invent values** — if you don't know a command or path,
ask. **Propose the final files and get an explicit "yes" before writing.** All `gh` runs through
`bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh`, never bare `gh`. This skill never runs `gh` or
touches the network for the file-scaffolding part — that part is delegated to `scaffold.sh` (see step 4).

Do these in order. Stop and report if a step genuinely can't proceed.

## 1. Preconditions & orientation
- Read `docs/GETTING_STARTED.md`, `docs/USAGE.md`, `docs/HARDENING.md` (if present in this repo — a
  downstream consumer may only have the plugin, not the template's docs; fall back to this skill's own
  description of the model in step 2 if they're missing), the current `.claude/gates.json`, and `CLAUDE.md`.
- **Redundant-setup check (warn, then ask — don't hard-abort).** If `gates.json.gates` already has non-empty
  commands, the project looks already configured. **Warn clearly**: show the current `project`/`modules`/`gates`,
  and say that continuing will re-interview and, on your confirmation, overwrite the adapter files and reconcile
  labels. Then **ask the user whether to continue or stop** (use `AskUserQuestion`). If they choose stop, end the
  skill cleanly with no changes. If they continue, proceed with the flow. (You still confirm before each file
  write in later steps, so a re-run can't clobber silently.)
- Resolve the repo: `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh repo view --json nameWithOwner -q .nameWithOwner`.

## 2. Explain the model up front (so answers are informed)
Briefly tell the user how the loop decides what to build:
- The loop only builds issues labelled **`planned` + `module:<name>`**, one at a time, when no PRs are open — an explicit, owner-gated queue. Every issue starts as `backlog`; **only the owner** promotes it to `planned` (agents never assign `planned`).
- Each `module` maps to exactly one filesystem `path`, the **hard boundary** a worker may edit within. So the
  module list you define here is both the isolation boundary and the set of labels the loop understands. Include
  any non-code area you want automatable (e.g. `docs`, `.claude`, `examples`).
- Nothing merges until the **owner approves the bot's PR** on GitHub.

## 3. Interview
Collect, confirming back as you go:
1. **Project basics** — `project.name`, `language`, `packageManager`.
2. **Modules** (the important one) — for each ownable area: `name` (label-safe: lowercase/kebab), `path`
   (repo-relative, **non-overlapping / non-nested** with siblings), one-line `description`, optional `owner`.
   Push back on overlapping or nested paths — the isolation guarantee needs disjoint paths. Offer to include
   `docs`/infra modules if relevant.
3. **Gates** — exact shell commands (run from repo root) for `install`, `build`, `lint`, `typecheck`, `test`,
   `test_affected`, `coverage`, `e2e`, `security`. Empty = "skip" (fine, and the right default when a gate
   doesn't exist yet). Warn that a gate pointed at a command that can't pass will block the Stop hook. Ask
   `coverage_threshold` (default 80). If unsure on `test_affected`, default it to the full `test` command.
4. **Review** — `review.lenses` (default `["correctness","tests","security","performance"]`) and
   `review.consensus` (`all`, or an integer).
5. **Budget/routing** — `orchestrator_model`/`worker_model`/`explorer_model`/`reviewer_model`
   (defaults opus/sonnet/haiku/opus) and `max_parallel_workers` (default 3; advise 2–4).
6. **Merge** — `merge.policy` (`pr-per-agent` | `orchestrated-sequential-merge`) and `merge.baseBranch`
   (default the repo's default branch).

## 4. Scaffold the files (adapter, CLAUDE.md, workflow, CI, gitignore, state dir)
This is the part a plugin can't carry for you — it must land inside the consumer repo itself. Run it AFTER
the interview is confirmed, but note the script only writes files that don't already exist (user-owned) or
re-stamps a version-marked managed file — it never silently clobbers something you or a teammate hand-edited:

```
bash ${CLAUDE_PLUGIN_ROOT:-.claude}/skills/setup/scaffold.sh
```

Run it from the repo root (no argument needed there — it defaults to the current directory). It handles, all
idempotently:
- `.claude/gates.json` and `CLAUDE.md` — **user-owned from birth**. Created from templates only if absent.
  Since these already exist as placeholders in a fresh checkout, immediately after scaffold.sh runs (or before,
  your choice), you still need to **write the interview answers into `.claude/gates.json` and `CLAUDE.md`
  yourself** (propose the complete files, get an explicit "yes", then write) — scaffold.sh only guarantees the
  files exist to edit; it does not know the interview answers.
- `.claude/workflows/feature-fanout.js` — workflows aren't plugin-distributable, so it's scaffolded here,
  stamped with an `@orchestrator-managed feature-fanout vN` marker comment. On a re-run, if the marker version
  in the repo is older than the version scaffold.sh ships, it re-stamps (overwrites); if it's the same or
  newer, it's left alone. This is the seam a future plugin-upgrade flow uses to push workflow fixes into
  already-onboarded repos without touching hand-edited copies that opted out (by bumping their own marker).
- `.claude/systemd/pr-loop.service`, `.claude/systemd/claude-rc.service`, `.claude/scripts/arm-loop.sh`
  (issue #102) — the cron-less loop daemon's systemd unit TEMPLATES and the installer script, all `managed`
  the same way as `feature-fanout.js` (own `@orchestrator-managed <name> vN` marker, re-stamped on upgrade).
  These carry `__WORKDIR__`/`__REPO_SLUG__`/etc. placeholders that `arm-loop.sh` substitutes at ARM time, not
  at scaffold time — scaffolding them here does NOT install or start anything. See step 9 below for arming.
- **`.claude/{agents,commands,hooks,scripts,skills}/`** (issue #128) — the runtime harness itself, vendored
  wholesale from the plugin root, managed as ONE unit via a single top-level marker file
  (`.claude/.orchestrator-vendor`, `@orchestrator-managed runtime-vendor vN`), restamped/re-vendored on the
  same behind/never-downgrade ladder as every other managed row. **`.claude/scripts/arm-loop.sh` is excluded**
  from this copy — it's already managed by its own row above with a different canonical source, so
  double-vendoring it would create two disagreeing sources of truth for the same file. Once this tree is
  vendored, the plugin's own `agents/commands/hooks/scripts/skills` are no longer on the runtime critical
  path — a session reads the local `.claude/` copies instead, whether or not the plugin is enabled.
- **`.claude/settings.json`** — **user-owned, created only if absent.** Wires the runtime hooks
  (`PostToolUse` lint + log-worker-tool, `Stop` test_affected, `PreToolUse` guard-git-add) to
  `$CLAUDE_PROJECT_DIR/.claude/scripts/...`, plus baseline `permissions`/`sandbox`. Deliberately carries no
  `enabledPlugins`/`extraKnownMarketplaces` — keep those only in a settings.json you maintain yourself while
  installing/updating the plugin (e.g. the block from Step 1 of `docs/GETTING_STARTED.md`), not in the
  runtime file, which must keep working with the plugin disabled. **If you already have a `settings.json`**
  (likely, since you needed `enabledPlugins` to install the plugin in the first place), scaffold.sh reports it
  "kept" and leaves it completely untouched — merge the four hooks above and the `permissions`/`sandbox`
  blocks from `.claude/skills/setup/templates/settings.json` into your existing file by hand, then it's safe
  to drop `enabledPlugins`/`extraKnownMarketplaces` from it once you don't need the plugin loaded anymore.
- `.github/workflows/gates.yml` + `.github/actions/setup/action.yml` — the CI gate. Created if absent, left
  untouched if present.
- `.gitignore` entries (append-if-missing, never duplicated): `.env`, `.env.*`, `!.env.example`,
  `.claude/settings.local.json`, `.claude/state/`.
- `.claude/state/` directory (the notify-poll cursor and the loop daemon's run ledger live here).

Report the script's per-file summary (created / kept / restamped / up to date / appended) to the user. Then
write the interview answers into `.claude/gates.json` (validate with `node -e "require('./.claude/gates.json')"`)
and fill `CLAUDE.md` from its template sections (What this project is / Stack & layout mirroring the module map /
Conventions / Merge policy mirroring `gates.json` / Don'ts) — propose both files and get an explicit "yes"
before writing. Beyond that, **you (the interview) should not hand-edit `.claude/settings.json` or any vendored
agent/script/hook** — `scaffold.sh` already handled those mechanically (settings.json created-if-absent,
the runtime harness vendored); only the adapter and `CLAUDE.md` need YOUR project-specific answers written in.
If scaffold.sh reported settings.json "kept" because one already existed, tell the user to merge the runtime
hooks in by hand (see step 4 above) — don't do it for them silently.

## 5. Gitignore verification
`scaffold.sh` already appended the required entries in step 4. Spot-check with `git check-ignore <path>` for
`.env`, `.claude/settings.local.json`, and `.claude/state/` to confirm they actually resolve as ignored (e.g. a
repo-level override elsewhere in `.gitignore` could still un-ignore one).

## 6. Create the module + approval labels
For every module `name`: `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh label create "module:<name>" --description "<desc>" --force`.
Also create the approval-workflow pair PLUS the needs-human signal label (if `gh label create` is unavailable in the installed gh, use `bot-gh.sh api repos/<owner>/<repo>/labels -f name=... -f color=... -f description=...`):
- `backlog` (color `bfd4f2`) — "Filed, not yet approved by the owner — the loop must NOT pick it up"
- `planned` (color `0e8a16`) — "Owner-approved for the autonomous loop (assigned ONLY by the owner)"
- `needs-human` (color `b60205`) — "Loop is blocked on owner judgment -- see the issue/PR body/comments" (issue #99: applied/removed by `.claude/scripts/needs-human.sh` at every block-on-owner point — PR ready for review, CHANGES_REQUESTED addressed and awaiting re-review, attempt-budget/stall escalation. Surfaced as a "Needs you" strip at the top of the cockpit dashboard, and optionally pushed via `.claude/scripts/notify.sh` if the adapter's `notify` command is configured.)

Report created vs already-existing. Remind: **an issue is only loop-eligible once the OWNER labels it `planned` and it carries a `module:*` label**; issues agents file must be labelled `backlog`.

## 7. Verify the bot account
- Confirm `.env` has `GH_BOT_TOKEN` and the bot can see the repo:
  `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh api user --jq .login` and a `repo view` on the resolved repo.
- If missing/no access, DON'T fail the whole setup — point at the one-time setup notes in
  `.claude/scripts/bot-gh.sh` (create machine account → add as **write** collaborator → classic `repo`-scope
  token → `.env`) and mark this step "action needed".

## 8. Server-side gates (CI)
- Confirm `.github/workflows/gates.yml` exists (scaffolded in step 4 if it wasn't already) and its jobs match
  the gate commands just configured. If the commands differ from what's in `gates.json`, tell the user which
  to reconcile. Note that **branch protection / required checks** (making CI a hard merge gate) is an owner
  action in repo Settings — flag it as a manual step.

## 9. Arm the loop
Two ways to fire the loop; ask the user which one (`AskUserQuestion`), presenting the daemon as the default:

- **Daemon (RECOMMENDED, new default) — issue #102.** A `systemd --user` service (`loop-daemon.sh`)
  supervises the loop forever, independent of any Claude Code session: it runs a tick, and only when the
  tick's verdict is actionable does it spawn a headless driver (`claude -p`), contained (`setsid` + `timeout`)
  and ledgered (`.claude/state/loop-runs.log`). `action=none` spawns nothing — the dominant cost of the old
  cron (a fresh full-context session on every quiet firing) is gone. Survives Claude Code restarting/exiting.
  Requires Linux systemd (native, or WSL2 with systemd enabled).
- **Legacy cron — `/pr-loop`.** Session-scoped `CronCreate`; dies with the Claude Code session that armed it
  and must be re-armed every session. Kept for environments without systemd, or as a fallback. **Never run
  both at once** against the same repo — the spawn lock in `loop-tick.sh` makes it *safe* (no double-spawn),
  merely wasteful (two firing sources burning ticks against the same state).

### If the user picks the daemon
1. **Ask the environment**: `Linux` or `WSL2` (`AskUserQuestion`).
2. **WSL2 only — verify systemd first.** Ask the user to check `/etc/wsl.conf` for a `[boot]` section with
   `systemd=true`. If it's missing or false, this MUST be fixed before continuing:
   - Print the edit for them to make (in a real editor, on the Windows side or via `wsl.exe`):
     ```
     [boot]
     systemd=true
     ```
   - Print the command to apply it: `wsl --shutdown` (run from Windows, then reopen the WSL terminal).
   - **Stop here** for this sub-step — do not proceed to unit install until they confirm systemd is enabled
     (re-check with `systemctl --version` inside WSL2 after the restart).
3. **Sandbox caveat (both Linux and WSL2).** Installing systemd units under `~/.config/systemd/user/`,
   `loginctl enable-linger`, and starting a detached tmux session all touch `$HOME` and systemd — **the
   sandbox blocks this** (`docs/HARDENING.md` → Caveats). Tell the user to run the following in a **real
   terminal outside Claude Code**:
   ```
   bash .claude/scripts/arm-loop.sh
   ```
   (Self-hosting: `bash .claude/scripts/arm-loop.sh --gates-file .claude/self/gates.json`.) This one script
   installs both `pr-loop-<repo>.service` (the loop daemon) and `claude-rc-<repo>.service` (`claude
   remote-control` in a detached tmux session, so planning sessions can be spawned from claude.ai/mobile),
   enables + starts them, and runs `loginctl enable-linger $USER` so they keep running without an open login
   session. It substitutes this checkout's actual path/repo-slug/permission-mode into the templates
   scaffolded at `.claude/systemd/pr-loop.service` and `.claude/systemd/claude-rc.service` — do not hand-edit
   the installed copies under `~/.config/systemd/user/`; edit the checked-in templates and re-run
   `arm-loop.sh` instead.
4. **WSL2 only — offer Windows autostart.** Ask whether they want WSL2 to relaunch automatically after a
   Windows reboot (so the daemon comes back without a manual `wsl` open), offering two tiers
   (`AskUserQuestion`):
   - **Unattended (recommended)** — WSL2 boots at **system startup, before anyone logs on**. Point them at
     the `Register-ScheduledTask` PowerShell block in `docs/USAGE.md` → "Linux vs WSL2" (AtStartup trigger +
     S4U principal; must be run from an **elevated** Windows PowerShell, never from inside WSL). Two
     required companions, also documented there:
     - `vmIdleTimeout=-1` under `[wsl2]` in `%UserProfile%\.wslconfig` (then one `wsl --shutdown` from
       Windows) — without it WSL2 idles the VM back down and stops the daemon even though the task fired;
     - `loginctl enable-linger` (arm-loop.sh already ran this in step 3).
   - **Logon-only (simpler)** — print the exact command to run in an **elevated Windows terminal** (not WSL):
     ```
     schtasks /create /tn "WSL pr-loop autostart" /tr "wsl.exe -d <distro> --exec true" /sc onlogon
     ```
     substituting `<distro>` from `wsl -l` (run on the Windows side) — booting the distro starts systemd,
     which starts both units automatically (`WantedBy=default.target` + linger).
   - **No** → tell them this is safe to skip: GitHub is the loop's only source of truth, so any events that
     land while WSL2 is stopped are simply picked up by the first tick after the next manual WSL2 start —
     nothing is dropped, it's just delayed.
   - Either way, state the caveat: autostart protects the **queue**, not a **driver in flight** — a reboot,
     sleep, or `wsl --shutdown` mid-driver kills that driver and leaves `in_flight` debris (see
     `docs/USAGE.md` → failure contract, "Daemon killed mid-driver"; #119 tracks the fix).
5. Report the units' names and how to inspect them (`systemctl --user status pr-loop-<repo>.service`,
   `journalctl --user -u pr-loop-<repo>.service -f`, `tail -f .claude/state/loop-runs.log`,
   `tmux attach -t rc-<repo>`).

### If the user picks the legacy cron
- Explain `/pr-loop` (session-scoped cron; adaptive cadence). **Offer to run it now** (ask; don't auto-run).
  If they decline, note they can run `/pr-loop` anytime — and must re-arm it each session.

## 10. Hardening (offer LAST — order matters)
- Explain `/harden`: it writes `bypassPermissions` + a strict OS sandbox into `.claude/settings.local.json` for
  hands-off autonomous runs (`docs/HARDENING.md` is the source of truth, if present). **Offer to run `/harden`
  now** (ask).
- Sequencing the user must know: hardening only takes effect after a **restart**, once hardened the agent can no
  longer edit `.claude/settings*.json` (by design), and the restart drops any in-session PR-loop cron. So the
  correct order is: finish setup → `/harden` → restart Claude Code → **re-run `/pr-loop`** in the hardened
  session (legacy cron path only). Do not harden before the rest of setup is done. The **daemon path is
  unaffected by this** — `loop-daemon.sh` runs under systemd, entirely outside any Claude Code session, so a
  restart (or hardening) never drops it; no re-arming needed.

## 11. Hand off
Summarize what changed (files written/kept/restamped by `scaffold.sh`, `gates.json`/`CLAUDE.md` filled,
gitignore entries, labels created, bot status, CI status, loop armed?, hardened?). Restate the two control
points in one line each: **label an issue `module:*` to queue it; approve the bot's PR to ship it.** Finish
with an ordered checklist of everything only the human can complete, e.g.:
- add `GH_BOT_TOKEN` to `.env` / add the bot as a write collaborator (if step 7 flagged it),
- set branch protection / required status checks (if wanted),
- OS-level isolation from `docs/HARDENING.md` Step 2 (sudo / VM / WSL interop) if hardening,
- if the daemon path was chosen: run `bash .claude/scripts/arm-loop.sh` in a real terminal outside Claude
  Code (sandbox caveat), plus the WSL2-only `systemd=true` fix and/or `schtasks` autostart command if flagged
  in step 9,
- if the legacy cron path was chosen: restart, then re-run `/pr-loop`.

## Reference: file inventory this skill scaffolds
See `.claude/skills/setup/templates/MANIFEST.md` for the full template → destination map, and
`.claude/skills/setup/scaffold.sh` for the idempotent implementation (safe to re-run any time; it never
touches user-owned files that already exist, and only re-stamps a managed file when its version marker
is behind).
