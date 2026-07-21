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
# If the caller has already computed a `$repo` ("owner/name") in its own
# top-level scope (every current caller does, right before sourcing this
# file), this file reuses it; otherwise it falls back to `gh repo view`.
#
# This file intentionally does NOT `set -e`/`set -u`/etc — it is SOURCED into
# the caller's shell, and changing the caller's shell options out from under
# it would be a much bigger foot-gun than the small amount of defensiveness
# lost by not doing so here. Every statement in both functions below already
# ends in `|| true` for exactly this reason: they must be safe to call from a
# caller running under `set -e` (pr-feedback.sh, merge-ready.sh) AND one that
# isn't (loop-tick.sh).
#
# REST, not `gh label`/`gh pr|issue edit --*-label` (issue #169): on this
# environment EVERY one of those used to silently no-op --
#   - `gh label create` -- gh 2.4.0 has no `gh label` subcommand at all.
#   - `gh pr|issue edit --add-label`/`--remove-label` -- a GraphQL scope error
#     with the bot token on gh 2.4.0.
# each one wrapped in `|| true`, so the label NEVER actually stuck, every tick
# read "no label" as a fresh episode, and the comment below posted on EVERY
# tick (99 identical comments on PR #168 overnight, ~128 on PR #161). All
# label reads/writes below go through `gh api` instead (proven to work with
# this token/gh version): POST .../labels to (idempotently) create the label,
# POST .../issues/N/labels to add it, DELETE .../issues/N/labels/needs-human
# to remove it, and a plain GET .../issues/N to read the current set. PRs ARE
# issues in the REST API, so this also collapses what used to be separate
# pr/issue branches into one shared code path.
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
#           posted as a comment on TARGET -- but ONLY on a FRESH escalation
#           episode that ALSO has its label add CONFIRMED (see below); always
#           skipped when BODY is empty.
#
#   Comment is first-transition-only (issue #99 re-review finding #1): BEFORE
#   (re-)adding the label, this reads TARGET's CURRENT labels from GitHub. If
#   `needs-human` is already present, this call is a REPEAT of an ongoing
#   escalation episode -- the label add + notify (still throttled by
#   notify.sh) still run, but the COMMENT is skipped, so a persisting
#   block-on-owner condition doesn't spam a fresh GitHub comment every tick
#   (loop-tick.sh/loop-census.sh invoke the callers of this seam every few
#   minutes for as long as the condition holds). If `needs-human` is ABSENT,
#   this is a fresh episode (first flag ever, or a prior episode was cleared).
#
#   CRITICAL INVARIANT (issue #169): a fresh episode is NOT enough on its own
#   -- the comment posts ONLY once the label add is CONFIRMED by re-reading
#   TARGET's labels AFTER the add (never from the add's exit code alone: old
#   gh (2.4.0) is known to exit non-zero on some calls that actually
#   succeeded, and swallowing every exit code with `|| true` throughout this
#   file means a genuinely FAILED add must never be mistaken for success
#   either). If the add is not confirmed, the comment is skipped -- an
#   unverifiable episode must never comment, since "the label never really
#   stuck" plus "post anyway" is exactly the mechanism that produced the
#   #168/#161 spam -- and the failure is logged LOUDLY to events.jsonl (via
#   log-event.sh, best-effort, mirroring loop-tick.sh's own log_loop_event
#   convention) so it is visible in the cockpit instead of silently
#   swallowed like every other step in this file.
#
# needs_human_clear TARGET KIND
#   Removes the needs-human label from TARGET (best-effort — a target that
#   was never labeled just no-ops; a 404 from the DELETE is the expected
#   steady state and is not distinguished from success) and clears notify.sh's
#   throttle entry for (KIND,TARGET), so a FUTURE flag of the same kind on the
#   same target notifies immediately instead of staying throttled from the
#   episode that just cleared. Call this from the success point where the
#   corresponding block-on-owner condition resolves (PR merged, approval
#   given, issue advanced, budget/attempts counter manually reset, etc).
#
# Both functions are best-effort throughout: a gh/notify failure here must
# NEVER break the calling script -- with the one deliberate exception of the
# confirmed-before-comment gate above, which fails CLOSED (no comment) instead
# of open, and instead surfaces loudly via events.jsonl.
needs_human_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# $1 = "issue:42" or "pr:17" -> sets NH_TYPE ("issue"|"pr") and NH_NUM.
_needs_human_split_target() {
  local t="$1"
  NH_TYPE="${t%%:*}"
  NH_NUM="${t#*:}"
}

# _needs_human_repo: prints "owner/name" -- reuses the caller's own `$repo`
# (every current caller computes this in its own top-level scope, right
# before sourcing this file) so this doesn't burn a second `gh repo view`
# round-trip per call; falls back to computing it directly (e.g. when this
# file is sourced standalone, as needs-human.test.sh does) if `$repo` is
# unset/empty. A failure here (offline/unauthenticated) just yields an empty
# string -- every REST call built from it below will then fail too, which is
# fine: this whole file is best-effort.
_needs_human_repo() {
  if [ -n "${repo:-}" ]; then
    printf '%s\n' "$repo"
  else
    gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null
  fi
}

