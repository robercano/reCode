#!/usr/bin/env bash
# needs-human.test.sh — offline smoke test for needs-human.sh (issue #99,
# rewritten for issue #169's REST label ops + confirmed-episode guard).
#
# Sources the REAL needs-human.sh (+ notify.sh/log-event.sh/resolve-roots.sh,
# next to it) with a stubbed `gh` shell FUNCTION (never a network call) that
# logs every invocation, so needs_human_flag/needs_human_clear exercise their
# real gh call sequence with zero network/tokens. notify.sh's own configured
# command is also a local file write, never gh/network.
#
# Issue #169: every label read/write now goes through `gh api` (REST) instead
# of `gh label create`/`gh pr|issue edit --*-label` (gh 2.4.0 has no `gh
# label` subcommand, and the edit --*-label GraphQL calls hit a scope error
# with the bot token on this environment -- both silently no-op'd behind
# `|| true`, so the label never actually stuck and the episode guard below
# reset on every tick, spamming a fresh GitHub comment every ~5 min). PRs are
# issues in the REST API, so `gh api repos/OWNER/REPO/issues/N` is now the ONE
# shared read for both pr:/issue: targets. The CRITICAL invariant added by
# #169: the episode comment posts ONLY once the label add is CONFIRMED by
# re-reading the target's labels after the add -- never from the add's exit
# code alone -- and an unconfirmed add fails LOUDLY via log-event.sh instead
# of silently posting an unverifiable-episode comment.
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
# root dir (a throwaway <root>/.claude/{scripts,state} tree). Copies
# log-event.sh too (issue #169) so the confirmed-episode failure path can
# actually append to a real events.jsonl instead of silently no-op'ing on a
# missing sibling script.
new_fixture() {
  local name="$1" notify_cmd="$2"
  local dir="$work/$name"
  local scripts="$dir/.claude/scripts"
  mkdir -p "$scripts" "$dir/.claude/state"
  cp "$script_dir/needs-human.sh" "$scripts/needs-human.sh"
  cp "$script_dir/notify.sh" "$scripts/notify.sh"
  cp "$script_dir/resolve-roots.sh" "$scripts/resolve-roots.sh"
  cp "$script_dir/log-event.sh" "$scripts/log-event.sh"
  chmod +x "$scripts"/*.sh
  CLAUDE_NOTIFY_CMD="$notify_cmd" node -e '
    const fs = require("fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({ notify: process.env.CLAUDE_NOTIFY_CMD }));
  ' "$dir/.claude/gates.json"
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# 1. needs_human_flag on an ISSUE target, FRESH episode, label add CONFIRMED
#    (stub `gh` simulates GitHub's own label state via a marker FILE the
#    add-label POST touches, so the pre-add read reports "absent" and the
#    post-add confirm read reports "present"): repo view + label-create +
#    label-presence read (before) + label add + label-presence read (confirm)
#    + issue comment (in that order), all via the stubbed `gh`.
# ---------------------------------------------------------------------------
dir1="$(new_fixture scenario1 "")"
gh_log1="$work/scenario1-gh.log"
label_marker1="$work/scenario1-label.marker"
out1="$(bash -c '
  gh() {
    printf "%s\n" "$*" >> "'"$gh_log1"'"
    case "$1" in
      repo) echo "acme/repo" ;;
      api)
        shift
        case "$*" in
          "repos/acme/repo/issues/42 -q .labels[].name")
            [ -f "'"$label_marker1"'" ] && echo "needs-human"
            ;;
          "-X POST repos/acme/repo/issues/42/labels --input -")
            touch "'"$label_marker1"'"
            ;;
          *) : ;;
        esac
        ;;
      *) : ;;
    esac
  }
  . "'"$dir1"'/.claude/scripts/needs-human.sh"
  needs_human_flag "issue:42" "attempt-budget" "high" "Attempt budget exhausted" "Please look at issue 42"
' 2>&1)"
rc1=$?
check "scenario 1: needs_human_flag exits 0" [ "$rc1" -eq 0 ]
check "scenario 1: repo view is the FIRST gh call" bash -c 'sed -n 1p "$1" | grep -q "^repo view --json nameWithOwner"' _ "$gh_log1"
check "scenario 1: ensure-label REST create is the SECOND gh call" bash -c 'sed -n 2p "$1" | grep -qF -- "-X POST repos/acme/repo/labels"' _ "$gh_log1"
check "scenario 1: label-presence read (BEFORE add) is the THIRD gh call" bash -c 'sed -n 3p "$1" | grep -qF "api repos/acme/repo/issues/42 -q .labels[].name"' _ "$gh_log1"
check "scenario 1: label add via REST POST .../issues/42/labels is the FOURTH gh call" bash -c 'sed -n 4p "$1" | grep -qF -- "-X POST repos/acme/repo/issues/42/labels --input -"' _ "$gh_log1"
check "scenario 1: label-presence read (CONFIRM after add) is the FIFTH gh call" bash -c 'sed -n 5p "$1" | grep -qF "api repos/acme/repo/issues/42 -q .labels[].name"' _ "$gh_log1"
check "scenario 1: issue comment with the body is the SIXTH gh call (add was CONFIRMED)" bash -c 'sed -n 6p "$1" | grep -qF "issue comment 42 --body Please look at issue 42"' _ "$gh_log1"
check "scenario 1: exactly 6 gh calls (no extra side effects)" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 6 ]' _ "$gh_log1"

# ---------------------------------------------------------------------------
# 2. needs_human_flag on a PR target: reads/writes the SAME REST
#    repos/OWNER/REPO/issues/N endpoint (PRs ARE issues in the REST API --
#    issue #169 unifies what used to be separate pr view/issue view
#    branches), but still posts via `gh pr comment`, not `gh issue comment`.
# ---------------------------------------------------------------------------
dir2="$(new_fixture scenario2 "")"
gh_log2="$work/scenario2-gh.log"
label_marker2="$work/scenario2-label.marker"
bash -c '
  gh() {
    printf "%s\n" "$*" >> "'"$gh_log2"'"
    case "$1" in
      repo) echo "acme/repo" ;;
      api)
        shift
        case "$*" in
          "repos/acme/repo/issues/17 -q .labels[].name")
            [ -f "'"$label_marker2"'" ] && echo "needs-human"
            ;;
          "-X POST repos/acme/repo/issues/17/labels --input -")
            touch "'"$label_marker2"'"
            ;;
          *) : ;;
        esac
        ;;
      *) : ;;
    esac
  }
  . "'"$dir2"'/.claude/scripts/needs-human.sh"
  needs_human_flag "pr:17" "pr-review" "low" "PR ready" "please review PR 17"
' >/dev/null 2>&1
check "scenario 2: PR target reads/writes the shared issues/17 REST endpoint" bash -c '
  grep -qF "api repos/acme/repo/issues/17 -q .labels[].name" "$1" &&
  grep -qF -- "-X POST repos/acme/repo/issues/17/labels --input -" "$1"
' _ "$gh_log2"
check "scenario 2: PR target posts via 'pr comment', never 'issue comment'" bash -c '
  grep -qF "pr comment 17 --body please review PR 17" "$1" && ! grep -q "^issue comment" "$1"
' _ "$gh_log2"

# ---------------------------------------------------------------------------
# 3. needs_human_clear removes the label via REST DELETE (the OPPOSITE gh
#    call from flag's add) and never posts a comment or (re-)creates the
#    label.
# ---------------------------------------------------------------------------
dir3="$(new_fixture scenario3 "")"
gh_log3="$work/scenario3-gh.log"
bash -c '
  gh() {
    printf "%s\n" "$*" >> "'"$gh_log3"'"
    case "$1" in
      repo) echo "acme/repo" ;;
      *) : ;;
    esac
  }
  . "'"$dir3"'/.claude/scripts/needs-human.sh"
  needs_human_clear "issue:99" "stall"
' >/dev/null 2>&1
check "scenario 3: clear removes the label via REST DELETE .../issues/99/labels/needs-human" grep -qF -- "-X DELETE repos/acme/repo/issues/99/labels/needs-human" "$gh_log3"
check "scenario 3: clear never posts a comment" bash -c '! grep -qE "^(issue|pr) comment" "$1"' _ "$gh_log3"
check "scenario 3: clear never (re-)creates the label" bash -c '! grep -q -- "-X POST repos/acme/repo/labels " "$1"' _ "$gh_log3"
check "scenario 3: exactly 2 gh calls (repo view + the DELETE)" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 2 ]' _ "$gh_log3"

# ---------------------------------------------------------------------------
# 4. Idempotent add/remove round-trip driven through notify.sh's real
#    throttle state: flag -> clear -> flag again fires the SAME (kind,target)
#    notification TWICE (clear resets the throttle so the second flag isn't
#    silently swallowed) — proves flag/clear are a genuine round trip, not
#    just gh label bookkeeping with a notify path that's accidentally inert.
#    The marker file the stub `gh` uses to simulate GitHub's label state is
#    touched by the add and removed by the DELETE, so the SECOND flag also
#    sees a fresh (label-absent) episode and posts its own comment.
# ---------------------------------------------------------------------------
fired4="$work/scenario4-fired.txt"
dir4="$(new_fixture scenario4 "printf 'fired\n' >> $fired4")"
gh_log4="$work/scenario4-gh.log"
label_marker4="$work/scenario4-label.marker"
bash -c '
  gh() {
    printf "%s\n" "$*" >> "'"$gh_log4"'"
    case "$1" in
      repo) echo "acme/repo" ;;
      api)
        shift
        case "$*" in
          "repos/acme/repo/issues/7 -q .labels[].name")
            [ -f "'"$label_marker4"'" ] && echo "needs-human"
            ;;
          "-X POST repos/acme/repo/issues/7/labels --input -")
            touch "'"$label_marker4"'"
            ;;
          "-X DELETE repos/acme/repo/issues/7/labels/needs-human")
            rm -f "'"$label_marker4"'"
            ;;
          *) : ;;
        esac
        ;;
      *) : ;;
    esac
  }
  . "'"$dir4"'/.claude/scripts/needs-human.sh"
  needs_human_flag "issue:7" "attempt-budget" "high" "T" "B"
  needs_human_clear "issue:7" "attempt-budget"
  needs_human_flag "issue:7" "attempt-budget" "high" "T2" "B2"
' >/dev/null 2>&1
check "scenario 4: label add appears TWICE (flag, clear, flag again)" bash -c '[ "$(grep -c -- "-X POST repos/acme/repo/issues/7/labels --input -" "$1")" -eq 2 ]' _ "$gh_log4"
check "scenario 4: label remove appears ONCE (the clear in between)" bash -c '[ "$(grep -c -- "-X DELETE repos/acme/repo/issues/7/labels/needs-human" "$1")" -eq 1 ]' _ "$gh_log4"
check "scenario 4: both flags post a comment (each is its own fresh, CONFIRMED episode)" bash -c '[ "$(grep -c "^issue comment 7" "$1")" -eq 2 ]' _ "$gh_log4"
check "scenario 4: notify fired TWICE (clear reset the throttle between the two flags)" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 2 ]' _ "$fired4"

# ---------------------------------------------------------------------------
# 5. Without an intervening clear, a SECOND flag for the SAME (kind,target)
#    is throttled by notify.sh -- the "one notification per (kind,target) per
#    window" contract this issue's acceptance criteria calls for. `gh` here
#    is a total no-op (stands in for "every REST call fails/does nothing"),
#    which per the #169 invariant also means neither call's comment posts --
#    but notify.sh's throttle is independent of the label/comment path, so it
#    still only fires once.
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
# 7. Comment episode-gating (issue #99 re-review finding #1, re-verified
#    under #169's REST rewrite): a REPEAT flag call on a target that ALREADY
#    carries the needs-human label (per the stubbed REST read, present on
#    BOTH the before- and after-add reads) still (re-)applies the label but
#    SKIPS the comment -- task acceptance criterion (a): "second flag with
#    label present -> no comment".
# ---------------------------------------------------------------------------
dir7="$(new_fixture scenario7 "")"
gh_log7="$work/scenario7-gh.log"
bash -c '
  gh() {
    printf "%s\n" "$*" >> "'"$gh_log7"'"
    case "$1" in
      repo) echo "acme/repo" ;;
      api)
        shift
        case "$*" in
          "repos/acme/repo/issues/50 -q .labels[].name") echo "needs-human" ;;
          *) : ;;
        esac
        ;;
      *) : ;;
    esac
  }
  . "'"$dir7"'/.claude/scripts/needs-human.sh"
  needs_human_flag "issue:50" "attempt-budget" "high" "T" "already labeled body"
' >/dev/null 2>&1
check "scenario 7: label is still (re-)applied when already present" grep -qF -- "-X POST repos/acme/repo/issues/50/labels --input -" "$gh_log7"
check "scenario 7: comment is SKIPPED because the label was already present (repeat episode)" bash -c '! grep -qE "^(issue|pr) comment" "$1"' _ "$gh_log7"

# ---------------------------------------------------------------------------
# 8. Fresh episode with an UNRELATED label already present (needs-human
#    itself absent before the add, confirmed present after) -- comment posts.
#    Task acceptance criterion (a): "label-add confirmed -> comment posts
#    once".
# ---------------------------------------------------------------------------
dir8="$(new_fixture scenario8 "")"
gh_log8="$work/scenario8-gh.log"
label_marker8="$work/scenario8-label.marker"
bash -c '
  gh() {
    printf "%s\n" "$*" >> "'"$gh_log8"'"
    case "$1" in
      repo) echo "acme/repo" ;;
      api)
        shift
        case "$*" in
          "repos/acme/repo/issues/51 -q .labels[].name")
            if [ -f "'"$label_marker8"'" ]; then printf "some-other-label\nneeds-human\n"; else printf "some-other-label\n"; fi
            ;;
          "-X POST repos/acme/repo/issues/51/labels --input -")
            touch "'"$label_marker8"'"
            ;;
          *) : ;;
        esac
        ;;
      *) : ;;
    esac
  }
  . "'"$dir8"'/.claude/scripts/needs-human.sh"
  needs_human_flag "issue:51" "attempt-budget" "high" "T" "fresh episode body"
' >/dev/null 2>&1
check "scenario 8: comment posts on a fresh, CONFIRMED episode (needs-human absent before, present after add)" grep -qF "issue comment 51 --body fresh episode body" "$gh_log8"

# ---------------------------------------------------------------------------
# 9. CRITICAL INVARIANT (issue #169): a label add that can never be CONFIRMED
#    (every REST label read fails -- offline/unauthenticated/permission
#    error, standing in for the exact #168/#161 failure mode) must NOT post
#    the episode comment, and must fail LOUDLY by appending an error line to
#    events.jsonl via log-event.sh -- task acceptance criterion (b):
#    "label-add FAILS -> NO comment posted + an events.jsonl error line".
#    This deliberately INVERTS this suite's old "fails OPEN toward the
#    comment" assertion: that old fail-open behavior is exactly how an
#    unconfirmable episode used to spam a fresh comment every tick.
# ---------------------------------------------------------------------------
dir9="$(new_fixture scenario9 "")"
gh_log9="$work/scenario9-gh.log"
events9="$work/scenario9-events.jsonl"
bash -c '
  gh() {
    printf "%s\n" "$*" >> "'"$gh_log9"'"
    case "$1" in
      repo) echo "acme/repo" ;;
      api)
        shift
        case "$*" in
          "repos/acme/repo/issues/52 -q .labels[].name") return 1 ;;
          *) : ;;
        esac
        ;;
      *) : ;;
    esac
  }
  . "'"$dir9"'/.claude/scripts/needs-human.sh"
  CLAUDE_EVENTS_FILE="'"$events9"'" needs_human_flag "issue:52" "attempt-budget" "high" "T" "unconfirmed body"
' >/dev/null 2>&1
check "scenario 9: an unconfirmable label add does NOT post a comment" bash -c '! grep -qE "^(issue|pr) comment" "$1"' _ "$gh_log9"
check "scenario 9: the label add was still ATTEMPTED (best-effort, just unconfirmed)" grep -qF -- "-X POST repos/acme/repo/issues/52/labels --input -" "$gh_log9"
check "scenario 9: the failure is logged LOUDLY to events.jsonl (phase=error)" bash -c '[ -f "$1" ] && grep -q "\"phase\":\"error\"" "$1"' _ "$events9"
check "scenario 9: the events.jsonl line names the target (issue:52)" bash -c 'grep -q "\"task\":\"issue:52\"" "$1"' _ "$events9"

# ---------------------------------------------------------------------------
# 10. Task acceptance criterion (c): "remove treats 404 as success" -- a
#     failing (non-zero-exit) REST DELETE, standing in for a 404 on a target
#     that was never labeled (or already cleared), must be treated exactly
#     like success: no crash, no special-casing, no retried/duplicated calls.
# ---------------------------------------------------------------------------
dir10="$(new_fixture scenario10 "")"
gh_log10="$work/scenario10-gh.log"
out10="$(bash -c '
  gh() {
    printf "%s\n" "$*" >> "'"$gh_log10"'"
    case "$1" in
      repo) echo "acme/repo" ;;
      api)
        shift
        case "$*" in
          "-X DELETE repos/acme/repo/issues/60/labels/needs-human") return 1 ;; # simulated 404
          *) : ;;
        esac
        ;;
      *) : ;;
    esac
  }
  . "'"$dir10"'/.claude/scripts/needs-human.sh"
  needs_human_clear "issue:60" "stall"
  echo "CLEAR_SURVIVED"
' 2>&1)"
check "scenario 10: a 404-like DELETE failure never crashes needs_human_clear" bash -c 'printf "%s\n" "$1" | grep -q "CLEAR_SURVIVED"' _ "$out10"
check "scenario 10: exactly ONE DELETE attempt (no retry loop on the 'failure')" bash -c '[ "$(grep -c -- "-X DELETE repos/acme/repo/issues/60/labels/needs-human" "$1")" -eq 1 ]' _ "$gh_log10"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "needs-human.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "needs-human.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
