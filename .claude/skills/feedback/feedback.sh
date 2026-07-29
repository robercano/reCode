#!/usr/bin/env bash
# feedback.sh — helper for the /orchestrator:feedback skill (issue #177).
#
# Runs in a CONSUMER repo (e.g. reDeploy, reDeFi) and files a triage-inbox
# issue in the PLUGIN repo (robercano/reCode). This is the ONE deliberate spot
# in this plugin that shells out to PLAIN `gh` instead of bot-gh.sh: the issue
# being filed genuinely IS the owner's own feedback (they are the one running
# this from inside a consumer repo during rollout testing), so there is no
# "bot needs to open a PR the owner can approve" problem bot-gh.sh exists to
# solve — see bot-gh.sh's own header for that rationale, which does not apply
# here. `gh` runs with whatever identity is already logged in on the machine
# (the owner's), by design.
#
# Usage:
#   feedback.sh "<one-line description>" [--severity SEV] [--dry-run]
#   feedback.sh --description "<...>" [--severity SEV] [--dry-run]
#
# --dry-run performs every PURE step (consumer-repo guard, origin->label
# mapping, plugin-version resolution, body-template assembly) for real, then
# PRINTS the exact `gh issue create` invocation it would run — including the
# fully assembled body — instead of executing it. No network call of any
# kind happens under --dry-run (mirrors release.sh's --dry-run boundary).
#
# The actual `gh` calls (both non-dry-run label-create and issue-create) are
# additionally routed through an overridable command, $FEEDBACK_GH_BIN
# (defaults to plain `gh`), so a test can point this at a logging stub
# instead of the real network binary without needing --dry-run.
#
# Consumer-repo guard (concrete definition — ALL three must hold, checked in
# order, first failure wins, and NO gh call is ever made if any fails, dry-run
# or not):
#   1. the current repo has a resolvable GitHub `origin` remote,
#   2. that origin is NOT robercano/reCode itself (this skill files INTO
#      reCode, it does not run FROM it),
#   3. the orchestrator plugin's manifest is resolvable — either
#      ${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json (the normal consumer
#      case: plugin installed from the marketplace cache) or, as a fallback,
#      <repo-root>/.claude/.claude-plugin/plugin.json (a local-clone install,
#      or this repo's own self-hosting layout).
# Any failure degrades gracefully: a clear one-line error on stderr, exit
# non-zero, and no issue (partial or otherwise) is ever created.
#
# Origin -> label mapping (best-effort, never blocks filing):
#   the origin owner/repo slug is matched case-insensitively for the
#   substring "redeploy" -> `from:redeploy`, or "redefi" -> `from:redefi`. If
#   neither matches, NO from:* label is applied — the issue still files with
#   just `feedback`, and the raw origin repo slug is always noted in the body
#   regardless of whether a from:* label could be derived from it, so nothing
#   is silently lost.
#
# Installed plugin version: read from whichever manifest resolved above,
# case degrading to the string "unknown" (never crashing) if the file exists
# but its `version` field can't be parsed.
#
# Missing-label degrade: label creation (`gh label create ... --force`) is
# always best-effort (`|| true`) before filing. If the `gh issue create` call
# itself then fails (e.g. because a label genuinely doesn't exist and this
# gh/token combination can't create it), this retries EXACTLY ONCE with no
# --label flags at all, so a label problem degrades to "filed without
# labels" (with a loud warning to add them by hand) rather than losing the
# issue entirely.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/resolve-roots.sh
. "$script_dir/../../scripts/resolve-roots.sh"

GH_BIN="${FEEDBACK_GH_BIN:-gh}"
TARGET_REPO="${FEEDBACK_TARGET_REPO:-robercano/reCode}"

DESCRIPTION=""
SEVERITY=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --description) DESCRIPTION="${2:?--description requires a value}"; shift 2 ;;
    --severity) SEVERITY="${2:?--severity requires a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*)
      echo "feedback.sh: unknown flag '$1'" >&2
      exit 2
      ;;
    *)
      if [ -z "$DESCRIPTION" ]; then
        DESCRIPTION="$1"
        shift
      else
        echo "feedback.sh: unexpected extra argument '$1'" >&2
        exit 2
      fi
      ;;
  esac
done

if [ -z "$DESCRIPTION" ]; then
  echo "feedback.sh: a one-line description is required (positional argument or --description)" >&2
  exit 2
fi

# --- consumer-repo guard, step 1: resolvable origin remote -------------------
origin_url="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
if [ -z "$origin_url" ]; then
  echo "feedback.sh: no 'origin' git remote found in $root — /orchestrator:feedback must be run from a CONSUMER repo checkout with an origin remote, not a repo with no remote configured." >&2
  exit 1
fi

