#!/usr/bin/env bash
# pr-comment-fix.sh — print open, bot-authored PRs that have an UNRESOLVED
# inline review-comment thread from the owner (or an allowlisted bot
# commenter) that hasn't already been addressed, so the loop can dispatch an
# implementer to push a fix onto the SAME branch. This is capability #2 of
# issue #96 (review-comment convergence); capability #1 (CI-failure fixing)
# is pr-ci-fix.sh, capability #3 (rebase-after-sibling-merge) is a follow-up.
# Prints one TSV line per PR needing a comment fix:
#   <number>\t<branch>\t<thread_id>:<next_attempt>[,<thread_id>:<next_attempt>...]\t<head_sha>
#
# A PR is listed when ALL hold:
#   - authored by the bot ($BOT_LOGIN, default robercano-ghbot), open, base is
#     the adapter's merge.baseBranch ($GATES_FILE, default .claude/gates.json
#     — same node-read as loop-census.sh/pr-ci-fix.sh);
#   - it is NOT ALSO a pr-feedback.sh candidate. VERDICT PRECEDENCE (issue
#     #96): feedback > comment-fix > ci-fix > advance — owner
#     CHANGES_REQUESTED always outranks a comment-fix dispatch, so a PR that
#     is both a feedback candidate AND has unresolved review threads is left
#     entirely to pr-feedback.sh here (excluded, not merely deprioritized),
#     and loop-tick.sh additionally enforces the same precedence at the
#     verdict level;
#   - not labeled `needs-human` (the per-thread attempt budget below already
#     gave up, or some OTHER escalation gave up, on this PR) and not labeled
#     `claude-comment-fixing` (an in-flight guard, mirroring pr-ci-fix.sh's
#     `claude-ci-fixing`, so overlapping ticks don't double-dispatch the SAME
#     PR while a fix is already being worked);
#   - it has at least one review thread (GraphQL `reviewThreads`) that is
#     UNRESOLVED, has at least one comment from the repo OWNER (derived from
#     the `owner/repo` slug, overridable via $OWNER_LOGIN for tests) or a
#     bot commenter on the adapter's `commentFix.botAllowlist` (gates.json;
#     empty array = disabled — only the owner qualifies by default; see
#     gates.json's `_commentFix_note`), and hasn't already been addressed for
#     its CURRENT state.
#
# ALREADY-ADDRESSED CURSOR + PER-THREAD ATTEMPT NUMBER (both derived from the
# marker itself, no extra state file — mirrors pr-ci-fix.sh's head_sha-keyed
# marker, and pr-feedback.sh's timestamp-cursor discipline): the implementer
# that fixes a thread posts a bot comment containing
# `<!-- claude-comment-addressed:<thread_id>:<attempt> -->` after pushing and
# resolving the threads it actually addressed. For a given thread:
#   - no marker at all -> next attempt is 1, thread is a fresh candidate;
#   - a marker exists and its comment's created_at is >= the thread's own
#     newest comment's createdAt -> nothing has happened on the thread since
#     the fix was posted (still unresolved because the reviewer hasn't
#     re-reviewed yet, or GitHub's resolved state lags) -> skip this tick;
#   - a marker exists but the thread has a NEWER comment since -> the thread
#     REOPENED after a completed fix attempt -> next attempt is
#     marker-attempt + 1.
#
# ANTI-LIVELOCK (bounded per-thread retries): once a thread has reopened
# after 2 completed fix attempts (i.e. its next attempt would be 3), this
# script escalates instead of emitting another candidate for it — applies the
# `needs-human` label to the PR via needs-human.sh's needs_human_flag (same
# seam pr-feedback.sh's own inline escalation uses), and drops that thread
# from this PR's candidate list. needs_human_flag's own "already labeled"
# check makes repeated escalation ticks a no-op (no repeat comment spam), and
# once the label lands, the very next tick's guard-label check above excludes
# the WHOLE PR from further comment-fix automation until a human clears it —
# by design: a thread that keeps reopening after fixes needs a human's
# judgment, not more automated churn. Other STILL-fixable threads on the same
# PR are not excluded from the CURRENT tick's output (only from the NEXT
# tick, once the label has landed) — one last dispatch can still land their
# fixes before automation halts on this PR.
#
# Repo derived from the git remote; override with $1. Bot login via
# $BOT_LOGIN. Owner login via $OWNER_LOGIN (default: the part of `owner/repo`
# before the slash). Adapter (baseBranch, commentFix.botAllowlist) via
# $GATES_FILE, default .claude/gates.json. Invoke as
# `bash .claude/scripts/pr-comment-fix.sh` (pre-approve that exact command).
# Mutates ONLY via needs-human.sh's needs_human_flag on a genuine escalation
# (label + one-time comment + throttled notify) — never resolves a thread,
# never posts a `claude-comment-addressed` marker itself; those are written
# by the driver this script's output goes on to dispatch.
set -euo pipefail

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"
# Route EVERY gh call through the bot identity (see bot-gh.sh).
gh() { bash "$script_dir/bot-gh.sh" "$@"; }
repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
bot="${BOT_LOGIN:-robercano-ghbot}"
owner_login="${OWNER_LOGIN:-${repo%%/*}}"
repo_name="${repo#*/}"
repo_owner="${repo%%/*}"

