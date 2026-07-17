#!/usr/bin/env bash
# vendor-runtime.test.sh — offline smoke test for the runtime harness vendor
# (issue #128): scaffold.sh vendoring agents/commands/hooks/scripts/skills
# wholesale into a consumer .claude/, gated by the single top-level marker
# .claude/.orchestrator-vendor, and sync.sh's behind/up-to-date/conflict
# ladder for that same tree. Asserts:
#   1. fresh scaffold -> vendor tree created, marker stamped, arm-loop.sh
#      NOT duplicated by the tree copy (still only the managed-file copy),
#      settings.json created with no enabledPlugins/extraKnownMarketplaces.
#   2. re-running scaffold -> idempotent ("up to date" / "kept", no errors).
#   3. sync against an unchanged plugin root -> "up to date".
#   4. sync against a plugin root whose marker was bumped with NO other
#      content change -> restamped (no false conflict).
#   5. sync against a plugin root whose marker was bumped WITH a real
#      content change -> conflict (installed has no local edits, but the
#      script can't tell a legitimate upstream change from a hand-edit —
#      same conservative behavior as every other managed row).
#   6. sync with a genuine local edit to a vendored file (same version) ->
#      conflict.
#   7. sync with a local edit ONLY to arm-loop.sh -> the runtime-vendor row
#      stays "up to date" (excluded from its diff), while arm-loop.sh's OWN
#      managed row reports the conflict — proves the two mechanisms don't
#      double-manage the same file.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/vendor-runtime.test.sh
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scaffold_sh="$repo_root/.claude/skills/setup/scaffold.sh"
sync_sh="$repo_root/.claude/skills/sync/sync.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/vendor-runtime-test.XXXXXX")"
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
check_output() {
  # $1 = desc, $2 = haystack, $3 = needle (grep -F)
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    ok=$((ok + 1))
    echo "ok - $desc"
  else
    fail=1
    echo "FAIL - $desc (expected to find: $needle)"
  fi
}

# ---------------------------------------------------------------------------
# Scenario 1: fresh scaffold.
# ---------------------------------------------------------------------------
t1="$work/consumer1"
mkdir -p "$t1"
out1="$(bash "$scaffold_sh" "$t1" 2>&1)"
scaffold1_rc=$?
check "s1: scaffold exits 0" test "$scaffold1_rc" -eq 0
check "s1: marker file created" test -f "$t1/.claude/.orchestrator-vendor"
check "s1: agents/ vendored" test -f "$t1/.claude/agents/orchestrator.md"
check "s1: commands/ vendored" test -d "$t1/.claude/commands"
check "s1: hooks/ vendored" test -f "$t1/.claude/hooks/hooks.json"
check "s1: skills/ vendored (includes scaffold.sh itself)" test -f "$t1/.claude/skills/setup/scaffold.sh"
check "s1: scripts/ vendored (e.g. gate.sh)" test -f "$t1/.claude/scripts/gate.sh"
check "s1: gate.sh executable bit preserved" test -x "$t1/.claude/scripts/gate.sh"
check "s1: arm-loop.sh present via its OWN managed row" test -f "$t1/.claude/scripts/arm-loop.sh"
check "s1: settings.json created" test -f "$t1/.claude/settings.json"
check "s1: settings.json has no enabledPlugins key" \
  node -e "process.exit('enabledPlugins' in require(process.argv[1]) ? 1 : 0)" "$t1/.claude/settings.json"
check "s1: settings.json has no extraKnownMarketplaces key" \
  node -e "process.exit('extraKnownMarketplaces' in require(process.argv[1]) ? 1 : 0)" "$t1/.claude/settings.json"
check_output "s1: vendor row reported created/up-to-date" "$out1" "runtime harness vendor"

# ---------------------------------------------------------------------------
# Scenario 2: re-running scaffold is idempotent.
# ---------------------------------------------------------------------------
out2="$(bash "$scaffold_sh" "$t1" 2>&1)"
check_output "s2: re-run reports vendor up to date" "$out2" "up to date: runtime harness vendor"
check_output "s2: re-run keeps settings.json (user-owned)" "$out2" "kept:      consumer runtime settings"

