#!/usr/bin/env bash
# gate.test.sh — offline smoke test for gate.sh's dependency-freshness
# preflight vs. the empty/unconfigured-gate skip (issue #129).
#
# gate.sh runs two checks in this order:
#   1. pnpm-lock.yaml vs node_modules/.pnpm/lock.yaml staleness preflight
#      (aborts with exit 1 + a specific stderr message when they differ).
#   2. the requested gate key's command lookup in gates.json (skips with
#      exit 0 when the key is blank/unconfigured).
#
# Before #129, the preflight ran unconditionally BEFORE the empty-gate skip,
# so an unconfigured gate (e.g. "test_affected": "" on a repo that doesn't
# wire it up yet) would still abort on a stale node_modules — even though
# no command was ever going to run. The fix keeps the preflight (still
# needed to guard configured gates) but this fixture pins the interaction:
# a blank gate key must skip cleanly regardless of lockfile staleness,
# while a configured gate key still gets the preflight's protection, and a
# fresh/absent lockfile still lets a configured gate's command actually run.
#
# Uses REAL gate.sh + resolve-roots.sh copied into a mocked fixture root
# (own pnpm-lock.yaml / node_modules / GATES_FILE) — mirrors
# plan-gate.test.sh's fixture-scaffolding pattern. Offline, no network, no
# real pnpm/node_modules touched.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/gate.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate_src="$script_dir/gate.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/gate-test.XXXXXX")"
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

