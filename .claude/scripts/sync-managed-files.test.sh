#!/usr/bin/env bash
# sync-managed-files.test.sh — offline smoke test for scaffold.sh's / sync.sh's
# managed-file ladder AND the stale-vendor detect-and-warn behavior (issue #134).
#
# Issue #134 stopped vendoring the plugin's own runtime harness (`agents/`, `commands/`,
# `hooks/`, `scripts/`, `skills/`) into consumer repos (issue #128's model) — consumer
# sessions now read those straight from the plugin cache (`${CLAUDE_PLUGIN_ROOT}`), and
# `.claude/{agents,commands,hooks,scripts,skills}` are no longer created/managed by
# scaffold.sh/sync.sh at all. This file replaces vendor-runtime.test.sh (which tested the
# now-removed vendoring copy machinery) and asserts:
#   1. fresh scaffold -> the 4 MANAGED_FILES rows are created (feature-fanout.js,
#      pr-loop.service, claude-rc.service, arm-loop.sh), settings.json is created with no
#      enabledPlugins/extraKnownMarketplaces, and NO .claude/{agents,commands,hooks,skills}
#      are created, NO .claude/.orchestrator-vendor marker is written, and .claude/scripts/
#      contains ONLY arm-loop.sh (not the plugin's other generic scripts).
#   2. re-running scaffold -> idempotent (kept/up to date, no errors).
#   3. sync against an unchanged plugin root -> managed files "up to date"; stale-vendor
#      detection reports "none found" (no local vendor leftovers to warn about).
#   4. scaffold.sh restamp (v1 -> v2) of a managed file (feature-fanout.js) actually lands
#      the new content.
#   5. sync.sh restamp (v1 -> v2), marker-only bump -> restamps cleanly.
#   6. sync.sh conflict: installed managed file has local edits, behind shipped version ->
#      flagged conflict, left untouched.
#   7. never-downgrade: scaffold.sh and sync.sh both leave a target whose managed-file
#      marker is newer than shipped completely alone.
#   8. stale-vendor detection: a consumer with LEFTOVER local .claude/scripts (and a legacy
#      `.claude/.orchestrator-vendor` marker) from the old #128 vendoring model gets a
#      "stale-vendor" warning (not a silent restamp, not a delete) — content identical to
#      the plugin's own copy is flagged "safe to delete"; content that diverges is flagged
#      as a possible deliberate local override ("conflict"), and either way the local
#      directory is left completely untouched by sync.sh. The legacy marker file and the
#      systemd-restart migration caveat are both surfaced.
#   9. self-hosting: sync.sh running from INSIDE the target's own .claude (plugin_root ==
#      target_root/.claude, as when this plugin's own repo syncs against itself) never
#      flags its own canonical agents/commands/hooks/scripts/skills as stale-vendor
#      leftovers — no leftover/conflict line, no "verify it's not a leftover" phrasing, no
#      migration caveat — even when a stray legacy marker is also present.
#   10. stray legacy marker with no stale vendor directories present (consumer manually
#       deleted the vendored dirs but left `.claude/.orchestrator-vendor` behind) still
#       gets a detect-and-warn line calling out the leftover marker file — it is not
#       silently ignored just because no directories triggered the main check — and the
#       marker is left on disk untouched.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/sync-managed-files.test.sh
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scaffold_sh="$repo_root/.claude/skills/setup/scaffold.sh"
sync_sh="$repo_root/.claude/skills/sync/sync.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/sync-managed-files-test.XXXXXX")"
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
check_no_output() {
  # $1 = desc, $2 = haystack, $3 = needle that must NOT appear (grep -F)
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    fail=1
    echo "FAIL - $desc (did not expect to find: $needle)"
  else
    ok=$((ok + 1))
    echo "ok - $desc"
  fi
}
build_plugin_fixture() {
  # $1 = destination dir for a trimmed "plugin root" fixture. Copies only the entries
  # scaffold.sh/sync.sh actually read from a plugin root — agents/, commands/, hooks/,
  # scripts/, skills/ (skills/ carries scaffold.sh, sync.sh, and templates/) — instead of
  # the whole live .claude/ tree, which would otherwise drag in .claude/worktrees/ (large),
  # .claude/state/, and settings.local.json into every fixture.
  local dest="$1" entry
  mkdir -p "$dest"
  for entry in agents commands hooks scripts skills; do
    cp -a "$repo_root/.claude/$entry" "$dest/$entry"
  done
}

