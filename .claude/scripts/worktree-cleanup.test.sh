#!/usr/bin/env bash
# worktree-cleanup.test.sh — offline smoke test for worktree-cleanup.sh
# (issue #91). Builds a THROWAWAY temp git repo with real `git worktree add`
# worktrees (no real network, no gh, no real PR merge — scenario 6 uses a
# local bare repo as a stand-in "origin", never a real remote) and exercises
# the real worktree-cleanup.sh against it, asserting:
#   1. merged + clean + matching-name worktree -> removed + branch deleted
#   2. dirty worktree -> preserved (never touched)
#   3. unmerged branch -> preserved (never touched)
#   4. non-matching path (main worktree, and an arbitrary non-worker path)
#      -> never touched
#   5. no worktree at all -> skip, no crash
#   6. PRODUCTION ordering (issue #91 follow-up): merge landed on the
#      authoritative remote but local base is still stale -> removed + branch
#      deleted anyway (via origin ancestry, never a forced delete)
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/worktree-cleanup.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cleanup_src="$script_dir/worktree-cleanup.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/worktree-cleanup-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail=0
ok=0
check() {
  local desc="$1"; shift
  if "$@"; then
    ok=$((ok + 1))
    echo "ok - $desc"
  else
    fail=1
    echo "FAIL - $desc"
  fi
}

# Throwaway "consumer project" git repo: real commits + real `git worktree
# add`, with the REAL worktree-cleanup.sh + resolve-roots.sh copied into its
# .claude/scripts/ (mirrors loop-tick.test.sh's fixture pattern), so root
# derivation matches how the script resolves things in production.
repo="$work/repo"
mkdir -p "$repo"
git init -q -b main "$repo"
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
echo "seed" > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m "seed"

mkdir -p "$repo/.claude/scripts"
cp "$cleanup_src" "$repo/.claude/scripts/worktree-cleanup.sh"
cp "$resolve_roots_src" "$repo/.claude/scripts/resolve-roots.sh"
chmod +x "$repo/.claude/scripts/worktree-cleanup.sh"

run_cleanup() {
  # $1 = base branch, $@[2:] = branch names to attempt cleanup on.
  ( cd "$repo" && bash "$repo/.claude/scripts/worktree-cleanup.sh" "$@" )
}

worktree_present() {
  git -C "$repo" worktree list --porcelain | grep -qF "worktree $1"
}
branch_present() {
  git -C "$repo" branch --list "$1" | grep -q .
}

# ---------------------------------------------------------------------------
# Scenario 1: merged + clean + matching-name worktree -> removed + branch
# deleted.
# ---------------------------------------------------------------------------
git -C "$repo" checkout -q -b feat/issue-1-x
echo "one" > "$repo/file1.txt"
git -C "$repo" add file1.txt
git -C "$repo" commit -q -m "feat1"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff feat/issue-1-x -m "merge feat1"
wt1="$repo/.claude/worktrees/agent-test1"
git -C "$repo" worktree add -q "$wt1" feat/issue-1-x

out1="$(run_cleanup main feat/issue-1-x)"
check "scenario 1: emits a JSON line reporting the removal" bash -c 'printf "%s\n" "$1" | grep -q "worktree_removed"' _ "$out1"
check "scenario 1: worktree_removed path is correct" bash -c 'printf "%s\n" "$1" | grep -qF "\"worktree_removed\":\"$2\""' _ "$out1" "$wt1"
check "scenario 1: branch_deleted reports the branch name" bash -c 'printf "%s\n" "$1" | grep -qF "\"branch_deleted\":\"feat/issue-1-x\""' _ "$out1"
check "scenario 1: worktree is actually gone from git worktree list" bash -c '! git -C "$1" worktree list --porcelain | grep -qF "worktree $2"' _ "$repo" "$wt1"
check "scenario 1: worktree directory removed from disk" bash -c '[ ! -d "$1" ]' _ "$wt1"
check "scenario 1: local branch actually deleted" bash -c '! git -C "$1" branch --list feat/issue-1-x | grep -q .' _ "$repo"

