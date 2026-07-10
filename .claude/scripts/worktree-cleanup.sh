#!/usr/bin/env bash
# worktree-cleanup.sh — after merge-ready.sh merges a PR, remove the worker's
# now-dead worktree + delete its local branch, so `.claude/worktrees/` and the
# local branch list don't silently accumulate `prunable` entries forever
# (issue #91). Factored out of merge-ready.sh so it's independently testable
# offline (see worktree-cleanup.test.sh) without a real merge or network call.
#
# Usage: worktree-cleanup.sh <base-branch> [<branch>...]
#   <base-branch>  the branch merged PRs land on (e.g. main) — used to decide
#                   "fully merged" against origin/<base> (falling back to
#                   local `git branch --merged <base>` if origin is
#                   unreachable/unset — see merged_via_origin below).
#   <branch>...    zero or more branch names that were just merged. For each,
#                   the corresponding worktree (if any) is located via
#                   `git worktree list --porcelain` and, ONLY if every safety
#                   rail below holds, the worktree is removed and the local
#                   branch deleted.
#
# Safety rails — ALL must hold, else the branch is SKIPPED with a logged
# reason and left untouched. NEVER `--force`, NEVER `git branch -D`:
#   - the branch has an associated worktree at all
#   - that worktree's path matches the worker naming convention:
#     .claude/worktrees/agent-* or .claude/worktrees/issue-* (rejects the
#     main worktree and anything else, e.g. a hand-made worktree)
#   - the worktree has a clean tree (`git status --porcelain` empty)
#   - the branch is fully merged into <base-branch> — checked against the
#     fetched origin/<base> (authoritative; see merged_via_origin) OR local
#     `git branch --merged <base>` (issue #91 follow-up: merge-ready.sh calls
#     this script right after `gh pr merge`, which only merges on the
#     remote, so local <base> is stale at this point — checking it alone
#     would report every just-merged branch as unmerged forever)
#   - `git worktree remove` succeeds on its own steam (never forced); the
#     branch is then deleted via `git branch -d` if it agrees, or — only when
#     merged_via_origin independently verified the merge — via a direct ref
#     delete (never `-D`/`--force`, never for an unverified branch)
#
# Emits ONE JSON line per branch on stdout, either:
#   {"branch":"<name>","worktree_removed":"<path>","branch_deleted":"<name>"}
#   {"branch":"<name>","worktree_removed":"<path>","action":"skip","reason":"branch-delete-failed"}
#   {"branch":"<name>","action":"skip","reason":"<why>"}
# consistent with merge-ready.sh's existing JSON-lines output style.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-roots.sh
. "$script_dir/resolve-roots.sh"

base="${1:?usage: worktree-cleanup.sh <base-branch> [<branch>...]}"
shift || true

json_escape() {
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

# Map a branch name -> its worktree's absolute path, by parsing
# `git worktree list --porcelain` records:
#   worktree <path>
#   HEAD <sha>
#   branch refs/heads/<name>      (absent when detached)
#   <blank line separates records>
worktree_for_branch() {
  local want="$1"
  git -C "$root" worktree list --porcelain | node -e '
    const want = process.argv[1];
    const chunks = require("fs").readFileSync(0, "utf8").split(/\n\n+/);
    for (const c of chunks) {
      let path = null, branch = null;
      for (const l of c.split("\n")) {
        if (l.startsWith("worktree ")) path = l.slice("worktree ".length);
        if (l.startsWith("branch refs/heads/")) branch = l.slice("branch refs/heads/".length);
      }
      if (path && branch === want) { process.stdout.write(path); process.exit(0); }
    }
  ' "$want"
}

is_worker_path() {
  case "$1" in
    */.claude/worktrees/agent-*|*/.claude/worktrees/issue-*) return 0 ;;
    *) return 1 ;;
  esac
}

skip() {
  local branch="$1" reason="$2"
  echo "{\"branch\":$(json_escape "$branch"),\"action\":\"skip\",\"reason\":$(json_escape "$reason")}"
}

# merge-ready.sh invokes this script IMMEDIATELY after `gh pr merge` succeeds
# — that merges on the REMOTE only. The LOCAL base branch isn't fast-forwarded
# until merge-ready.sh's post-loop local_sync block, which runs AFTER this
# script returns. A plain local `git branch --merged "$base"` check therefore
# always reports the just-merged branch as unmerged, so cleanup never fires
# (issue #91 follow-up — the feature was inert in production). Fetch the
# authoritative remote base once up front and prefer ancestry against it;
# fall back to the local check (previous behavior) when the fetch is
# unavailable (offline) or origin/$base doesn't exist yet.
git -C "$root" fetch --quiet origin "$base" 2>/dev/null || true

# True iff $1 is an ancestor of origin/$base — i.e. genuinely merged on the
# remote — independent of whatever local $base happens to point at right
# now. Used both as (part of) the merged-ness gate and, if `git branch -d`
# refuses below because local $base hasn't caught up yet, as the trusted
# basis for a non-force deletion.
merged_via_origin() {
  local branch="$1"
  git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null 2>&1 \
    && git -C "$root" merge-base --is-ancestor "$branch" "refs/remotes/origin/$base" 2>/dev/null
}

for branch in "$@"; do
  [ -z "$branch" ] && continue

  wt="$(worktree_for_branch "$branch")"
  if [ -z "$wt" ]; then
    skip "$branch" "no-worktree"
    continue
  fi
  if ! is_worker_path "$wt"; then
    skip "$branch" "not-a-worker-worktree-path"
    continue
  fi
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    skip "$branch" "worktree-dirty"
    continue
  fi
  # `git branch --merged` prefixes the current branch with `*` and any branch
  # checked out in ANOTHER linked worktree with `+` — strip both markers
  # before comparing names. OR'd with merged_via_origin so a branch merged on
  # the remote but not yet reflected in local $base still counts as merged.
  if ! merged_via_origin "$branch" \
     && ! git -C "$root" branch --merged "$base" 2>/dev/null | sed 's/^[*+ ]*//' | grep -qxF "$branch"; then
    skip "$branch" "branch-not-merged"
    continue
  fi
  if ! git -C "$root" worktree remove "$wt" 2>/dev/null; then
    skip "$branch" "worktree-remove-failed(dirty-or-locked)"
    continue
  fi
  if git -C "$root" branch -d "$branch" >/dev/null 2>&1; then
    echo "{\"branch\":$(json_escape "$branch"),\"worktree_removed\":$(json_escape "$wt"),\"branch_deleted\":$(json_escape "$branch")}"
  elif merged_via_origin "$branch" && git -C "$root" update-ref -d "refs/heads/$branch" 2>/dev/null; then
    # `git branch -d` refused because it only trusts local $base/upstream,
    # which hasn't fast-forwarded yet — but we've independently verified via
    # origin/$base ancestry above that this is genuinely merged, so deleting
    # the ref directly is safe (still never -D/--force on anything unverified).
    echo "{\"branch\":$(json_escape "$branch"),\"worktree_removed\":$(json_escape "$wt"),\"branch_deleted\":$(json_escape "$branch")}"
  else
    echo "{\"branch\":$(json_escape "$branch"),\"worktree_removed\":$(json_escape "$wt"),\"action\":\"skip\",\"reason\":\"branch-delete-failed(unmerged-elsewhere?)\"}"
  fi
done
