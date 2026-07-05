---
description: Prepare an open PR for local human testing — checks out its branch into an isolated, ready-to-run worktree (deps built) and hands you the launch command.
argument-hint: <pr-number> [--phone]
---

You are preparing an OPEN pull request for the user to manually test locally, WITHOUT disturbing their main
working tree. The arguments are: **$ARGUMENTS**

Do this:

1. Run `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/prepare-pr.sh $ARGUMENTS`. It resolves the PR's head branch, fetches it, creates (or
   refreshes) a **detached** worktree at `<humanTest.worktreeDir>/pr-<n>` (default `.worktrees/pr-<n>`),
   and runs the project's `humanTest.prepare` command (install + build) inside it. The script is idempotent —
   re-running it on the same PR just fast-forwards the worktree to the latest pushed commit and rebuilds.

2. If the script fails, report the exact error and stop (common causes: the PR is closed, the bot token isn't set,
   or `humanTest` isn't configured in `.claude/gates.json`). Do not guess.

3. On success, report to the user, in this order:
   - the PR number, its title, and the **exact head commit SHA** the worktree is now at (so they know they are
     testing the latest pushed code, not a stale build — the usual reason "the fix doesn't work" for them);
   - the ready-to-run path and the launch command the script printed, e.g.
     `cd <path> && <humanTest.launch>`.
   - Tell them to run the launch command **in their own terminal** (a dev server is long-running and needs a
     browser), and to tear the worktree down with `git worktree remove <path>` when finished.

4. Offer (do not assume) to start the launch command for them in the background if they'd rather you drive it.

## Testing on a phone (opt-in): `--phone`

`/test-pr <pr-number> --phone` (equivalently: `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/prepare-pr.sh <pr-number> --phone`,
or set `PHONE=1` in the environment) does everything the default path does, but prints `humanTest.launchPhone`
instead of `humanTest.launch`. That command is expected to start the same dev server(s) **and** open a public
tunnel (e.g. a `cloudflared` quick tunnel) to the already-running app, so a phone (or anyone with the link) can
reach it over the internet. Nothing about the app changes — it's the same dev server, just tunneled.

Before telling the user to run the printed command, make sure they see all four caveats:
1. **Public** — the printed tunnel URL (e.g. `https://<random>.trycloudflare.com`) works for anyone who has it
   while the tunnel is up, not just the phone it's meant for.
2. **Exposes the whole app** — the tunnel forwards the dev server, including any backend/API it proxies. A visitor
   to the URL can do anything the app can, using whatever credentials/keys are configured in the worktree's `.env`.
3. **Ephemeral** — the tunnel and the dev server(s) are typically tied together (backgrounded servers + a trap);
   killing the command (Ctrl-C) tears down everything at once. There is no persistence across runs.
4. **Attended use only** — don't leave it running unattended; treat the tunnel URL like a temporary,
   unauthenticated view of the app for the duration it's up.

As with step 4 above, offer (do not assume) to start the launch command in the background for the user; if you do
start `humanTest.launchPhone`, watch its output for the tunnel URL and surface that URL clearly once it appears,
so it's easy to open on the phone.

If `humanTest.launchPhone` isn't configured in `.claude/gates.json`, the script says so and falls back to printing
the normal `humanTest.launch` command — report that to the user rather than treating it as a failure.

Notes:
- This never edits the PR and never touches `main` — the worktree is an isolated, detached checkout, so it can
  coexist with the same branch checked out elsewhere (e.g. an agent worktree).
- The prepare/launch/launchPhone/worktree-dir commands are read from `.claude/gates.json` → `humanTest`, so this
  command is project-agnostic. If `humanTest` is absent, the script still makes the worktree and tells the user to
  build/run manually.