origin_owner_repo=""
case "$origin_url" in
  git@github.com:*) origin_owner_repo="${origin_url#git@github.com:}"; origin_owner_repo="${origin_owner_repo%.git}" ;;
  ssh://git@github.com/*) origin_owner_repo="${origin_url#ssh://git@github.com/}"; origin_owner_repo="${origin_owner_repo%.git}" ;;
  https://github.com/*) origin_owner_repo="${origin_url#https://github.com/}"; origin_owner_repo="${origin_owner_repo%.git}" ;;
esac

if [ -z "$origin_owner_repo" ]; then
  echo "feedback.sh: could not parse a GitHub owner/repo out of origin remote '$origin_url' — only github.com remotes are supported." >&2
  exit 1
fi

origin_lower="$(printf '%s' "$origin_owner_repo" | tr '[:upper:]' '[:lower:]')"

# --- consumer-repo guard, step 2: must NOT be robercano/reCode itself --------
if [ "$origin_lower" = "robercano/recode" ]; then
  echo "feedback.sh: refusing to run inside robercano/reCode itself — /orchestrator:feedback captures a CONSUMER's feedback and files it INTO reCode; run it from the consumer repo (reDeploy/reDeFi/etc), not from reCode's own checkout." >&2
  exit 1
fi

# --- consumer-repo guard, step 3: the plugin's manifest must be resolvable ---
plugin_manifest=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then
  plugin_manifest="$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json"
elif [ -f "$root/.claude/.claude-plugin/plugin.json" ]; then
  plugin_manifest="$root/.claude/.claude-plugin/plugin.json"
fi

if [ -z "$plugin_manifest" ]; then
  echo "feedback.sh: could not find the orchestrator plugin's manifest (checked \${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json and $root/.claude/.claude-plugin/plugin.json) — is the orchestrator plugin installed in this repo?" >&2
  exit 1
fi

# --- installed plugin version (degrade to "unknown", never crash) -----------
plugin_version="$(node -e '
  try {
    const fs = require("fs");
    const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(String(j.version || "unknown"));
  } catch (e) {
    process.stdout.write("unknown");
  }
' "$plugin_manifest" 2>/dev/null || true)"
[ -n "$plugin_version" ] || plugin_version="unknown"

# --- origin -> from:* label mapping (best-effort; empty = no from:* label) ---
origin_label=""
case "$origin_lower" in
  *redeploy*) origin_label="from:redeploy" ;;
  *redefi*) origin_label="from:redefi" ;;
esac

# --- body template ------------------------------------------------------------
severity_line="${SEVERITY:-(not specified)}"
title="Feedback: $DESCRIPTION"
body="## Observed
$DESCRIPTION

## Expected
(fill in if different from observed)

## Severity suggestion
$severity_line

---
Origin repo: $origin_owner_repo
Installed plugin version: $plugin_version
Filed via \`/orchestrator:feedback\` (issue #177)."

labels=(feedback)
[ -n "$origin_label" ] && labels+=("$origin_label")

label_args=()
for lbl in "${labels[@]}"; do
  label_args+=(--label "$lbl")
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "feedback.sh: [dry-run] would run: $GH_BIN issue create --repo $TARGET_REPO --title \"$title\" ${label_args[*]}"
  echo "feedback.sh: [dry-run] body would be:"
  printf '%s\n' "$body"
  echo "feedback.sh: [dry-run] complete — no gh/network call performed"
  exit 0
fi

# =============================================================================
# Everything below performs a REAL gh call (or the overridable $GH_BIN stand-
# in) and is never reached under --dry-run.
# =============================================================================

# Idempotent label creation, best-effort. Owner's own real gh (not the bot's
# older gh, which issue #169 found silently no-ops `gh label create` — this
# path never touches bot-gh.sh, so that caveat does not apply here), so plain
# `gh label create ... --force` is fine.
for lbl in "${labels[@]}"; do
  "$GH_BIN" label create "$lbl" --description "Feedback filed via /orchestrator:feedback" --force >/dev/null 2>&1 || true
done

if issue_out="$("$GH_BIN" issue create --repo "$TARGET_REPO" --title "$title" --body "$body" "${label_args[@]}" 2>&1)"; then
  printf '%s\n' "$issue_out"
  exit 0
fi

echo "feedback.sh: warning — issue create with labels failed, retrying once without labels: $issue_out" >&2
if issue_out="$("$GH_BIN" issue create --repo "$TARGET_REPO" --title "$title" --body "$body" 2>&1)"; then
  printf '%s\n' "$issue_out"
  echo "feedback.sh: warning — filed without labels; add ${labels[*]} by hand." >&2
  exit 0
fi

echo "feedback.sh: error — could not file the feedback issue: $issue_out" >&2
exit 1