# _needs_human_read_labels: prints TARGET's (NH_TYPE/NH_NUM, must already be
# split) current label names, one per line, via a plain REST GET -- PRs ARE
# issues in the REST API, so this is the SAME call for both kinds (issue #169
# unifies what used to be separate `gh pr view`/`gh issue view` branches).
# $1 = repo ("owner/name"). Read-only: never mutates anything.
_needs_human_read_labels() {
  local nh_repo="$1"
  gh api "repos/$nh_repo/issues/$NH_NUM" -q '.labels[].name' 2>/dev/null
}

# _needs_human_already_labeled: prints "yes" if TARGET currently carries the
# needs-human label on GitHub, "no" otherwise -- including on any read
# failure (offline/unauthenticated/missing gh/empty repo). $1 = repo.
_needs_human_already_labeled() {
  local nh_repo="$1" out=""
  out="$(_needs_human_read_labels "$nh_repo")" || out=""
  if printf '%s\n' "$out" | grep -qx "needs-human"; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

# _needs_human_log_error: best-effort append to events.jsonl via log-event.sh
# (issue #169) so a label-add that never got confirmed surfaces in the
# cockpit instead of silently vanishing behind this file's `|| true`s.
# Mirrors loop-tick.sh's own log_loop_event helper: role=orchestrator, and a
# missing log-event.sh (a fixture that doesn't ship it) is a silent no-op.
_needs_human_log_error() {
  local target="$1" detail="$2"
  [ -f "$needs_human_script_dir/log-event.sh" ] || return 0
  bash "$needs_human_script_dir/log-event.sh" --role orchestrator --task "$target" \
    --phase error --detail "$detail" >/dev/null 2>&1 || true
}

needs_human_flag() {
  local target="$1" kind="$2" severity="$3" title="$4" body="$5"
  _needs_human_split_target "$target"
  local nh_repo
  nh_repo="$(_needs_human_repo)" || nh_repo=""

  # Ensure the label exists repo-wide (idempotent create via REST -- issue
  # #169: gh 2.4.0 has no `gh label` subcommand, so this MUST go through
  # `gh api`). A 422 "already_exists" is the expected steady state; like every
  # other statement in this file it is swallowed by `|| true` -- this step is
  # NOT part of the confirmed-before-comment gate below (that gate only cares
  # about the per-target add a few lines down).
  gh api -X POST "repos/$nh_repo/labels" \
    -f name=needs-human -f color=b60205 \
    -f description="Loop is blocked on owner judgment -- see the issue/PR body/comments" \
    >/dev/null 2>&1 || true

  # Read BEFORE mutating: this call's own label add below must not make
  # itself look like a "repeat" episode.
  local fresh_episode="yes"
  { [ "$(_needs_human_already_labeled "$nh_repo")" = "yes" ] && fresh_episode="no"; } || true

  # Add the label via REST (issue #169): the one call shape proven to work
  # with this token/gh version. NOTE: exit code intentionally ignored here --
  # old gh (2.4.0) can exit non-zero parsing an otherwise-successful response;
  # the re-read immediately below is the actual ground truth, in EITHER
  # direction (see the CRITICAL INVARIANT note at the top of this file).
  printf '{"labels":["needs-human"]}' \
    | gh api -X POST "repos/$nh_repo/issues/$NH_NUM/labels" --input - >/dev/null 2>&1 || true

  local confirmed="no"
  { [ "$(_needs_human_already_labeled "$nh_repo")" = "yes" ] && confirmed="yes"; } || true

  # NOTE: every conditional below ends in `|| true` on the OUTSIDE of the
  # `[ ... ] && { ... }` too (not just inside the braces) -- under a caller
  # running `set -e` (pr-feedback.sh, merge-ready.sh), a bare
  # `[ -n "$body" ] && { ...; }` statement whose test is FALSE evaluates the
  # whole statement to non-zero and would trip errexit right here.
  if [ "$confirmed" = "yes" ]; then
    case "$NH_TYPE" in
      pr)
        { [ "$fresh_episode" = "yes" ] && [ -n "$body" ] && gh pr comment "$NH_NUM" --body "$body" >/dev/null 2>&1; } || true
        ;;
      issue)
        { [ "$fresh_episode" = "yes" ] && [ -n "$body" ] && gh issue comment "$NH_NUM" --body "$body" >/dev/null 2>&1; } || true
        ;;
      *) ;;
    esac
  else
    # The label add could not be confirmed -- fail LOUDLY instead of quietly
    # posting a comment for an escalation episode that GitHub itself does not
    # show as labeled (issue #169: this is precisely the mechanism that let
    # the #168/#161 spam happen).
    _needs_human_log_error "$target" "needs-human label add unconfirmed (kind=$kind) -- comment suppressed"
  fi

  local body_line
  body_line="$(printf '%s\n' "$body" | head -1)"
  bash "$needs_human_script_dir/notify.sh" "$severity" "$title" "$body_line" \
    --kind "$kind" --target "$target" >/dev/null 2>&1 || true
}

needs_human_clear() {
  local target="$1" kind="$2"
  _needs_human_split_target "$target"
  local nh_repo
  nh_repo="$(_needs_human_repo)" || nh_repo=""

  # REST DELETE (issue #169) -- a 404 (never labeled, or already cleared) is
  # the expected steady state and is not distinguished from success; like
  # every other statement in this file, best-effort only.
  gh api -X DELETE "repos/$nh_repo/issues/$NH_NUM/labels/needs-human" >/dev/null 2>&1 || true

  bash "$needs_human_script_dir/notify.sh" --clear --kind "$kind" --target "$target" >/dev/null 2>&1 || true
}
