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
# `loop-event: action=advance|feedback|ci-fix ...` line below.
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
#   loop-event: action=comment-fix pr=N   (issue #96 part 2)
#   loop-event: action=ci-fix pr=N
#   loop-event: action=rebase pr=N   (issue #96 part 3)
#   loop-event: model=<model>
#   loop-event: prompt-file=<absolute path to a plain-text file holding the
#               verdict-obeying prompt for the driver session>
#     -> actionable. The caller is expected to spawn something equivalent to
#        `claude --model <model> -p "$(cat <prompt-file>)" --output-format json`
#        itself, under whatever containment it wants (loop-daemon.sh wraps it
#        in setsid + timeout + a run-ledger append) — this script never execs
#        claude, setsid, or timeout.
#
# Exit code: 0 on `action=none` OR a successfully emitted advance/feedback/
# ci-fix verdict (in which case a prompt-file was written). Non-zero if
# loop-tick.sh itself failed, or its verdict line failed to parse — in EITHER
# case a `loop-event: action=none` line is STILL printed last (so a caller
# doing a blind `sed -n 's/^loop-event: action=//p' | tail -1` never sees a
# stale or missing action), and no prompt-file is written.
#
# Honors $GATES_FILE: not read directly here beyond quoting it into the
# self-hosting adapter clause baked into the prompt below (loop-tick.sh and
# loop-census.sh are what actually act on it).
#
# Plan gate (issue #100): for action=advance, loop-tick.sh's stdout carries an
# advance_mode=plan|implement-gated|implement line (present only when
# plan.gate != "off" — see gates.json) that this script greps out (never
# tail -1 — that's the verdict) to pick one of three ADVANCE prompt variants:
# a PLAN-ONLY turn that posts a structured plan comment + plan-review/
# needs-human labels and writes no code, a normal implement turn with the
# owner-approved plan comment injected into the implementer/every reviewer as
# authoritative scope, or (mode absent/"implement") today's unchanged
# single-pass prompt.
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
  "action=comment-fix pr="*) n="${verdict#action=comment-fix pr=}" ;;
  "action=ci-fix pr="*)     n="${verdict#action=ci-fix pr=}" ;;
  "action=rebase pr="*)     n="${verdict#action=rebase pr=}" ;;
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

# Plan-gate mode (issue #100): loop-tick.sh echoes advance_mode=<mode> into
# its own stdout ONLY alongside a genuine action=advance verdict -- grep the
# FULL tick output for it (never tail -1; that line is not the verdict).
# Defaults to "implement" (today's ungated single-pass prompt) whenever the
# line is absent -- action=feedback verdicts, and every advance verdict when
# plan.gate=off (the vast majority of ticks).
mode="$(printf '%s\n' "$tick_out" | sed -n 's/^advance_mode=//p' | tail -1)"
mode="${mode:-implement}"

# Adapter clause: only when this loop runs against a non-default adapter
# (self-hosting). Mirrors the wording in .claude/self/pr-loop-self.md.
adapter=""
if [ -n "${GATES_FILE:-}" ]; then
  adapter="Export GATES_FILE=$GATES_FILE for every gate/orchestration step, and instruct every spawned agent (orchestrator, implementers, reviewers) to read $GATES_FILE — NOT the placeholder root .claude/gates.json — as its adapter (module map, gates, review lenses). Every gate.sh invocation MUST run as: GATES_FILE=$GATES_FILE bash $script_dir/gate.sh <name>. "
fi
common="The tick (loop-tick.sh) already ran census/poll/merge/feedback-detection/ci-fix-detection this firing and emitted this verdict — do NOT re-run those scripts and do NOT re-derive the verdict. ${adapter}ALL gh interaction (yours and every agent's) MUST run as the bot via bash $script_dir/bot-gh.sh — never bare gh; only git commits/pushes stay as the owner. Follow docs/USAGE.md and .claude/agents/*; reviewer lenses + consensus per the adapter. YOU ARE A HEADLESS ONE-SHOT SESSION: the moment you end your turn, this session and every background process/agent it spawned are terminated (a background orchestrator gets at most a short grace ceiling, then is killed mid-work — observed 2026-07-10: two drivers exited 'cleanly' leaving half-born local branches that wedged their issues as in_flight). Therefore run the ENTIRE orchestration SYNCHRONOUSLY: spawn the orchestrator and every agent in the FOREGROUND (run_in_background: false), wait for each to finish, and do NOT end your turn until the work product exists on GitHub (the bot PR is open, or the feedback/ci-fix push + marker comment landed) or you are reporting a definite failure — never a 'running in background, will report later' message, which is a self-deception in this mode. If orchestration fails partway, CLEAN UP before exiting: delete any local feat/issue-N-* branch and worktree you created that has no open PR, so census never mistakes your debris for in-flight work. Keep the final report to a few lines — it is telemetry, not documentation."

