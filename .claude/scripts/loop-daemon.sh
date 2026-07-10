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
#   pid=<pgid> session=<session_id> verdict=<advance issue=N|feedback pr=N> ts=<ISO8601> [result=exit|timeout rc=N]
# session_id is parsed out of the driver's own --output-format json stdout,
# so a hung/dead driver can be inspected later with
# `claude --resume <session_id> --fork-session` (safe while it's still
# running; transcripts are append-only JSONL). .claude/state/ is gitignored —
# this ledger is never committed.
#
# Env:
#   LOOP_MODEL                   model for the driver (default sonnet; read by loop-event.sh)
#   GATES_FILE                   adapter override, passed straight through the environment
#                                 (self-hosting: .claude/self/gates.json)
#   LOOP_DRIVER_TIMEOUT          wall-clock cap per driver (default 90m)
#   LOOP_DAEMON_SLEEP_FAST/WATCH/IDLE/FALLBACK   override the adaptive-sleep seconds (test hook)
#   LOOP_DAEMON_MAX_ITERATIONS   bound the forever loop; 0 = unbounded (test/debug hook)
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
  ensure_claude_on_path \
    || log "warning: 'claude' not resolvable at startup (nor via nvm) — node-dependent tick steps and driver spawns will fail until PATH provides it"
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
