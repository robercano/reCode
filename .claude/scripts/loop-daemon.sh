#!/usr/bin/env bash
# loop-daemon.sh — the forever loop for the cron-less autonomous PR loop
# (issue #102). Replaces the session-scoped CronCreate loop: systemd (user)
# supervises THIS process (pr-loop.service, Restart=always) instead of a
# Claude Code session that dies with the session that armed it.
#
# Each iteration: run loop-event.sh (which runs the deterministic tick via
# loop-tick.sh); on `loop-event: action=none` sleep and repeat WITHOUT
# spawning anything; on an actionable verdict, spawn exactly ONE contained
# driver session, ledger it, then sleep for however long the tick's census
# cadence line says. Never runs two driver sessions concurrently — this loop
# is itself single-threaded/sequential, and loop-tick.sh's own spawn lock
# additionally guards against a second overlapping tick anywhere else
# (e.g. the legacy /pr-loop cron still armed at the same time) double-firing
# the same ADVANCE.
#
# DRIVER CONTAINMENT (claude-code#29096): a driver is spawned via `setsid`
# (its own session/process group, independent of this daemon's) wrapped in
# `timeout <LOOP_DRIVER_TIMEOUT, default 90m>` with `--kill-after=30s`; on
# timeout the whole process GROUP is targeted (not just the immediate child)
# so a driver's own bash children can never be orphaned by a bare SIGTERM.
#
# RUN LEDGER: one line per driver appended to .claude/state/loop-runs.log:
#   pid=<pgid> session=<session_id> verdict=<advance issue=N|feedback pr=N> ts=<ISO8601> [result=exit|timeout|phantom rc=N] [pr=N] [debris=empty|publishable|half-done [action=deleted|resumable]] [verify=skipped]
# session_id is parsed out of the driver's own --output-format json stdout,
# so a hung/dead driver can be inspected later with
# `claude --resume <session_id> --fork-session` (safe while it's still
# running; transcripts are append-only JSONL). .claude/state/ is gitignored —
# this ledger is never committed.
#
# POST-EXIT VERIFICATION + DEBRIS CLASSIFIER (issue #111): two incident
# classes wedged the loop before this fix — (1) a driver spawned its
# orchestrator in the BACKGROUND and ended its own headless turn early,
# leaving a half-born local `feat/issue-N-*` branch with no commits/push/PR
# while the ledger recorded a phantom `result=exit rc=0` and census read the
# local branch as in_flight forever, silently starving that issue; (2) a
# driver killed mid-flight AFTER committing gates-green work but BEFORE
# pushing — a naive "delete any debris branch" fix would have DESTROYED that
# finished work (recovered manually as PR #117 for issue #107). The fix:
# after every `advance issue=N` driver exits (skipping timeouts/spawn-errors,
# which have no work product to check yet), verify_and_classify_post_exit
# queries GitHub for an open PR on that issue's branch, corrects
# `result=exit rc=0` to `result=phantom rc=0` when none exists, and calls
# classify_debris (pure git, no network) to tell an `empty` branch (safe to
# delete — case 1 above) apart from `publishable`/`half-done` (real work,
# NEVER deleted — case 2 above). Only the `empty`+no-PR case is destructive.
#
# Env:
#   LOOP_MODEL                   model for the driver (default sonnet; read by loop-event.sh)
#   GATES_FILE                   adapter override, passed straight through the environment
#                                 (self-hosting: .claude/self/gates.json)
#   LOOP_DRIVER_TIMEOUT          wall-clock cap per driver (default 90m)
#   LOOP_DAEMON_SLEEP_FAST/WATCH/IDLE/FALLBACK   override the adaptive-sleep seconds (test hook)
#   LOOP_DAEMON_MAX_ITERATIONS   bound the forever loop; 0 = unbounded (test/debug hook)
#   CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS   forced to 0 for the driver spawn (issue #111 pt 4)
#                                 unless the caller already set it — fail-fast on a
#                                 backgrounded driver instead of a silent half-completion
#
# Sourcing this file (rather than executing it) has ZERO side effects — every
# function below only runs when called, and `main` only runs when this file
# is executed directly (the BASH_SOURCE guard at the bottom). This is what
# loop-daemon.test.sh relies on to unit-test cadence_to_sleep_seconds and
# ledger_line without spinning up the real forever loop.
set -uo pipefail

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"

