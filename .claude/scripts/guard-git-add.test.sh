#!/usr/bin/env bash
# guard-git-add.test.sh — offline smoke test for guard-git-add.py's PreToolUse
# hook (issue #106): both the pre-existing blanket-`git add -A`/`commit -a`
# guard and the new worker-vs-main-checkout git-state-mutation guard.
#
# Hermetic: builds a real throwaway git repo ($main) plus a real `git worktree
# add`-created worktree under $main/.claude/worktrees/w1 (mirroring how the
# implementer/orchestrator agents actually run), and pipes crafted PreToolUse
# event JSON (tool_name/cwd/tool_input.command) straight into
# `python3 guard-git-add.py`, asserting its exit code (0 = allow, 2 = block).
# No `git add`/`checkout`/etc in the crafted commands is ever actually run —
# the hook only inspects the command text and shells out to
# `git -C <dir> rev-parse --show-toplevel` to resolve effective targets, so
# nonexistent branch/file names in the crafted commands are fine.
#
# _sandbox_enabled() is forced true via a $main/.claude/settings.json fixture
# + CLAUDE_PROJECT_DIR=$main (see guard-git-add.py) so the guard deterministically
# engages, matching the hook's own hardened-only detection logic.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/guard-git-add.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="$script_dir/guard-git-add.py"

work="$(mktemp -d "${TMPDIR:-/tmp}/guard-git-add-test.XXXXXX")"
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

# ---------------------------------------------------------------------------
# Fixture: a real git repo ($main) — the "main checkout" — with a real
# `git worktree add` worktree at $main/.claude/worktrees/w1, exactly the
# layout a worker's isolation:worktree session runs under. A sandbox-hardened
# settings.json makes _sandbox_enabled() true so the guard engages.
# ---------------------------------------------------------------------------
main="$work/main"
mkdir -p "$main/.claude"
git -C "$main" init -q -b main
git -C "$main" -c user.email=t@e.st -c user.name=t commit -q --allow-empty -m init

cat > "$main/.claude/settings.json" <<'EOF'
{ "sandbox": { "enabled": true } }
EOF

git -C "$main" worktree add -q -b wbranch "$main/.claude/worktrees/w1" main
w1="$main/.claude/worktrees/w1"

# ---------------------------------------------------------------------------
# Helpers: build a PreToolUse event JSON and invoke the guard against it.
# worker=1 sets the RECODE_WORKER=1 marker env var; worker=0 (or omitted)
# leaves it unset, i.e. an owner session (or, for the corroboration-only
# case, a worker whose marker somehow didn't propagate).
# ---------------------------------------------------------------------------
build_event() {
  node -e '
    const [cwd, command] = process.argv.slice(1);
    process.stdout.write(JSON.stringify({ tool_name: "Bash", cwd, tool_input: { command } }));
  ' "$1" "$2"
}

assert_guard() {
  local desc="$1" cwd="$2" command="$3" worker="$4" expect="$5"
  local json rc out
  json="$(build_event "$cwd" "$command")"
  if [ "$worker" = "1" ]; then
    out="$(printf '%s' "$json" | CLAUDE_PROJECT_DIR="$main" RECODE_WORKER=1 python3 "$guard" 2>&1)"
  else
    out="$(printf '%s' "$json" | CLAUDE_PROJECT_DIR="$main" env -u RECODE_WORKER python3 "$guard" 2>&1)"
  fi
  rc=$?
  check "$desc (exit $expect)" bash -c '[ "$1" -eq "$2" ]' _ "$rc" "$expect"
  if [ "$rc" -ne "$expect" ]; then
    echo "  cwd=$cwd command=[$command] worker=$worker got=$rc output=$out"
  fi
}

# ---------------------------------------------------------------------------
# (c) Owner session (no marker) in the main checkout: NEVER blocked, whether
#     the command is a plain explicit-path add or a blanket one — owner
#     sessions must be unaffected (default allow when the marker is absent).
# ---------------------------------------------------------------------------
assert_guard "owner: explicit-path git add in main is allowed" \
  "$main" "git add foo.txt" 0 0

# ---------------------------------------------------------------------------
# Pre-existing behavior: blanket `git add -A`/`git commit -a` blocked once
# hardened, regardless of worker/owner (check 1 is independent of check 2).
# ---------------------------------------------------------------------------
assert_guard "owner: blanket 'git add -A' in main is blocked" \
  "$main" "git add -A" 0 2
assert_guard "owner: blanket 'git commit -a' in main is blocked" \
  "$main" 'git commit -a -m wip' 0 2

# ---------------------------------------------------------------------------
# (a) Worker session (marker=1) + mutating git subcommands, toplevel==main
#     checkout -> BLOCKED for every mutating subcommand named in the issue.
# ---------------------------------------------------------------------------
assert_guard "worker: git add in main checkout is blocked" \
  "$main" "git add foo.txt" 1 2
assert_guard "worker: git rm --cached in main checkout is blocked" \
  "$main" "git rm --cached foo.txt" 1 2
assert_guard "worker: git mv in main checkout is blocked" \
  "$main" "git mv a b" 1 2
assert_guard "worker: git reset --hard in main checkout is blocked" \
  "$main" "git reset --hard" 1 2
assert_guard "worker: git switch <branch> in main checkout is blocked" \
  "$main" "git switch some-branch" 1 2
assert_guard "worker: git checkout <branch> in main checkout is blocked" \
  "$main" "git checkout some-branch" 1 2
assert_guard "worker: git restore --staged in main checkout is blocked" \
  "$main" "git restore --staged foo.txt" 1 2

# Non-mutating / narrower forms must NOT be blocked even for a worker in main
# — this proves the guard isn't just blanket-blocking every git call there.
assert_guard "worker: git status in main checkout is allowed" \
  "$main" "git status" 1 0
assert_guard "worker: git restore (no --staged) in main checkout is allowed" \
  "$main" "git restore foo.txt" 1 0
assert_guard "worker: 'git checkout -- <path>' (pathspec restore) is allowed" \
  "$main" "git checkout -- foo.txt" 1 0

# ---------------------------------------------------------------------------
# (b) Worker session + the SAME commands run against its OWN worktree ->
#     ALLOWED (this is exactly where a worker is supposed to work).
# ---------------------------------------------------------------------------
assert_guard "worker: git add in its own worktree is allowed" \
  "$w1" "git add foo.txt" 1 0
assert_guard "worker: git checkout <branch> in its own worktree is allowed" \
  "$w1" "git checkout some-branch" 1 0
assert_guard "worker: git reset --hard in its own worktree is allowed" \
  "$w1" "git reset --hard" 1 0

# ---------------------------------------------------------------------------
# Escape hatches: a worker whose cwd IS its own worktree but whose command
# retargets the MAIN checkout via `git -C <main>` or a `cd <main> &&` prefix
# must still be BLOCKED — this is the exact bug #106 closes.
# ---------------------------------------------------------------------------
assert_guard "worker: 'git -C <main> add' from own worktree is blocked" \
  "$w1" "git -C $main add foo.txt" 1 2
assert_guard "worker: 'cd <main> && git add' from own worktree is blocked" \
  "$w1" "cd $main && git add foo.txt" 1 2

# Corroboration-only: marker absent, but cwd is already under
# .claude/worktrees/* — the cwd signal alone must still catch the -C escape.
assert_guard "corroboration-only (no marker): 'git -C <main> add' from a worktree cwd is blocked" \
  "$w1" "git -C $main add foo.txt" 0 2

echo ""
if [ "$fail" -eq 0 ]; then
  echo "guard-git-add.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "guard-git-add.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