# new_fixture NAME -- a root dir carrying its own .claude/scripts/{gate.sh,
# resolve-roots.sh} copy, so resolve-roots.sh's "*/.claude/scripts ->
# strip suffix" rule makes root=$work/NAME (real script, mocked root).
new_fixture() {
  local name="$1"
  local dir="$work/$name/.claude/scripts"
  mkdir -p "$dir"
  cp "$gate_src" "$dir/gate.sh"
  cp "$resolve_roots_src" "$dir/resolve-roots.sh"
  chmod +x "$dir"/*.sh
  printf '%s\n' "$work/$name"
}

# write_gates_file NAME JSON_BODY -- an absolute-path GATES_FILE (gate.sh
# takes absolute GATES_FILE values as-is, no root-relative resolution).
write_gates_file() {
  local name="$1" body="$2"
  local f="$work/$name.gates.json"
  printf '%s' "$body" > "$f"
  printf '%s\n' "$f"
}

run_gate() {
  # $1 = fixture root, $2 = GATES_FILE (absolute), $3 = gate key
  GATES_FILE="$2" bash "$1/.claude/scripts/gate.sh" "$3"
}

# =============================================================================
# (1) Blanked/unconfigured gate key => exit 0 (skip), EVEN with a stale/absent
# node_modules/.pnpm/lock.yaml. This is the #129 regression: under the old
# ordering the preflight ran first and would abort (exit 1) here even though
# the gate is a no-op. Proves the fix reordered the checks correctly.
# =============================================================================
dir1="$(new_fixture blank-gate-stale-lock)"
printf 'lockfileVersion: 6\n' > "$dir1/pnpm-lock.yaml"
mkdir -p "$dir1/node_modules/.pnpm"
printf 'lockfileVersion: 5\n' > "$dir1/node_modules/.pnpm/lock.yaml"  # deliberately mismatched
gates1="$(write_gates_file blank-gate '{"gates":{"test_affected":""}}')"
out1="$(run_gate "$dir1" "$gates1" test_affected 2>"$work/err1")"
rc1=$?
check "(1) blank gate key + stale lock: exit 0" bash -c '[ "$1" -eq 0 ]' _ "$rc1"
check "(1) blank gate key + stale lock: skip message on stdout" bash -c \
  'printf "%s\n" "$1" | grep -q "not configured in gates.json — skipping"' _ "$out1"
check "(1) blank gate key + stale lock: no preflight abort on stderr" bash -c \
  '! grep -q "node_modules is out of sync" "$1"' _ "$work/err1"

# Same, but node_modules/.pnpm/lock.yaml absent entirely (not just stale).
dir1b="$(new_fixture blank-gate-absent-lock)"
printf 'lockfileVersion: 6\n' > "$dir1b/pnpm-lock.yaml"
gates1b="$(write_gates_file blank-gate-absent '{"gates":{"test_affected":""}}')"
out1b="$(run_gate "$dir1b" "$gates1b" test_affected 2>"$work/err1b")"
rc1b=$?
check "(1b) blank gate key + absent installed lock: exit 0" bash -c '[ "$1" -eq 0 ]' _ "$rc1b"
check "(1b) blank gate key + absent installed lock: no preflight abort on stderr" bash -c \
  '! grep -q "node_modules is out of sync" "$1"' _ "$work/err1b"

# =============================================================================
# (2) Configured gate + stale/mismatched lock => exit 1 with the exact
# stderr message, naming the requested gate key. The command must NOT run.
# =============================================================================
dir2="$(new_fixture configured-gate-stale-lock)"
printf 'lockfileVersion: 6\n' > "$dir2/pnpm-lock.yaml"
mkdir -p "$dir2/node_modules/.pnpm"
printf 'lockfileVersion: 5\n' > "$dir2/node_modules/.pnpm/lock.yaml"
sideEffect2="$dir2/ran.txt"
gates2="$(write_gates_file configured-gate "{\"gates\":{\"my_gate\":\"touch $sideEffect2\"}}")"
out2="$(run_gate "$dir2" "$gates2" my_gate 2>"$work/err2")"
rc2=$?
check "(2) configured gate + stale lock: exit 1" bash -c '[ "$1" -eq 1 ]' _ "$rc2"
check "(2) configured gate + stale lock: exact stderr message" bash -c \
  'grep -qxF "gate.sh: node_modules is out of sync with pnpm-lock.yaml — run '"'"'pnpm install'"'"' (gate '"'"'my_gate'"'"' aborted)." "$1"' \
  _ "$work/err2"
check "(2) configured gate + stale lock: command never ran (no side effect)" bash -c '[ ! -e "$1" ]' _ "$sideEffect2"

# =============================================================================
# (3) Configured gate + fresh/matching lock (or no pnpm-lock.yaml at all) =>
# the gate command actually runs (side effect + exit 0 propagated).
# =============================================================================
dir3="$(new_fixture configured-gate-fresh-lock)"
printf 'lockfileVersion: 6\n' > "$dir3/pnpm-lock.yaml"
mkdir -p "$dir3/node_modules/.pnpm"
cp "$dir3/pnpm-lock.yaml" "$dir3/node_modules/.pnpm/lock.yaml"  # byte-identical => fresh
sideEffect3="$dir3/ran.txt"
gates3="$(write_gates_file configured-gate-fresh "{\"gates\":{\"my_gate\":\"touch $sideEffect3\"}}")"
out3="$(run_gate "$dir3" "$gates3" my_gate 2>"$work/err3")"
rc3=$?
check "(3) configured gate + fresh lock: exit 0" bash -c '[ "$1" -eq 0 ]' _ "$rc3"
check "(3) configured gate + fresh lock: command actually ran (side effect exists)" bash -c '[ -e "$1" ]' _ "$sideEffect3"
check "(3) configured gate + fresh lock: no preflight abort on stderr" bash -c \
  '! grep -q "node_modules is out of sync" "$1"' _ "$work/err3"

# Same, but no pnpm-lock.yaml at all (non-pnpm repo) -- preflight is a no-op.
dir3b="$(new_fixture configured-gate-no-lockfile)"
sideEffect3b="$dir3b/ran.txt"
gates3b="$(write_gates_file configured-gate-no-lockfile "{\"gates\":{\"my_gate\":\"touch $sideEffect3b\"}}")"
out3b="$(run_gate "$dir3b" "$gates3b" my_gate 2>"$work/err3b")"
rc3b=$?
check "(3b) configured gate + no pnpm-lock.yaml: exit 0" bash -c '[ "$1" -eq 0 ]' _ "$rc3b"
check "(3b) configured gate + no pnpm-lock.yaml: command actually ran" bash -c '[ -e "$1" ]' _ "$sideEffect3b"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "gate.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "gate.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