state_dir="$root/.claude/state"
ledger="$state_dir/loop-runs.log"

log() { printf '%s loop-daemon: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

# --- adaptive sleep: parse the census `cadence=FAST|WATCH|IDLE cron=<expr>` line ---
# $1 = any text to scan (typically loop-event.sh's full stdout, which passes
# loop-tick.sh's `cadence=...` line straight through). Prints seconds to sleep.
cadence_to_sleep_seconds() {
  local out="${1:-}"
  local cadence
  cadence="$(printf '%s\n' "$out" | sed -n 's/^cadence=\([A-Z]*\).*/\1/p' | tail -1)"
  case "$cadence" in
    FAST)  echo "${LOOP_DAEMON_SLEEP_FAST:-60}" ;;
    WATCH) echo "${LOOP_DAEMON_SLEEP_WATCH:-300}" ;;
    IDLE)  echo "${LOOP_DAEMON_SLEEP_IDLE:-900}" ;;
    *)     echo "${LOOP_DAEMON_SLEEP_FALLBACK:-300}" ;;
  esac
}

# --- run ledger ---------------------------------------------------------------
# $1=pgid $2=session_id (may be empty -> printed as "unknown") $3=verdict
# (e.g. "advance issue=42") $4=ts(ISO8601) $5=extra (optional, e.g.
# "result=exit rc=0" / "result=timeout rc=124") appended verbatim if non-empty.
ledger_line() {
  local pgid="$1" session="$2" verdict="$3" ts="$4" extra="${5:-}"
  local line="pid=$pgid session=${session:-unknown} verdict=$verdict ts=$ts"
  [ -n "$extra" ] && line="$line $extra"
  printf '%s\n' "$line"
}

append_ledger() {
  mkdir -p "$state_dir"
  ledger_line "$@" >> "$ledger"
}

# --- claude-on-PATH resolution (daemon/service environments lack nvm) --------
ensure_claude_on_path() {
  if ! command -v claude >/dev/null 2>&1; then
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
  fi
  command -v claude >/dev/null 2>&1
}

# --- extract a session_id out of a --output-format json driver transcript ----
# Deliberately grep/sed, not `node -e ...`: a daemon/service environment that
# needed ensure_claude_on_path's nvm fallback to find `claude` may still not
# have `node` itself resolvable the same way (and re-sourcing nvm a second
# time here would re-prepend nvm's bin dir onto PATH, risking it shadowing an
# already-resolved non-nvm `claude`). Covers both the documented single-object
# `--output-format json` shape and a JSONL stream (last match wins either way).
extract_session_id() {
  local out_file="$1"
  [ -f "$out_file" ] || return 0
  grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$out_file" 2>/dev/null \
    | tail -1 \
    | sed -E 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
}

# --- map a local branch name -> its worktree's absolute path, if any --------
# Same idea as worktree-cleanup.sh's own worktree_for_branch, but deliberately
# pure bash/git — NOT node — parsing `git worktree list --porcelain`'s
# blank-line-separated records. This mirrors extract_session_id's own
# grep/sed-not-node rule above: a daemon/service environment that needed
# ensure_claude_on_path's nvm fallback to find `claude` may still not have
# `node` resolvable, and this runs unconditionally on every advance driver
# exit (unlike worktree-cleanup.sh, which only runs after a successful gh
# merge where node was already required). Prints nothing (not an error) when
# the branch has no worktree.
worktree_for_branch() {
  local want="$1" path="" branch="" line
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }" ;;
      "branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
      "")
        if [ -n "$path" ] && [ "$branch" = "$want" ]; then
          printf '%s' "$path"
          return 0
        fi
        path="" branch=""
        ;;
    esac
  done < <(git -C "$root" worktree list --porcelain 2>/dev/null; printf '\n')
}

