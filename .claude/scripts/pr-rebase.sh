#!/usr/bin/env bash
# pr-rebase.sh — print open, bot-authored PRs that have gone CONFLICTING
# against their base (typically because a sibling PR merged into base first),
# so the loop can dispatch a driver to rebase the SAME branch onto the new
# base and force-push it back in place. This is capability #3 of issue #96
# (rebase-after-sibling-merge); capability #1 (CI-failure fixing) is
# pr-ci-fix.sh, capability #2 (review-comment convergence) is
# pr-comment-fix.sh. Prints one TSV line per PR needing a rebase:
#   <number>\t<branch>\t<head_sha>\t<base_sha>\t<attempt>
#
# A PR is listed when ALL hold:
#   - authored by the bot ($BOT_LOGIN, default robercano-ghbot), open, base is
#     the adapter's merge.baseBranch ($GATES_FILE, default .claude/gates.json
#     — same node-read as loop-census.sh/pr-ci-fix.sh/pr-comment-fix.sh);
#   - GitHub's own `mergeable` field on the PR is EXACTLY `CONFLICTING`. This
#     is the one and only trigger: a PR that WAS cleanly mergeable but no
#     longer is has almost always gone stale because ANOTHER PR merged into
#     base first (the very thing this capability exists to recover from).
#     `MERGEABLE` obviously doesn't qualify (nothing to fix), and — mirroring
#     pr-ci-fix.sh's "PENDING CI doesn't qualify" reasoning for its own
#     rollup — `PENDING`/`UNKNOWN` do NOT qualify either: GitHub computes
#     `mergeable` asynchronously and hasn't finished yet, so treating either
#     as a green light would dispatch a rebase driver against a stale/unknown
#     answer instead of waiting one more tick for GitHub to settle;
#   - it is NOT ALSO a pr-feedback.sh, pr-comment-fix.sh, OR pr-ci-fix.sh
#     candidate. VERDICT PRECEDENCE (issue #96, all three parts): feedback >
#     comment-fix > ci-fix > rebase > advance — rebase is the LOWEST of the
#     four PR-event reactions (a merge conflict, unlike unaddressed feedback,
#     an unresolved review thread, or red CI, is not itself proof that
#     something is WRONG with this PR's own change — it only needs to catch
#     up with base), so a PR that also qualifies for any of the other three
#     is left ENTIRELY to that script here (excluded, not merely
#     deprioritized), and the caller (loop-tick.sh) additionally enforces the
#     same precedence at the verdict level;
#   - not labeled `needs-human` (the anti-livelock budget below already gave
#     up on this PR for its CURRENT base commit, or some OTHER escalation
#     gave up on it) and not labeled `claude-rebasing` (an in-flight guard,
#     mirroring pr-ci-fix.sh's `claude-ci-fixing`/pr-comment-fix.sh's
#     `claude-comment-fixing`, so overlapping ticks don't double-dispatch the
#     SAME PR while a rebase is already being worked);
#   - the rebase has NOT already been exhausted for the CURRENT base commit
#     (see ANTI-LIVELOCK below).
#
# ANTI-LIVELOCK (bounded per-base-commit retries, marker-cursor, no new state
# file — mirrors pr-ci-fix.sh's head_sha-keyed marker and pr-comment-fix.sh's
# per-thread attempt-number derivation): the driver that attempts a rebase
# posts a bot comment containing
# `<!-- claude-rebase-attempted:<base_sha>:<attempt> -->` after EVERY attempt
# (both a clean rebase+force-push AND an aborted conflicting one — see
# loop-event.sh's rebase prompt). For the PR's CURRENT `baseRefOid` (base_sha):
#   - no marker at all for this EXACT base_sha -> next attempt is 1, this PR
#     is a fresh candidate;
#   - the highest-attempt marker found for this EXACT base_sha is K -> next
#     attempt is K+1;
#   - once the next attempt would be 3 (i.e. 2 completed attempts already
#     recorded against this SAME base_sha), this script escalates instead of
#     emitting another candidate: applies the `needs-human` label via
#     needs-human.sh's `needs_human_flag` (same seam pr-comment-fix.sh's own
#     inline escalation uses) and drops the PR from this tick's output.
# A marker's base_sha is compared for EXACT equality only — a marker posted
# against an OLDER base_sha never counts toward the CURRENT base_sha's
# budget. This is what makes the budget self-resetting: once a NEW sibling PR
# merges into base, `baseRefOid` changes, every marker on file was written
# against the now-stale base_sha, so the count for the fresh base_sha starts
# back at zero and this PR is eligible again (attempt=1) even if it had
# previously exhausted its budget against the OLD base_sha and been labeled
# needs-human for it. needs_human_flag's own "already labeled" check makes
# repeated escalation ticks against the SAME base_sha a no-op (no repeat
# comment spam); once the label lands, the very next tick's guard-label check
# above excludes the whole PR from further rebase automation (of ANY base
# commit) until a human clears it — a PR that keeps conflicting needs a
# human's judgment on the underlying change, not more automated churn.
#
# Repo derived from the git remote; override with $1. Bot login via
# $BOT_LOGIN. Adapter (baseBranch) via $GATES_FILE, default .claude/gates.json
# — same fallback the two siblings use (the SELF run passes GATES_FILE
# explicitly). Invoke as `bash .claude/scripts/pr-rebase.sh` (pre-approve that
# exact command). Read-only w.r.t. PR state: detects only. The
# `claude-rebasing` label and the `<!-- claude-rebase-attempted:... -->`
# marker comment are written by the DRIVER this script's output goes on to
# dispatch, never by this script. Mutates ONLY via needs-human.sh's
# needs_human_flag on a genuine escalation — never rebases, never
# force-pushes, never posts a `claude-rebase-attempted` marker itself.
set -euo pipefail

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"
# Route EVERY gh call through the bot identity (see bot-gh.sh).
gh() { bash "$script_dir/bot-gh.sh" "$@"; }
repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
bot="${BOT_LOGIN:-robercano-ghbot}"

