#!/usr/bin/env bash
# merge-ready.sh — merge every open PR the repo OWNER has approved and that is
# safe to merge, then delete the branch. The human Approve on GitHub is the ONLY
# gate; this script never approves anything — it just acts on approvals. Pair it
# with notify-poll.sh in a cron to close the loop: review → approve → auto-merge.
#
# A PR is merged iff ALL hold:
#   - base is the configured baseBranch (gates.json merge.baseBranch), not a draft
#   - latest review by the OWNER is APPROVED
#   - that approval was submitted at/after the PR's last commit (so it covers the
#     current head) — guards against commits pushed after an approval. A private
#     repo on a free plan has no branch protection to auto-dismiss stale
#     approvals, so we enforce "approval covers head" here instead.
#   - mergeable (no conflicts)
#   - every CI check is green (none failing, none still pending)
# Anything else is SKIPPED with a reason. Output is JSON lines a cron summarizes.
#
# Auth: ALL `gh` calls (listing, viewing, and the merge itself) run as the bot via
# bot-gh.sh — the bot is a write collaborator, so it can merge. The merge GATE is
# still the human OWNER's APPROVED review (detected below); running the merge as the
# bot does not change who authorized it. Repo is derived from the git remote;
# override with $1 (owner/repo).
# The approver defaults to the repo owner; override with $MERGE_APPROVER.
# Pre-approve `bash .claude/scripts/merge-ready.sh` in .claude/settings.json.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"
# Route EVERY gh call (list/view/merge) through the bot identity (see bot-gh.sh).
gh() { bash "$script_dir/bot-gh.sh" "$@"; }
repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
owner="${MERGE_APPROVER:-${repo%%/*}}"   # the approver whose APPROVED review authorizes a merge
gates="$root/.claude/gates.json"
base="$(node -e "try{const g=require('$gates');process.stdout.write((g.merge&&g.merge.baseBranch)||'main')}catch(e){process.stdout.write('main')}")"

# Decide MERGE / SKIP:<reason> for one PR's JSON (read on stdin).
decide() {
  node -e '
    const base = process.argv[1], owner = process.argv[2];
    function verdict(p) {
      if (p.isDraft) return "SKIP:draft";
      if (p.baseRefName !== base) return "SKIP:base-is-"+p.baseRefName;
      if (p.mergeable !== "MERGEABLE") return "SKIP:mergeable="+p.mergeable;

      // CI: every check green; none failing or pending.
      for (const c of (p.statusCheckRollup||[])) {
        if (c.conclusion !== undefined && c.conclusion !== null && c.conclusion !== "") {   // CheckRun
          if (["FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","STALE"].includes(c.conclusion))
            return "SKIP:check-failed:"+(c.name||"");
          if (c.status && c.status !== "COMPLETED") return "SKIP:check-pending:"+(c.name||"");
        } else if (c.state) {                                                                // legacy StatusContext
          if (["FAILURE","ERROR"].includes(c.state)) return "SKIP:status-failed:"+(c.context||"");
          if (c.state === "PENDING") return "SKIP:status-pending:"+(c.context||"");
        }
      }

      // Latest review by the owner must be APPROVED and cover the current head.
      const mine = (p.reviews||[]).filter(r => r.author && r.author.login === owner && r.submittedAt)
                                  .sort((a,b) => a.submittedAt.localeCompare(b.submittedAt));
      const last = mine[mine.length-1];
      if (!last) return "SKIP:no-owner-review";
      if (last.state !== "APPROVED") return "SKIP:owner-review="+last.state;
      const commits = p.commits||[];
      const head = commits.length ? commits[commits.length-1].committedDate : null;
      if (head && last.submittedAt < head) return "SKIP:approval-stale (re-approve current head)";
      return "MERGE";
    }
    let p; try { p = JSON.parse(require("fs").readFileSync(0,"utf8")); } catch(e){ console.log("SKIP:bad-json"); process.exit(0); }
    console.log(verdict(p));
  ' "$base" "$owner"
}