# ---------------------------------------------------------------------------
# Scenario 2: dirty worktree -> preserved (never removed, branch never
# deleted), even though the branch IS fully merged.
# ---------------------------------------------------------------------------
git -C "$repo" checkout -q -b feat/issue-2-x
echo "two" > "$repo/file2.txt"
git -C "$repo" add file2.txt
git -C "$repo" commit -q -m "feat2"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff feat/issue-2-x -m "merge feat2"
wt2="$repo/.claude/worktrees/agent-test2"
git -C "$repo" worktree add -q "$wt2" feat/issue-2-x
echo "dirty" >> "$wt2/file2.txt"   # make the worktree dirty

out2="$(run_cleanup main feat/issue-2-x)"
check "scenario 2: emits a skip with reason worktree-dirty" bash -c 'printf "%s\n" "$1" | grep -qF "\"reason\":\"worktree-dirty\""' _ "$out2"
check "scenario 2: worktree still present (untouched)" worktree_present "$wt2"
check "scenario 2: worktree directory still on disk" [ -d "$wt2" ]
check "scenario 2: branch still present (untouched)" branch_present "feat/issue-2-x"

# ---------------------------------------------------------------------------
# Scenario 3: unmerged branch -> preserved (clean tree, matching path, but
# never merged into base).
# ---------------------------------------------------------------------------
git -C "$repo" checkout -q -b feat/issue-3-x
echo "three" > "$repo/file3.txt"
git -C "$repo" add file3.txt
git -C "$repo" commit -q -m "feat3 (never merged)"
git -C "$repo" checkout -q main
wt3="$repo/.claude/worktrees/agent-test3"
git -C "$repo" worktree add -q "$wt3" feat/issue-3-x

out3="$(run_cleanup main feat/issue-3-x)"
check "scenario 3: emits a skip with reason branch-not-merged" bash -c 'printf "%s\n" "$1" | grep -qF "\"reason\":\"branch-not-merged\""' _ "$out3"
check "scenario 3: worktree still present (untouched)" worktree_present "$wt3"
check "scenario 3: worktree directory still on disk" [ -d "$wt3" ]
check "scenario 3: branch still present (untouched)" branch_present "feat/issue-3-x"

# ---------------------------------------------------------------------------
# Scenario 4a: the base/main branch itself (worktree is the MAIN worktree,
# not a worker one) -> never touched, even though "main" trivially satisfies
# "merged into main" and the tree is clean.
# ---------------------------------------------------------------------------
out4a="$(run_cleanup main main)"
check "scenario 4a: emits a skip for the main worktree's own branch" bash -c 'printf "%s\n" "$1" | grep -qF "\"branch\":\"main\""' _ "$out4a"
check "scenario 4a: reason is not-a-worker-worktree-path" bash -c 'printf "%s\n" "$1" | grep -qF "\"reason\":\"not-a-worker-worktree-path\""' _ "$out4a"
check "scenario 4a: main worktree itself is untouched" bash -c '[ -d "$1" ] && git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1' _ "$repo"

# ---------------------------------------------------------------------------
# Scenario 4b: an arbitrary non-worker-naming worktree path (merged + clean,
# but not .claude/worktrees/agent-* or issue-*) -> never touched.
# ---------------------------------------------------------------------------
git -C "$repo" checkout -q -b feat/issue-4-x
echo "four" > "$repo/file4.txt"
git -C "$repo" add file4.txt
git -C "$repo" commit -q -m "feat4"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff feat/issue-4-x -m "merge feat4"
wt4="$repo/.claude/worktrees/some-random-dir"
git -C "$repo" worktree add -q "$wt4" feat/issue-4-x

out4b="$(run_cleanup main feat/issue-4-x)"
check "scenario 4b: emits a skip with reason not-a-worker-worktree-path" bash -c 'printf "%s\n" "$1" | grep -qF "\"reason\":\"not-a-worker-worktree-path\""' _ "$out4b"
check "scenario 4b: worktree still present (untouched)" worktree_present "$wt4"
check "scenario 4b: worktree directory still on disk" [ -d "$wt4" ]
check "scenario 4b: branch still present (untouched)" branch_present "feat/issue-4-x"

