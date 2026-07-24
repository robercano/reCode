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
cockpit_src="$script_dir/cockpit.sh"
log_event_src="$script_dir/log-event.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/loop-census-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --- curated PATH (post-review finding #5) -----------------------------------
# The driver_unit_active guard scenario (b) below needs systemctl to be
# genuinely ABSENT so it deterministically hits the no-op/fallback branch,
# regardless of what the real host has on /usr/bin:/bin (essentially every
# Linux/CI host, including this sandbox) — mirrors loop-daemon.test.sh's own
# curated_bin technique, with `node` added since loop-census.sh shells out to
# it directly for its adapter-derived facts.
curated_bin="$work/curated-bin"
mkdir -p "$curated_bin"
for tool in bash sh cat sed awk grep head tail tr wc mkdir mktemp rm date printf \
  kill git sleep basename dirname cut sort uniq env true false node; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && ln -sf "$real" "$curated_bin/$tool"
done

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
#   - issue 44:  a REMOTE-tracking-only branch feat/issue-44-m (pushed, local
#                copy deleted, same shape as issue 42), but a MERGED PR
#                already exists for it -> stale-merged-remote (issue #158):
#                must report branch=none and NOT be in_flight, even though
#                the remote-tracking ref itself still exists.
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
cat > "$scripts_dir/pr-ci-fix.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$scripts_dir/pr-comment-fix.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$scripts_dir/pr-rebase.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# Fake bot-gh.sh: no network, no real `gh` — dispatches on the subcommand and
# a `--json` marker to canned, fixture-appropriate output.
#   - `pr list --state merged --head <branch> ...`: merged-PR count for a
#     bare branch name (issue #158) — 1 for feat/issue-44-m (the
#     stale-merged-remote case), 0 for everything else (default). Checked
#     BEFORE the headRefName/default branches below since it shares the `pr`
#     subcommand but never carries the `headRefName` marker.
#   - `pr list ... --json headRefName ...`: bare branch names of open PRs —
#     issues 43 and 100 already have one; issue 42 and 44 do not (issue 4 has
#     no branch, so it can't have a PR either).
#   - `pr list ... --json number ...`:       open PR count (2, matching above).
#   - `issue list ...`:                      TSV `num<TAB>labels<TAB>milestone<TAB>title`
#     for the five planned+module:test issues (milestone field empty here —
#     none of these issues are milestone-scoped; see issue #174's dedicated
#     milestone-scoping fixtures further below).
cat > "$scripts_dir/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    if printf '%s\n' "$*" | grep -q -- '--state merged'; then
      case "$*" in
        *"--head feat/issue-44-m"*) echo 1 ;;
        *) echo 0 ;;
      esac
    elif printf '%s\n' "$*" | grep -q 'headRefName'; then
      printf '%s\n' "feat/issue-43-z"
      printf '%s\n' "feat/issue-100-w"
    else
      echo 2
    fi
    ;;
  issue)
    printf '4\tplanned,module:test\t\tIssue four\n'
    printf '42\tplanned,module:test\t\tIssue forty two\n'
    printf '43\tplanned,module:test\t\tIssue forty three\n'
    printf '44\tplanned,module:test\t\tIssue forty four\n'
    printf '100\tplanned,module:test\t\tIssue one hundred\n'
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$scripts_dir"/*.sh

# Real git repo at the fixture root (census does `git -C "$root" branch -a`).
git -C "$fixture" init -q -b main
git -C "$fixture" -c user.email=t@e.st -c user.name=t commit -q --allow-empty -m init

# Commit the fixture scaffolding written above (.claude/scripts/*, gates.json,
# ...) plus a real tracked file — used further below to exercise
# main_dirty=yes (issue #106) via an actual uncommitted modification. Without
# this commit the scaffolding itself would sit untracked and main_dirty would
# always read "yes", breaking the "clean fixture" checks that run first.
#
# Also seed TRACKED baseline files under the read-only-mounted
# .claude/agents/ and .claude/skills/setup/templates/ trees, mirroring a real
# repo where those paths are checked in. Used further below to exercise the
# "can legitimately lag behind HEAD" exclusion (issue #106, acceptance
# criterion 3) via an in-place modification to an EXISTING tracked file —
# the real shape of a stale bind-mount, as opposed to a brand-new untracked
# path (which git would collapse into a single directory-level status line).
echo "tracked" > "$fixture/tracked.txt"
mkdir -p "$fixture/.claude/agents" "$fixture/.claude/skills/setup/templates"
echo "implementer baseline" > "$fixture/.claude/agents/implementer.md"
echo "template baseline" > "$fixture/.claude/skills/setup/templates/CLAUDE.md"
git -C "$fixture" add .claude tracked.txt
git -C "$fixture" -c user.email=t@e.st -c user.name=t commit -q -m "add fixture scaffolding + tracked file"

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

# issue 44: same shape as 42/43 (remote-tracking-only ref, local copy
# deleted), but the fake bot-gh.sh reports a MERGED PR already exists for its
# bare branch name — the stale-merged-remote case (issue #158): this ref must
# be ignored (branch=none), not counted as in_flight forever.
git -C "$fixture" branch feat/issue-44-m main >/dev/null
git -C "$fixture" push -q origin feat/issue-44-m >/dev/null 2>&1
git -C "$fixture" branch -D feat/issue-44-m >/dev/null

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
check "issue 44 (remote-only branch, MERGED PR already exists) reports branch=none (issue #158)" bash -c 'printf "%s\n" "$1" | grep -q "^issue=44 branch=none"' _ "$out"
check "issue 44 (stale merged remote-only ref) is NOT in_flight (issue #158)" bash -c '! printf "%s\n" "$1" | grep -qx "in_flight=44"' _ "$out"
check "exactly one in_flight line total (only issue 42 qualifies)" bash -c '[ "$(printf "%s\n" "$1" | grep -c "^in_flight=")" -eq 1 ]' _ "$out"
check "planned_issues=5 counted" bash -c 'printf "%s\n" "$1" | grep -qx "planned_issues=5"' _ "$out"
check "issue=42 branch line shows the origin-prefixed remote-tracking name" bash -c 'printf "%s\n" "$1" | grep -q "^issue=42 branch=origin/feat/issue-42-y"' _ "$out"
check "ci_fix_prs=0 counted (no-op pr-ci-fix.sh stub, issue #96)" bash -c 'printf "%s\n" "$1" | grep -qx "ci_fix_prs=0"' _ "$out"
check "comment_fix_prs=0 counted (no-op pr-comment-fix.sh stub, issue #96 part 2)" bash -c 'printf "%s\n" "$1" | grep -qx "comment_fix_prs=0"' _ "$out"
check "rebase_prs=0 counted (no-op pr-rebase.sh stub, issue #96 part 3)" bash -c 'printf "%s\n" "$1" | grep -qx "rebase_prs=0"' _ "$out"