# --- debris classifier (issue #111 pt 2) -------------------------------------
# $1=branch $2=worktree_dir (may be empty/nonexistent). PURE SHELL, NETWORK
# FREE — only `git` against the local repo. Echoes exactly one of:
#   absent       branch doesn't exist at all in the relevant repo (nothing to
#                classify)
#   empty        no commits ahead of main AND worktree clean/absent — safe to
#                delete (the #91/#92 half-born-branch case)
#   publishable  commits ahead of main AND worktree clean — real work, a PR
#                should exist or be opened for it, NEVER delete
#   half-done    commits ahead but the worktree is dirty (uncommitted work),
#                OR ahead=0 with a dirty worktree — resumable, NEVER delete
#
# Repo context: when $2 is a real directory it's used as the git context for
# BOTH the branch-existence/ahead-count check and the dirty check (a linked
# worktree shares refs/objects with its parent repo, so this works whether
# $2 is a genuine `git worktree add` checkout or a standalone repo — the
# latter is what loop-daemon.test.sh uses to unit-test this function in full
# isolation from the real project's own git state). Falls back to the
# daemon's own $root only when no worktree dir was given/found.
#
# NOTE (documented assumption): the issue asked for a per-branch events.jsonl
# gates/review signal to distinguish "publishable" more precisely. This repo's
# events.jsonl (log-event.sh) is a single GLOBAL, size-capped, rotating log —
# there is no per-branch event trail to inspect. So "publishable" here is
# "commits ahead of main + clean worktree", full stop; a finer-grained
# gates/review-verified signal is left for a follow-up if it's ever needed.
classify_debris() {
  local branch="$1" wt="${2:-}"
  local repo="$root"
  [ -n "$wt" ] && [ -d "$wt" ] && repo="$wt"

  if ! git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
    echo "absent"
    return 0
  fi

  local ahead
  ahead="$(git -C "$repo" rev-list --count "main..$branch" 2>/dev/null || echo 0)"
  [ -n "$ahead" ] || ahead=0

  local dirty=0
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && dirty=1
  fi

  if [ "$ahead" -eq 0 ] && [ "$dirty" -eq 0 ]; then
    echo "empty"
  elif [ "$ahead" -gt 0 ] && [ "$dirty" -eq 0 ]; then
    echo "publishable"
  else
    echo "half-done"
  fi
}

# --- post-exit verification + ledger honesty (issue #111 pt 1) --------------
# $1=verdict $2=rc $3=extra (the "result=... rc=N" string run_driver already
# built). Echoes the (possibly augmented/replaced) extra string the ONE
# ledger line should carry instead — never appends a second ledger line.
#
# Only applies to `advance issue=N` verdicts with a non-timeout/non-spawn-error
# rc (124/137/127 pass $3 straight through unchanged: a killed/never-spawned
# driver has no work product to verify yet). All GitHub access goes through
# bot-gh.sh; a failed/offline/empty query degrades to appending `verify=skipped`
# — it NEVER falsely declares `result=phantom`, and NEVER deletes anything, on
# a network hiccup. classify_debris (pure git) still runs regardless of
# network reachability.
verify_and_classify_post_exit() {
  local verdict="$1" rc="$2" extra="$3"

  case "$verdict" in
    "advance issue="*) : ;;
    *) printf '%s' "$extra"; return 0 ;;
  esac
  case "$rc" in
    124|137|127) printf '%s' "$extra"; return 0 ;;
  esac
  local n="${verdict#advance issue=}"
  case "$n" in
    *[!0-9]*|'') printf '%s' "$extra"; return 0 ;;
  esac

  # Local branch for this issue, if any — there may be none (e.g. the driver
  # never even reached `git checkout -b`). `git branch --list` prefixes the
  # CURRENTLY CHECKED OUT branch with "* " and any branch checked out in a
  # DIFFERENT linked worktree with "+ " (this is exactly that case — the
  # driver's own worktree has it checked out) — strip both markers, same as
  # worktree-cleanup.sh's own `git branch --merged` parsing does.
  local branch
  branch="$(git -C "$root" branch --list "feat/issue-$n-*" 2>/dev/null | sed 's/^[*+ ]*//' | head -1)"

  # Query GitHub for an OPEN PR whose head branch matches feat/issue-N-* —
  # this works whether or not a LOCAL branch still exists (the driver may
  # have pushed + opened a PR from a worktree already cleaned up elsewhere).
  local gh_out gh_rc pr_num=""
  gh_out="$(bash "$script_dir/bot-gh.sh" pr list --state open --json number,headRefName \
    --jq ".[] | select(.headRefName | test(\"^feat/issue-$n-\")) | .number" 2>/dev/null)"
  gh_rc=$?

  if [ "$gh_rc" -ne 0 ]; then
    # offline/failure: degrade gracefully — never falsely declare phantom,
    # never delete on a network hiccup.
    printf '%s verify=skipped' "$extra"
    return 0
  fi
  pr_num="$(printf '%s\n' "$gh_out" | head -1)"

  local out="$extra"
  if [ -n "$pr_num" ]; then
    out="$out pr=$pr_num"
  elif [ "$rc" -eq 0 ]; then
    # rc=0 with NO open PR: the naive "result=exit rc=0" would be a phantom
    # success (issue #111 pt 1) — the driver ended cleanly without its work
    # product ever landing on GitHub. Correct the record, don't just append.
    out="$(printf '%s' "$out" | sed -E 's/result=exit/result=phantom/')"
  fi

  if [ -n "$branch" ]; then
    local wt state
    wt="$(worktree_for_branch "$branch")"
    state="$(classify_debris "$branch" "$wt")"
    out="$out debris=$state"

    case "$state" in
      empty)
        # The ONLY destructive path (case A) — provably no commits, no dirty
        # worktree, no open PR. Case B/C (publishable/half-done) are NEVER
        # touched here (deferred publish / resumable, respectively).
        if [ -z "$pr_num" ]; then
          if [ -n "$wt" ]; then
            git -C "$root" worktree remove --force "$wt" 2>/dev/null || true
          fi
          if git -C "$root" branch -D "$branch" >/dev/null 2>&1; then
            out="$out action=deleted"
            log "post-exit debris cleanup: deleted empty local branch/worktree for issue #$n ($branch)"
          fi
        fi
        ;;
      half-done)
        out="$out resumable"
        ;;
      *)
        : # publishable/absent: recorded via debris=$state above, nothing else to do
        ;;
    esac
  fi

  printf '%s' "$out"
}

