#!/usr/bin/env bash
# pr-ci-fix.sh — print open, bot-authored PRs whose CURRENT head commit has a
# FAILING CI check that hasn't already been addressed, so the loop can
# dispatch an implementer to push a fix onto the SAME branch. This is
# capability #1 of issue #96 (remote-CI-failure fixing); capabilities #2
# (review-comment convergence) and #3 (rebase-after-sibling-merge) are
# deferred to a follow-up. Prints one TSV line per PR needing a CI fix:
#   <number>\t<branch>\t<failing_check_names_csv>\t<head_sha>
#
# A PR is listed when ALL hold:
#   - authored by the bot ($BOT_LOGIN, default: the bot token's own login), open, base is
#     the adapter's merge.baseBranch ($GATES_FILE, default .claude/gates.json —
#     same node-read as loop-census.sh/merge-ready.sh);
#   - at least one CI check on the CURRENT head is FAILING: CheckRun
#     conclusion in FAILURE/CANCELLED/TIMED_OUT/ACTION_REQUIRED/
#     STARTUP_FAILURE/STALE, or legacy StatusContext state FAILURE/ERROR — the
#     EXACT parse merge-ready.sh's `decide()` uses for the same rollup shape.
#     PENDING/in-progress checks do NOT qualify (a re-run in flight means
#     "wait", not "fix");
#   - it is NOT ALSO a pr-feedback.sh candidate, and NOT ALSO a
#     pr-comment-fix.sh candidate. VERDICT PRECEDENCE (issue #96, part 2):
#     feedback > comment-fix > ci-fix > advance — owner CHANGES_REQUESTED
#     always outranks a CI fix, and an unresolved qualifying review-comment
#     thread outranks a CI fix too (the reopened conversation is addressed
#     before chasing a possibly-unrelated CI failure), so a PR that is both
#     red-CI and awaiting EITHER kind of review action is left entirely to
#     pr-feedback.sh/pr-comment-fix.sh here (excluded, not merely
#     deprioritized) and the caller (loop-tick.sh) additionally enforces the
#     same precedence at the verdict level;
#   - not labeled `needs-human` (the loop's #95 attempt-budget escalation
#     already gave up on this PR/issue — see loop-tick.sh's per-issue attempt
#     budget) and not labeled `claude-ci-fixing` (an in-flight guard, mirroring
#     pr-feedback.sh's `claude-addressing`, so overlapping ticks don't
#     double-dispatch the SAME PR while a fix is already being worked);
#   - the failure has NOT already been addressed for the CURRENT head. This
#     mirrors pr-feedback.sh's `<!-- claude-addressed -->` + `claude-addressing`
#     cursor discipline, but keyed to the head SHA rather than a timestamp: the
#     implementer that fixes CI posts `<!-- claude-ci-addressed:<head_sha> -->`
#     as a bot comment after pushing. If that EXACT marker (for the CURRENT
#     head_sha) is already present, this PR is skipped this tick — either CI
#     hasn't finished re-running the just-pushed fix yet, or it landed and a
#     stale rollup just hasn't caught up. A NEW commit changes head_sha, so a
#     marker tied to the OLD sha no longer matches and a genuinely NEW failure
#     on the NEW commit re-triggers detection. (A timestamp cursor, like
#     pr-feedback.sh uses against `submitted_at` on a review, doesn't work
#     here: a CI conclusion carries no stable "when this failure state began"
#     timestamp to compare against a marker's post time.)
#
# Repo derived from the git remote; override with $1. Bot login via
# $BOT_LOGIN. Adapter (baseBranch) via $GATES_FILE, default .claude/gates.json.
# Invoke as `bash .claude/scripts/pr-ci-fix.sh` (pre-approve that exact
# command). Read-only: detects, never mutates — the `claude-ci-fixing` label
# and the `<!-- claude-ci-addressed:... -->` marker comment are written by the
# driver this script's output goes on to dispatch, never by this script.
set -euo pipefail

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"
# Route EVERY gh call through the bot identity (see bot-gh.sh).
gh() { bash "$script_dir/bot-gh.sh" "$@"; }
repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
bot="${BOT_LOGIN:-$(gh api user --jq .login)}"   # default: the bot token's own login

