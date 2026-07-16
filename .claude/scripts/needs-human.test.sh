#!/usr/bin/env bash
# needs-human.test.sh — offline smoke test for needs-human.sh (issue #99),
# the ONE shared label+notify seam for the loop's block-on-owner points.
#
# Sources the REAL needs-human.sh (+ notify.sh, next to it) with a stubbed
# `gh` shell FUNCTION (never a network call) that logs every invocation, so
# needs_human_flag/needs_human_clear exercise their real gh call sequence
# with zero network/tokens. notify.sh's own configured command is also a
# local file write, never gh/network.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/needs-human.test.sh
set -uo pipefail

# Isolate from the CALLER's environment (mirrors cockpit.test.sh/notify.test.sh):
# this test is wired into .claude/self/checks.sh's `test` case, which itself
# often runs under `GATES_FILE=.claude/self/gates.json` (the self-host loop).
# An ambient GATES_FILE would silently redirect notify.sh's config lookup
# (called by needs_human_flag/needs_human_clear below) onto the SELF adapter
# instead of each fixture's own hand-written .claude/gates.json.
unset GATES_FILE

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/needs-human-test.XXXXXX")"
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

# $1 = fixture name, $2 = notify command (may be empty). Prints the fixture
# root dir (a throwaway <root>/.claude/{scripts,state} tree).
new_fixture() {
  local name="$1" notify_cmd="$2"
  local dir="$work/$name"
  local scripts="$dir/.claude/scripts"
  mkdir -p "$scripts" "$dir/.claude/state"
  cp "$script_dir/needs-human.sh" "$scripts/needs-human.sh"
  cp "$script_dir/notify.sh" "$scripts/notify.sh"
  cp "$script_dir/resolve-roots.sh" "$scripts/resolve-roots.sh"
  chmod +x "$scripts"/*.sh
  CLAUDE_NOTIFY_CMD="$notify_cmd" node -e '
    const fs = require("fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({ notify: process.env.CLAUDE_NOTIFY_CMD }));
  ' "$dir/.claude/gates.json"
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# 1. needs_human_flag on an ISSUE target, FRESH episode (stub `gh` returns no
#    labels, so the pre-flight presence check reports "not already labeled"):
#    label-presence read + label create + issue edit --add-label + issue
#    comment (in that order), all via the stubbed `gh`.
# ---------------------------------------------------------------------------
dir1="$(new_fixture scenario1 "")"
gh_log1="$work/scenario1-gh.log"
out1="$(bash -c '
  gh() { printf "%s\n" "$*" >> "'"$gh_log1"'"; }
  . "'"$dir1"'/.claude/scripts/needs-human.sh"
  needs_human_flag "issue:42" "attempt-budget" "high" "Attempt budget exhausted" "Please look at issue 42"
' 2>&1)"
rc1=$?
check "scenario 1: needs_human_flag exits 0" [ "$rc1" -eq 0 ]
check "scenario 1: label-presence check is the FIRST gh call" bash -c 'head -1 "$1" | grep -q "^issue view 42 --json labels"' _ "$gh_log1"
check "scenario 1: label create is the SECOND gh call" bash -c 'sed -n 2p "$1" | grep -q "^label create needs-human"' _ "$gh_log1"
check "scenario 1: issue edit --add-label needs-human is the THIRD gh call" bash -c 'sed -n 3p "$1" | grep -qF "issue edit 42 --add-label needs-human"' _ "$gh_log1"
check "scenario 1: issue comment with the body is the FOURTH gh call" bash -c 'sed -n 4p "$1" | grep -qF "issue comment 42 --body Please look at issue 42"' _ "$gh_log1"
check "scenario 1: exactly 4 gh calls (no extra side effects)" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 4 ]' _ "$gh_log1"

# ---------------------------------------------------------------------------
# 2. needs_human_flag on a PR target: `pr edit`/`pr comment`, not `issue *`.
# ---------------------------------------------------------------------------
dir2="$(new_fixture scenario2 "")"
gh_log2="$work/scenario2-gh.log"
bash -c '
  gh() { printf "%s\n" "$*" >> "'"$gh_log2"'"; }
  . "'"$dir2"'/.claude/scripts/needs-human.sh"
  needs_human_flag "pr:17" "pr-review" "low" "PR ready" "please review PR 17"
' >/dev/null 2>&1
check "scenario 2: PR target uses 'pr edit', not 'issue edit'" bash -c 'grep -q "^pr edit 17 --add-label needs-human" "$1" && ! grep -q "^issue edit" "$1"' _ "$gh_log2"
check "scenario 2: PR target posts via 'pr comment'" grep -qF "pr comment 17 --body please review PR 17" "$gh_log2"

# ---------------------------------------------------------------------------
# 3. needs_human_clear removes the label (the OPPOSITE gh call from flag) and
#    never posts a comment.
# ---------------------------------------------------------------------------
dir3="$(new_fixture scenario3 "")"
gh_log3="$work/scenario3-gh.log"
bash -c '
  gh() { printf "%s\n" "$*" >> "'"$gh_log3"'"; }
  . "'"$dir3"'/.claude/scripts/needs-human.sh"
  needs_human_clear "issue:99" "stall"
' >/dev/null 2>&1
check "scenario 3: clear removes the label via 'issue edit --remove-label'" grep -qF "issue edit 99 --remove-label needs-human" "$gh_log3"
check "scenario 3: clear never posts a comment" bash -c '! grep -q "^issue comment" "$1"' _ "$gh_log3"
check "scenario 3: clear never (re-)creates the label" bash -c '! grep -q "^label create" "$1"' _ "$gh_log3"

# ---------------------------------------------------------------------------
# 4. Idempotent add/remove round-trip driven through notify.sh's real
#    throttle state: flag -> clear -> flag again fires the SAME (kind,target)
#    notification TWICE (clear resets the throttle so the second flag isn't
#    silently swallowed) — proves flag/clear are a genuine round trip, not
#    just gh label bookkeeping with a notify path that's accidentally inert.
# ---------------------------------------------------------------------------
fired4="$work/scenario4-fired.txt"
dir4="$(new_fixture scenario4 "printf 'fired\n' >> $fired4")"
gh_log4="$work/scenario4-gh.log"
bash -c '
  gh() { printf "%s\n" "$*" >> "'"$gh_log4"'"; }
  . "'"$dir4"'/.claude/scripts/needs-human.sh"
  needs_human_flag "issue:7" "attempt-budget" "high" "T" "B"
  needs_human_clear "issue:7" "attempt-budget"
  needs_human_flag "issue:7" "attempt-budget" "high" "T2" "B2"
' >/dev/null 2>&1
check "scenario 4: label add appears TWICE (flag, clear, flag again)" bash -c '[ "$(grep -c "add-label needs-human" "$1")" -eq 2 ]' _ "$gh_log4"
check "scenario 4: label remove appears ONCE (the clear in between)" bash -c '[ "$(grep -c "remove-label needs-human" "$1")" -eq 1 ]' _ "$gh_log4"
check "scenario 4: notify fired TWICE (clear reset the throttle between the two flags)" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 2 ]' _ "$fired4"

# ---------------------------------------------------------------------------
# 5. Without an intervening clear, a SECOND flag for the SAME (kind,target)
#    is throttled by notify.sh (still re-applies the gh label, but does not
#    re-notify) -- the "one notification per (kind,target) per window"
#    contract this issue's acceptance criteria calls for.
# ---------------------------------------------------------------------------
fired5="$work/scenario5-fired.txt"
dir5="$(new_fixture scenario5 "printf 'fired\n' >> $fired5")"
bash -c '
  gh() { :; }
  . "'"$dir5"'/.claude/scripts/needs-human.sh"
  needs_human_flag "issue:8" "attempt-budget" "high" "T" "B"
  needs_human_flag "issue:8" "attempt-budget" "high" "T again" "B again"
' >/dev/null 2>&1
check "scenario 5: repeated flag with no clear in between notifies only ONCE" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 1 ]' _ "$fired5"

# ---------------------------------------------------------------------------
# 6. A failing `gh` (offline/unauthenticated) never crashes the caller
#    (best-effort contract) -- `gh` here always returns non-zero, standing in
#    for "gh unreachable", WITHOUT ever falling through to a real gh binary
#    that might be on this machine's PATH (a bare undefined `gh` would risk
#    exactly that -- this stub is deliberate, not a shortcut).
# ---------------------------------------------------------------------------
dir6="$(new_fixture scenario6 "")"
out6="$(bash -c '
  gh() { return 1; }
  . "'"$dir6"'/.claude/scripts/needs-human.sh"
  needs_human_flag "issue:1" "attempt-budget" "high" "T" "B"
  echo "SURVIVED"
' 2>&1)"
check "scenario 6: caller survives (prints SURVIVED) even when every gh call fails" bash -c 'printf "%s\n" "$1" | grep -q "SURVIVED"' _ "$out6"

# ---------------------------------------------------------------------------
# 7. Comment episode-gating (issue #99 re-review finding #1): a REPEAT flag
#    call on a target that ALREADY carries the needs-human label (per the
#    stubbed `gh issue view --json labels` read) still (re-)applies the label
#    but SKIPS the comment -- this is the fix for the "fresh GitHub comment
#    every tick" bug the reviewer reproduced.
# ---------------------------------------------------------------------------
dir7="$(new_fixture scenario7 "")"
gh_log7="$work/scenario7-gh.log"
bash -c '
  gh() {
    printf "%s\n" "$*" >> "'"$gh_log7"'"
    case "$*" in
      "issue view 50 --json labels -q .labels[].name") printf "needs-human\n" ;;
      *) : ;;
    esac
  }
  . "'"$dir7"'/.claude/scripts/needs-human.sh"
  needs_human_flag "issue:50" "attempt-budget" "high" "T" "already labeled body"
' >/dev/null 2>&1
check "scenario 7: label is still (re-)applied when already present" grep -qF "issue edit 50 --add-label needs-human" "$gh_log7"
check "scenario 7: comment is SKIPPED because the label was already present" bash -c '! grep -q "^issue comment" "$1"' _ "$gh_log7"

# ---------------------------------------------------------------------------
# 8. Same target shape, label ABSENT (a fresh episode -- e.g. right after a
#    needs_human_clear, or the very first flag ever) -- comment posts.
# ---------------------------------------------------------------------------
dir8="$(new_fixture scenario8 "")"
gh_log8="$work/scenario8-gh.log"
bash -c '
  gh() {
    printf "%s\n" "$*" >> "'"$gh_log8"'"
    case "$*" in
      "issue view 51 --json labels -q .labels[].name") printf "some-other-label\n" ;;
      *) : ;;
    esac
  }
  . "'"$dir8"'/.claude/scripts/needs-human.sh"
  needs_human_flag "issue:51" "attempt-budget" "high" "T" "fresh episode body"
' >/dev/null 2>&1
check "scenario 8: comment posts on a fresh episode (needs-human label absent)" grep -qF "issue comment 51 --body fresh episode body" "$gh_log8"

# ---------------------------------------------------------------------------
# 9. A failing label READ (offline/unauthenticated `gh issue view`) fails
#    OPEN toward posting the comment -- the old, safe (if noisier) behavior
#    -- never toward silently swallowing a genuinely fresh escalation.
# ---------------------------------------------------------------------------
dir9="$(new_fixture scenario9 "")"
gh_log9="$work/scenario9-gh.log"
bash -c '
  gh() {
    printf "%s\n" "$*" >> "'"$gh_log9"'"
    case "$*" in
      "issue view 52 --json labels -q .labels[].name") return 1 ;;
      *) : ;;
    esac
  }
  . "'"$dir9"'/.claude/scripts/needs-human.sh"
  needs_human_flag "issue:52" "attempt-budget" "high" "T" "fail-open body"
' >/dev/null 2>&1
check "scenario 9: a failing label read fails OPEN -- comment still posts" grep -qF "issue comment 52 --body fail-open body" "$gh_log9"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "needs-human.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "needs-human.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