# ---------------------------------------------------------------------------
# ci_fix_prs (issue #96): loop-census.sh must surface pr-ci-fix.sh's own
# candidate count verbatim as `ci_fix_prs=N`, exactly mirroring how
# feedback_prs already wraps pr-feedback.sh (`grep -c .` over its TSV output)
# -- reusing fixture1's real git repo/adapter, just swapping in a pr-ci-fix.sh
# stub that prints two candidate lines instead of the no-op above.
# ---------------------------------------------------------------------------
cat > "$scripts_dir/pr-ci-fix.sh" <<'EOF'
#!/usr/bin/env bash
printf '10\tfeat/issue-10-a\tbuild\tsha10\n'
printf '11\tfeat/issue-11-a\tbuild\tsha11\n'
EOF
# Commit this swap into fixture1's git history — fixture1 is reused for the
# main_dirty checks much further below, which assume the fixture is otherwise
# clean; leaving this rewrite uncommitted made `git status --porcelain` show
# a real ` M .claude/scripts/pr-ci-fix.sh` line for the rest of the fixture's
# life, permanently tripping main_dirty=yes regardless of which exclusion was
# actually under test (unrelated pre-existing gap, not part of what's being
# tested here).
git -C "$fixture" add .claude/scripts/pr-ci-fix.sh
git -C "$fixture" -c user.email=t@e.st -c user.name=t commit -q -m "swap in ci_fix_prs stub (test fixture)"
outCiFix="$(env -u GATES_FILE bash "$scripts_dir/loop-census.sh" "acme/repo")"
check "ci_fix_prs=2 counted when pr-ci-fix.sh reports two candidates" bash -c 'printf "%s\n" "$1" | grep -qx "ci_fix_prs=2"' _ "$outCiFix"

# ---------------------------------------------------------------------------
# comment_fix_prs (issue #96 part 2): same wrapping contract as ci_fix_prs
# above, exercised against pr-comment-fix.sh instead.
# ---------------------------------------------------------------------------
cat > "$scripts_dir/pr-comment-fix.sh" <<'EOF'
#!/usr/bin/env bash
printf '20\tfeat/issue-20-a\tTABC:1\tsha20\n'
EOF
git -C "$fixture" add .claude/scripts/pr-comment-fix.sh
git -C "$fixture" -c user.email=t@e.st -c user.name=t commit -q -m "swap in comment_fix_prs stub (test fixture)"
outCommentFix="$(env -u GATES_FILE bash "$scripts_dir/loop-census.sh" "acme/repo")"
check "comment_fix_prs=1 counted when pr-comment-fix.sh reports one candidate" bash -c 'printf "%s\n" "$1" | grep -qx "comment_fix_prs=1"' _ "$outCommentFix"

# ---------------------------------------------------------------------------
# rebase_prs (issue #96 part 3): same wrapping contract as ci_fix_prs/
# comment_fix_prs above, exercised against pr-rebase.sh instead.
# ---------------------------------------------------------------------------
cat > "$scripts_dir/pr-rebase.sh" <<'EOF'
#!/usr/bin/env bash
printf '30\tfeat/issue-30-a\tsha30\tbase30\t1\n'
EOF
git -C "$fixture" add .claude/scripts/pr-rebase.sh
git -C "$fixture" -c user.email=t@e.st -c user.name=t commit -q -m "swap in rebase_prs stub (test fixture)"
outRebase="$(env -u GATES_FILE bash "$scripts_dir/loop-census.sh" "acme/repo")"
check "rebase_prs=1 counted when pr-rebase.sh reports one candidate" bash -c 'printf "%s\n" "$1" | grep -qx "rebase_prs=1"' _ "$outRebase"

# ---------------------------------------------------------------------------
# driver_unit_active guard (issue #119 post-review finding #5): loop-census.sh
# must never report advance_ready for an issue whose transient driver unit
# (pr-loop-driver-issue<N>, spawned by loop-daemon.sh's run_driver) is
# currently active — the driver may not have reached `git checkout -b` yet, so
# it has no branch for the in_flight check above to catch, and a second tick
# would otherwise double-spawn an orchestrator for the same issue.
#
# build_guard_fixture: like fixture1 above but with two planned issues (5, 6),
# NEITHER with a branch nor an open PR — with the guard disabled,
# advance_ready would always report "5" (lowest-numbered), which is exactly
# what lets scenario (a) below prove the guard actually skips it in favor of
# issue 6.
# ---------------------------------------------------------------------------
build_guard_fixture() {
  local name="$1"
  local dir="$work/$name"
  local scripts="$dir/.claude/scripts"
  mkdir -p "$scripts"
  cp "$census_src" "$scripts/loop-census.sh"
  cp "$resolve_roots_src" "$scripts/resolve-roots.sh"
  cat > "$dir/.claude/gates.json" <<'EOF'
{
  "modules": [{ "name": "test", "path": ".", "description": "", "owner": "" }],
  "merge": { "baseBranch": "main" }
}
EOF
  cat > "$scripts/pr-feedback.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$scripts/pr-ci-fix.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$scripts/pr-comment-fix.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$scripts/pr-rebase.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs at all
    else
      echo 0
    fi
    ;;
  issue)
    printf '5\tplanned,module:test\t\tIssue five\n'
    printf '6\tplanned,module:test\t\tIssue six\n'
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$scripts"/*.sh
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.email=t@e.st -c user.name=t commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# (a) issue 5's driver unit is active (systemctl stub answers "active") ->
#     excluded from advance_ready, which falls through to issue 6 instead.
dirA="$(build_guard_fixture guardA)"
mkdir -p "$dirA/bin"
cat > "$dirA/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"is-active pr-loop-driver-issue5"*) echo "active"; exit 0 ;;
  *"is-active"*) echo "inactive"; exit 3 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$dirA/bin/systemctl"
outA="$(env -u GATES_FILE PATH="$dirA/bin:$PATH" bash "$dirA/.claude/scripts/loop-census.sh" "acme/repo")"
check "driver_unit_active guard (a): issue 5's active driver unit excludes it from advance_ready" bash -c '
  ! printf "%s\n" "$1" | grep -qx "advance_ready=5"' _ "$outA"
check "driver_unit_active guard (a): advance_ready falls through to issue 6 instead" bash -c '
  printf "%s\n" "$1" | grep -qx "advance_ready=6"' _ "$outA"

# (b) systemctl unavailable entirely (curated PATH, no stub) -> the guard
#     cleanly no-ops (command -v systemctl fails, driver_unit_active always
#     reports "not active"), so advance_ready falls back to prior behavior:
#     issue 5 (lowest-numbered, no branch, no open PRs).
dirB="$(build_guard_fixture guardB)"
outB="$(env -u GATES_FILE PATH="$curated_bin" bash "$dirB/.claude/scripts/loop-census.sh" "acme/repo")"
check "driver_unit_active guard (b): systemctl unavailable — guard no-ops, advance_ready falls back to issue 5" bash -c '
  printf "%s\n" "$1" | grep -qx "advance_ready=5"' _ "$outB"