# ---------------------------------------------------------------------------
# Scenario 3: sync against an unchanged plugin root -> up to date.
# ---------------------------------------------------------------------------
out3="$(bash "$sync_sh" "$t1" 2>&1)"
rc3=$?
check "s3: sync exits 0" test "$rc3" -eq 0
check_output "s3: vendor row up to date" "$out3" "up to date: .claude/{agents,commands,hooks,scripts,skills}"

# ---------------------------------------------------------------------------
# Scenario 4: plugin marker bumped, no other content change -> restamp.
# ---------------------------------------------------------------------------
plugin_v2="$work/plugin-v2"
cp -a "$repo_root/.claude" "$plugin_v2"
sed -i 's/@orchestrator-managed runtime-vendor v1/@orchestrator-managed runtime-vendor v2/' \
  "$plugin_v2/.orchestrator-vendor"
t4="$work/consumer4"
mkdir -p "$t4"
bash "$scaffold_sh" "$t4" >/dev/null 2>&1
out4="$(bash "$plugin_v2/skills/sync/sync.sh" "$t4" 2>&1)"
check_output "s4: marker-only bump restamps cleanly" "$out4" "restamped:  .claude/{agents,commands,hooks,scripts,skills} v1 -> v2"

# ---------------------------------------------------------------------------
# Scenario 5: plugin marker bumped WITH a real content change -> conflict
# (can't distinguish a legitimate upstream change from a local hand-edit).
# ---------------------------------------------------------------------------
plugin_v3="$work/plugin-v3"
cp -a "$repo_root/.claude" "$plugin_v3"
sed -i 's/@orchestrator-managed runtime-vendor v1/@orchestrator-managed runtime-vendor v2/' \
  "$plugin_v3/.orchestrator-vendor"
echo "<!-- upgraded -->" >> "$plugin_v3/agents/orchestrator.md"
t5="$work/consumer5"
mkdir -p "$t5"
bash "$scaffold_sh" "$t5" >/dev/null 2>&1
out5="$(bash "$plugin_v3/skills/sync/sync.sh" "$t5" 2>&1)"
check_output "s5: content-changing bump flags conflict, not a silent restamp" "$out5" \
  "conflict:   .claude/{agents,commands,hooks,scripts,skills} is v1 (behind v2) AND has local edits"

# ---------------------------------------------------------------------------
# Scenario 6: genuine local edit, same version -> conflict.
# ---------------------------------------------------------------------------
t6="$work/consumer6"
mkdir -p "$t6"
bash "$scaffold_sh" "$t6" >/dev/null 2>&1
echo "<!-- local hack -->" >> "$t6/.claude/agents/orchestrator.md"
out6="$(bash "$sync_sh" "$t6" 2>&1)"
check_output "s6: local edit at same version flags conflict" "$out6" \
  "conflict:   .claude/{agents,commands,hooks,scripts,skills} is marked v1 but content diverges"

# ---------------------------------------------------------------------------
# Scenario 7: local edit ONLY to arm-loop.sh doesn't leak into the vendor row.
# ---------------------------------------------------------------------------
t7="$work/consumer7"
mkdir -p "$t7"
bash "$scaffold_sh" "$t7" >/dev/null 2>&1
echo "# hand edit" >> "$t7/.claude/scripts/arm-loop.sh"
out7="$(bash "$sync_sh" "$t7" 2>&1)"
check_output "s7: arm-loop.sh's OWN managed row flags the conflict" "$out7" \
  "conflict:   .claude/scripts/arm-loop.sh is marked"
check_output "s7: vendor row unaffected by the arm-loop.sh edit" "$out7" \
  "up to date: .claude/{agents,commands,hooks,scripts,skills}"

echo
if [ "$fail" -ne 0 ]; then
  echo "vendor-runtime.test.sh: FAILED"
  exit 1
fi
echo "vendor-runtime.test.sh: all $ok checks passed"