merged=0; skipped=0
for n in $(gh pr list -R "$repo" --base "$base" --state open --json number -q '.[].number'); do
  data="$(gh pr view "$n" -R "$repo" --json number,title,isDraft,baseRefName,headRefName,mergeable,reviews,statusCheckRollup,commits)"
  verdict="$(printf '%s' "$data" | decide)"
  title="$(printf '%s' "$data" | node -e 'process.stdout.write((JSON.parse(require("fs").readFileSync(0,"utf8")).title)||"")')"
  head_branch="$(printf '%s' "$data" | node -e 'process.stdout.write((JSON.parse(require("fs").readFileSync(0,"utf8")).headRefName)||"")')"
  if [ "$verdict" = "MERGE" ]; then
    if gh pr merge "$n" -R "$repo" --merge --delete-branch >/dev/null 2>&1; then
      echo "{\"pr\":$n,\"action\":\"merged\",\"title\":\"$title\"}"; merged=$((merged+1))
      # Auto-cleanup (issue #91): the merged branch's local worktree + local
      # branch are now stale. worktree-cleanup.sh applies its OWN safety
      # rails (worker-path naming, clean tree, fully merged into $base) and
      # NEVER forces — a "skip" line from it is expected and fine, just
      # tag it with the PR number and pass it through.
      if [ -n "$head_branch" ]; then
        while IFS= read -r cleanup_line; do
          [ -z "$cleanup_line" ] && continue
          printf '%s\n' "$cleanup_line" | node -e '
            const pr = process.argv[1];
            const obj = JSON.parse(require("fs").readFileSync(0,"utf8"));
            obj.pr = Number(pr);
            console.log(JSON.stringify(obj));
          ' "$n"
        done < <(bash "$script_dir/worktree-cleanup.sh" "$base" "$head_branch")
      fi
    else
      echo "{\"pr\":$n,\"action\":\"merge-failed\",\"title\":\"$title\"}"
    fi
  else
    echo "{\"pr\":$n,\"action\":\"skip\",\"reason\":\"${verdict#SKIP:}\",\"title\":\"$title\"}"; skipped=$((skipped+1))
  fi
done

# Post-merge: fast-forward the LOCAL checkout to the freshly-merged base so the
# owner's terminal/IDE shows the latest code without a manual pull. Strictly safe:
# acts ONLY when the checkout is on the base branch with a clean tree, and only
# fast-forwards (never a merge commit, never a branch switch, never clobbers
# uncommitted work). Untracked sandbox device-node masks don't count as changes.
# Any obstacle -> skip with a reason; never force. See docs/HARDENING.md.
if [ "$merged" -gt 0 ]; then
  wt="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  cur="$(git -C "${wt:-.}" symbolic-ref --quiet --short HEAD 2>/dev/null || echo DETACHED)"
  if [ -z "$wt" ]; then
    :
  elif [ "$cur" != "$base" ]; then
    echo "{\"local_sync\":\"skip\",\"reason\":\"checkout on '$cur', not '$base'\"}"
  elif ! git -C "$wt" diff --quiet || ! git -C "$wt" diff --cached --quiet; then
    echo "{\"local_sync\":\"skip\",\"reason\":\"working tree has tracked changes\"}"
  elif git -C "$wt" fetch --quiet origin "$base" 2>/dev/null \
       && git -C "$wt" merge --ff-only -q "origin/$base" 2>/dev/null; then
    echo "{\"local_sync\":\"ok\",\"branch\":\"$base\",\"head\":\"$(git -C "$wt" rev-parse --short HEAD)\"}"
  else
    echo "{\"local_sync\":\"skip\",\"reason\":\"fetch or fast-forward failed (diverged/offline?)\"}"
  fi
fi
echo "=== merge-ready: merged=$merged skipped=$skipped ==="
