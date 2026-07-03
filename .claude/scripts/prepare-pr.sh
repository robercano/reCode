#!/usr/bin/env bash
# prepare-pr.sh <pr-number>
# Prepare a ready-to-run local checkout of an OPEN pull request so a human can
# manually test it, WITHOUT touching the main working tree. Idempotent.
#
#   1. Resolves the PR's head branch (via bot-gh.sh) and fetches it.
#   2. Creates or refreshes a DETACHED git worktree at <worktreeDir>/pr-<n>.
#      (Detached, not a named branch, so it never clashes with the same branch
#      already checked out in an agent worktree — git forbids that.)
#   3. Runs humanTest.prepare inside the worktree (install/build) if configured.
#   4. Prints the worktree path + the humanTest.launch command to run.
#
# Config (.claude/gates.json → "humanTest"):
#   prepare       shell cmd run IN the worktree to make it runnable (optional)
#   launch        shell cmd to start the app for manual testing (printed, optional)
#   worktreeDir   parent dir for PR worktrees (optional, default ".worktrees")
#
# gh reads go through bot-gh.sh for consistent auth; git ops stay local.
set -uo pipefail

pr="${1:?usage: prepare-pr.sh <pr-number>}"
case "$pr" in
  ''|*[!0-9]*) echo "prepare-pr: PR number must be numeric (got '$pr')" >&2; exit 2 ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/../.." && pwd)"
cd "$root"

gates="$root/.claude/gates.json"
read_gate() {
  node -e "try{const g=require('$gates');process.stdout.write((g.humanTest&&g.humanTest['$1'])||'')}catch(e){process.stdout.write('')}" 2>/dev/null
}
prepare_cmd="$(read_gate prepare)"
launch_cmd="$(read_gate launch)"
wt_parent="$(read_gate worktreeDir)"; wt_parent="${wt_parent:-.worktrees}"

# Resolve the PR's head branch (gh through the bot wrapper for consistent auth).
branch="$("$script_dir/bot-gh.sh" pr view "$pr" --json headRefName -q .headRefName 2>/dev/null)"
if [ -z "$branch" ]; then
  echo "prepare-pr: could not resolve head branch for PR #$pr (is it open? is the bot token set?)" >&2
  exit 1
fi
echo "▶ PR #$pr → branch '$branch'"

git fetch origin "$branch" || { echo "prepare-pr: git fetch origin $branch failed" >&2; exit 1; }
sha="$(git rev-parse FETCH_HEAD)"

wt="$root/$wt_parent/pr-$pr"
if git worktree list --porcelain | grep -qxF "worktree $wt"; then
  echo "▶ refreshing existing worktree $wt → $sha"
  git -C "$wt" checkout -q --detach "$sha" || { echo "prepare-pr: could not update worktree" >&2; exit 1; }
else
  echo "▶ creating worktree $wt (detached at $sha)"
  mkdir -p "$root/$wt_parent"
  git worktree add -f --detach "$wt" "$sha" || { echo "prepare-pr: git worktree add failed" >&2; exit 1; }
fi

if [ -n "$prepare_cmd" ]; then
  echo "▶ prepare: $prepare_cmd"
  ( cd "$wt" && eval "$prepare_cmd" ) || { echo "prepare-pr: humanTest.prepare failed" >&2; exit 1; }
else
  echo "▶ humanTest.prepare not configured in gates.json — skipping deps/build"
fi

echo ""
echo "✅ PR #$pr is ready to test. In your terminal:"
echo "     cd $wt"
if [ -n "$launch_cmd" ]; then
  echo "     $launch_cmd"
else
  echo "     (no humanTest.launch configured — start the app manually)"
fi
echo ""
echo "When done, tear it down with:  git worktree remove $wt"