case "$verdict" in
  action=advance*)
    action_line="action=advance issue=$n"
    case "$mode" in
      # --- plan.gate: needs-plan -> PLAN-ONLY turn (issue #100) -------------
      # Scope the issue and post ONE structured plan comment; apply the
      # plan-review + needs-human labels for owner review; then STOP. No
      # code, no branch, no PR -- the driver's job this turn is the plan
      # artifact and the labels, nothing else.
      plan)
        prompt="Run the PLAN step of the autonomous PR loop for issue #$n (plan.gate). $common
This is a PLAN ONLY phase (plan.gate). Do NOT implement — write no code, create no feat/issue-$n-* branch, and open no PR. STOP once the plan comment and labels below are posted; do not spawn an implementer or any reviewer this turn.
1. Read issue #$n (\`bash $script_dir/bot-gh.sh issue view $n\`) and scope it: which module (per gates.json's \`modules[]\`) it belongs to, the files you expect the eventual implementation to touch, the implementation approach, and how each of the issue's acceptance criteria maps to that approach.
2. Post exactly ONE structured plan comment on issue #$n via \`bash $script_dir/bot-gh.sh issue comment $n --body \"...\"\`. The comment body MUST begin with the literal marker \`<!-- plan-gate:plan -->\` on its own first line, followed by the module, expected files, approach, and acceptance-criteria mapping from step 1 — this is the durable, reviewable plan artifact the owner and the later implement turn both read.
3. Create the plan-gate labels if they don't already exist (idempotent, mirrors needs-human.sh's own pattern): \`bash $script_dir/bot-gh.sh label create plan-review --color fbca04 --description \"Plan posted, awaiting owner review (plan.gate)\" --force\` and \`bash $script_dir/bot-gh.sh label create needs-human --color b60205 --description \"Loop is blocked on owner judgment\" --force\`.
4. Apply both labels to issue #$n: \`bash $script_dir/bot-gh.sh issue edit $n --add-label plan-review --add-label needs-human\`.
5. Report done and STOP. The owner reviews the plan comment on GitHub and either replaces \`plan-review\` with \`plan-approved\` (approve — the next tick implements it, with your plan injected as authoritative scope) or removes \`plan-review\` (request changes — the loop re-plans on a later tick)."
        ;;
      # --- plan.gate: gated-approved -> normal implement turn, PLUS the
      # approved plan is authoritative scope for the implementer AND every
      # reviewer (issue #100). ----------------------------------------------
      implement-gated)
        prompt="Run the ADVANCE step of the autonomous PR loop for issue #$n. $common
Drive issue #$n through the orchestrator: scope → worktree implementer → gate.sh gates → reviewer lenses → bot PR. One issue in flight at a time — work ONLY issue #$n. \`backlog\` issues are owner-unapproved: if you file an issue yourself, label it backlog — NEVER planned (that label is the owner's formal approval, assigned by the owner alone).
This issue is plan-gated and APPROVED (plan.gate). Before implementing, fetch the approved plan: \`bash $script_dir/bot-gh.sh issue view $n --json comments\` and locate the comment whose body begins with the marker \`<!-- plan-gate:plan -->\`. Treat that plan as the AUTHORITATIVE scope for this issue. Inject the plan text VERBATIM into the implementer's spawn prompt as its authoritative scope, AND into every reviewer's spawn prompt. Instruct the correctness reviewer explicitly: a diff that exceeds the approved plan's declared files or approach is a valid reject reason under the correctness lens (\"exceeds approved scope\")."
        ;;
      # --- ungated (plan.gate=off, or label mode without plan-first) -------
      # today's single-pass prompt, byte-identical to pre-#100 behavior.
      *)
        prompt="Run the ADVANCE step of the autonomous PR loop for issue #$n. $common
Drive issue #$n through the orchestrator: scope → worktree implementer → gate.sh gates → reviewer lenses → bot PR. One issue in flight at a time — work ONLY issue #$n. \`backlog\` issues are owner-unapproved: if you file an issue yourself, label it backlog — NEVER planned (that label is the owner's formal approval, assigned by the owner alone)."
        ;;
    esac
    ;;
  action=comment-fix*)
    prompt="Run the COMMENT-FIX step of the autonomous PR loop for PR #$n (issue #96 part 2). $common
PR #$n has one or more UNRESOLVED, qualifying inline review-comment threads (see the \`5/7 pr-comment-fix.sh\` section above for the exact thread id(s) and next attempt number(s), formatted \`<thread_id>:<attempt>\`). Before starting, label the PR \`claude-comment-fixing\` via bot-gh.sh (create the label with --force if it doesn't exist yet) as an in-flight guard against a second tick double-dispatching this same PR. Address the threads: orchestrator → worktree implementer on the SAME branch (checkout the PR's existing branch, do NOT create a new one) → reviewer lenses per the adapter, push the fix(es) to update the PR in place. Then, for EACH thread you actually addressed (and ONLY those — do not claim one you didn't touch): (1) resolve that review thread on GitHub (\`bot-gh.sh api graphql -f query='mutation{resolveReviewThread(input:{threadId:\"<thread_id>\"}){thread{id}}}'\`), and (2) post ONE bot comment on the PR whose body contains, for every addressed thread, a line \`<!-- claude-comment-addressed:<thread_id>:<attempt> -->\` (substituting the real thread id and the EXACT attempt number pr-comment-fix.sh's output gave you for that thread — this is the cursor pr-comment-fix.sh checks so an already-fixed-but-not-yet-re-reviewed thread isn't re-dispatched every tick, while a genuinely NEW comment reopening the thread still re-triggers). Do NOT merge, and do NOT force-push."
    action_line="action=comment-fix pr=$n"
    ;;
  action=ci-fix*)
    prompt="Run the CI-FIX step of the autonomous PR loop for PR #$n. $common
PR #$n has a FAILING CI check on its current head (see the \`6/7 pr-ci-fix.sh\` section above for which check(s) and its head SHA). Before starting, label the PR \`claude-ci-fixing\` via bot-gh.sh (create the label with --force if it doesn't exist yet) as an in-flight guard against a second tick double-dispatching this same PR. Address the failure: orchestrator → worktree implementer on the SAME branch (checkout the PR's existing branch, do NOT create a new one) → reviewer lenses per the adapter, push the fix to update the PR in place. After pushing, query the PR's CURRENT head commit SHA (bot-gh.sh pr view $n --json headRefOid) and post a bot comment containing exactly \`<!-- claude-ci-addressed:<that-head-sha> -->\` (substituting the real SHA) — this is the cursor pr-ci-fix.sh checks so an unresolved-but-still-rerunning check isn't re-dispatched every tick, while a genuinely NEW failure on a NEW commit still re-triggers. Do NOT merge, and do NOT force-push."
    action_line="action=ci-fix pr=$n"
    ;;
  action=rebase*)
    prompt="Run the REBASE step of the autonomous PR loop for PR #$n (issue #96 part 3). $common
PR #$n has gone unmergeable (GitHub reports mergeable=CONFLICTING against base), typically because a sibling PR merged into base first (see the \`7/7 pr-rebase.sh\` section above for its branch, head/base SHA, and this attempt's number). Before starting, label the PR \`claude-rebasing\` via bot-gh.sh (create the label with --force if it doesn't exist yet) as an in-flight guard against a second tick double-dispatching this same PR. Checkout the PR's EXISTING branch/worktree — do NOT create a new branch and do NOT create a new PR. Run \`git fetch origin\` then \`git rebase origin/<the adapter's merge.baseBranch>\` on that branch. Exactly one of two outcomes follows:
1. CLEAN rebase: force-push it back in place with \`git push --force-with-lease\` (a deliberate, accepted policy exception — this is the bot's own branch), then rerun the adapter's build/lint/test gates (\`GATES_FILE=... bash $script_dir/gate.sh <name>\`, per the adapter clause above) to confirm the rebased branch is still green, then post ONE bot comment on the PR containing exactly \`<!-- claude-rebase-attempted:<base_sha>:<attempt> -->\` (substituting the PR's CURRENT base_sha and the EXACT attempt number pr-rebase.sh's output gave you) — this is the cursor pr-rebase.sh checks so a PR that stays CONFLICTING against the SAME base commit isn't re-dispatched forever, while a NEW sibling merge (a new base_sha) always resets the budget.
2. CONFLICT: run \`git rebase --abort\` immediately — never leave the worktree mid-rebase. Label the PR \`needs-human\` via bot-gh.sh (create the label with --force if it doesn't exist yet, color b60205, mirroring needs-human.sh's seam) and post ONE bot comment explaining the conflict (which files/hunks conflicted) that ALSO contains \`<!-- claude-rebase-attempted:<base_sha>:<attempt> -->\` (same substitution as above), so pr-rebase.sh's cursor still reflects this attempt if a human later clears the label.
NEVER force-merge, and NEVER merge, in either outcome."
    action_line="action=rebase pr=$n"
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
