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
#   4. scaffold.sh restamp (v1 -> v2) with a REAL content change inside a
#      vendored subdirectory (skills/setup/) -> proves the copy is idempotent
#      AND refreshing: no duplicate nests (.claude/skills/setup/setup,
#      .claude/skills/sync/sync — the reported bug) and the subdir file's
#      content actually lands at the new version instead of staying stale.
#      arm-loop.sh's own managed copy must also survive untouched.
#   5. sync.sh restamp (v1 -> v2), marker-only bump with no other content
#      change -> restamped cleanly (no false conflict) AND no nesting.
#   6. sync against a plugin root whose marker was bumped WITH a real
#      content change -> conflict (installed has no local edits, but the
#      script can't tell a legitimate upstream change from a hand-edit —
#      same conservative behavior as every other managed row); the
#      installed file must NOT have picked up the new upstream bytes.
#   7. sync with a genuine local edit to a vendored file (same version) ->
#      conflict, and the local edit marker is still readable back out of
#      the file afterward (proves it was genuinely left untouched, not
#      just that the log line said so).
#   8. sync with a local edit ONLY to arm-loop.sh -> the runtime-vendor row
#      stays "up to date" (excluded from its diff), while arm-loop.sh's OWN
#      managed row reports the conflict — proves the two mechanisms don't
#      double-manage the same file; the hand edit is still present in
#      arm-loop.sh afterward.
#   9. never-downgrade: a target marker newer than the plugin's shipped
#      version (v99) is left byte-for-byte untouched by scaffold.sh.
#  10. never-downgrade: same, for sync.sh.
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
trees_identical() {
  # $1, $2 = two directory trees. True iff a recursive diff finds no differences at all
  # (used by the never-downgrade scenarios to prove a "kept, newer" verdict really left
  # the whole vendored tree byte-for-byte alone, not just logged the right line).
  diff -rq "$1" "$2" >/dev/null 2>&1
}
build_plugin_fixture() {
  # $1 = destination dir for a trimmed "plugin root" fixture. Copies only the entries
  # scaffold.sh/sync.sh's vendor step actually reads from a plugin root — agents/,
  # commands/, hooks/, scripts/, skills/, .orchestrator-vendor — instead of the whole live
  # .claude/ tree, which would otherwise drag in .claude/worktrees/ (large),
  # .claude/state/, and settings.local.json into every fixture.
  local dest="$1" entry
  mkdir -p "$dest"
  for entry in agents commands hooks scripts skills .orchestrator-vendor; do
    cp -a "$repo_root/.claude/$entry" "$dest/$entry"
  done
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
check "s2: still no nested skills/setup/setup after idempotent re-run" test ! -e "$t1/.claude/skills/setup/setup"
check "s2: still no nested skills/sync/sync after idempotent re-run" test ! -e "$t1/.claude/skills/sync/sync"

# ---------------------------------------------------------------------------
# Scenario 3: sync against an unchanged plugin root -> up to date.
# ---------------------------------------------------------------------------
out3="$(bash "$sync_sh" "$t1" 2>&1)"
rc3=$?
check "s3: sync exits 0" test "$rc3" -eq 0
check_output "s3: vendor row up to date" "$out3" "up to date: .claude/{agents,commands,hooks,scripts,skills}"

# ---------------------------------------------------------------------------
# Scenario 4: scaffold.sh restamp (v1 -> v2) with a REAL content change inside
# a vendored subdirectory -> no nesting, content genuinely refreshed. This is
# the direct regression test for the reported bug: the old `cp -a "$entry"
# "$dst/$base"` form nests the source dir INTO an already-existing destination
# (producing .claude/skills/setup/setup) instead of refreshing it in place, so
# the top-level file never actually picks up the new content.
# ---------------------------------------------------------------------------
t4="$work/consumer4"
mkdir -p "$t4"
bash "$scaffold_sh" "$t4" >/dev/null 2>&1

plugin_v2content="$work/plugin-v2-content"
build_plugin_fixture "$plugin_v2content"
sed -i 's/@orchestrator-managed runtime-vendor v1/@orchestrator-managed runtime-vendor v2/' \
  "$plugin_v2content/.orchestrator-vendor"
printf '\n<!-- v2 skill content -->\n' >> "$plugin_v2content/skills/setup/SKILL.md"

out4="$(bash "$plugin_v2content/skills/setup/scaffold.sh" "$t4" 2>&1)"
check_output "s4: restamp reported v1 -> v2" "$out4" "restamped: runtime harness vendor"
check "s4: no nested .claude/skills/setup/setup (nesting bug)" test ! -e "$t4/.claude/skills/setup/setup"
check "s4: no nested .claude/skills/sync/sync (nesting bug)" test ! -e "$t4/.claude/skills/sync/sync"
check "s4: skills/setup/SKILL.md content actually refreshed to v2 (not stale)" \
  grep -q -- "v2 skill content" "$t4/.claude/skills/setup/SKILL.md"
check "s4: arm-loop.sh not vendored/overwritten by the tree copy" \
  grep -q -- "@orchestrator-managed arm-loop v" "$t4/.claude/scripts/arm-loop.sh"

# ---------------------------------------------------------------------------
# Scenario 5: sync.sh restamp, marker-only bump with NO other content change
# -> restamps cleanly (no false conflict) AND without nesting.
# ---------------------------------------------------------------------------
plugin_v2="$work/plugin-v2"
build_plugin_fixture "$plugin_v2"
sed -i 's/@orchestrator-managed runtime-vendor v1/@orchestrator-managed runtime-vendor v2/' \
  "$plugin_v2/.orchestrator-vendor"
t5="$work/consumer5"
mkdir -p "$t5"
bash "$scaffold_sh" "$t5" >/dev/null 2>&1
out5="$(bash "$plugin_v2/skills/sync/sync.sh" "$t5" 2>&1)"
check_output "s5: marker-only bump restamps cleanly" "$out5" "restamped:  .claude/{agents,commands,hooks,scripts,skills} v1 -> v2"
check "s5: no nested .claude/skills/setup/setup after sync restamp" test ! -e "$t5/.claude/skills/setup/setup"
check "s5: no nested .claude/skills/sync/sync after sync restamp" test ! -e "$t5/.claude/skills/sync/sync"

# ---------------------------------------------------------------------------
# Scenario 6: plugin marker bumped WITH a real content change -> conflict
# (can't distinguish a legitimate upstream change from a local hand-edit).
# The installed file must NOT have picked up the new upstream bytes.
# ---------------------------------------------------------------------------
plugin_v3="$work/plugin-v3"
build_plugin_fixture "$plugin_v3"
sed -i 's/@orchestrator-managed runtime-vendor v1/@orchestrator-managed runtime-vendor v2/' \
  "$plugin_v3/.orchestrator-vendor"
echo "<!-- upgraded -->" >> "$plugin_v3/agents/orchestrator.md"
t6="$work/consumer6"
mkdir -p "$t6"
bash "$scaffold_sh" "$t6" >/dev/null 2>&1
out6="$(bash "$plugin_v3/skills/sync/sync.sh" "$t6" 2>&1)"
check_output "s6: content-changing bump flags conflict, not a silent restamp" "$out6" \
  "conflict:   .claude/{agents,commands,hooks,scripts,skills} is v1 (behind v2) AND has local edits"
check "s6: installed file did not silently pick up the new upstream bytes" \
  bash -c '! grep -qF -- "<!-- upgraded -->" "$1"' _ "$t6/.claude/agents/orchestrator.md"

# ---------------------------------------------------------------------------
# Scenario 7: genuine local edit, same version -> conflict, and the edit is
# still readable back out of the file afterward (proves the tree was
# genuinely left untouched, not just that the log line said so).
# ---------------------------------------------------------------------------
t7="$work/consumer7"
mkdir -p "$t7"
bash "$scaffold_sh" "$t7" >/dev/null 2>&1
echo "<!-- local hack -->" >> "$t7/.claude/agents/orchestrator.md"
out7="$(bash "$sync_sh" "$t7" 2>&1)"
check_output "s7: local edit at same version flags conflict" "$out7" \
  "conflict:   .claude/{agents,commands,hooks,scripts,skills} is marked v1 but content diverges"
check "s7: local marker persists — file genuinely untouched by sync" \
  grep -qF -- "<!-- local hack -->" "$t7/.claude/agents/orchestrator.md"

# ---------------------------------------------------------------------------
# Scenario 8: local edit ONLY to arm-loop.sh doesn't leak into the vendor row,
# and the hand edit is still present afterward (neither mechanism touched it).
# ---------------------------------------------------------------------------
t8="$work/consumer8"
mkdir -p "$t8"
bash "$scaffold_sh" "$t8" >/dev/null 2>&1
echo "# hand edit" >> "$t8/.claude/scripts/arm-loop.sh"
out8="$(bash "$sync_sh" "$t8" 2>&1)"
check_output "s8: arm-loop.sh's OWN managed row flags the conflict" "$out8" \
  "conflict:   .claude/scripts/arm-loop.sh is marked"
check_output "s8: vendor row unaffected by the arm-loop.sh edit" "$out8" \
  "up to date: .claude/{agents,commands,hooks,scripts,skills}"
check "s8: hand edit persists in arm-loop.sh — untouched by either mechanism" \
  grep -qF -- "# hand edit" "$t8/.claude/scripts/arm-loop.sh"

# ---------------------------------------------------------------------------
# Scenario 9: never-downgrade — scaffold.sh must not touch a target whose
# vendor marker is newer (v99) than what this installer ships.
# ---------------------------------------------------------------------------
t9="$work/consumer9"
mkdir -p "$t9"
bash "$scaffold_sh" "$t9" >/dev/null 2>&1
sed -i 's/@orchestrator-managed runtime-vendor v1/@orchestrator-managed runtime-vendor v99/' \
  "$t9/.claude/.orchestrator-vendor"
snapshot9="$work/snapshot9"
cp -a "$t9/.claude" "$snapshot9"
out9="$(bash "$scaffold_sh" "$t9" 2>&1)"
check_output "s9: scaffold keeps a newer-than-shipped marker" "$out9" \
  "is v99, newer than this installer's v1"
check "s9: vendored tree byte-identical after run (no downgrade)" \
  trees_identical "$snapshot9" "$t9/.claude"

# ---------------------------------------------------------------------------
# Scenario 10: never-downgrade — sync.sh must not touch a target whose vendor
# marker is newer (v99) than what this plugin ships.
# ---------------------------------------------------------------------------
t10="$work/consumer10"
mkdir -p "$t10"
bash "$scaffold_sh" "$t10" >/dev/null 2>&1
sed -i 's/@orchestrator-managed runtime-vendor v1/@orchestrator-managed runtime-vendor v99/' \
  "$t10/.claude/.orchestrator-vendor"
snapshot10="$work/snapshot10"
cp -a "$t10/.claude" "$snapshot10"
out10="$(bash "$sync_sh" "$t10" 2>&1)"
check_output "s10: sync keeps a newer-than-shipped marker" "$out10" \
  "is v99, newer than this plugin's v1"
check "s10: vendored tree byte-identical after run (no downgrade)" \
  trees_identical "$snapshot10" "$t10/.claude"

echo
if [ "$fail" -ne 0 ]; then
  echo "vendor-runtime.test.sh: FAILED"
  exit 1
fi
echo "vendor-runtime.test.sh: all $ok checks passed"