# ---------------------------------------------------------------------------
# Scenario 1: fresh scaffold — managed files only, no vendoring.
# ---------------------------------------------------------------------------
t1="$work/consumer1"
mkdir -p "$t1"
out1="$(bash "$scaffold_sh" "$t1" 2>&1)"
scaffold1_rc=$?
check "s1: scaffold exits 0" test "$scaffold1_rc" -eq 0
check "s1: feature-fanout.js created" test -f "$t1/.claude/workflows/feature-fanout.js"
check "s1: pr-loop.service created" test -f "$t1/.claude/systemd/pr-loop.service"
check "s1: claude-rc.service created" test -f "$t1/.claude/systemd/claude-rc.service"
check "s1: arm-loop.sh created" test -f "$t1/.claude/scripts/arm-loop.sh"
check "s1: arm-loop.sh executable bit preserved" test -x "$t1/.claude/scripts/arm-loop.sh"
check "s1: settings.json created" test -f "$t1/.claude/settings.json"
check "s1: settings.json has no enabledPlugins key" \
  node -e "process.exit('enabledPlugins' in require(process.argv[1]) ? 1 : 0)" "$t1/.claude/settings.json"
check "s1: settings.json has no extraKnownMarketplaces key" \
  node -e "process.exit('extraKnownMarketplaces' in require(process.argv[1]) ? 1 : 0)" "$t1/.claude/settings.json"
check "s1: NOT vendored — .claude/agents absent" test ! -e "$t1/.claude/agents"
check "s1: NOT vendored — .claude/commands absent" test ! -e "$t1/.claude/commands"
check "s1: NOT vendored — .claude/hooks absent" test ! -e "$t1/.claude/hooks"
check "s1: NOT vendored — .claude/skills absent" test ! -e "$t1/.claude/skills"
check "s1: NOT vendored — .claude/.orchestrator-vendor absent" test ! -e "$t1/.claude/.orchestrator-vendor"
check "s1: .claude/scripts contains ONLY the managed arm-loop.sh (no gate.sh etc.)" \
  bash -c '[ "$(ls -1 "$1")" = "arm-loop.sh" ]' _ "$t1/.claude/scripts"

# ---------------------------------------------------------------------------
# Scenario 2: re-running scaffold is idempotent.
# ---------------------------------------------------------------------------
out2="$(bash "$scaffold_sh" "$t1" 2>&1)"
check_output "s2: re-run keeps settings.json (user-owned)" "$out2" "kept:      consumer runtime settings"
check_output "s2: re-run reports arm-loop.sh up to date" "$out2" "up to date: managed file (.claude/scripts/arm-loop.sh)"

# ---------------------------------------------------------------------------
# Scenario 3: sync against an unchanged plugin root -> up to date, no stale-vendor.
# ---------------------------------------------------------------------------
out3="$(bash "$sync_sh" "$t1" 2>&1)"
rc3=$?
check "s3: sync exits 0" test "$rc3" -eq 0
check_output "s3: feature-fanout.js up to date" "$out3" "up to date: .claude/workflows/feature-fanout.js"
check_output "s3: stale-vendor none found" "$out3" "stale-vendor: none found"

# base_v = the version this checkout's template actually ships today (read dynamically —
# see sync.sh's "single source of truth" comment for why nothing here hardcodes v1/v2).
base_v="$(grep -F -- '@orchestrator-managed feature-fanout v' \
  "$repo_root/.claude/skills/setup/templates/feature-fanout.js" | head -1 | grep -o '[0-9]\+$')"
