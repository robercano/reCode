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
- `.github/workflows/gates.yml` + `.github/actions/setup/action.yml` — the CI gate. Created if absent, left
  untouched if present.
- `.gitignore` entries (append-if-missing, never duplicated): `.env`, `.env.*`, `!.env.example`,
  `.claude/settings.local.json`, `.claude/state/`.
- `.claude/state/` directory (the notify-poll cursor lives here).

Report the script's per-file summary (created / kept / restamped / up to date / appended) to the user. Then
write the interview answers into `.claude/gates.json` (validate with `node -e "require('./.claude/gates.json')"`)
and fill `CLAUDE.md` from its template sections (What this project is / Stack & layout mirroring the module map /
Conventions / Merge policy mirroring `gates.json` / Don'ts) — propose both files and get an explicit "yes"
before writing. Do **not** touch `.claude/settings.json` or any generic agent/script — only the adapter and
`CLAUDE.md` are project-specific here.

## 5. Gitignore verification
`scaffold.sh` already appended the required entries in step 4. Spot-check with `git check-ignore <path>` for
`.env`, `.claude/settings.local.json`, and `.claude/state/` to confirm they actually resolve as ignored (e.g. a
repo-level override elsewhere in `.gitignore` could still un-ignore one).

## 6. Create the module labels
For every module `name`: `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh label create "module:<name>" --description "<desc>" --force`.
Report created vs already-existing. Remind: **an issue is only loop-eligible once it carries a `module:*` label.**

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

## 9. Arm the PR loop
- Explain `/pr-loop` (session-scoped cron; adaptive cadence). **Offer to run it now** (ask; don't auto-run).
  If they decline, note they can run `/pr-loop` anytime — and must re-arm it each session.

## 10. Hardening (offer LAST — order matters)
- Explain `/harden`: it writes `bypassPermissions` + a strict OS sandbox into `.claude/settings.local.json` for
  hands-off autonomous runs (`docs/HARDENING.md` is the source of truth, if present). **Offer to run `/harden`
  now** (ask).
- Sequencing the user must know: hardening only takes effect after a **restart**, once hardened the agent can no
  longer edit `.claude/settings*.json` (by design), and the restart drops the in-session PR-loop cron. So the
  correct order is: finish setup → `/harden` → restart Claude Code → **re-run `/pr-loop`** in the hardened
  session. Do not harden before the rest of setup is done.

## 11. Hand off
Summarize what changed (files written/kept/restamped by `scaffold.sh`, `gates.json`/`CLAUDE.md` filled,
gitignore entries, labels created, bot status, CI status, loop armed?, hardened?). Restate the two control
points in one line each: **label an issue `module:*` to queue it; approve the bot's PR to ship it.** Finish
with an ordered checklist of everything only the human can complete, e.g.:
- add `GH_BOT_TOKEN` to `.env` / add the bot as a write collaborator (if step 7 flagged it),
- set branch protection / required status checks (if wanted),
- OS-level isolation from `docs/HARDENING.md` Step 2 (sudo / VM / WSL interop) if hardening,
- restart, then re-run `/pr-loop`.

## Reference: file inventory this skill scaffolds
See `.claude/skills/setup/templates/MANIFEST.md` for the full template → destination map, and
`.claude/skills/setup/scaffold.sh` for the idempotent implementation (safe to re-run any time; it never
touches user-owned files that already exist, and only re-stamps the managed workflow when its version marker
is behind).
