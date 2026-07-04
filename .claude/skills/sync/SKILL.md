---
name: sync
description: Re-stamp MANAGED files after a plugin update in an already-onboarded repo. Reconciles scaffolded files (e.g. `.claude/workflows/feature-fanout.js`) against the version markers `/orchestrator:setup` wrote, without ever touching user-owned files. Use this whenever the orchestrator plugin has been updated and the user asks to "sync the orchestrator", "re-stamp managed files after a plugin update", update managed files to match the new plugin version, or run `/orchestrator:sync`.
---

You are running **sync** — the reconcile step that runs *after* a plugin update, in a repo that has already
been through `/orchestrator:setup`. Setup materializes files a plugin can't distribute directly (the adapter,
`CLAUDE.md`, the fan-out workflow, CI YAML) and stamps the ones it manages going forward with an
`@orchestrator-managed <name> vN` marker comment. When the plugin later ships a newer version of one of those
managed files, sync is what brings the consumer repo's copy up to date — it is the seam that lets a plugin
upgrade reach into repos that already onboarded, without a human re-running the whole interview.

## Ownership model (reuse the setup MANIFEST — do not invent a new scheme)
See `.claude/skills/setup/templates/MANIFEST.md` for the authoritative ownership classes. Sync only acts on
the **managed** row (today: `feature-fanout.js` -> `.claude/workflows/feature-fanout.js`). It is designed so
adding a new managed file later is a one-line addition to `sync.sh`'s managed-file table, not a rewrite.

Sync **never** touches user-owned files, under any circumstance:
- `.claude/gates.json`
- `CLAUDE.md`
- `.claude/settings.local.json`
- `.claude/state/`

Nor does it touch `ci`-owned files (`.github/workflows/gates.yml`, `.github/actions/setup/action.yml`) —
those are created once by setup if absent and otherwise left to the human; sync's job is strictly the
version-marked managed files, not the "create if absent" ci files.

## Flow

1. **Orient.** Confirm you're in a repo that has already run `/orchestrator:setup` (a `.claude/gates.json`
   with real values, not the placeholder, is a good signal — but don't hard-block on it; sync is harmless to
   run even if a managed file is simply missing, it will just report `missing`). Resolve the repo root as the
   current working directory.

2. **Run the reconcile script.** All of the actual comparison/re-stamp logic is non-interactive, offline shell
   — delegate to it rather than reasoning about file contents yourself:

   ```
   bash ${CLAUDE_PLUGIN_ROOT:-.claude}/skills/sync/sync.sh
   ```

   Run it from the repo root (no argument needed there — it defaults to the current directory). For each
   managed file it prints one of:
   - `missing` — the file setup would have created isn't there. Sync does not create it (that's setup's job,
     since creating implies opting the repo in); report this to the user and suggest re-running
     `/orchestrator:setup` if the omission is unintentional.
   - `up to date` — the installed marker version already matches what the plugin ships, and content matches
     the pristine template. Nothing to do.
   - `restamped vX -> vY` — the installed file was behind and carried no local edits, so it was safely
     overwritten with the new version.
   - `conflict / needs-merge` — the installed file is behind **and** its content has diverged from the
     pristine template it was originally stamped from (i.e. someone hand-edited it). Sync does **not**
     overwrite this file. It leaves it exactly as-is on disk.
   - `kept (newer)` — the installed marker version is *newer* than what this plugin ships (e.g. a
     hand-authored bump). Never downgrade; left untouched.
   - `user-owned — skipped by design` — printed for awareness only; these files are never written by sync.

3. **Report a diff summary.** Relay the script's per-file summary verbatim to the user (it's already in the
   created/up-to-date/restamped/conflict/kept/skipped vocabulary above). Call out clearly which line, if any,
   changed on disk (`restamped`) versus which are informational only.

4. **Handle conflicts explicitly — never silently overwrite.** For every `conflict / needs-merge` line, tell
   the user which file it is, that it has local edits diverging from the last pristine version it was stamped
   from, and offer two paths — pick with the user, don't assume:
   - **merge**: show the user the diff between their local copy and the new shipped template (e.g.
     `diff -u <installed> <shipped-template>`), and if they confirm, write the merged result yourself (or, if
     they'd rather take the new template wholesale and re-apply their local change afterward, do that
     instead) — always propose the exact content and get an explicit "yes" before writing.
   - **leave**: do nothing to that file. Note in your final summary that it's still behind and will be
     flagged again on the next sync.
   Under no circumstances write to a `conflict` file without the user's explicit go-ahead in this step —
   `sync.sh` itself never does, and neither should you.

5. **Hand off.** Summarize: which managed files were checked, which were restamped, which need a human
   merge decision (and what you did about it, if anything), and which are already current. Remind the user
   that user-owned files (`gates.json`, `CLAUDE.md`, `settings.local.json`, `.claude/state/`) are never
   touched by sync — those stay exactly as the human left them.

## Reference
- `.claude/skills/setup/templates/MANIFEST.md` — the template -> destination map and ownership classes this
  skill reuses.
- `.claude/skills/sync/sync.sh` — the idempotent, offline implementation (safe to re-run any time; never
  writes a user-owned file, never overwrites a file with local edits without being told to).
- `.claude/skills/setup/scaffold.sh` — the sibling script this mirrors; scaffold.sh handles first-time
  creation, sync.sh handles ongoing reconciliation of what scaffold.sh already created.
