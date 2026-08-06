#!/usr/bin/env bash
# managed-template-parity.test.sh — offline guard against the two hand-maintained
# copies of a managed script drifting apart.
#
# The problem this exists to catch:
#   Some managed files live TWICE in this repo — once under .claude/scripts/ (the
#   copy that actually executes when a user runs it out of the installed plugin
#   cache) and once under .claude/skills/setup/templates/ (the copy scaffold.sh
#   writes into a consumer repo and sync.sh re-stamps from). Nothing kept the two
#   in sync: release.sh does not copy one onto the other, and no check compared
#   them. They silently drifted — `arm-loop.sh` shipped as v7 under scripts/ while
#   the template was still v6, so `/orchestrator:sync` reported every consumer
#   "up to date" at v6 forever while the plugin's own runtime copy was v7.
#
#   That skew is not cosmetic: arm-loop v7 added --stop-after-days (issue #95),
#   which writes .claude/state/loop-arming.json — the file loop-tick.sh reads to
#   decide whether the loop has passed its self-disarm horizon. A consumer stamped
#   at v6 arms a loop whose tick script expects state the arming script never
#   writes.
#
# Asserts, for every templates/ file that has a same-named .claude/scripts/ twin:
#   1. the two are byte-identical (so the @orchestrator-managed marker version,
#      and everything else, necessarily agrees);
#   2. the executable bit matches, since scaffold.sh copies the template with its
#      mode preserved and an armed loop runs it directly.
#
# Pure filesystem comparison — no gh, no network, no temp dirs, no mutation.
# Exit 0 on success, non-zero if any pair has drifted. Runnable bare:
#   bash .claude/scripts/managed-template-parity.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
templates_dir="$repo_root/skills/setup/templates"
scripts_dir="$repo_root/scripts"

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

if [ ! -d "$templates_dir" ]; then
  echo "managed-template-parity: missing $templates_dir" >&2
  exit 1
fi

pairs=0
for tpl in "$templates_dir"/*; do
  [ -f "$tpl" ] || continue
  base="$(basename "$tpl")"
  twin="$scripts_dir/$base"
  # Only files that exist in BOTH places are dual-maintained. Templates with no
  # scripts/ twin (gates.json, gates.yml, CLAUDE.md, the .service units, …) are
  # scaffold-only by design and are deliberately not compared here.
  [ -f "$twin" ] || continue
  pairs=$((pairs + 1))

  check "$base: templates/ copy is byte-identical to scripts/ copy" \
    diff -q "$twin" "$tpl"

  tpl_x=no; [ -x "$tpl" ] && tpl_x=yes
  twin_x=no; [ -x "$twin" ] && twin_x=yes
  check "$base: executable bit matches (scripts=$twin_x templates=$tpl_x)" \
    [ "$tpl_x" = "$twin_x" ]
done

# Guard the guard: if a refactor ever moves these files apart, this test must not
# quietly pass by comparing nothing at all.
check "found at least one dual-maintained template/script pair (got $pairs)" \
  [ "$pairs" -ge 1 ]

echo
if [ "$fail" -eq 0 ]; then
  echo "managed-template-parity.test.sh: all $ok assertion(s) passed ($pairs pair(s) compared)"
else
  echo "managed-template-parity.test.sh: FAILURES — a managed script and its setup template have drifted." >&2
  echo "  Fix: copy the canonical .claude/scripts/<name> over .claude/skills/setup/templates/<name>" >&2
  echo "  (keeping the higher @orchestrator-managed marker version), then re-run this test." >&2
fi
exit "$fail"
