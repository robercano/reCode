#!/usr/bin/env bash
# pr-ci-fix.test.sh — offline smoke test for pr-ci-fix.sh (issue #96 capability
# #1: CI-failure auto-fix detection).
#
# Builds a throwaway .claude/scripts/ fixture containing the REAL pr-ci-fix.sh
# + resolve-roots.sh next to a FAKE bot-gh.sh (which stands in for `gh`
# entirely — it prints the ALREADY-jq-filtered output the real `gh ... --jq`
# calls would have produced, mirroring loop-census.test.sh's own fake-gh
# convention) and a FAKE pr-feedback.sh (so the precedence exclusion can be
# exercised without any real feedback-detection logic). No network, no real
# `gh` CLI required.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/pr-ci-fix.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cifix_src="$script_dir/pr-ci-fix.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/pr-ci-fix-test.XXXXXX")"
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

fixture="$work/fixture1"
scripts_dir="$fixture/.claude/scripts"
mkdir -p "$scripts_dir"
cp "$cifix_src" "$scripts_dir/pr-ci-fix.sh"
cp "$resolve_roots_src" "$scripts_dir/resolve-roots.sh"

# --- fixture PR set ----------------------------------------------------------
#   10: failing CI (CheckRun conclusion=FAILURE), no labels    -> EMITTED
#   11: pending CI (conclusion=null, still running)             -> NOT emitted (wait, don't fix)
#   12: failing CI, labeled needs-human                         -> NOT emitted (guard)
#   13: failing CI, labeled claude-ci-fixing (in-flight guard)  -> NOT emitted (guard)
#   14: failing CI, ALSO a pr-feedback.sh candidate              -> NOT emitted (precedence)
#   15: failing CI, but already has the <!-- claude-ci-addressed:sha15 --> marker
#                                                                 -> NOT emitted (already-addressed cursor)
#   16: failing CI via the LEGACY StatusContext shape (state=ERROR, no
#       "conclusion" field at all)                                -> EMITTED (dual-shape parse, same as merge-ready.sh)
cat > "$scripts_dir/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefOid'; then
      cat <<'JSON'
{"number":10,"headRefName":"feat/issue-10-a","author":{"login":"testbot"},"labels":[],"statusCheckRollup":[{"name":"build","conclusion":"FAILURE"}],"headRefOid":"sha10"}
{"number":11,"headRefName":"feat/issue-11-a","author":{"login":"testbot"},"labels":[],"statusCheckRollup":[{"name":"build","conclusion":null,"status":"IN_PROGRESS"}],"headRefOid":"sha11"}
{"number":12,"headRefName":"feat/issue-12-a","author":{"login":"testbot"},"labels":[{"name":"needs-human"}],"statusCheckRollup":[{"name":"build","conclusion":"FAILURE"}],"headRefOid":"sha12"}
{"number":13,"headRefName":"feat/issue-13-a","author":{"login":"testbot"},"labels":[{"name":"claude-ci-fixing"}],"statusCheckRollup":[{"name":"build","conclusion":"FAILURE"}],"headRefOid":"sha13"}
{"number":14,"headRefName":"feat/issue-14-a","author":{"login":"testbot"},"labels":[],"statusCheckRollup":[{"name":"build","conclusion":"FAILURE"}],"headRefOid":"sha14"}
{"number":15,"headRefName":"feat/issue-15-a","author":{"login":"testbot"},"labels":[],"statusCheckRollup":[{"name":"build","conclusion":"FAILURE"}],"headRefOid":"sha15"}
{"number":16,"headRefName":"feat/issue-16-a","author":{"login":"testbot"},"labels":[],"statusCheckRollup":[{"context":"legacy-ci","state":"ERROR"}],"headRefOid":"sha16"}
JSON
    else
      echo "fake-bot-gh.sh: unexpected pr subcommand: $*" >&2
      exit 1
    fi
    ;;
  api)
    case "$*" in
      *"issues/15/comments"*) echo 1 ;;   # already carries the claude-ci-addressed:sha15 marker
      *"issues/"*"/comments"*) echo 0 ;;  # no marker for any other PR
      *) echo "fake-bot-gh.sh: unhandled api call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF

# 14 is a feedback candidate (precedence: feedback outranks ci-fix).
cat > "$scripts_dir/pr-feedback.sh" <<'EOF'
#!/usr/bin/env bash
printf '14\tfeat/issue-14-a\towner\t2026-01-01T00:00:00Z\n'
EOF

chmod +x "$scripts_dir"/*.sh

out="$(BOT_LOGIN=testbot bash "$scripts_dir/pr-ci-fix.sh" "acme/repo")"

check "PR 10 (failing CI, not addressed): emitted with branch/check/sha" bash -c '
  printf "%s\n" "$1" | grep -qF "$(printf "10\tfeat/issue-10-a\tbuild\tsha10")"' _ "$out"
check "PR 11 (pending CI, no failing check yet): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^11\b"' _ "$out"
check "PR 12 (needs-human guard): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^12\b"' _ "$out"
check "PR 13 (claude-ci-fixing in-flight guard): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^13\b"' _ "$out"
check "PR 14 (also a feedback candidate — precedence): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^14\b"' _ "$out"
check "PR 15 (already-addressed marker for the current head): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^15\b"' _ "$out"
check "PR 16 (failing CI via legacy StatusContext shape): emitted" bash -c '
  printf "%s\n" "$1" | grep -qF "$(printf "16\tfeat/issue-16-a\tlegacy-ci\tsha16")"' _ "$out"
check "exactly 2 PRs emitted total (10 and 16 only)" bash -c '[ "$(printf "%s\n" "$1" | grep -c .)" -eq 2 ]' _ "$out"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "pr-ci-fix.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "pr-ci-fix.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
