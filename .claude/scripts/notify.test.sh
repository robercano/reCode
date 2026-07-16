#!/usr/bin/env bash
# notify.test.sh — offline smoke test for notify.sh (issue #99).
#
# Every scenario runs against a throwaway <fixture>/.claude/ tree (real
# notify.sh + resolve-roots.sh, a hand-written gates.json) so root/GATES_FILE
# resolution matches production exactly, with zero network/gh calls: notify.sh
# never calls gh at all, so this is just shell + a configured shell command
# that writes to a temp file.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/notify.test.sh
set -uo pipefail

# Isolate from the CALLER's environment (mirrors cockpit.test.sh): this test
# is wired into .claude/self/checks.sh's `test` case, which itself often runs
# under `GATES_FILE=.claude/self/gates.json` (the self-host loop). Since env
# vars set before a command propagate to every child process, an ambient
# GATES_FILE would silently redirect notify.sh's config lookup onto the SELF
# adapter instead of each fixture's own hand-written .claude/gates.json below.
unset GATES_FILE

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
notify_src="$script_dir/notify.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/notify-test.XXXXXX")"
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

# $1 = fixture name, $2 = notify command (may be empty). Prints the fixture's
# .claude/scripts dir and writes a matching .claude/gates.json.
new_fixture() {
  local name="$1" notify_cmd="$2"
  local dir="$work/$name"
  local scripts="$dir/.claude/scripts"
  mkdir -p "$scripts"
  cp "$notify_src" "$scripts/notify.sh"
  cp "$resolve_roots_src" "$scripts/resolve-roots.sh"
  chmod +x "$scripts"/*.sh
  CLAUDE_NOTIFY_CMD="$notify_cmd" node -e '
    const fs = require("fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({ notify: process.env.CLAUDE_NOTIFY_CMD }));
  ' "$dir/.claude/gates.json"
  printf '%s\n' "$scripts"
}

run_notify() {
  # $1=scripts dir, rest = notify.sh args. Runs with a throwaway throttle
  # state file scoped to THIS fixture (never the real .claude/state/).
  local scripts="$1"; shift
  CLAUDE_NOTIFY_THROTTLE_FILE="$scripts/../state/notify-throttle.json" bash "$scripts/notify.sh" "$@"
}

# ---------------------------------------------------------------------------
# 1. Empty command -> silent no-op, exit 0, no throttle state written.
# ---------------------------------------------------------------------------
dir1="$(new_fixture scenario1 "")"
out1="$(run_notify "$dir1" high "Some title" "Some body" --kind test --target issue:1)"
rc1=$?
check "scenario 1 (empty command): exit 0" [ "$rc1" -eq 0 ]
check "scenario 1: no output" [ -z "$out1" ]
check "scenario 1: no throttle state file created" [ ! -f "$dir1/../state/notify-throttle.json" ]

# ---------------------------------------------------------------------------
# 2. Configured command fires exactly once; an IMMEDIATE second call for the
#    SAME (kind,target) is throttled (no second fire).
# ---------------------------------------------------------------------------
fired2="$work/scenario2-fired.txt"
dir2="$(new_fixture scenario2 "printf '%s|%s|%s|%s\n' \"\$1\" \"\$2\" \"\$3\" \"\$NOTIFY_SEVERITY\" >> $fired2")"
run_notify "$dir2" high "First title" "First body" --kind foo --target issue:1 >/dev/null
check "scenario 2: command fired exactly once" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 1 ]' _ "$fired2"
check "scenario 2: severity/title/body reached the command as positional args AND env var" \
  grep -qF "high|First title|First body|high" "$fired2"

run_notify "$dir2" high "Second title" "Second body" --kind foo --target issue:1 >/dev/null
check "scenario 2: immediate second call for the SAME (kind,target) is throttled (still exactly 1 fire)" \
  bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 1 ]' _ "$fired2"

# A DIFFERENT (kind,target) is a distinct throttle bucket -> fires independently.
run_notify "$dir2" high "Third title" "Third body" --kind foo --target issue:2 >/dev/null
check "scenario 2: a different target is an independent throttle bucket (now 2 fires total)" \
  bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 2 ]' _ "$fired2"

# ---------------------------------------------------------------------------
# 3. --window overrides the default throttle window: a call using a 0-second
#    window is effectively never throttled.
# ---------------------------------------------------------------------------
fired3="$work/scenario3-fired.txt"
dir3="$(new_fixture scenario3 "printf 'fired\n' >> $fired3")"
run_notify "$dir3" low "T" "B" --kind zero-window --target issue:9 --window 0 >/dev/null
run_notify "$dir3" low "T" "B" --kind zero-window --target issue:9 --window 0 >/dev/null
check "scenario 3: --window 0 never throttles (both calls fired)" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 2 ]' _ "$fired3"

# ---------------------------------------------------------------------------
# 4. --clear removes the throttle entry with NO notification, so a
#    subsequent call for the same (kind,target) fires immediately again.
# ---------------------------------------------------------------------------
fired4="$work/scenario4-fired.txt"
dir4="$(new_fixture scenario4 "printf 'fired\n' >> $fired4")"
run_notify "$dir4" high "T" "B" --kind clear-me --target issue:5 >/dev/null
check "scenario 4: first call fired" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 1 ]' _ "$fired4"
run_notify "$dir4" --clear --kind clear-me --target issue:5
rc4clear=$?
check "scenario 4: --clear exits 0 and does NOT itself fire the command" bash -c '[ "'"$rc4clear"'" -eq 0 ] && [ "$(wc -l < "$1" | tr -d " ")" -eq 1 ]' _ "$fired4"
run_notify "$dir4" high "T2" "B2" --kind clear-me --target issue:5 >/dev/null
check "scenario 4: after --clear, the SAME (kind,target) fires again immediately (not throttled)" \
  bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 2 ]' _ "$fired4"

# ---------------------------------------------------------------------------
# 5. Missing/unwritable state dir degrades gracefully (never crashes, never
#    blocks the notification) -- guards the "read-only state dir" contract.
# ---------------------------------------------------------------------------
fired5="$work/scenario5-fired.txt"
dir5="$(new_fixture scenario5 "printf 'fired\n' >> $fired5")"
out5="$(CLAUDE_NOTIFY_THROTTLE_FILE="/nonexistent-dir-$$/notify-throttle.json" bash "$dir5/notify.sh" high T B --kind x --target y 2>&1)"
rc5=$?
check "scenario 5 (unwritable throttle path): exit 0 despite being unable to persist state" [ "$rc5" -eq 0 ]
check "scenario 5: the notification still fired despite the degraded state path" bash -c '[ -s "$1" ]' _ "$fired5"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "notify.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "notify.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
