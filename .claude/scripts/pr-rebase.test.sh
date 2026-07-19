#!/usr/bin/env bash
# pr-rebase.test.sh — offline smoke test for pr-rebase.sh (issue #96
# capability #3: rebase-after-sibling-merge detection).
#
# Builds a throwaway .claude/scripts/ fixture containing the REAL
# pr-rebase.sh + resolve-roots.sh + needs-human.sh + notify.sh next to a FAKE
# bot-gh.sh (which stands in for `gh` entirely, mirroring pr-ci-fix.test.sh's
# and pr-comment-fix.test.sh's own fake-gh convention) and FAKE pr-feedback.sh
# / pr-comment-fix.sh / pr-ci-fix.sh (so the three-way precedence exclusion
# can be exercised without any real detection logic in those siblings). No
# network, no real `gh` CLI required.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/pr-rebase.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$script_dir/pr-rebase.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/pr-rebase-test.XXXXXX")"
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
mkdir -p "$scripts_dir" "$fixture/.claude/state"
cp "$src" "$scripts_dir/pr-rebase.sh"
cp "$resolve_roots_src" "$scripts_dir/resolve-roots.sh"
cp "$script_dir/needs-human.sh" "$scripts_dir/needs-human.sh"
cp "$script_dir/notify.sh" "$scripts_dir/notify.sh"

cat > "$fixture/.claude/gates.json" <<'EOF'
{
  "modules": [{ "name": "test", "path": ".", "description": "", "owner": "" }],
  "merge": { "baseBranch": "main" }
}
EOF

# --- fixture PR set ----------------------------------------------------------
#   10: mergeable=CONFLICTING, no marker                          -> EMITTED attempt=1
#   11: mergeable=MERGEABLE                                       -> NOT emitted (nothing to rebase)
#   12: mergeable=CONFLICTING, labeled needs-human                -> NOT emitted (guard)
#   13: mergeable=CONFLICTING, labeled claude-rebasing             -> NOT emitted (in-flight guard)
#   14: mergeable=CONFLICTING, ALSO a pr-feedback.sh candidate     -> NOT emitted (precedence)
#   15: mergeable=CONFLICTING, ALSO a pr-comment-fix.sh candidate  -> NOT emitted (precedence)
#   20: mergeable=CONFLICTING, ALSO a pr-ci-fix.sh candidate       -> NOT emitted (precedence)
#   16: mergeable=CONFLICTING, marker attempt=1 for SAME base_sha  -> EMITTED attempt=2
#   17: mergeable=CONFLICTING, marker attempt=2 for SAME base_sha  -> NOT emitted (escalated)
#   18: mergeable=UNKNOWN                                          -> NOT emitted (still computing)
#   19: mergeable=CONFLICTING, marker attempt=2 for a DIFFERENT (old) base_sha
#                                                                  -> EMITTED attempt=1 (reset)
cat > "$scripts_dir/bot-gh.sh" <<'BOTGH'
#!/usr/bin/env bash
# Log every invocation (mirrors pr-comment-fix.test.sh's gh-call-log
# convention) so escalation side effects (needs_human_flag's `gh pr edit ...
# --add-label needs-human`) can be asserted on directly, not just inferred
# from "the PR wasn't emitted".
log_dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >> "$log_dir/gh-calls.log"
case "$1" in
  repo) echo "acme/repo" ;;
  label) exit 0 ;;  # needs_human_flag's `gh label create needs-human ...`
  pr)
    case "$2" in
      edit|comment) exit 0 ;;  # needs_human_flag's `gh pr edit`/`gh pr comment`
      view) echo ""; exit 0 ;;  # _needs_human_already_labeled's `gh pr view --json labels`
    esac
    if printf '%s\n' "$*" | grep -q 'headRefOid'; then
      cat <<'JSON'
{"number":10,"headRefName":"feat/issue-10-a","author":{"login":"testbot"},"labels":[],"mergeable":"CONFLICTING","baseRefOid":"base1","headRefOid":"sha10"}
{"number":11,"headRefName":"feat/issue-11-a","author":{"login":"testbot"},"labels":[],"mergeable":"MERGEABLE","baseRefOid":"base1","headRefOid":"sha11"}
{"number":12,"headRefName":"feat/issue-12-a","author":{"login":"testbot"},"labels":[{"name":"needs-human"}],"mergeable":"CONFLICTING","baseRefOid":"base1","headRefOid":"sha12"}
{"number":13,"headRefName":"feat/issue-13-a","author":{"login":"testbot"},"labels":[{"name":"claude-rebasing"}],"mergeable":"CONFLICTING","baseRefOid":"base1","headRefOid":"sha13"}
{"number":14,"headRefName":"feat/issue-14-a","author":{"login":"testbot"},"labels":[],"mergeable":"CONFLICTING","baseRefOid":"base1","headRefOid":"sha14"}
{"number":15,"headRefName":"feat/issue-15-a","author":{"login":"testbot"},"labels":[],"mergeable":"CONFLICTING","baseRefOid":"base1","headRefOid":"sha15"}
{"number":20,"headRefName":"feat/issue-20-a","author":{"login":"testbot"},"labels":[],"mergeable":"CONFLICTING","baseRefOid":"base1","headRefOid":"sha20"}
{"number":16,"headRefName":"feat/issue-16-a","author":{"login":"testbot"},"labels":[],"mergeable":"CONFLICTING","baseRefOid":"base1","headRefOid":"sha16"}
{"number":17,"headRefName":"feat/issue-17-a","author":{"login":"testbot"},"labels":[],"mergeable":"CONFLICTING","baseRefOid":"base1","headRefOid":"sha17"}
{"number":18,"headRefName":"feat/issue-18-a","author":{"login":"testbot"},"labels":[],"mergeable":"UNKNOWN","baseRefOid":"base1","headRefOid":"sha18"}
{"number":19,"headRefName":"feat/issue-19-a","author":{"login":"testbot"},"labels":[],"mergeable":"CONFLICTING","baseRefOid":"base-new","headRefOid":"sha19"}
JSON
    else
      echo "fake-bot-gh.sh: unexpected pr subcommand: $*" >&2
      exit 1
    fi
    ;;
  api)
    case "$*" in
      *"issues/16/comments"*)
        echo '[{"user":{"login":"testbot"},"body":"<!-- claude-rebase-attempted:base1:1 -->"}]'
        ;;
      *"issues/17/comments"*)
        echo '[{"user":{"login":"testbot"},"body":"<!-- claude-rebase-attempted:base1:2 -->"}]'
        ;;
      *"issues/19/comments"*)
        echo '[{"user":{"login":"testbot"},"body":"<!-- claude-rebase-attempted:base-old:2 -->"}]'
        ;;
      *"issues/"*"/comments"*) echo '[]' ;;
      *) echo "fake-bot-gh.sh: unhandled api call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
