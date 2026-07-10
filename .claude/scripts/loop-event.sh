#!/usr/bin/env bash
# loop-event.sh — one firing of the autonomous PR loop (cron-less entry point,
# issue #102). Adapted from the verified draft in the issue.
#
# Runs the deterministic tick (loop-tick.sh), parses its LAST-line verdict, and
# emits a small structured `loop-event: ...` block describing what (if
# anything) a caller should do next. This script touches NO model/driver
# process itself: issue #102's daemon (loop-daemon.sh) owns the
# setsid/timeout/ledger wrapping around the actual `claude -p` spawn, so a
# broken/garbage verdict here can NEVER result in a driver being spawned — the
# spawn is a whole separate step the caller only reaches by parsing the
# `loop-event: action=advance|feedback ...` line below.
#
# Never re-derives the verdict — issue #81 contract: it is computed ONCE, by
# loop-tick.sh's shell logic, and passed through byte-identical.
#
# Output contract — stdout is loop-tick.sh's own full, un-swallowed output,
# FOLLOWED by this script's own lines, every one of which is prefixed
# `loop-event: ` so a caller can `sed -n 's/^loop-event: //p'` them out
# without caring about anything above:
#
#   loop-event: action=none
#     -> nothing else is printed. NO model/driver process must be spawned.
#   loop-event: action=advance issue=N
#   loop-event: action=feedback pr=N
#   loop-event: model=<model>
#   loop-event: prompt-file=<absolute path to a plain-text file holding the
#               verdict-obeying prompt for the driver session>
#     -> actionable. The caller is expected to spawn something equivalent to
#        `claude --model <model> -p "$(cat <prompt-file>)" --output-format json`
#        itself, under whatever containment it wants (loop-daemon.sh wraps it
#        in setsid + timeout + a run-ledger append) — this script never execs
#        claude, setsid, or timeout.
#
# Exit code: 0 on `action=none` OR a successfully emitted advance/feedback
# verdict (in which case a prompt-file was written). Non-zero if loop-tick.sh
# itself failed, or its verdict line failed to parse — in EITHER case a
# `loop-event: action=none` line is STILL printed last (so a caller doing a
# blind `sed -n 's/^loop-event: action=//p' | tail -1` never sees a stale or
# missing action), and no prompt-file is written.
#
# Honors $GATES_FILE: not read directly here beyond quoting it into the
# self-hosting adapter clause baked into the prompt below (loop-tick.sh and
# loop-census.sh are what actually act on it).
set -uo pipefail

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"

cd "$root"

state_dir="$root/.claude/state"
mkdir -p "$state_dir"

# --- 1. Deterministic tick ---------------------------------------------------
tick_out="$(bash "$script_dir/loop-tick.sh")"
tick_rc=$?
printf '%s\n' "$tick_out"
if [ "$tick_rc" -ne 0 ]; then
  echo "loop-event: loop-tick.sh exited $tick_rc — not spawning a driver on a broken tick" >&2
  echo "loop-event: action=none"
  exit "$tick_rc"
fi
verdict="$(printf '%s\n' "$tick_out" | tail -1)"

# --- 2. Obey the verdict -----------------------------------------------------
n=""
case "$verdict" in
  action=none)
    echo "loop-event: no actionable activity — no driver to spawn"
    echo "loop-event: action=none"
    exit 0
    ;;
  "action=advance issue="*) n="${verdict#action=advance issue=}" ;;
  "action=feedback pr="*)   n="${verdict#action=feedback pr=}" ;;
  *)
    echo "loop-event: unexpected verdict line: $verdict" >&2
    echo "loop-event: action=none"
    exit 1
    ;;
esac
case "$n" in
  *[!0-9]*|'')
    echo "loop-event: verdict number failed to parse from: $verdict" >&2
    echo "loop-event: action=none"
    exit 1
    ;;
esac

# Adapter clause: only when this loop runs against a non-default adapter
# (self-hosting). Mirrors the wording in .claude/self/pr-loop-self.md.
adapter=""
if [ -n "${GATES_FILE:-}" ]; then
  adapter="Export GATES_FILE=$GATES_FILE for every gate/orchestration step, and instruct every spawned agent (orchestrator, implementers, reviewers) to read $GATES_FILE — NOT the placeholder root .claude/gates.json — as its adapter (module map, gates, review lenses). Every gate.sh invocation MUST run as: GATES_FILE=$GATES_FILE bash $script_dir/gate.sh <name>. "
fi
common="The tick (loop-tick.sh) already ran census/poll/merge/feedback-detection this firing and emitted this verdict — do NOT re-run those scripts and do NOT re-derive the verdict. ${adapter}ALL gh interaction (yours and every agent's) MUST run as the bot via bash $script_dir/bot-gh.sh — never bare gh; only git commits/pushes stay as the owner. Follow docs/USAGE.md and .claude/agents/*; reviewer lenses + consensus per the adapter. YOU ARE A HEADLESS ONE-SHOT SESSION: the moment you end your turn, this session and every background process/agent it spawned are terminated (a background orchestrator gets at most a short grace ceiling, then is killed mid-work — observed 2026-07-10: two drivers exited 'cleanly' leaving half-born local branches that wedged their issues as in_flight). Therefore run the ENTIRE orchestration SYNCHRONOUSLY: spawn the orchestrator and every agent in the FOREGROUND (run_in_background: false), wait for each to finish, and do NOT end your turn until the work product exists on GitHub (the bot PR is open, or the feedback push + marker comment landed) or you are reporting a definite failure — never a 'running in background, will report later' message, which is a self-deception in this mode. If orchestration fails partway, CLEAN UP before exiting: delete any local feat/issue-N-* branch and worktree you created that has no open PR, so census never mistakes your debris for in-flight work. Keep the final report to a few lines — it is telemetry, not documentation."

case "$verdict" in
  action=advance*)
    prompt="Run the ADVANCE step of the autonomous PR loop for issue #$n. $common
Drive issue #$n through the orchestrator: scope → worktree implementer → gate.sh gates → reviewer lenses → bot PR. One issue in flight at a time — work ONLY issue #$n. \`backlog\` issues are owner-unapproved: if you file an issue yourself, label it backlog — NEVER planned (that label is the owner's formal approval, assigned by the owner alone)."
    action_line="action=advance issue=$n"
    ;;
  *)
    prompt="Run the ADDRESS FEEDBACK step of the autonomous PR loop for PR #$n. $common
Address the unaddressed CHANGES_REQUESTED feedback on PR #$n: orchestrator → worktree implementer → reviewer lenses on the SAME branch, push to update the PR in place, and post the \`<!-- claude-addressed -->\` marker comment via bot-gh.sh. Do NOT merge."
    action_line="action=feedback pr=$n"
    ;;
esac

prompt_file="$(mktemp "$state_dir/.loop-event-prompt.XXXXXX")"
printf '%s\n' "$prompt" > "$prompt_file"

echo "=== loop-event: verdict-obeying driver requested ($action_line, model=${LOOP_MODEL:-sonnet}) ==="
echo "loop-event: $action_line"
echo "loop-event: model=${LOOP_MODEL:-sonnet}"
echo "loop-event: prompt-file=$prompt_file"
exit 0