# needs_human_flag (issue #99 seam): sourced AFTER `gh` is defined above, so
# its calls run through the bot identity too. Guarded (not a bare source
# under `set -e`) so a fixture missing this sibling file degrades to "no
# escalation" rather than aborting the whole script.
if [ -f "$script_dir/needs-human.sh" ]; then . "$script_dir/needs-human.sh"; fi

gates_rel="${GATES_FILE:-.claude/gates.json}"
case "$gates_rel" in /*) gates="$gates_rel" ;; *) gates="$root/$gates_rel" ;; esac
base="$(node -e 'const g=require(process.argv[1]); console.log((g.merge&&g.merge.baseBranch)||"main")' "$gates" 2>/dev/null || echo main)"
allowlist_json="$(node -e '
  const g = require(process.argv[1]);
  const list = (g.commentFix && Array.isArray(g.commentFix.botAllowlist)) ? g.commentFix.botAllowlist : [];
  console.log(JSON.stringify(list));
' "$gates" 2>/dev/null || echo '[]')"

# Feedback candidates OUTRANK comment-fix (precedence) — exclude their PR
# numbers up front so a PR that qualifies for both never shows up here.
feedback_prs="$(bash "$script_dir/pr-feedback.sh" "$repo" 2>/dev/null \
  | awk -F'\t' 'NF>=2 && $1 ~ /^[0-9]+$/ {print $1}' || true)"
is_feedback_candidate() {
  local n="$1"
  case $'\n'"$feedback_prs"$'\n' in
    *$'\n'"$n"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

gh pr list -R "$repo" --state open --base "$base" \
  --json number,headRefName,author,labels,headRefOid \
  --jq '.[] | select(.author.login=="'"$bot"'")' \
| while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue

    parsed="$(printf '%s' "$pr_json" | node -e '
      const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
      const labels = (p.labels || []).map((l) => l.name);
      const guardSkip = labels.includes("needs-human") || labels.includes("claude-comment-fixing");
      console.log([p.number, p.headRefName || "", p.headRefOid || "", guardSkip ? 1 : 0].join("\t"));
    ')"
    num="$(printf '%s' "$parsed" | cut -f1)"
    branch="$(printf '%s' "$parsed" | cut -f2)"
    head_sha="$(printf '%s' "$parsed" | cut -f3)"
    guard_skip="$(printf '%s' "$parsed" | cut -f4)"

    [ -z "${num:-}" ] && continue
    [ "$guard_skip" = "1" ] && continue
    is_feedback_candidate "$num" && continue

    # Unresolved review threads for this PR, GraphQL (REST has no
    # "resolved" concept for review-comment threads). Each node carries the
    # thread id, isResolved, and every comment's author login + createdAt —
    # enough to decide qualification/already-addressed/attempt-number below
    # in a single node pass, no second network round-trip per thread.
    threads_json="$(gh api graphql -f query='
      query($owner:String!, $name:String!, $number:Int!) {
        repository(owner:$owner, name:$name) {
          pullRequest(number:$number) {
            reviewThreads(first:100) {
              nodes {
                id
                isResolved
                comments(first:100) { nodes { author { login } createdAt } }
              }
            }
          }
        }
      }' -f owner="$repo_owner" -f name="$repo_name" -F number="$num" \
      --jq '.data.repository.pullRequest.reviewThreads.nodes' 2>/dev/null || echo '[]')"
    [ -z "$threads_json" ] && threads_json='[]'
    [ "$threads_json" = "null" ] && threads_json='[]'

    # This PR's own bot comments (the only place `claude-comment-addressed`
    # markers are ever posted) -- fed to node alongside the threads so the
    # already-addressed/attempt-number decision below is made once, in one
    # process, per PR.
    marker_comments_json="$(gh api "repos/$repo/issues/$num/comments" \
      --jq '[.[]|select(.user.login=="'"$bot"'")|{body:.body,created_at:.created_at}]' \
      2>/dev/null || echo '[]')"
    [ -z "$marker_comments_json" ] && marker_comments_json='[]'

    decisions="$(node -e '
      const threads = JSON.parse(process.argv[1] || "[]");
      const markers = JSON.parse(process.argv[2] || "[]");
      const owner = process.argv[3];
      const allowlist = new Set(JSON.parse(process.argv[4] || "[]"));

      const markerRe = /<!-- claude-comment-addressed:([^:]+):(\d+) -->/g;
      const markerMap = {};
      for (const c of markers) {
        let m;
        markerRe.lastIndex = 0;
        while ((m = markerRe.exec(c.body || "")) !== null) {
          const tid = m[1], att = parseInt(m[2], 10);
          const cur = markerMap[tid];
          if (!cur || att > cur.attempt || (att === cur.attempt && c.created_at > cur.created_at)) {
            markerMap[tid] = { attempt: att, created_at: c.created_at };
          }
        }
      }

      for (const t of threads) {
        if (t.isResolved) continue;
        const comments = (t.comments && t.comments.nodes) || [];
        if (comments.length === 0) continue;
        const qualifies = comments.some((c) => {
          const login = c.author && c.author.login;
          return login === owner || allowlist.has(login);
        });
        if (!qualifies) continue;
        let lastActivity = comments[0].createdAt;
        for (const c of comments) { if (c.createdAt > lastActivity) lastActivity = c.createdAt; }
        const marker = markerMap[t.id];
        const currentAttempt = marker ? marker.attempt : 0;
        if (marker && marker.created_at >= lastActivity) continue; // nothing new since the fix
        if (currentAttempt >= 2) {
          console.log("ESCALATE\t" + t.id);
        } else {
          console.log("FIX\t" + t.id + "\t" + (currentAttempt + 1));
        }
      }
    ' "$threads_json" "$marker_comments_json" "$owner_login" "$allowlist_json" 2>/dev/null || true)"

    [ -z "$decisions" ] && continue

    fix_pairs=""
    while IFS=$'\t' read -r kind tid attempt; do
      [ -z "$kind" ] && continue
      if [ "$kind" = "ESCALATE" ]; then
        if command -v needs_human_flag >/dev/null 2>&1; then
          needs_human_flag "pr:$num" "comment-fix-thread-budget" "high" \
            "PR #$num: a review thread reopened after 2 fix attempts" \
            "Review thread $tid on PR #$num has reopened after 2 automated fix attempts (budget: 2 attempts/thread). The loop will not retry it automatically -- labeling \`needs-human\`. Address it by hand, then either resolve the thread or leave a fresh comment once it's fixed."
        fi
      elif [ "$kind" = "FIX" ]; then
        [ -n "$fix_pairs" ] && fix_pairs+=","
        fix_pairs+="${tid}:${attempt}"
      fi
    done <<< "$decisions"

    [ -z "$fix_pairs" ] && continue
    printf '%s\t%s\t%s\t%s\n' "$num" "$branch" "$fix_pairs" "$head_sha"
  done