# ---------------------------------------------------------------------------
# Scenario 5: a branch with no worktree at all -> skip:no-worktree, no crash.
# ---------------------------------------------------------------------------
git -C "$repo" branch -q feat/issue-5-x-no-worktree
out5="$(run_cleanup main feat/issue-5-x-no-worktree)"
check "scenario 5: emits a skip with reason no-worktree" bash -c 'printf "%s\n" "$1" | grep -qF "\"reason\":\"no-worktree\""' _ "$out5"

# ---------------------------------------------------------------------------
# Scenario 6 (issue #91 follow-up, PRODUCTION ordering): merge-ready.sh calls
# worktree-cleanup.sh IMMEDIATELY after `gh pr merge` succeeds, which merges
# on the REMOTE only — local $base isn't fast-forwarded until a block that
# runs AFTER cleanup. Reproduce that ordering hermetically: a real bare repo
# stands in for "origin"; the merge is performed and pushed from a SEPARATE
# clone, so $repo's own local `main` ref is never touched by it. Cleanup must
# still detect the merge (via origin/$base ancestry) and remove the worktree
# + delete the branch — without ever advancing local `main` itself, and
# without ever needing `-D`/`--force`.
# ---------------------------------------------------------------------------
origin_bare="$work/origin.git"
git init -q --bare -b main "$origin_bare"
git -C "$repo" remote add origin "$origin_bare"
git -C "$repo" push -q origin main:main

git -C "$repo" checkout -q -b feat/issue-6-x
echo "six" > "$repo/file6.txt"
git -C "$repo" add file6.txt
git -C "$repo" commit -q -m "feat6"
git -C "$repo" checkout -q main
git -C "$repo" push -q origin feat/issue-6-x:feat/issue-6-x

# Perform + push the merge from a THIRD, independent clone (mimics GitHub
# doing the merge server-side) so local `main` in $repo is never advanced.
remote_work="$work/remote-work"
git clone -q "$origin_bare" "$remote_work"
git -C "$remote_work" config user.email "test@example.com"
git -C "$remote_work" config user.name "Test"
git -C "$remote_work" checkout -q main
git -C "$remote_work" merge -q --no-ff origin/feat/issue-6-x -m "merge feat6"
git -C "$remote_work" push -q origin main:main

local_main_before="$(git -C "$repo" rev-parse main)"

wt6="$repo/.claude/worktrees/agent-test6"
git -C "$repo" worktree add -q "$wt6" feat/issue-6-x

out6="$(run_cleanup main feat/issue-6-x)"
check "scenario 6 (sanity): local main is genuinely stale before cleanup runs" bash -c '[ "$1" = "$(git -C "$2" rev-parse main)" ]' _ "$local_main_before" "$repo"
check "scenario 6: emits a JSON line reporting the removal despite stale local main" bash -c 'printf "%s\n" "$1" | grep -q "worktree_removed"' _ "$out6"
check "scenario 6: branch_deleted reports the branch name" bash -c 'printf "%s\n" "$1" | grep -qF "\"branch_deleted\":\"feat/issue-6-x\""' _ "$out6"
check "scenario 6: worktree is actually gone from git worktree list" bash -c '! git -C "$1" worktree list --porcelain | grep -qF "worktree $2"' _ "$repo" "$wt6"
check "scenario 6: worktree directory removed from disk" bash -c '[ ! -d "$1" ]' _ "$wt6"
check "scenario 6: local branch actually deleted" bash -c '! git -C "$1" branch --list feat/issue-6-x | grep -q .' _ "$repo"
check "scenario 6: local main ref itself was never advanced by cleanup" bash -c '[ "$1" = "$(git -C "$2" rev-parse main)" ]' _ "$local_main_before" "$repo"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "worktree-cleanup.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "worktree-cleanup.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
