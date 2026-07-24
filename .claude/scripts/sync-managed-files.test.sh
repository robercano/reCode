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
# Issue #141 ("sync v2") adds four more offline DETECT-AND-REPORT checks to sync.sh —
# scenarios 11-16 cover them:
#   11. environment check: .env/GH_BOT_TOKEN presence (found / missing key / no .env at
#       all — and the token VALUE itself is never echoed into the output) and installed
#       plugin version vs. the issue #136 floor (>= at floor ok, above floor ok, < too-old,
#       a malformed non-numeric component degrades to "verify manually" rather than a wrong
#       compare, and a plugin.json missing the "version" field entirely degrades to "could
#       not parse" — all compared off synthetic `.claude-plugin/plugin.json` fixtures).
#   12. missing-labels check: expected `module:<name>` labels + `needs-human` are derived
#       from the TARGET's `.claude/gates.json` `modules[]` and printed as exact
#       `bot-gh.sh label create` advisory commands (never run); no adapter present
#       degrades to "cannot derive labels" rather than a crash. Both scenario 12 and 12b
#       pin `GATES_FILE` to their own fixture's adapter path (absolute) so the assertions
#       hold regardless of an ambient `GATES_FILE` leaking in from the caller's environment.
#   13. observability-plumbing check: `.claude/state/{worker-tools,events}.jsonl` reported
#       absent / present-but-empty / present-with-activity (both files, not just
#       worker-tools.jsonl), referencing issue #137 for the gap case, without ever
#       attempting to create/fix those files.
#   14. deploy-lag check: `.claude/state/loop-runs.log` absent / empty / a recent ts= / an
#       old ts= / a last line with no parseable `ts=` field at all (must still exit 0 and
#       print the "could not parse" fallback, not abort the whole script under `set
#       -euo pipefail`) all produce report-only guidance without sync.sh touching the file
#       or any unit — and, since the ledger only ever logs FINISHED runs (issue #141 review
#       round), neither a recent nor an old ts= is ever read as an "active" or "safe to
#       restart" verdict; both point the operator at an independent liveness check instead.
#   15. self-hosting quiets the remediation-flavored advisories (module/needs-human label
#       creation) while still running the plain informational reads (env, observability,
#       deploy-lag) with no crash and exit 0 — mirrors the self_hosting short-circuit
#       scenario 9 already asserts for stale-vendor. Pins `GATES_FILE` to its own fixture's
#       adapter for the same ambient-env-isolation reason as scenario 12.
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
build_plugin_fixture_with_version() {
  # $1 = destination dir, $2 = version string to stamp into a synthetic
  # .claude-plugin/plugin.json (issue #141's environment check reads plugin_root's
  # .claude-plugin/plugin.json "version" field — real plugin roots always carry one,
  # build_plugin_fixture alone does not, so tests that need a specific version use this).
  local dest="$1" version="$2"
  build_plugin_fixture "$dest"
  mkdir -p "$dest/.claude-plugin"
  printf '{\n  "name": "orchestrator",\n  "version": "%s"\n}\n' "$version" >"$dest/.claude-plugin/plugin.json"
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

# ---------------------------------------------------------------------------
# Scenario 11: environment check (issue #141 item 2) — .env/GH_BOT_TOKEN + plugin
# version, both offline. Never echoes the token VALUE.
# ---------------------------------------------------------------------------
t11="$work/consumer11"
mkdir -p "$t11/.claude"
plugin_v_ok="$work/plugin-v-ok"
build_plugin_fixture_with_version "$plugin_v_ok" "0.2.2"
plugin_v_old="$work/plugin-v-old"
build_plugin_fixture_with_version "$plugin_v_old" "0.2.1"

out11a="$(bash "$plugin_v_ok/skills/sync/sync.sh" "$t11" 2>&1)"
check_output "s11a: no .env reported" "$out11a" "env: .env — not found at $t11/.env"
check_output "s11a: version at floor reported OK" "$out11a" "env: plugin version — v0.2.2 >= required v0.2.2"

printf 'GH_BOT_TOKEN=super-secret-value-should-never-appear\n' >"$t11/.env"
out11b="$(bash "$plugin_v_ok/skills/sync/sync.sh" "$t11" 2>&1)"
check_output "s11b: GH_BOT_TOKEN= key found" "$out11b" "env: .env — GH_BOT_TOKEN= assignment found"
check_no_output "s11b: token VALUE never echoed" "$out11b" "super-secret-value-should-never-appear"

printf 'SOME_OTHER_VAR=1\n' >"$t11/.env"
out11c="$(bash "$plugin_v_ok/skills/sync/sync.sh" "$t11" 2>&1)"
check_output "s11c: .env present but no GH_BOT_TOKEN key" "$out11c" "no GH_BOT_TOKEN= assignment found"

out11d="$(bash "$plugin_v_old/skills/sync/sync.sh" "$t11" 2>&1)"
check_output "s11d: below-floor plugin version flagged" "$out11d" \
  "env: plugin version — v0.2.1 is BELOW required v0.2.2"

check_output "s11: live bot-identity advisory printed, not run" "$out11a" \
  "ADVISORY (live, network — not run by sync.sh) — verify bot identity + repo access: bash \${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh api user --jq .login"

# 11e. Above-floor plugin version (e.g. a later release than the #136 MIN_PLUGIN_VERSION
# floor) is reported OK too, not just the exact-floor case s11a already covers.
plugin_v_above="$work/plugin-v-above"
build_plugin_fixture_with_version "$plugin_v_above" "0.3.0"
out11e="$(bash "$plugin_v_above/skills/sync/sync.sh" "$t11" 2>&1)"
check_output "s11e: above-floor plugin version reported OK" "$out11e" \
  "env: plugin version — v0.3.0 >= required v0.2.2"

# 11f. Malformed version field (non-numeric component) degrades to "verify manually"
# rather than a wrong lexical/numeric compare (version_ge's return-2 "unparseable" path).
plugin_v_malformed="$work/plugin-v-malformed"
build_plugin_fixture "$plugin_v_malformed"
mkdir -p "$plugin_v_malformed/.claude-plugin"
printf '{\n  "name": "orchestrator",\n  "version": "0.2.2-beta"\n}\n' \
  >"$plugin_v_malformed/.claude-plugin/plugin.json"
out11f="$(bash "$plugin_v_malformed/skills/sync/sync.sh" "$t11" 2>&1)"
check_output "s11f: malformed version component -> verify manually, no crash" "$out11f" \
  "could not compare \"0.2.2-beta\" against \"0.2.2\""

# 11g. Missing "version" field in plugin.json entirely -> "could not parse" message.
plugin_v_missing="$work/plugin-v-missing"
build_plugin_fixture "$plugin_v_missing"
mkdir -p "$plugin_v_missing/.claude-plugin"
printf '{\n  "name": "orchestrator"\n}\n' >"$plugin_v_missing/.claude-plugin/plugin.json"
out11g="$(bash "$plugin_v_missing/skills/sync/sync.sh" "$t11" 2>&1)"
check_output "s11g: missing version field -> could not parse message, no crash" "$out11g" \
  "env: plugin version — could not parse a \"version\" field from"

# 11h. Shorter version string than the floor ("0.2" vs required "0.2.2") -- version_ge's
# missing-component-defaults-to-0 path -- must compare as BELOW, not "unparseable".
plugin_v_short="$work/plugin-v-short"
build_plugin_fixture_with_version "$plugin_v_short" "0.2"
out11h="$(bash "$plugin_v_short/skills/sync/sync.sh" "$t11" 2>&1)"
check_output "s11h: shorter version below floor -> BELOW, not unparseable" "$out11h" \
  "env: plugin version — v0.2 is BELOW required v0.2.2"

# 11i. Longer version string than the floor ("0.2.2.1" vs required "0.2.2") -- the extra
# trailing component must compare as >= 0, not push the comparison the wrong way.
plugin_v_long="$work/plugin-v-long"
build_plugin_fixture_with_version "$plugin_v_long" "0.2.2.1"
out11i="$(bash "$plugin_v_long/skills/sync/sync.sh" "$t11" 2>&1)"
check_output "s11i: longer version at floor -> OK, not BELOW" "$out11i" \
  "env: plugin version — v0.2.2.1 >= required v0.2.2"

# ---------------------------------------------------------------------------
# Scenario 12: missing-labels check (issue #141 item 3) — derived from the target's
# .claude/gates.json modules[], printed as exact bot-gh.sh advisory commands.
# ---------------------------------------------------------------------------
t12="$work/consumer12"
mkdir -p "$t12/.claude"
cat >"$t12/.claude/gates.json" <<'JSON'
{"project":{"name":"x"},"modules":[{"name":"foo","description":"Foo module"},{"name":"bar","description":"Bar module"}],"gates":{}}
JSON
# Pin GATES_FILE to this fixture's OWN adapter (absolute path — sync.sh/derive_module_labels
# takes an absolute GATES_FILE as-is, same convention as gate.sh, see gate.test.sh's
# write_gates_file/run_gate). Scenarios 12/12b/15 must be deterministic regardless of an
# ambient GATES_FILE leaking in from the caller's environment (e.g. the self-hosted test
# gate runs *.test.sh with GATES_FILE=.claude/self/gates.json already exported) — without
# this pin, derive_module_labels would resolve the ambient adapter relative to $t12 instead
# of this fixture's own gates.json and silently fail to derive any labels.
out12="$(GATES_FILE="$t12/.claude/gates.json" bash "$plugin_v_ok/skills/sync/sync.sh" "$t12" 2>&1)"
check_output "s12: module:foo label advisory derived" "$out12" \
  'bot-gh.sh label create "module:foo" --description "Foo module" --force'
check_output "s12: module:bar label advisory derived" "$out12" \
  'bot-gh.sh label create "module:bar" --description "Bar module" --force'
check_output "s12: needs-human label advisory with color" "$out12" \
  'bot-gh.sh label create "needs-human" --description "Loop is blocked on owner judgment -- see the issue/PR body/comments" --color b60205 --force'

# Real regression guard (not just string-matching the printed advisory): stub `bot-gh.sh`
# and `gh` so any invocation -- accidental or otherwise -- leaves evidence in a marker
# file, then assert a fresh sync.sh run over the SAME fixture never touched either stub.
# Today the label-create commands are pure printed text (never executed), but this is what
# actually proves "advisory only, no network call" instead of just re-asserting it.
# Covers the two realistic regression shapes: (a) a bare `bot-gh.sh`/`gh` invocation
# resolved via PATH lookup, and (b) the EXACT `${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/
# bot-gh.sh` construction already sitting in the advisory string -- if that were ever
# copy-pasted into a real `bash ...` call, it would resolve under whatever
# CLAUDE_PLUGIN_ROOT is set to, so the stub is ALSO placed at that path and
# CLAUDE_PLUGIN_ROOT pointed at it (sync.sh itself never reads this var -- it derives its
# own plugin_root from $script_dir -- so exporting it here cannot mask a real regression).
label_stub_dir="$work/label-stub-bin"
mkdir -p "$label_stub_dir"
label_stub_root="$work/label-stub-root"
mkdir -p "$label_stub_root/scripts"
label_stub_marker="$work/label-stub-called"
rm -f "$label_stub_marker"
for stub_path in "$label_stub_dir/bot-gh.sh" "$label_stub_dir/gh" "$label_stub_root/scripts/bot-gh.sh"; do
  cat >"$stub_path" <<STUB
#!/usr/bin/env bash
echo "\$0 \$*" >>"$label_stub_marker"
exit 0
STUB
  chmod +x "$stub_path"
done
PATH="$label_stub_dir:$PATH" CLAUDE_PLUGIN_ROOT="$label_stub_root" GATES_FILE="$t12/.claude/gates.json" \
  bash "$plugin_v_ok/skills/sync/sync.sh" "$t12" >/dev/null 2>&1
check "s12: no labels actually created (advisory only, bot-gh.sh/gh stub never invoked)" \
  test ! -f "$label_stub_marker"

t12b="$work/consumer12b"
mkdir -p "$t12b"
# Pin GATES_FILE to a path that deliberately doesn't exist under this fixture, so "no
# adapter found" is asserted regardless of what the ambient environment's GATES_FILE points
# at (same isolation rationale as scenario 12 above).
out12b="$(GATES_FILE="$t12b/.claude/gates.json" bash "$plugin_v_ok/skills/sync/sync.sh" "$t12b" 2>&1)"
check_output "s12b: no adapter -> cannot derive labels, no crash" "$out12b" \
  "labels: cannot derive labels — no adapter found"

# ---------------------------------------------------------------------------
# Scenario 13: observability-plumbing check (issue #141 item 4, cf. #137) — detect only,
# absent / empty / present-with-activity, never creates the files itself.
# ---------------------------------------------------------------------------
t13="$work/consumer13"
mkdir -p "$t13/.claude/state"
out13a="$(bash "$plugin_v_ok/skills/sync/sync.sh" "$t13" 2>&1)"
check_output "s13a: worker-tools.jsonl absent -> issue #137 gap called out" "$out13a" \
  "observability: .claude/state/worker-tools.jsonl — absent; this is the observability gap tracked by issue #137"
check_output "s13a: events.jsonl absent -> issue #137 gap called out" "$out13a" \
  "observability: .claude/state/events.jsonl — absent; this is the observability gap tracked by issue #137"

: >"$t13/.claude/state/worker-tools.jsonl"
out13b="$(bash "$plugin_v_ok/skills/sync/sync.sh" "$t13" 2>&1)"
check_output "s13b: present-but-empty reported distinctly" "$out13b" \
  "observability: .claude/state/worker-tools.jsonl — present but empty"

printf '{"tool":"Read"}\n' >>"$t13/.claude/state/worker-tools.jsonl"
out13c="$(bash "$plugin_v_ok/skills/sync/sync.sh" "$t13" 2>&1)"
check_output "s13c: present-with-activity reported distinctly" "$out13c" \
  "observability: .claude/state/worker-tools.jsonl — present, 1 line(s)"
check "s13: sync never creates the observability state files itself" \
  test ! -e "$t13/.claude/state/events.jsonl"

# 13d/13e. events.jsonl gets the same present-but-empty / present-with-activity coverage
# worker-tools.jsonl already has above — the loop over both files in
# check_observability_plumbing is otherwise only exercised via the "absent" branch (s13a).
: >"$t13/.claude/state/events.jsonl"
out13d="$(bash "$plugin_v_ok/skills/sync/sync.sh" "$t13" 2>&1)"
check_output "s13d: events.jsonl present-but-empty reported distinctly" "$out13d" \
  "observability: .claude/state/events.jsonl — present but empty"

printf '{"event":"phase-change"}\n' >>"$t13/.claude/state/events.jsonl"
out13e="$(bash "$plugin_v_ok/skills/sync/sync.sh" "$t13" 2>&1)"
check_output "s13e: events.jsonl present-with-activity reported distinctly" "$out13e" \
  "observability: .claude/state/events.jsonl — present, 1 line(s)"

# ---------------------------------------------------------------------------
# Scenario 14: deploy-lag check (issue #141 item 5) — .claude/state/loop-runs.log
# absent / empty / recent (looks active) / old (looks idle, safe to restart).
# ---------------------------------------------------------------------------
t14="$work/consumer14"
mkdir -p "$t14/.claude/state"
out14a="$(bash "$plugin_v_ok/skills/sync/sync.sh" "$t14" 2>&1)"
check_output "s14a: no loop-runs.log -> not found, usually means never armed" "$out14a" \
  "deploy-lag: .claude/state/loop-runs.log — not found; usually means the loop was never armed here"
check_output "s14a: no loop-runs.log -> same honest verify-independently instruction" "$out14a" \
  "verify independently (e.g. \`systemctl --user status 'pr-loop-driver-*'\`)"

: >"$t14/.claude/state/loop-runs.log"
out14b="$(bash "$plugin_v_ok/skills/sync/sync.sh" "$t14" 2>&1)"
check_output "s14b: empty ledger -> present but empty" "$out14b" \
  "deploy-lag: .claude/state/loop-runs.log — present but empty"
check_output "s14b: empty ledger -> same honest message, no false 'safe to restart' claim" "$out14b" \
  "verify independently that no driver is currently active"
check_no_output "s14b: empty ledger -> never asserts restarting should be safe" "$out14b" \
  "restarting the loop units now should be safe"

recent_ts="$(date -u +%FT%TZ)"
printf 'pid=123 session=abc verdict=advance-issue=1 ts=%s result=exit rc=0\n' "$recent_ts" \
  >"$t14/.claude/state/loop-runs.log"
out14c="$(bash "$plugin_v_ok/skills/sync/sync.sh" "$t14" 2>&1)"
check_output "s14c: recent run -> never claims active/idle, tells operator to verify independently" "$out14c" \
  "this ledger only records FINISHED runs, so its recency cannot prove a driver isn't running right now"

old_ts="$(date -u -d '-3600 seconds' +%FT%TZ)"
printf 'pid=123 session=abc verdict=advance-issue=1 ts=%s result=exit rc=0\n' "$old_ts" \
  >"$t14/.claude/state/loop-runs.log"
out14d="$(bash "$plugin_v_ok/skills/sync/sync.sh" "$t14" 2>&1)"
check_output "s14d: old run -> same honest message, no false 'safe to restart' claim" "$out14d" \
  "verify independently that no driver is currently active"
check_no_output "s14d: old run -> never asserts idle is safe to restart" "$out14d" \
  "looks safe to re-arm/restart"

# 14e. Last line has no parseable ts= field at all — a correctness regression fixed by
# this issue #141 review round: under `set -euo pipefail`, the `grep -o 'ts=...' | ... |
# cut` pipeline used to be unguarded, so a last line with no ts= token made `grep` exit 1
# and pipefail abort the WHOLE script before the "could not parse a ts=" fallback message
# ever ran. Assert sync still exits 0 and prints that fallback message instead of dying.
printf 'pid=123 session=abc result=exit rc=0 (no timestamp field at all)\n' \
  >"$t14/.claude/state/loop-runs.log"
out14e="$(bash "$plugin_v_ok/skills/sync/sync.sh" "$t14" 2>&1)"
rc14e=$?
check "s14e: unparseable ts= field -> sync still exits 0" test "$rc14e" -eq 0
check_output "s14e: unparseable ts= field -> could not parse message printed" "$out14e" \
  "deploy-lag: could not parse a ts= field from the last entry"

# ---------------------------------------------------------------------------
# Scenario 15: self-hosting safety for the new sync v2 checks — reuses the t9
# self-hosting fixture from scenario 9 (plugin_root == target_root/.claude). The
# remediation-flavored label advisory must go quiet (same philosophy as
# detect_stale_vendor_copies' self-hosting short-circuit); the plain informational
# reads (env, observability, deploy-lag) must still run, without error, exit 0.
# ---------------------------------------------------------------------------
cat >"$t9/.claude/gates.json" <<'JSON'
{"project":{"name":"recode"},"modules":[{"name":"harness","description":"Orchestrator machinery"}],"gates":{}}
JSON
# Pin GATES_FILE to this self-hosting fixture's OWN adapter (absolute path — same isolation
# rationale as scenario 12) so this scenario is deterministic regardless of an ambient
# GATES_FILE (e.g. the real self-hosted test gate exports GATES_FILE=.claude/self/gates.json
# before invoking this file, which would otherwise make derive_module_labels look in the
# wrong place relative to $t9 and change which advisory lines print).
out15="$(GATES_FILE="$t9/.claude/gates.json" bash "$t9/.claude/skills/sync/sync.sh" "$t9" 2>&1)"
rc15=$?
check "s15: self-hosting sync still exits 0 with the new checks wired in" test "$rc15" -eq 0
check_output "s15: self-hosting quiets the module-label creation advisory" "$out15" \
  "labels: self-hosting — skipping the module/needs-human label advisory"
check_no_output "s15: self-hosting prints no module:harness label-create command" "$out15" \
  'label create "module:harness"'
check_output "s15: self-hosting still runs the plain env read" "$out15" "env: .env — not found"
check_output "s15: self-hosting still runs the plain observability read" "$out15" "observability: .claude/state/"
check_output "s15: self-hosting still runs the plain deploy-lag read" "$out15" "deploy-lag: .claude/state/loop-runs.log"

echo
if [ "$fail" -ne 0 ]; then
  echo "sync-managed-files.test.sh: FAILED"
  exit 1
fi
echo "sync-managed-files.test.sh: all $ok checks passed"
