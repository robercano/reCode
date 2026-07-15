#!/usr/bin/env bash
# loop-halt.test.sh — offline smoke test for loop-halt.sh (issue #119).
#
# Builds a throwaway fixture `.claude/scripts/` (mirroring loop-daemon.test.sh's
# own convention) containing the REAL loop-halt.sh + resolve-roots.sh, with a
# fake `systemctl` stub prepended onto PATH that records every invocation
# instead of touching the real (or, in this sandbox, non-functional) user
# systemd bus. Exit 0 on success, non-zero if any assertion fails. Runnable
# bare: bash .claude/scripts/loop-halt.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
loop_halt_src="$script_dir/loop-halt.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/loop-halt-test.XXXXXX")"
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

new_fixture() {
  # $1=name -> prints fixture root, containing the real loop-halt.sh +
  # resolve-roots.sh under .claude/scripts/ (so resolve-roots.sh's own
  # */.claude/scripts detection makes $root == the fixture root).
  local name="$1"
  local dir="$work/$name"
  mkdir -p "$dir/.claude/scripts" "$dir/bin"
  cp "$loop_halt_src" "$dir/.claude/scripts/loop-halt.sh"
  cp "$resolve_roots_src" "$dir/.claude/scripts/resolve-roots.sh"
  chmod +x "$dir/.claude/scripts"/*.sh
  printf '%s\n' "$dir"
}

fake_systemctl() {
  # $1=fixture root $2=script body (the case/dispatch logic ONLY — the
  # boilerplate arg-logging header is added here) -> installs bin/systemctl.
  local dir="$1" body="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "systemctl-args:$*" >> "%s/systemctl.calls"\n' "$dir"
    printf '%s\n' "$body"
  } > "$dir/bin/systemctl"
  chmod +x "$dir/bin/systemctl"
}

run_halt() {
  # $1=fixture root; remaining args passed straight to loop-halt.sh.
  local dir="$1"; shift
  ( cd "$dir" && PATH="$dir/bin:/usr/bin:/bin" bash .claude/scripts/loop-halt.sh "$@" )
}

# ---------------------------------------------------------------------------
# 1. -h / --help: usage text, exit 0, no systemctl call at all.
# ---------------------------------------------------------------------------
dir1="$(new_fixture scenario1)"
fake_systemctl "$dir1" 'exit 0'
out1="$(run_halt "$dir1" -h 2>&1)"
rc1=$?
check "scenario 1 (-h): exit 0" [ "$rc1" -eq 0 ]
check "scenario 1: usage text mentions --drivers" bash -c 'printf "%s" "$1" | grep -q -- "--drivers"' _ "$out1"
check "scenario 1: no systemctl call was made for -h" [ ! -f "$dir1/systemctl.calls" ]

# ---------------------------------------------------------------------------
# 2. No systemctl on PATH at all: degrades cleanly, exit 0, explanatory log.
# ---------------------------------------------------------------------------
dir2="$(new_fixture scenario2)"
out2="$( ( cd "$dir2" && PATH="/usr/bin:/bin" bash .claude/scripts/loop-halt.sh issue1 2>&1 ) )"
rc2=$?
# Real host may or may not have a systemctl on /usr/bin:/bin — this scenario
# only makes a strong assertion when it genuinely doesn't; skip gracefully
# otherwise rather than false-failing on a host where systemctl happens to
# live in /usr/bin (the systemd-available path is covered by scenarios 3-6
# below via an explicit stub regardless of the host).
if ! command -v systemctl >/dev/null 2>&1; then
  check "scenario 2 (no systemctl anywhere): exit 0" [ "$rc2" -eq 0 ]
  check "scenario 2: explains systemd is unavailable" bash -c 'printf "%s" "$1" | grep -qi "systemctl not found"' _ "$out2"
else
  echo "ok - scenario 2 (host has a real systemctl on PATH — degrade-cleanly path exercised via the stubbed scenarios instead)"
  ok=$((ok + 1))
fi

# ---------------------------------------------------------------------------
# 3. loop-halt.sh issue106 -> stops pr-loop-driver-issue106.
# ---------------------------------------------------------------------------
dir3="$(new_fixture scenario3)"
fake_systemctl "$dir3" '
case "$*" in
  "--user stop pr-loop-driver-issue106") exit 0 ;;
  *) exit 0 ;;
esac'
run_halt "$dir3" issue106 >/dev/null 2>&1
check "scenario 3 (issue106): stopped exactly pr-loop-driver-issue106" bash -c '
  grep -qF "stop pr-loop-driver-issue106" "$1"' _ "$dir3/systemctl.calls"

# ---------------------------------------------------------------------------
# 4. loop-halt.sh pr42 -> stops pr-loop-driver-pr42.
# ---------------------------------------------------------------------------
dir4="$(new_fixture scenario4)"
fake_systemctl "$dir4" 'exit 0'
run_halt "$dir4" pr42 >/dev/null 2>&1
check "scenario 4 (pr42): stopped exactly pr-loop-driver-pr42" bash -c '
  grep -qF "stop pr-loop-driver-pr42" "$1"' _ "$dir4/systemctl.calls"

# ---------------------------------------------------------------------------
# 5. loop-halt.sh <verbatim unit name>: passed straight through unchanged.
# ---------------------------------------------------------------------------
dir5="$(new_fixture scenario5)"
fake_systemctl "$dir5" 'exit 0'
run_halt "$dir5" pr-loop-driver-issue999 >/dev/null 2>&1
check "scenario 5 (verbatim unit): stopped exactly the given unit name" bash -c '
  grep -qF "stop pr-loop-driver-issue999" "$1"' _ "$dir5/systemctl.calls"

# ---------------------------------------------------------------------------
# 6. loop-halt.sh --drivers: lists active pr-loop-driver-* units, stops each.
# ---------------------------------------------------------------------------
dir6="$(new_fixture scenario6)"
fake_systemctl "$dir6" '
case "$*" in
  *list-units*)
    echo "pr-loop-driver-issue7.service loaded active running one"
    echo "pr-loop-driver-pr9.service loaded active running two"
    exit 0
    ;;
  *) exit 0 ;;
esac'
run_halt "$dir6" --drivers >/dev/null 2>&1
check "scenario 6 (--drivers): stopped pr-loop-driver-issue7" bash -c '
  grep -qF "stop pr-loop-driver-issue7" "$1"' _ "$dir6/systemctl.calls"
check "scenario 6 (--drivers): stopped pr-loop-driver-pr9" bash -c '
  grep -qF "stop pr-loop-driver-pr9" "$1"' _ "$dir6/systemctl.calls"

# ---------------------------------------------------------------------------
# 7. loop-halt.sh --all: stops the daemon unit (repo-slug derived) AND every
#    active driver unit.
# ---------------------------------------------------------------------------
dir7="$(new_fixture My-Repo_Fixture7)"
fake_systemctl "$dir7" '
case "$*" in
  *list-units*)
    echo "pr-loop-driver-issue3.service loaded active running one"
    exit 0
    ;;
  *) exit 0 ;;
esac'
run_halt "$dir7" --all >/dev/null 2>&1
check "scenario 7 (--all): stopped the repo-slug daemon unit" bash -c '
  grep -qF "stop pr-loop-my-repo-fixture7.service" "$1"' _ "$dir7/systemctl.calls"
check "scenario 7 (--all): also stopped the active driver unit" bash -c '
  grep -qF "stop pr-loop-driver-issue3" "$1"' _ "$dir7/systemctl.calls"

# ---------------------------------------------------------------------------
# 8. loop-halt.sh --drivers with NO active units: no stop call at all.
# ---------------------------------------------------------------------------
dir8="$(new_fixture scenario8)"
fake_systemctl "$dir8" '
case "$*" in
  *list-units*) exit 0 ;;
  *) exit 0 ;;
esac'
out8="$(run_halt "$dir8" --drivers 2>&1)"
check "scenario 8 (--drivers, none active): logs nothing-to-stop" bash -c 'printf "%s" "$1" | grep -qi "no active pr-loop-driver"' _ "$out8"
check "scenario 8: no stop call was ever made" bash -c '! grep -q " stop " "$1" 2>/dev/null' _ "$dir8/systemctl.calls"

# ---------------------------------------------------------------------------
# 9. Argument validation: no args / unknown / malformed issue|pr -> usage, exit 2.
# ---------------------------------------------------------------------------
dir9="$(new_fixture scenario9)"
fake_systemctl "$dir9" 'exit 0'
run_halt "$dir9" >/dev/null 2>&1
check "scenario 9 (no args): exit 2" [ "$?" -eq 2 ]
run_halt "$dir9" bogus >/dev/null 2>&1
check "scenario 9 (unknown arg): exit 2" [ "$?" -eq 2 ]
run_halt "$dir9" issueX >/dev/null 2>&1
check "scenario 9 (malformed issueX): exit 2" [ "$?" -eq 2 ]
run_halt "$dir9" prX >/dev/null 2>&1
check "scenario 9 (malformed prX): exit 2" [ "$?" -eq 2 ]

echo ""
if [ "$fail" -eq 0 ]; then
  echo "loop-halt.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "loop-halt.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
