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
the **managed** rows — today: `feature-fanout.js` -> `.claude/workflows/feature-fanout.js`, and (issue #102)
the cron-less loop daemon's systemd unit templates + installer:
`pr-loop.service` -> `.claude/systemd/pr-loop.service`, `claude-rc.service` -> `.claude/systemd/claude-rc.service`,
and `arm-loop.sh` -> `.claude/scripts/arm-loop.sh`. All of these are reconciled by the exact same
marker-version ladder below. It is designed so adding a new managed file later is a one-line addition to
`sync.sh`'s managed-file table, not a rewrite.

Re-stamping the loop-daemon templates only updates the checked-in files in the repo — it never touches an
already-installed unit under `~/.config/systemd/user/` or restarts a running daemon. Tell the user to re-run
`bash .claude/scripts/arm-loop.sh` (in a real terminal, per the sandbox caveat) after a restamp if they want
the installed units to pick up the change.

**This plugin does NOT vendor `agents/`, `commands/`, `hooks/`, `scripts/`, `skills/` into the consumer repo**
(issue #134 reverted issue #128's vendoring model) — those are read straight from the plugin cache
(`${CLAUDE_PLUGIN_ROOT}`), so **the `orchestrator` plugin must stay enabled for everyday sessions**, not just
to run this skill or `/orchestrator:setup`. Sync instead **detects and warns** about local leftovers of the
old vendored tree (e.g. a repo onboarded before #134, or one that legitimately kept a local override) — see
"Stale-vendor detection" below. It never deletes or restamps those directories itself.

### Stale-vendor detection (issue #134)
For each of `agents/`, `commands/`, `hooks/`, `scripts/`, `skills/` still present locally under `.claude/`,
`sync.sh`'s `detect_stale_vendor_copies` diffs it against the plugin's own shipped copy (excluding
`arm-loop.sh`, separately managed above) and reports one of:
- `stale-vendor: ... matches the plugin's shipped copy ... safe to delete` — a leftover from before #134 that
  now only shadows the plugin cache (`resolve-roots.sh` deliberately makes a repo-tracked `.claude/scripts`
  layout win over `${CLAUDE_PLUGIN_ROOT}`, which is exactly the failure mode that motivated #134 — see the
  reDeploy incident it references). Sync does **not** delete it; tell the user it's safe to.
- `stale-vendor conflict: ... diverges from the plugin's shipped copy` — treat this as a **possible deliberate
  local override**, not assumed-safe-to-delete. Show the user the diff (`diff -rq <plugin copy> <local copy>`)
  and let them decide whether it's a stale relic or a fix worth upstreaming (same "It's a generic improvement
  → upstream it" guidance as `docs/MIGRATION.md`).
- A leftover `.claude/.orchestrator-vendor` marker file (the old #128 vendor-version stamp) is called out
  separately, once you've reconciled the flagged directories above.
- **Migration caveat, always repeat when any stale-vendor line appears:** deleting/refreshing files on disk is
  not enough for a repo whose loop is already armed — a running `pr-loop`/`claude-rc` systemd unit holds its
  OLD script **in memory** until its unit restarts. Tell the user to run
  `systemctl --user restart pr-loop-<repo-slug>.service claude-rc-<repo-slug>.service` after cleaning up (cf.
  the 2026-07-16 reCode deploy-lag incident, issue #131).

Sync **never** touches user-owned files, under any circumstance:
- `.claude/gates.json`
- `CLAUDE.md`
- `.claude/settings.json`
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
   - `error` — the plugin install itself looks broken (a managed file's shipped template is missing, or the
     template carries no valid `@orchestrator-managed <name> vN` marker). This is not a per-repo verdict like
     the others above — it means the plugin's own files are inconsistent. `sync.sh` exits nonzero (1) whenever
     any `error` line is printed, distinct from every other outcome above (including `conflict`), which are
     normal per-file verdicts that still exit 0. Surface `error` lines to the user prominently and suggest
     reinstalling/updating the plugin rather than treating it as something to fix in the consumer repo.

   Separately (not a per-file managed-row verdict), it also prints `stale-vendor:` / `stale-vendor conflict:`
   lines — see "Stale-vendor detection" above — for any leftover local copy of the pre-#134 vendored tree,
   or `stale-vendor: none found` if there is none.

   It then prints four more offline sections (issue #141, "sync v2") — each report-only, never mutates
   anything, always exits 0 regardless of what it finds:
   - `deploy-lag:` — reads `.claude/state/loop-runs.log` (the loop daemon's run ledger) and reports how long
     ago the last recorded driver run started. The ledger only ever logs a run AFTER it has already finished,
     so its recency can never prove a driver isn't running right now — sync.sh therefore never claims
     "active" or "safe to restart" from this alone; it always tells the operator to verify independently
     (e.g. `systemctl --user status 'pr-loop-driver-*'`) before re-arming/restarting the pr-loop/claude-rc
     systemd units (issue #131). `not found` usually means the loop was never armed here, but — same caveat —
     a first driver run in progress hasn't appended a line yet either, so this too is never read as proof no
     driver is active.
   - `env:` — (a) whether `.env` exists and carries a `GH_BOT_TOKEN=` key (the token's **value** is never
     read or printed, only whether the key is present); (b) whether the installed plugin version (read from
     `.claude-plugin/plugin.json`) is at least the floor this sync ships (currently the issue #136 release,
     `0.2.2`) — `OK` / `BELOW required` / unparseable. It also prints one **ADVISORY** line for the live,
     network bot-identity check — sync.sh never runs it; see "Live steps the agent performs" below.
   - `labels:` — derives the expected `module:<name>` labels (one per `.claude/gates.json` `modules[].name`,
     honoring `$GATES_FILE` the same way `gate.sh` does) plus `needs-human`, and prints the exact
     `bot-gh.sh label create ...` commands as **ADVISORY** lines — it never queries or creates labels itself.
     No adapter parses -> `cannot derive labels`. Self-hosting quiets this section entirely (see below).
   - `observability:` — stats `.claude/state/worker-tools.jsonl` and `.claude/state/events.jsonl` and reports
     `absent` (referencing issue #137, the tracked gap — sync does **not** attempt to fix it), `present but
     empty`, or `present, N line(s)` (looks wired up). Detection only.

   **Self-hosting:** when this plugin's own repo runs sync.sh against itself, `deploy-lag`/`env`/
   `observability` still run as plain informational reads (there's nothing misleading about reporting this
   repo's own state), but the `labels:` section — which *implies* remediation ("go create these") — goes
   quiet with a one-line "already managed by the owner" note instead of repeating advisory commands for
   labels the repo obviously already has, the same way `detect_stale_vendor_copies` goes quiet on its own
   canonical tree.

3. **Report a diff summary.** Relay the script's per-file summary verbatim to the user (it's already in the
   created/up-to-date/restamped/conflict/kept/skipped/error vocabulary above). Call out clearly which line, if
   any, changed on disk (`restamped`) versus which are informational only, and call out `error` lines as a
   plugin-install problem rather than a repo problem. Relay the four `deploy-lag`/`env`/`labels`/
   `observability` sections too — they're display order and can be summarized after the managed-file table.

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

5. **Live steps the agent performs (issue #141).** sync.sh stays offline by design — these two steps pair
   with its `env:`/`labels:` ADVISORY lines and are the ONLY parts of sync v2 that touch the network. Run
   them yourself, as the agent, via `bot-gh.sh` (never bare `gh`):
   - **Bot identity/repo access** — run the exact command sync.sh printed:
     `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh api user --jq .login`, plus a `repo view` on this
     repo. If either fails, don't fail the whole sync — report "action needed" and point at the one-time
     setup notes in `.claude/scripts/bot-gh.sh` (same treatment as setup's step 7).
   - **Label existence + create-missing** — query which labels already exist (e.g.
     `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh label list`), diff that against sync.sh's derived
     `module:<name>` + `needs-human` set, and run the create command **only** for the ones actually missing
     — sync.sh already printed the exact command for each; don't invent new ones or run them unconditionally
     (most repos will have most labels already; a good sync run creates zero-to-few).

6. **Hand off.** Summarize: which managed files were checked, which were restamped, which need a human
   merge decision (and what you did about it, if anything), and which are already current. Remind the user
   that user-owned files (`gates.json`, `CLAUDE.md`, `settings.local.json`, `.claude/state/`) are never
   touched by sync — those stay exactly as the human left them. If any `stale-vendor` line was printed,
   surface it prominently (don't bury it in the managed-file summary) along with the migration caveat about
   restarting the armed systemd units after the human cleans up a stale local copy. Also summarize the sync
   v2 sections: deploy-lag (age of the last completed run, plus whether you independently verified no driver
   is currently active before restarting anything, and when), the environment check (token key present?
   plugin version floor met?), which labels (if any) you created
   after the live existence check, and the observability-plumbing verdict (flag issue #137 by number if
   either state file is absent/empty — don't attempt to fix it here).

## Reference
- `.claude/skills/setup/templates/MANIFEST.md` — the template -> destination map and ownership classes this
  skill reuses.
- `.claude/skills/sync/sync.sh` — the idempotent, offline implementation (safe to re-run any time; never
  writes a user-owned file, never overwrites a file with local edits without being told to).
- `.claude/skills/setup/scaffold.sh` — the sibling script this mirrors; scaffold.sh handles first-time
  creation, sync.sh handles ongoing reconciliation of what scaffold.sh already created.