next_v=$((base_v + 1))
future_v=99

# ---------------------------------------------------------------------------
# Scenario 4: scaffold.sh restamp (base_v -> next_v) of a managed file lands new content.
# ---------------------------------------------------------------------------
t4="$work/consumer4"
mkdir -p "$t4"
bash "$scaffold_sh" "$t4" >/dev/null 2>&1

plugin_v2="$work/plugin-v2"
build_plugin_fixture "$plugin_v2"
sed -i "s/@orchestrator-managed feature-fanout v$base_v/@orchestrator-managed feature-fanout v$next_v/" \
  "$plugin_v2/skills/setup/templates/feature-fanout.js"
printf '\n// bumped content\n' >> "$plugin_v2/skills/setup/templates/feature-fanout.js"

out4="$(bash "$plugin_v2/skills/setup/scaffold.sh" "$t4" 2>&1)"
check_output "s4: restamp reported base_v -> next_v" "$out4" \
  "restamped: managed file (.claude/workflows/feature-fanout.js) v$base_v -> v$next_v"
check "s4: feature-fanout.js content actually refreshed (not stale)" \
  grep -q -- "bumped content" "$t4/.claude/workflows/feature-fanout.js"

# ---------------------------------------------------------------------------
# Scenario 5: sync.sh restamp, marker-only bump -> restamps cleanly.
# ---------------------------------------------------------------------------
plugin_v2b="$work/plugin-v2b"
build_plugin_fixture "$plugin_v2b"
sed -i "s/@orchestrator-managed feature-fanout v$base_v/@orchestrator-managed feature-fanout v$next_v/" \
  "$plugin_v2b/skills/setup/templates/feature-fanout.js"
t5="$work/consumer5"
mkdir -p "$t5"
bash "$scaffold_sh" "$t5" >/dev/null 2>&1
out5="$(bash "$plugin_v2b/skills/sync/sync.sh" "$t5" 2>&1)"
check_output "s5: marker-only bump restamps cleanly" "$out5" \
  "restamped:  .claude/workflows/feature-fanout.js v$base_v -> v$next_v"

# ---------------------------------------------------------------------------
# Scenario 6: sync.sh conflict — local edit + behind shipped version.
# ---------------------------------------------------------------------------
t6="$work/consumer6"
mkdir -p "$t6"
bash "$scaffold_sh" "$t6" >/dev/null 2>&1
echo "// local hack" >> "$t6/.claude/workflows/feature-fanout.js"
out6="$(bash "$plugin_v2b/skills/sync/sync.sh" "$t6" 2>&1)"
check_output "s6: local edit + behind flags conflict" "$out6" \
  "conflict:   .claude/workflows/feature-fanout.js is v$base_v (behind v$next_v) AND has local edits"
check "s6: local edit persists — file untouched by sync" \
  grep -qF -- "// local hack" "$t6/.claude/workflows/feature-fanout.js"

# ---------------------------------------------------------------------------
# Scenario 7: never-downgrade — a marker newer than shipped is left alone by both scripts.
# ---------------------------------------------------------------------------
t7="$work/consumer7"
mkdir -p "$t7"
bash "$scaffold_sh" "$t7" >/dev/null 2>&1
sed -i "s/@orchestrator-managed feature-fanout v$base_v/@orchestrator-managed feature-fanout v$future_v/" \
  "$t7/.claude/workflows/feature-fanout.js"
snapshot7="$work/snapshot7"
cp -a "$t7/.claude/workflows/feature-fanout.js" "$snapshot7"
out7a="$(bash "$scaffold_sh" "$t7" 2>&1)"
check_output "s7: scaffold keeps a newer-than-shipped marker" "$out7a" \
  "is v$future_v, newer than this installer's v$base_v"
out7b="$(bash "$sync_sh" "$t7" 2>&1)"
check_output "s7: sync keeps a newer-than-shipped marker" "$out7b" \
  "is v$future_v, newer than this plugin's v$base_v"
