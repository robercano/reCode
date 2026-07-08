#!/usr/bin/env bash
# loop-census.test.sh — offline smoke test for loop-census.sh's in_flight
# detection (issue #81 re-review, finding 5).
#
# loop-tick.test.sh exercises loop-tick.sh against a FAKE loop-census.sh that
# just echoes canned `in_flight=N` lines — it never runs loop-census.sh's own
# branch-detection algorithm. This test closes that gap: it runs the REAL
# loop-census.sh (+ real resolve-roots.sh) against a REAL git repo with real
# local and remote-tracking branches, stubbing only `gh` (via a fake
# bot-gh.sh) and pr-feedback.sh (no network, no gh CLI required), and asserts
# on the actual `in_flight=`/`branch=` lines the real algorithm prints.
#
# Specifically covers the two failure modes called out in re-review:
#
#   - PREFIX COLLISION: issue 4 has NO branch of its own, while issue 42 and
#     issue 43 DO (as "issue-4" is a literal prefix of "issue-42"/"issue-43").
#     A glob without the trailing "-" (`*feat/issue-4*` instead of
#     `*feat/issue-4-*`) would make `git branch -a --list` for issue 4 also
#     match issue 42's/43's branches; since issue 4 has no LOCAL branch of
#     its own to sort first, `head -1` would then wrongly attribute one of
#     THEIR branches to issue 4. Asserted directly: issue 4 must come back
#     branch=none despite 42/43 existing.
#
#   - "remotes/origin/" HANDLING: issue 42's and 43's branches exist ONLY as
#     remote-tracking refs (pushed, then the local branch deleted), so
#     `git branch -a` reports them as "remotes/origin/feat/issue-4N-*".
#     Issue 43 additionally already has an open PR under its BARE branch
#     name (`feat/issue-43-z`, no "origin/" prefix, matching a real
#     `headRefName`) — that must still register as "already has a PR" (not
#     in_flight) via the "*/<bare>" suffix rule, not just an exact-string
#     match; issue 100's LOCAL (non-remote) branch with an open PR is the
#     control for the exact-match path.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/loop-census.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
census_src="$script_dir/loop-census.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/loop-census-test.XXXXXX")"
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
# Build one fixture: a real git repo (fixture root = census's $root) with:
#   - issue 4:   NO branch at all -> branch=none. Must not be fooled by
#                issue 42's/43's branches, whose names have "issue-4" as a
#                literal prefix.
#   - issue 42:  a REMOTE-tracking-only branch feat/issue-42-y (pushed, local
#                copy deleted), no open PR for it -> MUST be in_flight.
#   - issue 43:  a REMOTE-tracking-only branch feat/issue-43-z, which
#                ALREADY has an open PR under its bare name -> must NOT be
#                in_flight (the "remotes/origin/" strip + "*/<bare>" suffix
#                match on the POSITIVE path).
#   - issue 100: a LOCAL branch feat/issue-100-w, which ALREADY has an open
#                PR under its bare (exact, no prefix) name -> must NOT be
#                in_flight (the plain exact-match control case).
# ---------------------------------------------------------------------------
fixture="$work/fixture1"
scripts_dir="$fixture/.claude/scripts"
mkdir -p "$scripts_dir"
cp "$census_src" "$scripts_dir/loop-census.sh"
cp "$resolve_roots_src" "$scripts_dir/resolve-roots.sh"

# Minimal adapter: one module, so "module:test" is the only label census cares
# about; base branch is "main" to match the repo below.
cat > "$fixture/.claude/gates.json" <<'EOF'
{
  "modules": [{ "name": "test", "path": ".", "description": "", "owner": "" }],
  "merge": { "baseBranch": "main" }
}
EOF