# needs_human_flag (issue #99 seam): sourced AFTER `gh` is defined above, so
# its calls run through the bot identity too. Guarded (not a bare source
# under `set -e`) so a fixture missing this sibling file degrades to "no
# escalation" rather than aborting the whole script.
if [ -f "$script_dir/needs-human.sh" ]; then . "$script_dir/needs-human.sh"; fi

gates_rel="${GATES_FILE:-.claude/gates.json}"
case "$gates_rel" in /*) gates="$gates_rel" ;; *) gates="$root/$gates_rel" ;; esac
base="$(node -e 'const g=require(process.argv[1]); console.log((g.merge&&g.merge.baseBranch)||"main")' "$gates" 2>/dev/null || echo main)"

# Feedback, comment-fix, AND ci-fix candidates OUTRANK rebase (precedence) —
# exclude their PR numbers up front so a PR that qualifies for any of them
# never shows up here at all.
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
ci_fix_prs="$(bash "$script_dir/pr-ci-fix.sh" "$repo" 2>/dev/null \
  | awk -F'\t' 'NF>=2 && $1 ~ /^[0-9]+$/ {print $1}' || true)"
is_ci_fix_candidate() {
  local n="$1"
  case $'\n'"$ci_fix_prs"$'\n' in
    *$'\n'"$n"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

gh pr list -R "$repo" --state open --base "$base" \
  --json number,headRefName,author,labels,mergeable,baseRefOid,headRefOid \
  --jq '.[] | select(.author.login=="'"$bot"'")' \
| while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue

    # One node call per PR: parse number/branch/head/base/labels and compute
    # the guard-skip + qualifies decisions together, so the rest of this loop
    # body only branches on plain shell values. Extracted via `cut -f`, NOT
    # `IFS=$'\t' read` — bash's `read` classifies tab as "IFS whitespace"
    # REGARDLESS of what IFS is set to, so it silently collapses consecutive
    # tabs (an empty field would swallow the NEXT field too); `cut` never
    # does that (same rationale pr-ci-fix.sh documents for its own parse).
    parsed="$(printf '%s' "$pr_json" | node -e '
      const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
      const labels = (p.labels || []).map((l) => l.name);
      const guardSkip = labels.includes("needs-human") || labels.includes("claude-rebasing");
      const qualifies = p.mergeable === "CONFLICTING";
      console.log([p.number, p.headRefName || "", p.headRefOid || "", p.baseRefOid || "", guardSkip ? 1 : 0, qualifies ? 1 : 0].join("\t"));
    ')"
    num="$(printf '%s' "$parsed" | cut -f1)"
    branch="$(printf '%s' "$parsed" | cut -f2)"
    head_sha="$(printf '%s' "$parsed" | cut -f3)"
    base_sha="$(printf '%s' "$parsed" | cut -f4)"
    guard_skip="$(printf '%s' "$parsed" | cut -f5)"
    qualifies="$(printf '%s' "$parsed" | cut -f6)"

    [ -z "${num:-}" ] && continue
    [ "$guard_skip" = "1" ] && continue
    [ "$qualifies" = "1" ] || continue      # not CONFLICTING (or GitHub still computing it) -> nothing to rebase
    is_feedback_candidate "$num" && continue
    is_comment_fix_candidate "$num" && continue
    is_ci_fix_candidate "$num" && continue

    # This PR's own bot comments (the only place `claude-rebase-attempted`
    # markers are ever posted) -- fed to node so the anti-livelock
    # next-attempt/escalate decision below is made once, in one process.
    marker_comments_json="$(gh api "repos/$repo/issues/$num/comments" \
      --jq '[.[]|select(.user.login=="'"$bot"'")|{body:.body}]' \
      2>/dev/null || echo '[]')"
    [ -z "$marker_comments_json" ] && marker_comments_json='[]'

    decision="$(node -e '
      const markers = JSON.parse(process.argv[1] || "[]");
      const baseSha = process.argv[2];
      const markerRe = /<!-- claude-rebase-attempted:([^:]+):(\d+) -->/g;
      let maxAttempt = 0;
      for (const c of markers) {
        let m;
        markerRe.lastIndex = 0;
        while ((m = markerRe.exec(c.body || "")) !== null) {
          const sha = m[1];
          const att = parseInt(m[2], 10);
          if (sha === baseSha && att > maxAttempt) maxAttempt = att;
        }
      }
      const nextAttempt = maxAttempt + 1;
      if (nextAttempt >= 3) {
        console.log("ESCALATE");
      } else {
        console.log("FIX\t" + nextAttempt);
      }
    ' "$marker_comments_json" "$base_sha" 2>/dev/null || true)"

    kind="$(printf '%s' "$decision" | cut -f1)"
    if [ "$kind" = "ESCALATE" ]; then
      if command -v needs_human_flag >/dev/null 2>&1; then
        needs_human_flag "pr:$num" "rebase-attempt-budget" "high" \
          "PR #$num: rebase attempts exhausted for base $base_sha" \
          "PR #$num became unmergeable (mergeable=CONFLICTING) against base commit $base_sha and has already had 2 automated rebase attempts against this SAME base commit (budget: 2 attempts/base commit). The loop will not retry it automatically -- labeling \`needs-human\`. Resolve the conflict by hand; a FUTURE sibling merge that moves base to a new commit will reset this budget automatically."
      fi
      continue
    fi
    [ "$kind" = "FIX" ] || continue
    attempt="$(printf '%s' "$decision" | cut -f2)"
    [ -z "$attempt" ] && continue

    printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$branch" "$head_sha" "$base_sha" "$attempt"
  done