check "s7: feature-fanout.js byte-identical after both runs (no downgrade)" \
  diff -q "$snapshot7" "$t7/.claude/workflows/feature-fanout.js"

# ---------------------------------------------------------------------------
# Scenario 8: stale-vendor detection (issue #134) — leftover from the old #128 model.
# ---------------------------------------------------------------------------
plugin_fixture="$work/plugin-fixture"
build_plugin_fixture "$plugin_fixture"

# 8a. Local .claude/scripts identical to the plugin's own -> "safe to delete", no marker.
t8a="$work/consumer8a"
mkdir -p "$t8a"
bash "$scaffold_sh" "$t8a" >/dev/null 2>&1
cp -a "$plugin_fixture/scripts/." "$t8a/.claude/scripts/"  # re-vendor scripts/ by hand, simulating a stale #128-era install
out8a="$(bash "$plugin_fixture/skills/sync/sync.sh" "$t8a" 2>&1)"
check_output "s8a: identical local scripts/ flagged stale + safe to delete" "$out8a" \
  "stale-vendor: .claude/scripts — matches the plugin's shipped copy byte-for-byte"
check_output "s8a: safe-to-delete wording present" "$out8a" "safe to delete"
check "s8a: local scripts/ left completely untouched (sync never deletes)" \
  test -f "$t8a/.claude/scripts/gate.sh"

# 8b. Local .claude/scripts diverges from the plugin's own -> "conflict" (possible override).
t8b="$work/consumer8b"
mkdir -p "$t8b"
bash "$scaffold_sh" "$t8b" >/dev/null 2>&1
cp -a "$plugin_fixture/scripts/." "$t8b/.claude/scripts/"
echo "# local override" >> "$t8b/.claude/scripts/gate.sh"
out8b="$(bash "$plugin_fixture/skills/sync/sync.sh" "$t8b" 2>&1)"
check_output "s8b: diverging local scripts/ flagged as a possible override" "$out8b" \
  "stale-vendor conflict: .claude/scripts — diverges from the plugin's shipped copy"
check "s8b: local override persists — untouched by sync" \
  grep -qF -- "# local override" "$t8b/.claude/scripts/gate.sh"

# 8c. Legacy .orchestrator-vendor marker present -> extra legacy-marker + migration-caveat lines.
t8c="$work/consumer8c"
mkdir -p "$t8c"
bash "$scaffold_sh" "$t8c" >/dev/null 2>&1
cp -a "$plugin_fixture/scripts/." "$t8c/.claude/scripts/"
printf '# @orchestrator-managed runtime-vendor v1\n' > "$t8c/.claude/.orchestrator-vendor"
out8c="$(bash "$plugin_fixture/skills/sync/sync.sh" "$t8c" 2>&1)"
check_output "s8c: legacy vendor marker called out" "$out8c" \
  "stale-vendor: .claude/.orchestrator-vendor — legacy vendor marker"
check_output "s8c: migration caveat (systemd restart) surfaced" "$out8c" "MIGRATION CAVEAT"
check_output "s8c: migration caveat mentions restarting the unit" "$out8c" "systemctl --user restart"

# 8d. No local vendored dirs at all -> "none found", no false positives.
out8d="$(bash "$plugin_fixture/skills/sync/sync.sh" "$t1" 2>&1)"
check_output "s8d: no local vendor leftovers -> none found" "$out8d" "stale-vendor: none found"

# ---------------------------------------------------------------------------
# Scenario 9: self-hosting — sync.sh running from INSIDE the target's own .claude
# (plugin_root == target_root/.claude) must never flag the plugin's own canonical
# agents/commands/hooks/scripts/skills as stale-vendor leftovers (issue #134 review
# finding: this used to warn on the plugin repo's own tree and tell the operator to
# reconcile/delete it, plus print the systemd migration caveat — both wrong in self-host
# mode). Arrange the fixture so sync.sh's own script_dir/../.. resolves back to the
# target root: copy the plugin fixture straight into $t9/.claude so
# $t9/.claude/skills/sync/sync.sh's plugin_root is $t9/.claude itself.
# ---------------------------------------------------------------------------
t9="$work/consumer9"
mkdir -p "$t9/.claude"
for entry in agents commands hooks scripts skills; do
  cp -a "$plugin_fixture/$entry" "$t9/.claude/$entry"
