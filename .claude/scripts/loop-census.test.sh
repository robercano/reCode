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
    printf '5\tplanned,module:test\tIssue five\n'
    printf '6\tplanned,module:test\tIssue six\n'
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
  chmod +x "$scripts/pr-feedback.sh" "$scripts/cockpit.sh" "$scripts/loop-census.sh"
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
          printf '20\tplanned,module:test\tCandidate twenty\n'
          printf '21\tplanned,module:test\tCandidate twenty one\n'
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
          printf '20\tplanned,module:test\tCandidate twenty\n'
          printf '21\tplanned,module:test\tCandidate twenty one\n'
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
          printf '30\tplanned,module:test\tCandidate thirty\n'
          printf '31\tplanned,module:test\tCandidate thirty one\n'
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
          printf '40\tplanned,module:test\tTracker forty\n'
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
    printf '80\tplanned,module:test\tStale issue eighty\n'
    printf '81\tplanned,module:test\tFresh issue eighty one\n'
    printf '82\tplanned,module:test\tNo-events issue eighty two\n'
    printf '90\tplanned,module:test\tStale-but-has-PR issue ninety\n'
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

echo ""
if [ "$fail" -eq 0 ]; then
  echo "loop-census.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "loop-census.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
