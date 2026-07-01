---
description: Interactive full onboarding — interview the user, then write .claude/gates.json + CLAUDE.md, fix gitignore, create module:* labels, verify the bot, confirm CI gates, and offer to arm the PR loop and hardening. Brings a fresh project to a working autonomous state.
---

You are running **first-time setup** for this orchestrator template in the user's project. Goal: take a fresh
clone from placeholder to a fully working autonomous state — the same configuration a mature project here has:
a filled adapter, module labels, a working bot identity, server-side gates, the PR loop armed, and (optionally)
hardened hands-off mode. You *interview* the user, then materialize the files and GitHub state the loop depends on.

`docs/GETTING_STARTED.md`, `docs/USAGE.md`, and `docs/HARDENING.md` are the sources of truth — read them first
and defer to them on any detail.

Be conversational but efficient. Use the `AskUserQuestion` tool for discrete choices; ask for free-text
(names, paths, shell commands) in plain prose. **Never invent values** — if you don't know a command or path,
ask. **Propose the final files and get an explicit "yes" before writing.** All `gh` runs through
`bash .claude/scripts/bot-gh.sh`, never bare `gh`.

Do these in order. Stop and report if a step genuinely can't proceed.

## 1. Preconditions & orientation
- Read `docs/GETTING_STARTED.md`, `docs/USAGE.md`, `docs/HARDENING.md`, the current `.claude/gates.json`, and `CLAUDE.md`.
- **Redundant-setup check (warn, then ask — don't hard-abort).** If `gates.json.gates` already has non-empty
  commands, the project looks already configured. **Warn clearly**: show the current `project`/`modules`/`gates`,
  and say that continuing will re-interview and, on your confirmation, overwrite the adapter files and reconcile
  labels. Then **ask the user whether to continue or stop** (use `AskUserQuestion`). If they choose stop, end the
  command cleanly with no changes. If they continue, proceed with the flow. (You still confirm before each file
  write in later steps, so a re-run can't clobber silently.)
- Resolve the repo: `bash .claude/scripts/bot-gh.sh repo view --json nameWithOwner -q .nameWithOwner`.

## 2. Explain the model up front (so answers are informed)
Briefly tell the user how the loop decides what to build:
- The loop only builds issues **labelled `module:<name>`**, one at a time, when no PRs are open — an explicit opt-in queue.
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

## 4. Write the adapter (after confirmation)
- Produce the complete `.claude/gates.json`, show it, and on approval write it. It MUST be valid JSON —
  validate with `node -e "require('./.claude/gates.json')"`; fix and re-validate if it throws.
- Fill `CLAUDE.md` from its template sections (What this project is / Stack & layout mirroring the module map /
  Conventions / Merge policy mirroring `gates.json` / Don'ts). Keep it lean — project-WIDE context only.
- Do **not** touch `.claude/settings.json` or any generic agent/script — only the adapter.

## 5. Gitignore hygiene
Ensure these are gitignored (append if missing, don't duplicate): `.env` (holds `GH_BOT_TOKEN`),
`.claude/settings.local.json` (per-machine hardening/bypass — must never be inherited by a clone), and
`.claude/state/` (the notify-poll cursor). Verify with `git check-ignore <path>`.

## 6. Create the module labels
For every module `name`: `bash .claude/scripts/bot-gh.sh label create "module:<name>" --description "<desc>" --force`.
Report created vs already-existing. Remind: **an issue is only loop-eligible once it carries a `module:*` label.**

## 7. Verify the bot account
- Confirm `.env` has `GH_BOT_TOKEN` and the bot can see the repo:
  `bash .claude/scripts/bot-gh.sh api user --jq .login` and a `repo view` on the resolved repo.
- If missing/no access, DON'T fail the whole setup — point at the one-time setup notes in
  `.claude/scripts/bot-gh.sh` (create machine account → add as **write** collaborator → classic `repo`-scope
  token → `.env`) and mark this step "action needed".

## 8. Server-side gates (CI)
- Confirm `.github/workflows/gates.yml` exists and its jobs match the gate commands just configured (see #8).
  If the commands differ, tell the user which to reconcile. Note that **branch protection / required checks**
  (making CI a hard merge gate) is an owner action in repo Settings — flag it as a manual step.

## 9. Arm the PR loop
- Explain `/pr-loop` (session-scoped cron; adaptive cadence). **Offer to run it now** (ask; don't auto-run).
  If they decline, note they can run `/pr-loop` anytime — and must re-arm it each session.

## 10. Hardening (offer LAST — order matters)
- Explain `/harden`: it writes `bypassPermissions` + a strict OS sandbox into `.claude/settings.local.json` for
  hands-off autonomous runs (`docs/HARDENING.md` is the source of truth). **Offer to run `/harden` now** (ask).
- Sequencing the user must know: hardening only takes effect after a **restart**, once hardened the agent can no
  longer edit `.claude/settings*.json` (by design), and the restart drops the in-session PR-loop cron. So the
  correct order is: finish setup → `/harden` → restart Claude Code → **re-run `/pr-loop`** in the hardened
  session. Do not harden before the rest of setup is done.

## 11. Hand off
Summarize what changed (files written, gitignore entries, labels created, bot status, CI status, loop armed?,
hardened?). Restate the two control points in one line each: **label an issue `module:*` to queue it; approve
the bot's PR to ship it.** Finish with an ordered checklist of everything only the human can complete, e.g.:
- add `GH_BOT_TOKEN` to `.env` / add the bot as a write collaborator (if step 7 flagged it),
- set branch protection / required status checks (if wanted),
- OS-level isolation from `docs/HARDENING.md` Step 2 (sudo / VM / WSL interop) if hardening,
- restart, then re-run `/pr-loop`.