BOTGH
chmod +x "$scripts_dir/bot-gh.sh"

# 14 is a feedback candidate (precedence: feedback outranks rebase).
cat > "$scripts_dir/pr-feedback.sh" <<'EOF'
#!/usr/bin/env bash
printf '14\tfeat/issue-14-a\towner\t2026-01-01T00:00:00Z\n'
EOF
chmod +x "$scripts_dir/pr-feedback.sh"

# 15 is a comment-fix candidate (precedence: comment-fix outranks rebase).
cat > "$scripts_dir/pr-comment-fix.sh" <<'EOF'
#!/usr/bin/env bash
printf '15\tfeat/issue-15-a\tTABC:1\tsha15\n'
EOF
chmod +x "$scripts_dir/pr-comment-fix.sh"

# 20 is a ci-fix candidate (precedence: ci-fix outranks rebase).
cat > "$scripts_dir/pr-ci-fix.sh" <<'EOF'
#!/usr/bin/env bash
printf '20\tfeat/issue-20-a\tbuild\tsha20\n'
EOF
chmod +x "$scripts_dir/pr-ci-fix.sh"

out="$(env -u GATES_FILE BOT_LOGIN=testbot bash "$scripts_dir/pr-rebase.sh" "acme/repo")"

check "PR 10 (CONFLICTING, no marker): emitted attempt=1" bash -c '
  printf "%s\n" "$1" | grep -qF "$(printf "10\tfeat/issue-10-a\tsha10\tbase1\t1")"' _ "$out"
check "PR 11 (MERGEABLE): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^11\b"' _ "$out"
check "PR 12 (needs-human guard): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^12\b"' _ "$out"
check "PR 13 (claude-rebasing in-flight guard): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^13\b"' _ "$out"
check "PR 14 (also a feedback candidate -- precedence): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^14\b"' _ "$out"
check "PR 15 (also a comment-fix candidate -- precedence): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^15\b"' _ "$out"
check "PR 20 (also a ci-fix candidate -- precedence): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^20\b"' _ "$out"
check "PR 16 (marker attempt=1 for SAME base_sha): emitted attempt=2" bash -c '
  printf "%s\n" "$1" | grep -qF "$(printf "16\tfeat/issue-16-a\tsha16\tbase1\t2")"' _ "$out"
check "PR 17 (marker attempt=2 for SAME base_sha -- budget exhausted): NOT emitted (escalated)" bash -c '! printf "%s\n" "$1" | grep -qE "^17\b"' _ "$out"
check "PR 18 (UNKNOWN mergeable, still computing): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^18\b"' _ "$out"
check "PR 19 (marker for a DIFFERENT/old base_sha -- reset): emitted attempt=1" bash -c '
  printf "%s\n" "$1" | grep -qF "$(printf "19\tfeat/issue-19-a\tsha19\tbase-new\t1")"' _ "$out"
check "exactly 3 PRs emitted total (10, 16, 19)" bash -c '[ "$(printf "%s\n" "$1" | grep -c .)" -eq 3 ]' _ "$out"

# --- anti-livelock escalation: positive assertion on the ACTUAL gh side
# effect, not just "PR 17 wasn't emitted" (which can't tell correct
# escalation apart from a silent bug that just drops the PR).
gh_log1="$scripts_dir/gh-calls.log"
check "PR 17 (budget exhausted): needs-human label ACTUALLY applied (gh pr edit 17 --add-label needs-human)" \
  grep -q "pr edit 17 --add-label needs-human" "$gh_log1"
check "PR 16 (attempt 2, budget not yet exhausted): needs-human label NOT applied" \
  bash -c '! grep -q "pr edit 16 --add-label needs-human" "$1"' _ "$gh_log1"
check "PR 19 (reset after base change): needs-human label NOT applied" \
  bash -c '! grep -q "pr edit 19 --add-label needs-human" "$1"' _ "$gh_log1"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "pr-rebase.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "pr-rebase.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