# ---------------------------------------------------------------------------
# Blocking-graph gate (issue #97): advance_ready must skip a candidate whose
# body says "Blocked by #N" while N is still OPEN, emit a `blocked=<n> by=<N>`
# census line for it, and pick the next unblocked lowest-numbered candidate
# instead. A blocker closing (dropping out of the open-issue set) must make
# the previously-blocked candidate eligible again on the very next run — no
# extra state, since census re-derives everything from the current gh state
# every time it's invoked. A "Blocked by" cycle between two planned issues
# must not wedge the loop: fall back to the lowest-numbered of the cycle and
# log the fallback to stderr. Task-list refs (`- [ ] #N`) must NOT gate.
#
# Each fixture below reuses the REAL cockpit.sh (`--parse-blocking` seam),
# copied in verbatim — never reimplemented — plus a stub bot-gh.sh that
# dispatches on `issue list` (with/without `--label`, to tell the planned-
# issue TSV fetch apart from the all-open-issue-numbers fetch) and
# `issue view <n> --json body` (per-candidate body fetch).
# ---------------------------------------------------------------------------
scaffold_blocking_fixture() {
  local dir="$1"
  local scripts="$dir/.claude/scripts"
  mkdir -p "$scripts"
  cp "$census_src" "$scripts/loop-census.sh"
  cp "$resolve_roots_src" "$scripts/resolve-roots.sh"
  cp "$cockpit_src" "$scripts/cockpit.sh"
  cat > "$dir/.claude/gates.json" <<'EOF'
{
  "modules": [{ "name": "test", "path": ".", "description": "", "owner": "" }],
  "merge": { "baseBranch": "main" }
}
EOF
  cat > "$scripts/pr-feedback.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$scripts/pr-ci-fix.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$scripts/pr-comment-fix.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$scripts/pr-rebase.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$scripts/pr-feedback.sh" "$scripts/pr-ci-fix.sh" "$scripts/pr-comment-fix.sh" "$scripts/pr-rebase.sh" "$scripts/cockpit.sh" "$scripts/loop-census.sh"
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.email=t@e.st -c user.name=t commit -q --allow-empty -m init
}

run_blocking_fixture() {
  # $1 = fixture dir, $2 = stderr capture file. Stdout returned on stdout.
  env -u GATES_FILE bash "$1/.claude/scripts/loop-census.sh" "acme/repo" 2>"$2"
}

# --- (a)+(b): issue 20 "Blocked by #99", issue 21 no blockers. Two states of
# the SAME fixture shape, differing only in whether 99 is in the open set. ---
dirBlockOpen="$work/blockOpen"
scaffold_blocking_fixture "$dirBlockOpen"
cat > "$dirBlockOpen/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list)
        if printf '%s\n' "$*" | grep -q -- '--label'; then
          printf '20\tplanned,module:test\t\tCandidate twenty\n'
          printf '21\tplanned,module:test\t\tCandidate twenty one\n'
        else
          # all-open-issue-numbers fetch: 99 (the blocker) is still OPEN.
          printf '20\n21\n99\n'
        fi
        ;;
      view)
        case "$3" in
          20) echo '{"body":"Blocked by #99"}' ;;
          21) echo '{"body":"no blockers here"}' ;;
          *) echo '{"body":""}' ;;
        esac
        ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirBlockOpen/.claude/scripts/bot-gh.sh"
errBlockOpen="$work/blockOpen.stderr"
outBlockOpen="$(run_blocking_fixture "$dirBlockOpen" "$errBlockOpen")"

check "(a) issue 20 blocked by OPEN #99 is not advance_ready" bash -c \
  '! printf "%s\n" "$1" | grep -qx "advance_ready=20"' _ "$outBlockOpen"
check "(a) blocked=20 by=99 census line emitted" bash -c \
  'printf "%s\n" "$1" | grep -qx "blocked=20 by=99"' _ "$outBlockOpen"
check "(a) advance_ready instead picks unblocked candidate 21" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=21"' _ "$outBlockOpen"

# Same fixture, but 99 has since been closed (dropped from the open set) —
# copy the fixture and swap only the bot-gh.sh's open-issue-numbers branch.
dirBlockClosed="$work/blockClosed"
scaffold_blocking_fixture "$dirBlockClosed"
cat > "$dirBlockClosed/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list)
        if printf '%s\n' "$*" | grep -q -- '--label'; then
          printf '20\tplanned,module:test\t\tCandidate twenty\n'
          printf '21\tplanned,module:test\t\tCandidate twenty one\n'
        else
          # all-open-issue-numbers fetch: 99 (the blocker) is now CLOSED —
          # absent from this list entirely.
          printf '20\n21\n'
        fi
        ;;
      view)
        case "$3" in
          20) echo '{"body":"Blocked by #99"}' ;;
          21) echo '{"body":"no blockers here"}' ;;
          *) echo '{"body":""}' ;;
        esac
        ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirBlockClosed/.claude/scripts/bot-gh.sh"
errBlockClosed="$work/blockClosed.stderr"
outBlockClosed="$(run_blocking_fixture "$dirBlockClosed" "$errBlockClosed")"

check "(b) blocker #99 closed -> no blocked=20 line" bash -c \
  '! printf "%s\n" "$1" | grep -qx "blocked=20 by=99"' _ "$outBlockClosed"
check "(b) issue 20 becomes advance_ready again once its blocker closes" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=20"' _ "$outBlockClosed"

# --- (c): cycle — issue 30 "Blocked by #31", issue 31 "Blocked by #30", both
# open+planned. Must not wedge: falls back to the lowest-numbered (#30) and
# logs the fallback to stderr. ---
dirCycle="$work/cycle"
scaffold_blocking_fixture "$dirCycle"
cat > "$dirCycle/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list)
        if printf '%s\n' "$*" | grep -q -- '--label'; then
          printf '30\tplanned,module:test\t\tCandidate thirty\n'
          printf '31\tplanned,module:test\t\tCandidate thirty one\n'
        else
          printf '30\n31\n'
        fi
        ;;
      view)
        case "$3" in
          30) echo '{"body":"Blocked by #31"}' ;;
          31) echo '{"body":"Blocked by #30"}' ;;
          *) echo '{"body":""}' ;;
        esac
        ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirCycle/.claude/scripts/bot-gh.sh"
errCycle="$work/cycle.stderr"
outCycle="$(run_blocking_fixture "$dirCycle" "$errCycle")"

check "(c) cycle: advance_ready is non-none (loop does not wedge)" bash -c \
  '! printf "%s\n" "$1" | grep -qx "advance_ready=none"' _ "$outCycle"
check "(c) cycle: advance_ready falls back to the lowest-numbered issue (30)" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=30"' _ "$outCycle"
check "(c) cycle: both directions reported as blocked=" bash -c \
  'printf "%s\n" "$1" | grep -qx "blocked=30 by=31" && printf "%s\n" "$1" | grep -qx "blocked=31 by=30"' _ "$outCycle"