gates_rel="${GATES_FILE:-.claude/gates.json}"
case "$gates_rel" in /*) gates="$gates_rel" ;; *) gates="$root/$gates_rel" ;; esac
base="$(node -e 'const g=require(process.argv[1]); console.log((g.merge&&g.merge.baseBranch)||"main")' "$gates" 2>/dev/null || echo main)"

# Feedback AND comment-fix candidates OUTRANK ci-fix (precedence) — exclude
# their PR numbers up front so a PR that qualifies for either never shows up
# here at all.
feedback_prs="$(bash "$script_dir/pr-feedback.sh" "$repo" 2>/dev/null \
  | awk -F'\t' 'NF>=2 && $1 ~ /^[0-9]+$/ {print $1}' || true)"
is_feedback_candidate() {
  local n="$1"
  case $'\n'"$feedback_prs"$'\n' in
    *$'\n'"$n"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}
comment_fix_prs="$(bash "$script_dir/pr-comment-fix.sh" "$repo" 2>/dev/null \
  | awk -F'\t' 'NF>=2 && $1 ~ /^[0-9]+$/ {print $1}' || true)"
is_comment_fix_candidate() {
  local n="$1"
  case $'\n'"$comment_fix_prs"$'\n' in
    *$'\n'"$n"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

gh pr list -R "$repo" --state open --base "$base" \
  --json number,headRefName,author,labels,statusCheckRollup,headRefOid \
  --jq '.[] | select(.author.login=="'"$bot"'")' \
| while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue

    # One node call per PR: parse number/branch/labels/head_sha and compute
    # the failing-check CSV + the guard-label skip decision together, so the
    # rest of this loop body only branches on plain shell values. Extracted
    # via `cut -f`, NOT `IFS=$'\t' read` — bash's `read` classifies tab as
    # "IFS whitespace" REGARDLESS of what IFS is set to, so it silently
    # collapses consecutive tabs (e.g. an empty $failing field on a PR with no
    # failing check would swallow the NEXT field too); `cut` never does that.
    parsed="$(printf '%s' "$pr_json" | node -e '
      const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
      const bad = ["FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","STALE"];
      const names = [];
      for (const c of (p.statusCheckRollup || [])) {
        if (c.conclusion !== undefined && c.conclusion !== null && c.conclusion !== "") {
          if (bad.includes(c.conclusion)) names.push(c.name || "");
        } else if (c.state) {
          if (["FAILURE","ERROR"].includes(c.state)) names.push(c.context || "");
        }
      }
      const labels = (p.labels || []).map((l) => l.name);
      const guardSkip = labels.includes("needs-human") || labels.includes("claude-ci-fixing");
      console.log([p.number, p.headRefName || "", names.join(","), p.headRefOid || "", guardSkip ? 1 : 0].join("\t"));
    ')"
    num="$(printf '%s' "$parsed" | cut -f1)"
    branch="$(printf '%s' "$parsed" | cut -f2)"
    failing="$(printf '%s' "$parsed" | cut -f3)"
    head_sha="$(printf '%s' "$parsed" | cut -f4)"
    guard_skip="$(printf '%s' "$parsed" | cut -f5)"

    [ -z "${num:-}" ] && continue
    [ "$guard_skip" = "1" ] && continue
    [ -z "$failing" ] && continue          # no failing check on the current head -> nothing to fix
    is_feedback_candidate "$num" && continue
    is_comment_fix_candidate "$num" && continue

    # Already-addressed cursor: skip if a bot comment carries the marker tied
    # to THIS EXACT head_sha (see header doc above).
    marker="<!-- claude-ci-addressed:${head_sha} -->"
    already="$(gh api "repos/$repo/issues/$num/comments" \
      --jq '[.[]|select(.user.login=="'"$bot"'" and (.body|contains("'"$marker"'")))]|length' \
      2>/dev/null || echo 0)"
    case "$already" in ''|*[!0-9]*) already=0 ;; esac
    [ "$already" -gt 0 ] && continue

    printf '%s\t%s\t%s\t%s\n' "$num" "$branch" "$failing" "$head_sha"
  done
