#!/usr/bin/env bash
# worktree.test.sh — offline smoke test for worktree.sh's .env bootstrap.
# Builds a THROWAWAY temp git repo with real `git worktree add` worktrees and
# exercises the real worktree.sh against it, asserting:
#   1. setup inside a fresh worktree -> .env symlinked from the main checkout
#      (and the link resolves to the main checkout's content)
#   2. setup with a worktree-local .env already present -> preserved, not
#      replaced (worktree-local wins)
#   3. setup in the MAIN checkout -> no self-link, .env untouched
#   4. setup with no .env in the main checkout -> no link, no crash
#   5. teardown -> never creates a link
#   6. the linked .env still resolves as gitignored inside the worktree
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/worktree.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
worktree_src="$script_dir/worktree.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/worktree-test.XXXXXX")"
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
# add`, with the REAL worktree.sh + resolve-roots.sh copied into its
# .claude/scripts/ (mirrors worktree-cleanup.test.sh's fixture pattern), so
# root derivation matches how the script resolves things in production.
repo="$work/repo"
mkdir -p "$repo/.claude/scripts"
git init -q -b main "$repo"
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
printf '.env\n.env.*\n' > "$repo/.gitignore"
cp "$worktree_src" "$repo/.claude/scripts/worktree.sh"
cp "$resolve_roots_src" "$repo/.claude/scripts/resolve-roots.sh"
git -C "$repo" add .gitignore .claude/scripts/worktree.sh .claude/scripts/resolve-roots.sh
git -C "$repo" commit -q -m "seed"
echo "SECRET=main-checkout" > "$repo/.env"

run_setup() {
  # $1 = directory to run from (the worktree the "implementer" stands in).
  ( cd "$1" && bash .claude/scripts/worktree.sh setup >/dev/null 2>&1 )
}

# ---------------------------------------------------------------------------
# Scenario 1: fresh worktree -> .env symlinked from the main checkout.
# ---------------------------------------------------------------------------
wt1="$repo/.claude/worktrees/agent-one"
git -C "$repo" worktree add -q -b feat/one "$wt1" main
run_setup "$wt1"
check "s1: .env exists in fresh worktree after setup" test -e "$wt1/.env"
check "s1: .env is a symlink" test -L "$wt1/.env"
check "s1: .env resolves to main checkout content" grep -q "SECRET=main-checkout" "$wt1/.env"

# ---------------------------------------------------------------------------
# Scenario 2: worktree-local .env already present -> preserved.
# ---------------------------------------------------------------------------
wt2="$repo/.claude/worktrees/agent-two"
git -C "$repo" worktree add -q -b feat/two "$wt2" main
echo "SECRET=worktree-local" > "$wt2/.env"
run_setup "$wt2"
check "s2: pre-existing worktree .env preserved" grep -q "SECRET=worktree-local" "$wt2/.env"
check "s2: pre-existing worktree .env not turned into a link" test ! -L "$wt2/.env"

# ---------------------------------------------------------------------------
# Scenario 3: setup in the MAIN checkout -> no self-link, file untouched.
# ---------------------------------------------------------------------------
run_setup "$repo"
check "s3: main checkout .env untouched" grep -q "SECRET=main-checkout" "$repo/.env"
check "s3: main checkout .env is not a symlink" test ! -L "$repo/.env"

# ---------------------------------------------------------------------------
# Scenario 4: no .env in the main checkout -> no link, clean exit.
# ---------------------------------------------------------------------------
rm "$repo/.env"
wt4="$repo/.claude/worktrees/agent-four"
git -C "$repo" worktree add -q -b feat/four "$wt4" main
run_setup "$wt4"
rc=$?
check "s4: setup exits 0 without a main .env" test "$rc" -eq 0
check "s4: no .env materialized in worktree" test ! -e "$wt4/.env"
echo "SECRET=main-checkout" > "$repo/.env"

# ---------------------------------------------------------------------------
# Scenario 5: teardown never creates a link.
# ---------------------------------------------------------------------------
wt5="$repo/.claude/worktrees/agent-five"
git -C "$repo" worktree add -q -b feat/five "$wt5" main
( cd "$wt5" && bash .claude/scripts/worktree.sh teardown >/dev/null 2>&1 )
check "s5: teardown creates no .env" test ! -e "$wt5/.env"

# ---------------------------------------------------------------------------
# Scenario 6: the linked .env is still gitignored inside the worktree.
# ---------------------------------------------------------------------------
check "s6: linked .env resolves as ignored" git -C "$wt1" check-ignore -q .env

echo
if [ "$fail" -ne 0 ]; then
  echo "worktree.test.sh: FAILED"
  exit 1
fi
echo "worktree.test.sh: all $ok checks passed"