check "(c) cycle: fallback logged to stderr" bash -c \
  'grep -q "all planned candidates blocked" "$1" && grep -q "falling back to lowest-number #30" "$1"' _ "$errCycle"

# --- (d): task-list edge (`- [ ] #N`) but NO "Blocked by" — must NOT gate. ---
dirTasklist="$work/tasklist"
scaffold_blocking_fixture "$dirTasklist"
cat > "$dirTasklist/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list)
        if printf '%s\n' "$*" | grep -q -- '--label'; then
          printf '40\tplanned,module:test\t\tTracker forty\n'
        else
          printf '40\n41\n'
        fi
        ;;
      view)
        case "$3" in
          40) echo '{"body":"- [ ] #41 sub-task, not a blocker"}' ;;
          *) echo '{"body":""}' ;;
        esac
        ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirTasklist/.claude/scripts/bot-gh.sh"
errTasklist="$work/tasklist.stderr"
outTasklist="$(run_blocking_fixture "$dirTasklist" "$errTasklist")"

check "(d) task-list ref alone does not gate — advance_ready=40" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=40"' _ "$outTasklist"
check "(d) no blocked= line emitted for a task-list-only reference" bash -c \
  '! printf "%s\n" "$1" | grep -q "^blocked="' _ "$outTasklist"

