#!/usr/bin/env bash
# needs-human.sh — the ONE shared "needs-human" seam (issue #99). SOURCE this
# (never execute it) from a script that already defines `gh` the way every
# loop script does:
#   gh() { bash "$script_dir/bot-gh.sh" "$@"; }
# needs_human_flag/needs_human_clear below call that `gh` function directly,
# so sourcing this file WITHOUT `gh` already defined will make every call a
# plain (probably missing) `gh` binary — fine in a fixture that expects zero
# gh side effects, but callers that want real label/comment behavior must
# define `gh` first, exactly like they already do for their own gh calls.
#
# This file intentionally does NOT `set -e`/`set -u`/etc — it is SOURCED into
# the caller's shell, and changing the caller's shell options out from under
# it would be a much bigger foot-gun than the small amount of defensiveness
# lost by not doing so here. Every statement in both functions below already
# ends in `|| true` for exactly this reason: they must be safe to call from a
# caller running under `set -e` (pr-feedback.sh, merge-ready.sh) AND one that
# isn't (loop-tick.sh).
#
# needs_human_flag TARGET KIND SEVERITY TITLE BODY
#   TARGET: "issue:<N>" or "pr:<N>" — which GitHub object to label/comment on.
#   KIND:   a short escalation key, e.g. "attempt-budget", "stall",
#           "pr-review", "changes-requested", "expired", "daily-ceiling" —
#           combined with TARGET as notify.sh's throttle key (see notify.sh),
#           so distinct escalation kinds on the SAME target notify
#           independently, while repeats of the SAME kind on the SAME target
#           stay throttled to notify.sh's window.
#   SEVERITY/TITLE/BODY: passed straight through to notify.sh; BODY is also
#           posted as a comment on TARGET (skipped when BODY is empty).
#   Idempotent: `gh label create --force` never fails if the label already
#   exists; adding an already-present label is a no-op on GitHub's side.
#
# needs_human_clear TARGET KIND
#   Removes the needs-human label from TARGET (best-effort — a target that
#   was never labeled just no-ops) and clears notify.sh's throttle entry for
#   (KIND,TARGET), so a FUTURE flag of the same kind on the same target
#   notifies immediately instead of staying throttled from the episode that
#   just cleared. Call this from the success point where the corresponding
#   block-on-owner condition resolves (PR merged, approval given, issue
#   advanced, budget/attempts counter manually reset, etc).
#
# Both functions are best-effort throughout: a gh/notify failure here must
# NEVER break the calling script.
needs_human_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# $1 = "issue:42" or "pr:17" -> sets NH_TYPE ("issue"|"pr") and NH_NUM.
_needs_human_split_target() {
  local t="$1"
  NH_TYPE="${t%%:*}"
  NH_NUM="${t#*:}"
}

needs_human_flag() {
  local target="$1" kind="$2" severity="$3" title="$4" body="$5"
  _needs_human_split_target "$target"

  gh label create "needs-human" --color b60205 \
    --description "Loop is blocked on owner judgment -- see the issue/PR body/comments" \
    --force >/dev/null 2>&1 || true

  # NOTE: every conditional below ends in `|| true` on the OUTSIDE of the
  # `[ ... ] && { ... }` too (not just inside the braces) -- under a caller
  # running `set -e` (pr-feedback.sh, merge-ready.sh), a bare
  # `[ -n "$body" ] && { ...; }` statement whose test is FALSE evaluates the
  # whole statement to non-zero and would trip errexit right here.
  case "$NH_TYPE" in
    pr)
      gh pr edit "$NH_NUM" --add-label needs-human >/dev/null 2>&1 || true
      { [ -n "$body" ] && gh pr comment "$NH_NUM" --body "$body" >/dev/null 2>&1; } || true
      ;;
    issue)
      gh issue edit "$NH_NUM" --add-label needs-human >/dev/null 2>&1 || true
      { [ -n "$body" ] && gh issue comment "$NH_NUM" --body "$body" >/dev/null 2>&1; } || true
      ;;
    *) ;;
  esac

  local body_line
  body_line="$(printf '%s\n' "$body" | head -1)"
  bash "$needs_human_script_dir/notify.sh" "$severity" "$title" "$body_line" \
    --kind "$kind" --target "$target" >/dev/null 2>&1 || true
}

needs_human_clear() {
  local target="$1" kind="$2"
  _needs_human_split_target "$target"

  case "$NH_TYPE" in
    pr) gh pr edit "$NH_NUM" --remove-label needs-human >/dev/null 2>&1 || true ;;
    issue) gh issue edit "$NH_NUM" --remove-label needs-human >/dev/null 2>&1 || true ;;
    *) ;;
  esac

  bash "$needs_human_script_dir/notify.sh" --clear --kind "$kind" --target "$target" >/dev/null 2>&1 || true
}