# --- spawn ONE contained driver, block until it exits/times out, ledger it ---
# $1=verdict (e.g. "advance issue=42"), $2=model, $3=prompt-file (plain text).
# Returns the driver's exit code (124/137 on timeout).
run_driver() {
  local verdict="$1" model="$2" prompt_file="$3"
  local timeout_dur="${LOOP_DRIVER_TIMEOUT:-90m}"
  local ts; ts="$(date -u +%FT%TZ)"

  if ! ensure_claude_on_path; then
    log "'claude' CLI not found on PATH (nor via nvm) — cannot spawn the driver for $verdict"
    append_ledger "unknown" "" "$verdict" "$ts" "result=spawn-error rc=127"
    return 127
  fi
  if [ ! -f "$prompt_file" ]; then
    log "prompt-file '$prompt_file' does not exist — cannot spawn the driver for $verdict"
    append_ledger "unknown" "" "$verdict" "$ts" "result=spawn-error rc=2"
    return 2
  fi

  local prompt; prompt="$(cat "$prompt_file")"
  local out_file; out_file="$(mktemp "$state_dir/.loop-driver-out.XXXXXX.json")"

  log "spawning driver ($verdict, model=$model, timeout=$timeout_dur)"
  # Fail-fast spawn (issue #111 pt 4): a driver session that backgrounds its
  # own orchestrator/agents can otherwise end its headless turn "cleanly"
  # while that background work is still mid-flight — the half-born-branch
  # incident this whole file's post-exit verification exists to catch.
  # Forcing this ceiling to 0 makes a backgrounded spawn die loudly (instead
  # of half-completing) so the failure is immediate and visible, not a
  # phantom success discovered later. Still overridable by the caller's env.
  export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-0}"
  # setsid: own session, so the whole tree (claude + any bash children it
  # spawns) shares ONE fresh process group independent of this daemon's own —
  # timeout's --kill-after below then has a single group to aim at. Backstop
  # explicit group kill after `wait` covers anything that outlives timeout's
  # own signal delivery (claude-code#29096: a bare SIGTERM to just the
  # immediate child has been observed to orphan bash children).
  setsid timeout --kill-after=30s "$timeout_dur" \
    claude --model "$model" -p "$prompt" --output-format json \
    >"$out_file" 2>"$out_file.stderr" &
  local pgid=$!
  wait "$pgid"
  local rc=$?
  kill -TERM -- "-$pgid" 2>/dev/null || true

  local session_id; session_id="$(extract_session_id "$out_file")"

  local extra
  case "$rc" in
    124|137) extra="result=timeout rc=$rc" ;;
    *)       extra="result=exit rc=$rc" ;;
  esac

  # Post-exit verification + debris classification (issue #111 pts 1-2) —
  # ONLY for advance verdicts with a non-timeout/non-spawn-error rc; may
  # replace `result=exit` with `result=phantom` and/or append pr=/debris=
  # fields onto the SAME extra string, so exactly one ledger line still
  # covers this whole run.
  case "$verdict" in
    "advance issue="*)
      case "$rc" in
        124|137|127) : ;;
        *) extra="$(verify_and_classify_post_exit "$verdict" "$rc" "$extra")" ;;
      esac
      ;;
  esac

  append_ledger "$pgid" "$session_id" "$verdict" "$ts" "$extra"
  log "driver finished ($verdict): $extra session=${session_id:-unknown}"
  rm -f "$out_file" "$out_file.stderr" "$prompt_file"
  return "$rc"
}