# ---------------------------------------------------------------------------
# Priority-label ordering (issue #173): candidates are ordered by (priority
# rank, then issue number) BEFORE advance_ready/detail/blocking iterate them —
# critical=0, high=1, medium=2, low=3, unlabeled=4 (last), number is the
# tiebreaker. Three fixtures, one per acceptance scenario. None of these need
# cockpit.sh: every candidate's stubbed issue body is empty, so the
# --parse-blocking shell-out never fires except in the (c) blocked fixture
# below, which copies cockpit.sh in exactly like the blocking-graph fixtures
# above.
# ---------------------------------------------------------------------------
build_plain_fixture() {
  # $1 = dir. Same shape as build_guard_fixture above (no branches, no open
  # PRs) but factored out so the priority fixtures below can each supply
  # their own bot-gh.sh issue-list body.
  local dir="$1"
  local scripts="$dir/.claude/scripts"
  mkdir -p "$scripts"
  cp "$census_src" "$scripts/loop-census.sh"
  cp "$resolve_roots_src" "$scripts/resolve-roots.sh"
  cat > "$dir/.claude/gates.json" <<'EOF'
{
  "modules": [{ "name": "test", "path": ".", "description": "", "owner": "" }],
  "merge": { "baseBranch": "main" }
}
EOF
  for stub in pr-feedback pr-ci-fix pr-comment-fix pr-rebase; do
    cat > "$scripts/$stub.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  done
  chmod +x "$scripts"/*.sh
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.email=t@e.st -c user.name=t commit -q --allow-empty -m init
}

# --- (a) priority beats number: issue 50 (priority:critical) must become
# advance_ready over issue 3 (unlabeled, lower number) -- pure number order
# would pick 3 first. ---
dirPrioNum="$work/prio-beats-number"
build_plain_fixture "$dirPrioNum"
cat > "$dirPrioNum/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list)
        if printf '%s\n' "$*" | grep -q -- '--label'; then
          printf '3\tplanned,module:test\t\tLow-priority-in-number-order candidate\n'
          printf '50\tplanned,module:test,priority:critical\t\tHigh-priority higher-numbered candidate\n'
        else
          printf '3\n50\n'
        fi
        ;;
      view) echo '{"body":""}' ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirPrioNum/.claude/scripts/bot-gh.sh"
outPrioNum="$(env -u GATES_FILE bash "$dirPrioNum/.claude/scripts/loop-census.sh" "acme/repo")"

check "(a) priority-critical issue 50 becomes advance_ready over lower-numbered unlabeled issue 3" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=50"' _ "$outPrioNum"
check "(a) issue 50 (critical) is iterated/detailed BEFORE issue 3 (unlabeled)" bash -c '
  printf "%s\n" "$1" | grep -n "^issue=" | sort -t: -k1,1n | head -1 | grep -q "issue=50 "
' _ "$outPrioNum"

# --- (b) unlabeled-last: issue 5 (unlabeled, LOWER number) and issue 6
# (priority:low, HIGHER number) are BOTH otherwise-eligible (no branch, no
# open PR, not blocked) -- priority:low still outranks unlabeled despite
# 6 > 5, so issue 6 must be iterated first and win advance_ready. A plain
# `sort -n` revert would pick issue 5 first instead, so this genuinely
# discriminates (unlike a shape where the lower-numbered candidate is made
# ineligible, which would pass either way). ---
dirUnlabeledLast="$work/unlabeled-last"
build_plain_fixture "$dirUnlabeledLast"
cat > "$dirUnlabeledLast/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list)
        if printf '%s\n' "$*" | grep -q -- '--label'; then
          printf '5\tplanned,module:test\t\tUnlabeled lower-numbered candidate\n'
          printf '6\tplanned,module:test,priority:low\t\tLabeled higher-numbered candidate\n'
        else
          printf '5\n6\n'
        fi
        ;;
      view) echo '{"body":""}' ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirUnlabeledLast/.claude/scripts/bot-gh.sh"
# Neither issue has a branch, an open PR, or a blocker -- both are fully
# eligible, so the only thing that can decide the outcome is priority order.
outUnlabeledLast="$(env -u GATES_FILE bash "$dirUnlabeledLast/.claude/scripts/loop-census.sh" "acme/repo")"

check "(b) issue 6 (priority:low) is iterated before issue 5 (unlabeled)" bash -c '
  printf "%s\n" "$1" | grep -n "^issue=" | sort -t: -k1,1n | head -1 | grep -q "issue=6 "
' _ "$outUnlabeledLast"
check "(b) priority:low issue 6 becomes advance_ready over lower-numbered unlabeled issue 5" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=6"' _ "$outUnlabeledLast"
check "(b) unlabeled issue 5 (otherwise eligible) is NOT advance_ready" bash -c \
  '! printf "%s\n" "$1" | grep -qx "advance_ready=5"' _ "$outUnlabeledLast"
check "(b) unlabeled issue 5 is not in_flight either (genuinely eligible, just outranked)" bash -c \
  '! printf "%s\n" "$1" | grep -qx "in_flight=5"' _ "$outUnlabeledLast"

# --- (c) blocked-high-priority skipped for unblocked-lower: issue 70
# (priority:high, HIGHER number) is "Blocked by #99" (still OPEN) -> skipped,
# emits blocked=70 by=99; issue 8 (unlabeled, unblocked, LOWER number)
# becomes advance_ready instead, even though 70 outranks it on priority.
# Because 70 > 8, priority order and plain numeric order disagree on
# iteration order (priority puts 70 first; `sort -n` would put 8 first),
# so this genuinely discriminates a `sort -n` revert. Reuses the real
# cockpit.sh --parse-blocking seam, exactly like the blocking-graph fixtures
# above (scaffold_blocking_fixture copies it in verbatim). ---
dirBlockedPrio="$work/blocked-priority"
scaffold_blocking_fixture "$dirBlockedPrio"
cat > "$dirBlockedPrio/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list)
        if printf '%s\n' "$*" | grep -q -- '--label'; then
          printf '70\tplanned,module:test,priority:high\t\tBlocked high-priority candidate\n'
          printf '8\tplanned,module:test\t\tUnblocked lower-priority candidate\n'
        else
          # all-open-issue-numbers fetch: 99 (the blocker) is still OPEN.
          printf '70\n8\n99\n'
        fi
        ;;
      view)
        case "$3" in
          70) echo '{"body":"Blocked by #99"}' ;;
          8) echo '{"body":""}' ;;
          *) echo '{"body":""}' ;;
        esac
        ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirBlockedPrio/.claude/scripts/bot-gh.sh"
errBlockedPrio="$work/blocked-priority.stderr"
outBlockedPrio="$(run_blocking_fixture "$dirBlockedPrio" "$errBlockedPrio")"

check "(c) issue 70 (priority:high, iterated first) is iterated before issue 8 (unlabeled)" bash -c '
  printf "%s\n" "$1" | grep -n "^issue=" | sort -t: -k1,1n | head -1 | grep -q "issue=70 "
' _ "$outBlockedPrio"
check "(c) blocked=70 by=99 census line emitted (higher-priority candidate skipped)" bash -c \
  'printf "%s\n" "$1" | grep -qx "blocked=70 by=99"' _ "$outBlockedPrio"
check "(c) issue 70 (blocked) is NOT advance_ready despite outranking issue 8 on priority" bash -c \
  '! printf "%s\n" "$1" | grep -qx "advance_ready=70"' _ "$outBlockedPrio"
check "(c) advance_ready instead picks the unblocked lower-priority issue 8" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=8"' _ "$outBlockedPrio"

# ---------------------------------------------------------------------------
# Stall detection (issue #98): loop-census.sh must emit `stalled=N age_min=M`
# for an in_flight issue whose newest events.jsonl activity (task field either
# "N" or "issue-N" -- both forms occur in real logs) is older than
# budget.stall_minutes, while leaving fresh/zero-event/has-a-PR issues alone.
#
# Fixture: four planned+module:test issues, each with its own
# feat/issue-N-* branch and NO open PR (issue 90 is the one exception, with
# an open PR, to prove "stalled branch + open PR -> NOT stalled"):
#   80  stale events (task="80", well past the threshold)      -> stalled
#   81  fresh events (task="issue-81", well within the threshold) -> NOT stalled
#   82  zero events at all for this task                        -> NOT stalled
#     (conservative false-positive rule: never kill a just-created branch)
#   90  stale events (task="90") but an OPEN PR already exists   -> NOT stalled
#     (never even in_flight, so never even considered for staleness)
# stall_minutes is set to 2 in this fixture's own gates.json so the test
# doesn't need to wait a real 30 minutes -- timestamps below are computed
# relative to the ACTUAL wall clock at test run time via `date -u -d`.
# ---------------------------------------------------------------------------
dirStall="$work/stall"
scriptsStall="$dirStall/.claude/scripts"
mkdir -p "$scriptsStall"
cp "$census_src" "$scriptsStall/loop-census.sh"
cp "$resolve_roots_src" "$scriptsStall/resolve-roots.sh"
cat > "$dirStall/.claude/gates.json" <<'EOF'
{
  "modules": [{ "name": "test", "path": ".", "description": "", "owner": "" }],
  "merge": { "baseBranch": "main" },
  "budget": { "stall_minutes": 2 }
}
EOF
cat > "$scriptsStall/pr-feedback.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$scriptsStall/pr-ci-fix.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$scriptsStall/pr-comment-fix.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$scriptsStall/pr-rebase.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$scriptsStall/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      printf '%s\n' "feat/issue-90-x"
    else
      echo 1
    fi
    ;;
  issue)
    printf '80\tplanned,module:test\t\tStale issue eighty\n'
    printf '81\tplanned,module:test\t\tFresh issue eighty one\n'
    printf '82\tplanned,module:test\t\tNo-events issue eighty two\n'
    printf '90\tplanned,module:test\t\tStale-but-has-PR issue ninety\n'
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$scriptsStall"/*.sh
git -C "$dirStall" init -q -b main
git -C "$dirStall" -c user.email=t@e.st -c user.name=t commit -q --allow-empty -m init
git -C "$dirStall" branch feat/issue-80-a main >/dev/null
git -C "$dirStall" branch feat/issue-81-a main >/dev/null
git -C "$dirStall" branch feat/issue-82-a main >/dev/null
git -C "$dirStall" branch feat/issue-90-x main >/dev/null

eventsStall="$work/stall-events.jsonl"
stale_ts="$(date -u -d '-45 minutes' +%Y-%m-%dT%H:%M:%SZ)"
fresh_ts="$(date -u -d '-1 minutes' +%Y-%m-%dT%H:%M:%SZ)"
{
  printf '{"ts":"%s","role":"implementer","model":"sonnet","task":"80","phase":"implementing","lens":"","detail":""}\n' "$stale_ts"
  printf '{"ts":"%s","role":"implementer","model":"sonnet","task":"issue-81","phase":"implementing","lens":"","detail":""}\n' "$fresh_ts"
  printf '{"ts":"%s","role":"implementer","model":"sonnet","task":"90","phase":"implementing","lens":"","detail":""}\n' "$stale_ts"
} > "$eventsStall"

outStall="$(env -u GATES_FILE CLAUDE_EVENTS_FILE="$eventsStall" bash "$scriptsStall/loop-census.sh" "acme/repo")"

check "stall: stale in_flight issue 80 (task=\"80\" form) IS reported stalled" bash -c \
  'printf "%s\n" "$1" | grep -q "^stalled=80 age_min="' _ "$outStall"
check "stall: fresh in_flight issue 81 (task=\"issue-81\" form) is NOT stalled" bash -c \
  '! printf "%s\n" "$1" | grep -q "^stalled=81 "' _ "$outStall"
check "stall: issue 82 has zero events -> NOT stalled (conservative false-positive rule)" bash -c \
  '! printf "%s\n" "$1" | grep -q "^stalled=82 "' _ "$outStall"
check "stall: issue 90 has stale events but an OPEN PR -> NOT stalled" bash -c \
  '! printf "%s\n" "$1" | grep -q "^stalled=90 "' _ "$outStall"
check "stall: issue 90 with an open PR is also NOT in_flight" bash -c \
  '! printf "%s\n" "$1" | grep -qx "in_flight=90"' _ "$outStall"
check "stall: exactly one stalled= line total" bash -c \
  '[ "$(printf "%s\n" "$1" | grep -c "^stalled=")" -eq 1 ]' _ "$outStall"
check "stall: age_min on the stalled line is at least the 2-minute threshold" bash -c '
  age="$(printf "%s\n" "$1" | sed -n "s/^stalled=80 age_min=\([0-9]*\)/\1/p")"
  [ -n "$age" ] && [ "$age" -ge 2 ]
' _ "$outStall"

# ---------------------------------------------------------------------------
# main_dirty (issue #106): git-state-mutation guard's companion telemetry.
# ---------------------------------------------------------------------------
check "clean fixture: main_dirty=no" bash -c 'printf "%s\n" "$1" | grep -qx "main_dirty=no"' _ "$out"

# A real uncommitted modification to a tracked file -> main_dirty=yes.
echo "modified" >> "$fixture/tracked.txt"
out_dirty="$(env -u GATES_FILE bash "$scripts_dir/loop-census.sh" "acme/repo")"
check "fixture with a real tracked-file modification: main_dirty=yes" bash -c 'printf "%s\n" "$1" | grep -qx "main_dirty=yes"' _ "$out_dirty"
git -C "$fixture" checkout -q -- tracked.txt

# The ONLY dirt is a sandbox-mask phantom path — a symlink to /dev/null
# satisfies the same `[ -c path ]` test a real bind-mounted device-node mask
# would (unprivileged test code can't mknod a real character device, but a
# symlink to one passes the exact same `test -c`, since `[ -c ]` follows
# symlinks). Must still report main_dirty=no: the exclusion works.
ln -sf /dev/null "$fixture/.mcp.json"
out_mask="$(env -u GATES_FILE bash "$scripts_dir/loop-census.sh" "acme/repo")"
check "fixture whose only dirt is a sandbox-mask phantom path: main_dirty=no" bash -c 'printf "%s\n" "$1" | grep -qx "main_dirty=no"' _ "$out_mask"
rm -f "$fixture/.mcp.json"

# A modification to the EXISTING tracked .claude/agents/ baseline file can
# legitimately lag behind HEAD in sandboxed sessions — must NOT flip
# main_dirty (issue #106, acceptance criterion 3).
echo "stale mount content" >> "$fixture/.claude/agents/implementer.md"
out_agents="$(env -u GATES_FILE bash "$scripts_dir/loop-census.sh" "acme/repo")"
check "fixture with only a .claude/agents/ modification: main_dirty=no" bash -c 'printf "%s\n" "$1" | grep -qx "main_dirty=no"' _ "$out_agents"
git -C "$fixture" checkout -q -- .claude/agents/implementer.md

# Same for the read-only-mounted .claude/skills/setup/templates/ tree.
echo "stale mount content" >> "$fixture/.claude/skills/setup/templates/CLAUDE.md"
out_templates="$(env -u GATES_FILE bash "$scripts_dir/loop-census.sh" "acme/repo")"
check "fixture with only a .claude/skills/setup/templates/ modification: main_dirty=no" bash -c 'printf "%s\n" "$1" | grep -qx "main_dirty=no"' _ "$out_templates"
git -C "$fixture" checkout -q -- .claude/skills/setup/templates/CLAUDE.md

# ---------------------------------------------------------------------------
# main_head (issue #106): detects a DETACHED HEAD in the main checkout — the
# 2026-07-16 incident (a failed mid-op `git checkout` left main detached on
# an unmerged commit for ~12h, with a CLEAN working tree throughout, i.e.
# main_dirty=no the whole time; only main_head would have caught it).
# ---------------------------------------------------------------------------
check "clean fixture on its named branch: main_head=main" bash -c 'printf "%s\n" "$1" | grep -qx "main_head=main"' _ "$out"

git -C "$fixture" checkout -q --detach HEAD
out_detached="$(env -u GATES_FILE bash "$scripts_dir/loop-census.sh" "acme/repo")"
check "fixture with HEAD detached: main_head=detached" bash -c 'printf "%s\n" "$1" | grep -qx "main_head=detached"' _ "$out_detached"
check "fixture with HEAD detached: main_dirty still no (working tree itself is clean)" bash -c 'printf "%s\n" "$1" | grep -qx "main_dirty=no"' _ "$out_detached"
git -C "$fixture" checkout -q main

# ---------------------------------------------------------------------------
# Milestone scoping (issue #174): milestones represent versions (SCRUM
# sprints) -- the census's ADVANCE candidate set must scope to the CURRENT
# open milestone (lowest version-sorted open milestone with >=1 qualifying
# planned+module candidate), recomputed fresh every run, falling back to
# today's unscoped behavior when no open milestone qualifies (including the
# common case of a repo with no milestones at all, exercised implicitly by
# every fixture ABOVE this point in the file, none of which stub the `api`
# subcommand -- their bot-gh.sh falls through to the unhandled-args case,
# which degrades gracefully to an empty $milestones_tsv).
#
# build_milestone_fixture: same no-branch/no-open-PR shape as
# build_plain_fixture above, but also copies in log-event.sh (needed by the
# milestone-complete-event scenario) since these fixtures' own bot-gh.sh
# additionally answers the `api .../milestones?state=open` REST call.
# ---------------------------------------------------------------------------
build_milestone_fixture() {
  local dir="$1"
  local scripts="$dir/.claude/scripts"
  mkdir -p "$scripts"
  cp "$census_src" "$scripts/loop-census.sh"
  cp "$resolve_roots_src" "$scripts/resolve-roots.sh"
  cp "$log_event_src" "$scripts/log-event.sh"
  cat > "$dir/.claude/gates.json" <<'EOF'
{
  "modules": [{ "name": "test", "path": ".", "description": "", "owner": "" }],
  "merge": { "baseBranch": "main" }
}
EOF
  for stub in pr-feedback pr-ci-fix pr-comment-fix pr-rebase; do
    cat > "$scripts/$stub.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  done
  chmod +x "$scripts"/*.sh
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.email=t@e.st -c user.name=t commit -q --allow-empty -m init
}

# --- SCOPING: two open milestones, both with a qualifying candidate -- only
# the LOWER-versioned milestone's issue may advance. Issue 5 (LOWER number)
# is deliberately assigned to the HIGHER-version milestone (v2.0), and issue
# 10 (HIGHER number) to the LOWER-version milestone (v1.0): a scoping-unaware
# revert (plain priority/number order, ignoring milestone) would pick issue 5
# first, so this genuinely discriminates. ---
dirScoping="$work/milestone-scoping"
build_milestone_fixture "$dirScoping"
cat > "$dirScoping/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  api)
    printf '1\tv1.0\t1\t0\n'
    printf '2\tv2.0\t1\t0\n'
    ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list)
        if printf '%s\n' "$*" | grep -q -- '--label'; then
          printf '5\tplanned,module:test\tv2.0\tHigher-milestone lower-numbered candidate\n'
          printf '10\tplanned,module:test\tv1.0\tLower-milestone higher-numbered candidate\n'
        else
          printf '5\n10\n'
        fi
        ;;
      view) echo '{"body":""}' ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirScoping/.claude/scripts/bot-gh.sh"
outScoping="$(env -u GATES_FILE bash "$dirScoping/.claude/scripts/loop-census.sh" "acme/repo")"

check "(scoping) current milestone is v1.0 (lowest version-sorted open milestone with a qualifying candidate)" bash -c \
  'printf "%s\n" "$1" | grep -qx "milestone=v1.0"' _ "$outScoping"
check "(scoping) milestone_open=1 (only v1.0's own candidate counted)" bash -c \
  'printf "%s\n" "$1" | grep -qx "milestone_open=1"' _ "$outScoping"
check "(scoping) advance_ready is issue 10 (v1.0-scoped), not issue 5 (lower-numbered but v2.0)" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=10"' _ "$outScoping"
check "(scoping) issue 5 (out-of-scope v2.0 candidate) is never even detailed/counted" bash -c \
  '! printf "%s\n" "$1" | grep -q "^issue=5 "' _ "$outScoping"
check "(scoping) planned_issues=1 (scoped count, not the repo-wide 2)" bash -c \
  'printf "%s\n" "$1" | grep -qx "planned_issues=1"' _ "$outScoping"

# --- FALLBACK: an open milestone exists, but NO candidate targets it -- must
# fall back to today's unscoped behavior (no milestone= line, the unassigned
# candidate still advances). ---
dirFallback="$work/milestone-fallback"
build_milestone_fixture "$dirFallback"
cat > "$dirFallback/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  api)
    printf '1\tv1.0\t3\t0\n'
    ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list)
        if printf '%s\n' "$*" | grep -q -- '--label'; then
          printf '20\tplanned,module:test\t\tUnassigned candidate\n'
        else
          printf '20\n'
        fi
        ;;
      view) echo '{"body":""}' ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirFallback/.claude/scripts/bot-gh.sh"
outFallback="$(env -u GATES_FILE bash "$dirFallback/.claude/scripts/loop-census.sh" "acme/repo")"

check "(fallback) no milestone= line when no open milestone has a qualifying candidate" bash -c \
  '! printf "%s\n" "$1" | grep -q "^milestone="' _ "$outFallback"
check "(fallback) advance_ready falls back to the unscoped candidate (today's behavior)" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=20"' _ "$outFallback"
check "(fallback) planned_issues=1 counted (unscoped)" bash -c \
  'printf "%s\n" "$1" | grep -qx "planned_issues=1"' _ "$outFallback"

# --- RECOMPUTE-ON-DRAIN (a): v1.0 is fully drained (no qualifying candidate
# left) while v2.0 DOES have one -- v2.0 becomes current automatically, no
# persistent cursor needed. ---
dirDrainA="$work/milestone-drain-recompute"
build_milestone_fixture "$dirDrainA"
cat > "$dirDrainA/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  api)
    printf '1\tv1.0\t0\t2\n'
    printf '2\tv2.0\t1\t0\n'
    ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list)
        if printf '%s\n' "$*" | grep -q -- '--label'; then
          printf '30\tplanned,module:test\tv2.0\tNext-milestone candidate\n'
        else
          printf '30\n'
        fi
        ;;
      view) echo '{"body":""}' ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirDrainA/.claude/scripts/bot-gh.sh"
outDrainA="$(env -u GATES_FILE bash "$dirDrainA/.claude/scripts/loop-census.sh" "acme/repo")"

check "(recompute-on-drain) v1.0 drained -> v2.0 becomes current automatically" bash -c \
  'printf "%s\n" "$1" | grep -qx "milestone=v2.0"' _ "$outDrainA"
check "(recompute-on-drain) advance_ready advances v2.0's candidate (issue 30)" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=30"' _ "$outDrainA"

# --- RECOMPUTE-ON-DRAIN (b): v1.0 drained, v2.0 open but its issues are NOT
# YET labeled `planned` -- the loop must IDLE (advance_ready=none), never
# advance into the next milestone early. ---
dirDrainB="$work/milestone-drain-idle"
build_milestone_fixture "$dirDrainB"
cat > "$dirDrainB/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  api)
    printf '1\tv1.0\t0\t2\n'
    printf '2\tv2.0\t1\t0\n'
    ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      # v2.0's issue exists but isn't labeled `planned` yet -- the real
      # `--label planned` GitHub-side filter this call uses would exclude it
      # regardless of --label being present, so the planned TSV is empty.
      list) : ;;
      view) echo '{"body":""}' ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirDrainB/.claude/scripts/bot-gh.sh"
outDrainB="$(env -u GATES_FILE bash "$dirDrainB/.claude/scripts/loop-census.sh" "acme/repo")"

check "(recompute-on-drain, idle) no qualifying milestone -- no milestone= line" bash -c \
  '! printf "%s\n" "$1" | grep -q "^milestone="' _ "$outDrainB"
check "(recompute-on-drain, idle) loop idles rather than advancing into the unlabeled milestone" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=none"' _ "$outDrainB"
check "(recompute-on-drain, idle) planned_issues=0" bash -c \
  'printf "%s\n" "$1" | grep -qx "planned_issues=0"' _ "$outDrainB"

# --- MILESTONE-COMPLETE event (issue #174): a fully-drained milestone
# (open_issues=0, closed_issues>=1) logs ONE milestone-complete event via
# log-event.sh -- and re-running census repeatedly must NOT append a
# duplicate, preserving the read-only/re-run-safe contract for every other
# line this script prints (this write is the single deliberate exception). ---
dirComplete="$work/milestone-complete"
build_milestone_fixture "$dirComplete"
cat > "$dirComplete/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  api)
    printf '1\tv1.0\t0\t2\n'
    ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list) : ;;
      view) echo '{"body":""}' ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirComplete/.claude/scripts/bot-gh.sh"
eventsComplete="$work/milestone-complete-events.jsonl"
: > "$eventsComplete"
env -u GATES_FILE CLAUDE_EVENTS_FILE="$eventsComplete" bash "$dirComplete/.claude/scripts/loop-census.sh" "acme/repo" >/dev/null
env -u GATES_FILE CLAUDE_EVENTS_FILE="$eventsComplete" bash "$dirComplete/.claude/scripts/loop-census.sh" "acme/repo" >/dev/null
env -u GATES_FILE CLAUDE_EVENTS_FILE="$eventsComplete" bash "$dirComplete/.claude/scripts/loop-census.sh" "acme/repo" >/dev/null

check "(milestone-complete) event logged for the drained milestone" bash -c \
  'grep -q "\"phase\":\"milestone-complete\"" "$1" && grep -q "\"task\":\"v1.0\"" "$1"' _ "$eventsComplete"
check "(milestone-complete) idempotent -- exactly one event after three census runs" bash -c \
  '[ "$(grep -c "\"phase\":\"milestone-complete\"" "$1")" -eq 1 ]' _ "$eventsComplete"

# ---------------------------------------------------------------------------
# sort -V regression lock (issue #174 follow-up): two open milestones titled
# "v1.9" and "v1.10", where LEXICAL and VERSION order genuinely DIVERGE
# (lexically "v1.10" < "v1.9" since '1' < '9' at the third character; only
# `sort -V`'s numeric-aware comparison puts v1.9 first). Each has its own
# qualifying planned+module candidate -- issue 15 -> v1.9, issue 16 -> v1.10,
# fed to the fake `api` stub in v1.10-first order so a correct `sort -V`
# inside loop-census.sh is what has to reorder them, not accidental input
# order. If the "V" modifier were ever dropped from the `sort -k2,2V` call,
# plain lexical sort would pick v1.10 first and this whole block would flip.
# ---------------------------------------------------------------------------
dirSortV="$work/milestone-sort-v"
build_milestone_fixture "$dirSortV"
cat > "$dirSortV/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  api)
    printf '1\tv1.10\t1\t0\n'
    printf '2\tv1.9\t1\t0\n'
    ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list)
        if printf '%s\n' "$*" | grep -q -- '--label'; then
          printf '15\tplanned,module:test\tv1.9\tLower-version candidate\n'
          printf '16\tplanned,module:test\tv1.10\tHigher-version candidate\n'
        else
          printf '15\n16\n'
        fi
        ;;
      view) echo '{"body":""}' ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirSortV/.claude/scripts/bot-gh.sh"
outSortV="$(env -u GATES_FILE bash "$dirSortV/.claude/scripts/loop-census.sh" "acme/repo")"

check "(sort -V regression) milestone=v1.9 (lower VERSION wins over lexically-earlier-looking v1.10)" bash -c \
  'printf "%s\n" "$1" | grep -qx "milestone=v1.9"' _ "$outSortV"
check "(sort -V regression) advance_ready=15 (v1.9's candidate), not issue 16 (v1.10)" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=15"' _ "$outSortV"
check "(sort -V regression) issue 16 (out-of-scope v1.10 candidate) is never detailed" bash -c \
  '! printf "%s\n" "$1" | grep -q "^issue=16 "' _ "$outSortV"

# ---------------------------------------------------------------------------
# never-populated guard negative test (issue #174 follow-up): a milestone
# REST stub reports open_issues==0 AND closed_issues==0 -- brand-new, never
# populated with any issues at all -- with no candidates targeting it. The
# milestone-complete guard requires closed_issues>=1 (genuinely drained)
# alongside open_issues==0, so this must log ZERO milestone-complete events;
# a guard that fired on open==0 alone (ignoring closed>=1) would wrongly
# treat "never populated" as "complete".
# ---------------------------------------------------------------------------
dirNeverPop="$work/milestone-never-populated"
build_milestone_fixture "$dirNeverPop"
cat > "$dirNeverPop/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  api)
    printf '1\tv3.0\t0\t0\n'
    ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list) : ;;
      view) echo '{"body":""}' ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirNeverPop/.claude/scripts/bot-gh.sh"
eventsNeverPop="$work/milestone-never-populated-events.jsonl"
: > "$eventsNeverPop"
env -u GATES_FILE CLAUDE_EVENTS_FILE="$eventsNeverPop" bash "$dirNeverPop/.claude/scripts/loop-census.sh" "acme/repo" >/dev/null
env -u GATES_FILE CLAUDE_EVENTS_FILE="$eventsNeverPop" bash "$dirNeverPop/.claude/scripts/loop-census.sh" "acme/repo" >/dev/null

check "(never-populated guard) never-populated milestone (open=0, closed=0) logs zero milestone-complete events" bash -c \
  '[ "$(grep -c "\"phase\":\"milestone-complete\"" "$1")" -eq 0 ]' _ "$eventsNeverPop"

# ---------------------------------------------------------------------------
# un-drained milestone negative test (issue #174 follow-up): an OPEN
# milestone (open_issues>0) genuinely in scope -- it has its own qualifying
# planned+module candidate, so milestone= is non-vacuous (this isn't just an
# empty/fallback state) -- yet still un-drained. The milestone-complete guard
# must not fire: zero events logged while the milestone is still in play.
# ---------------------------------------------------------------------------
dirUndrained="$work/milestone-undrained"
build_milestone_fixture "$dirUndrained"
cat > "$dirUndrained/.claude/scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  api)
    printf '1\tv1.0\t2\t1\n'
    ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "$2" in
      list)
        if printf '%s\n' "$*" | grep -q -- '--label'; then
          printf '60\tplanned,module:test\tv1.0\tIn-play candidate\n'
        else
          printf '60\n'
        fi
        ;;
      view) echo '{"body":""}' ;;
      *) echo "unhandled issue subcmd: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirUndrained/.claude/scripts/bot-gh.sh"
eventsUndrained="$work/milestone-undrained-events.jsonl"
: > "$eventsUndrained"
outUndrained="$(env -u GATES_FILE CLAUDE_EVENTS_FILE="$eventsUndrained" bash "$dirUndrained/.claude/scripts/loop-census.sh" "acme/repo")"

check "(un-drained) milestone=v1.0 genuinely in scope (non-vacuous -- has its own qualifying candidate)" bash -c \
  'printf "%s\n" "$1" | grep -qx "milestone=v1.0"' _ "$outUndrained"
check "(un-drained) advance_ready=60 (the in-scope milestone's qualifying candidate)" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=60"' _ "$outUndrained"
check "(un-drained) zero milestone-complete events logged (milestone still open, not genuinely drained)" bash -c \
  '[ "$(grep -c "\"phase\":\"milestone-complete\"" "$1")" -eq 0 ]' _ "$eventsUndrained"

# ---------------------------------------------------------------------------
# no-leak assertion for the truly-milestone-less path (issue #174 follow-up):
# reuses fixture1's ALREADY-captured $out (its bot-gh.sh has no `api` case at
# all -- an unhandled `gh api ...` call falls into the catch-all `exit 1`,
# exactly the "no api stub" shape this check calls for). The existing
# `grep -qx` positive checks above only assert specific lines are PRESENT;
# they would not catch an EXTRA leaked `milestone=`/`milestone_open=` line
# sitting elsewhere in the same output, so this asserts their absence
# directly.
# ---------------------------------------------------------------------------
check "(no-leak) pre-milestone fixture (no api stub) never leaks a milestone= line" bash -c \
  '! printf "%s\n" "$1" | grep -q "^milestone="' _ "$out"
check "(no-leak) pre-milestone fixture (no api stub) never leaks a milestone_open= line" bash -c \
  '! printf "%s\n" "$1" | grep -q "^milestone_open="' _ "$out"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "loop-census.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "loop-census.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
