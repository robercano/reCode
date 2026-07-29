---
name: feedback
description: Capture rollout feedback from a CONSUMER repo (reDeploy, reDeFi, or any other project with the orchestrator plugin installed) as a five-second act — /orchestrator:feedback "<one-line description>" — and file it as a triage-inbox issue in the PLUGIN repo (robercano/reCode). Autofills the origin repo, installed plugin version, and a body template; only asks for the description and an optional severity. Use this whenever the user runs `/orchestrator:feedback`, or asks to "file feedback", "report a bug in the orchestrator", or "note this for reCode" while working in a consumer repo.
---

You are running **feedback capture** — the five-second consumer-side act of noting something wrong or
worth improving in the orchestrator plugin, without breaking the owner's flow while they're inside a
consumer repo (reDeFi, reDeploy, ...) during rollout testing (issue #177). This skill deliberately does
almost nothing itself: nearly all of the logic is deterministic and lives in
`.claude/skills/feedback/feedback.sh` (or `${CLAUDE_PLUGIN_ROOT}/skills/feedback/feedback.sh` when running
from the installed plugin cache) — you gather the two things only a human can supply, then call it.

## Identity note (read this — it is the one deliberate exception in this plugin)
Every other skill in this repo routes ALL `gh` calls through
`bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh` so PRs land bot-authored and the owner can approve
them. **This skill is the one deliberate exception.** `feedback.sh` calls **plain `gh`** — the owner's own
ambient identity — because the issue being filed genuinely IS the owner's own feedback (they are the one
running this, from inside a consumer repo, during their own rollout testing). There is no "the owner can't
approve their own PR" problem here to route around: this only ever files an *issue*, not a PR, and it is
correct for it to be owner-authored. Do not route this one call through bot-gh.sh.

## Flow

1. **Gather the two inputs.** Ask for:
   - the one-line description (required) — what was observed, said concisely enough to fit a `/orchestrator:feedback "..."` invocation. If the user already supplied it as the command argument, use that directly; don't re-ask.
   - a severity suggestion (optional) — if the user doesn't volunteer one, it's fine to skip; the helper
     fills in "(not specified)" and the owner can triage severity later. Don't stall the five-second goal
     interrogating for it.
   Everything else (origin label, plugin version, milestone, labels) is fully automatic — never ask about
   those.

2. **Run the helper for real** (no `--dry-run` — that flag exists for `feedback.test.sh`'s offline smoke
   test, not for actual use):
   ```
   bash ${CLAUDE_PLUGIN_ROOT:-.claude}/skills/feedback/feedback.sh "<description>" [--severity "<severity>"]
   ```
   Run it from the consumer repo's working directory (or any subdirectory of it) — it resolves the repo
   root itself via `resolve-roots.sh`, the same two-root derivation `bot-gh.sh` uses.

3. **Read the result.**
   - **Success** — the helper prints the created issue's URL on stdout. Tell the user it's filed, share the
     URL, and mention which label(s) landed on it (see "What gets autofilled" below).
   - **Guard failure** (exit 1, clear one-line message on stderr) — this means one of three concrete
     conditions wasn't met: (a) no resolvable `origin` git remote, (b) origin IS robercano/reCode itself
     (this skill files INTO reCode; it does not run FROM it), or (c) the orchestrator plugin's manifest
     isn't resolvable (neither `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` nor
     `<repo>/.claude/.claude-plugin/plugin.json` exists — i.e. the plugin doesn't look installed here). In
     every one of these cases the helper creates **no issue at all** — relay the exact stderr message to the
     user; don't retry with a workaround, since a guard failure means the five-second assumption
     (consumer repo, plugin installed) genuinely doesn't hold here.
   - **Label degrade warning** (exit 0, but a warning on stderr) — the issue still filed successfully, just
     without one or more labels attaching cleanly. Relay this too, so the user knows to label it by hand if
     they care.

## What gets autofilled (so you can explain it if asked)
- **Origin label** — derived from the consumer repo's `origin` git remote: a case-insensitive `redeploy`
  substring match adds `from:redeploy`, `redefi` adds `from:redefi`. Neither match still files the issue
  (labelled just `feedback`) — the raw origin repo slug is always noted in the body regardless, so nothing
  about where the feedback came from is ever lost even without a matching from:* label.
- **Installed plugin version** — read from whichever plugin manifest resolved during the guard check;
  degrades to the literal string `unknown` (never blocks filing) if the file exists but its `version` field
  can't be parsed.
- **Body template** — `## Observed` (the description), `## Expected` (left as a fill-in-if-different
  placeholder), `## Severity suggestion` (what was gathered, or "(not specified)"), plus a trailer noting the
  origin repo and plugin version.
- **Labels** — `feedback` + whichever `from:*` label matched. Deliberately **no milestone, no `planned`
  label** — this lands in reCode's census-invisible triage inbox (see `docs/USAGE.md` → "Release cycle" →
  the rollout & feedback companion) until the owner triages it, exactly like the auto-filed
  `Rollout & feedback: vX.Y.Z` issue `release.sh` files after every cut.

## Reference
- `.claude/skills/feedback/feedback.sh` — the offline-where-possible implementation; the one network call
  it makes (label create + issue create) uses plain `gh`, see the identity note above.
- `.claude/scripts/feedback.test.sh` — the standalone, offline smoke test (remote→label mapping, version
  resolution + fallback + "unknown" degrade, all three consumer-repo guard conditions, body-template
  assembly, and the no-partial-issue-on-guard-failure / degrade-without-labels-on-create-failure paths) —
  exercised via `feedback.sh --dry-run` and an overridable `$FEEDBACK_GH_BIN` stub, never the real network.
- `docs/USAGE.md` → "Release cycle" → the `/orchestrator:feedback` subsection for the user-facing summary.