# pr-feedback.sh is exercised by its own test (loop-tick.test.sh); here it's
# just a no-op stub so census's feedback_prs line is deterministic (0).
cat > "$scripts_dir/pr-feedback.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# Fake bot-gh.sh: no network, no real `gh` — dispatches on the subcommand and
# a `--json` marker to canned, fixture-appropriate output.
#   - `pr list ... --json headRefName ...`: bare branch names of open PRs —
#     issues 43 and 100 already have one; issue 42 does not (issue 4 has no
#     branch, so it can't have a PR either).
#   - `pr list ... --json number ...`:       open PR count (2, matching above).
#   - `issue list ...`:                      TSV `num<TAB>labels<TAB>title`
#     for the four planned+module:test issues.
cat > "$scripts_dir/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      printf '%s\n' "feat/issue-43-z"
      printf '%s\n' "feat/issue-100-w"
    else
      echo 2
    fi
    ;;
  issue)
    printf '4\tplanned,module:test\tIssue four\n'
    printf '42\tplanned,module:test\tIssue forty two\n'
    printf '43\tplanned,module:test\tIssue forty three\n'
    printf '100\tplanned,module:test\tIssue one hundred\n'
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$scripts_dir"/*.sh

# Real git repo at the fixture root (census does `git -C "$root" branch -a`).
git -C "$fixture" init -q -b main
git -C "$fixture" -c user.email=t@e.st -c user.name=t commit -q --allow-empty -m init

# Bare "remote" so `git branch -a` prints genuine "remotes/origin/..." lines.
remote="$work/remote.git"
git init -q --bare "$remote"
git -C "$fixture" remote add origin "$remote"

# issue 4: deliberately NO branch at all (see the prefix-collision note above).

# issue 42 and 43: pushed to origin, then the LOCAL copy is deleted so only
# the "remotes/origin/..." remote-tracking ref remains — this is the case
# census's "strip remotes/ or match as /-suffix" logic exists for.
git -C "$fixture" branch feat/issue-42-y main >/dev/null
git -C "$fixture" push -q origin feat/issue-42-y >/dev/null 2>&1
git -C "$fixture" branch -D feat/issue-42-y >/dev/null

git -C "$fixture" branch feat/issue-43-z main >/dev/null
git -C "$fixture" push -q origin feat/issue-43-z >/dev/null 2>&1
git -C "$fixture" branch -D feat/issue-43-z >/dev/null

# issue 100: LOCAL-only branch (never pushed) — exact-match control.
git -C "$fixture" branch feat/issue-100-w main >/dev/null

# Unset GATES_FILE explicitly: loop-census.sh reads it straight from the
# environment, and this test may itself be run from inside a gate invocation
# that exports GATES_FILE=.claude/self/gates.json for the OUTER repo — which
# would leak in here and make census look for a gates.json this fixture never
# created. Force it back to the fixture's own default-relative gates.json.
out="$(env -u GATES_FILE bash "$scripts_dir/loop-census.sh" "acme/repo")"

check "issue 4 (no branch at all) reports branch=none" bash -c 'printf "%s\n" "$1" | grep -q "^issue=4 branch=none"' _ "$out"
check "issue 4 is NOT in_flight (no branch to be in flight with)" bash -c '! printf "%s\n" "$1" | grep -qx "in_flight=4"' _ "$out"
check "issue 42 (remote-only branch, no open PR) IS in_flight" bash -c 'printf "%s\n" "$1" | grep -qx "in_flight=42"' _ "$out"
check "issue 43 (remote-only branch, already has an open PR via origin/ strip+suffix match) is NOT in_flight" bash -c '! printf "%s\n" "$1" | grep -qx "in_flight=43"' _ "$out"
check "issue 100 (local branch, already has an open PR, exact-match control) is NOT in_flight" bash -c '! printf "%s\n" "$1" | grep -qx "in_flight=100"' _ "$out"
check "exactly one in_flight line total (only issue 42 qualifies)" bash -c '[ "$(printf "%s\n" "$1" | grep -c "^in_flight=")" -eq 1 ]' _ "$out"
check "planned_issues=4 counted" bash -c 'printf "%s\n" "$1" | grep -qx "planned_issues=4"' _ "$out"
check "issue=42 branch line shows the origin-prefixed remote-tracking name" bash -c 'printf "%s\n" "$1" | grep -q "^issue=42 branch=origin/feat/issue-42-y"' _ "$out"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "loop-census.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "loop-census.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
