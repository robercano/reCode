#!/usr/bin/env bash
# merge-ready.sh — merge every open PR that the repo OWNER has approved and that
# is safe to merge, then delete the branch. The human Approve on GitHub is the
# ONLY gate; this script never approves anything — it just acts on approvals.
#
# A PR is merged iff ALL hold:
#   - base is the configured baseBranch (from gates.json, default main), not a draft
#   - latest review by the OWNER (the approver) is APPROVED
#   - that approval was submitted at/after the PR's last commit (so it covers the
#     current head — guards against new commits pushed after an approval, since a
#     free private repo has no branch protection to auto-dismiss stale approvals)
#   - mergeable (no conflicts)
#   - every CI check is green (no failing, none still pending)
# Anything else is SKIPPED with a reason. Output is JSON lines the cron summarizes.
#
# Repo is derived from the git remote (override with $1 = owner/repo). The approver
# defaults to the repo's owner login (override with $APPROVER — e.g. when the repo is
# org-owned and the human reviewer is not the org). Runs as the bot (GH_BOT_TOKEN, a
# write collaborator) so it works headless in the notification cron. Merging is not
# approving, so the bot may merge bot-authored PRs.
# Pre-approved in .claude/settings.json as `bash .claude/scripts/merge-ready.sh`.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ -f "$root/.env" ]; then set -a; . "$root/.env"; set +a; fi
: "${GH_BOT_TOKEN:?GH_BOT_TOKEN not set — add it to .env (see .env.example)}"
export GH_TOKEN="$GH_BOT_TOKEN"

repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
owner="${APPROVER:-$(gh repo view -R "$repo" --json owner -q .owner.login)}"   # approver whose APPROVED review authorizes a merge
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
  data="$(gh pr view "$n" -R "$repo" --json number,title,isDraft,baseRefName,mergeable,reviews,statusCheckRollup,commits)"
  verdict="$(printf '%s' "$data" | decide)"
  title="$(printf '%s' "$data" | node -e 'process.stdout.write((JSON.parse(require("fs").readFileSync(0,"utf8")).title)||"")')"
  if [ "$verdict" = "MERGE" ]; then
    if gh pr merge "$n" -R "$repo" --merge --delete-branch >/dev/null 2>&1; then
      echo "{\"pr\":$n,\"action\":\"merged\",\"title\":\"$title\"}"; merged=$((merged+1))
    else
      echo "{\"pr\":$n,\"action\":\"merge-failed\",\"title\":\"$title\"}"
    fi
  else
    echo "{\"pr\":$n,\"action\":\"skip\",\"reason\":\"${verdict#SKIP:}\",\"title\":\"$title\"}"; skipped=$((skipped+1))
  fi
done
echo "=== merge-ready: merged=$merged skipped=$skipped ==="