done

# 9a. Self-hosting, no legacy marker -> completely silent: no stale-vendor leftover/
# conflict lines, no migration caveat, just "none found".
out9a="$(bash "$t9/.claude/skills/sync/sync.sh" "$t9" 2>&1)"
rc9a=$?
check "s9a: self-hosting sync exits 0" test "$rc9a" -eq 0
check_output "s9a: self-hosting reports none found" "$out9a" "stale-vendor: none found"
check_no_output "s9a: no stale-vendor leftover warning for the plugin's own agents dir" "$out9a" "stale-vendor: .claude/agents"
check_no_output "s9a: no stale-vendor leftover warning for the plugin's own scripts dir" "$out9a" "stale-vendor: .claude/scripts"
check_no_output "s9a: no stale-vendor conflict warning" "$out9a" "stale-vendor conflict"
check_no_output "s9a: no 'verify it's not just a leftover' phrasing" "$out9a" "verify it's not just a leftover"
check_no_output "s9a: no migration caveat" "$out9a" "MIGRATION CAVEAT"
check_no_output "s9a: no reconcile-and-remove-marker instruction" "$out9a" "reconciled the flagged directories"

# 9b. Self-hosting WITH a stray legacy marker present -> still completely silent (the
# self-hosting short-circuit takes priority over the stray-marker check from scenario 10).
printf '# @orchestrator-managed runtime-vendor v1\n' > "$t9/.claude/.orchestrator-vendor"
out9b="$(bash "$t9/.claude/skills/sync/sync.sh" "$t9" 2>&1)"
check_output "s9b: self-hosting + stray marker still reports none found" "$out9b" "stale-vendor: none found"
check_no_output "s9b: self-hosting + stray marker emits no legacy-marker warning" "$out9b" "legacy vendor marker"
check_no_output "s9b: self-hosting + stray marker emits no migration caveat" "$out9b" "MIGRATION CAVEAT"
rm -f "$t9/.claude/.orchestrator-vendor"

# ---------------------------------------------------------------------------
# Scenario 10: stray legacy marker with NO stale vendor directories present (a consumer
# who deleted the vendored dirs by hand but left `.claude/.orchestrator-vendor` behind).
# Previously this got no warning at all since the legacy-marker check only ran when a
# stale directory was also found; it must now warn about the stray marker on its own,
# while never deleting it and never printing the full-leftover migration caveat (that
# caveat is reserved for when there's actually something to migrate away from).
# ---------------------------------------------------------------------------
t10="$work/consumer10"
mkdir -p "$t10"
bash "$scaffold_sh" "$t10" >/dev/null 2>&1
printf '# @orchestrator-managed runtime-vendor v1\n' > "$t10/.claude/.orchestrator-vendor"
out10="$(bash "$sync_sh" "$t10" 2>&1)"
rc10=$?
check "s10: sync exits 0" test "$rc10" -eq 0
check_output "s10: stray marker warns even with no stale dirs present" "$out10" \
  "legacy vendor marker from the old #128 model found, but no stale vendor directories are present"
check_output "s10: still reports none found for the directories themselves" "$out10" "stale-vendor: none found"
check_no_output "s10: no migration caveat for a bare stray marker (nothing to migrate)" "$out10" "MIGRATION CAVEAT"
check "s10: marker file left untouched — sync never deletes it" test -f "$t10/.claude/.orchestrator-vendor"

echo
if [ "$fail" -ne 0 ]; then
  echo "sync-managed-files.test.sh: FAILED"
  exit 1
fi
echo "sync-managed-files.test.sh: all $ok checks passed"