# --- one tick + (maybe) one driver spawn, sets NEXT_SLEEP as a side effect --
NEXT_SLEEP=300
run_once() {
  local out rc
  out="$(bash "$script_dir/loop-event.sh" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  NEXT_SLEEP="$(cadence_to_sleep_seconds "$out")"

  if [ "$rc" -ne 0 ]; then
    log "loop-event.sh exited $rc — not spawning a driver on a broken tick (retrying in ${NEXT_SLEEP}s)"
    return
  fi

  local action_line
  action_line="$(printf '%s\n' "$out" | sed -n 's/^loop-event: action=//p' | tail -1)"

  case "$action_line" in
    none|"")
      : # nothing actionable — no driver spawned
      ;;
    "advance issue="*|"feedback pr="*)
      local model prompt_file
      model="$(printf '%s\n' "$out" | sed -n 's/^loop-event: model=//p' | tail -1)"
      model="${model:-${LOOP_MODEL:-sonnet}}"
      prompt_file="$(printf '%s\n' "$out" | sed -n 's/^loop-event: prompt-file=//p' | tail -1)"
      if [ -z "$prompt_file" ]; then
        log "action=$action_line but no prompt-file was emitted — refusing to spawn"
      else
        run_driver "$action_line" "$model" "$prompt_file" || true
      fi
      ;;
    *)
      log "unrecognized loop-event action line: '$action_line' — treating as none this tick"
      ;;
  esac
}

main() {
  mkdir -p "$state_dir"
  # Resolve nvm-provisioned binaries ONCE, up front, for the whole daemon —
  # not only inside run_driver. A systemd (user) service PATH has `gh` but
  # neither `node` nor `claude`, and the tick's step scripts need node
  # (merge-ready.sh, loop-census.sh, write_tick_record): without this, ticks
  # under the service silently skip merges and tick records while polling
  # still works — a deadlock, since the only path that DID source nvm
  # (run_driver) is unreachable while an unmergeable PR keeps advance away.
  if ! ensure_claude_on_path; then
    log "warning: 'claude' not resolvable at startup (nor via nvm) — node-dependent tick steps and driver spawns will fail until PATH provides it"
    # append_ledger is pure bash (no node needed) — record the env-error even
    # though write_tick_record itself can't run without node (issue #107).
    append_ledger "unknown" "" "startup" "$(date -u +%FT%TZ)" "result=env-error"
  fi
  log "starting (LOOP_MODEL=${LOOP_MODEL:-sonnet} GATES_FILE=${GATES_FILE:-<default>} LOOP_DRIVER_TIMEOUT=${LOOP_DRIVER_TIMEOUT:-90m})"
  local iterations=0
  local max_iterations="${LOOP_DAEMON_MAX_ITERATIONS:-0}"
  while :; do
    iterations=$((iterations + 1))
    run_once
    if [ "$max_iterations" -gt 0 ] && [ "$iterations" -ge "$max_iterations" ]; then
      log "LOOP_DAEMON_MAX_ITERATIONS=$max_iterations reached — exiting (test/debug mode only; a real service loops forever)"
      break
    fi
    log "sleeping ${NEXT_SLEEP}s"
    sleep "$NEXT_SLEEP"
  done
}

# Only run the forever loop when EXECUTED, never when sourced (test hook).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
