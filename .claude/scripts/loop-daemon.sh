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
#   pid=<pgid> session=<session_id> verdict=<advance issue=N|feedback pr=N|ci-fix pr=N> ts=<ISO8601> [result=exit|timeout|phantom rc=N] [pr=N] [debris=empty|publishable|half-done [action=deleted|resumable]] [verify=skipped]
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
# DRIVER LIFETIME DECOUPLED FROM THE DAEMON (issue #119): the DRIVER
# CONTAINMENT setup above still leaves a driver living inside the DAEMON's
# own cgroup — `setsid` gives it an independent process *group*, but a
# process group is not a cgroup, and systemd's default `KillMode=control-group`
# kills the whole cgroup (driver included) whenever the daemon unit stops, be
# it a `systemctl --user restart`, a `Restart=always` crash-bounce, a host
# reboot/sleep, or `wsl --shutdown`. Evidence 2026-07-14/15: five of six
# drivers died ledger-less this way. The fix: when `systemd-run` is on PATH,
# `run_driver` spawns each driver as its OWN transient `--user` unit
# (`pr-loop-driver-issue<N>`/`pr-loop-driver-pr<N>`/`pr-loop-driver-cifix-pr<N>`,
# derived from the verdict)
# via `systemd-run --user --wait --collect --unit=... -p RuntimeMaxSec=<LOOP_DRIVER_TIMEOUT>`.
# The driver's real parent becomes the user manager — it lives in ITS OWN
# scope, independent of the daemon's cgroup — so a daemon restart/crash kills
# only the daemon's own `systemd-run --wait` waiter (a disposable client that
# blocks and relays the exit code), never the driver itself. `RuntimeMaxSec`
# (a systemd time-span, e.g. `90m`) replaces the `timeout` wrapper as the hard
# wall-clock ceiling, enforced by the user manager instead of the daemon, so
# an orphaned driver still has a real ceiling even if the daemon never comes
# back. When `systemd-run` is NOT on PATH (legacy-cron / non-systemd
# environments), `run_driver` falls back to the exact `setsid timeout
# --kill-after=30s ...` spawn documented above — unchanged. Both paths feed
# the SAME rc into the SAME ledger/verify code below; only the spawn+wait
# step branches. `main()` also re-attaches to any `pr-loop-driver-*` unit
# still active at startup (left running by a now-dead daemon) instead of
# ticking — see reattach_orphaned_drivers() — and `loop-census.sh` refuses to
# ADVANCE an issue whose driver unit is currently active. Ops helper:
# `.claude/scripts/loop-halt.sh` stops one/all/everything by hand.
#
# POST-REVIEW HARDENING (issue #119, second pass) — three gaps in the above:
#   (1) rc NORMALIZATION: `systemd-run --wait` relays `143` (128+SIGTERM) for
#       a unit killed by hitting its `RuntimeMaxSec` ceiling — NOT GNU
#       timeout's `124`/`137`. Left unnormalized, the `case "$rc" in 124|137)`
#       classification below never matches on the systemd path, so a real
#       timeout got ledgered as a plain `result=exit rc=143` AND wrongly
#       routed into `verify_and_classify_post_exit` (which deliberately skips
#       124/137/127 — a killed driver has no work product to verify yet).
#       `run_driver` now queries the unit's own `Result` property right after
#       `wait` returns and normalizes rc to 124 when it reads `timeout`, so
#       both spawn paths converge on the identical downstream classification.
#   (2) SPAWN/CONNECT FAILURE: branch selection was presence-based
#       (`command -v systemd-run`), not reachability-based — on a systemd host
#       where the `--user` bus is unreachable (classic cron with no
#       XDG_RUNTIME_DIR/session, or the user manager not running/lingering),
#       `systemd-run --user --wait` fails to connect with no fallback, and the
#       driver never spawns at all. `run_driver` now has the wrapped command
#       touch a start-marker file as its very first action; if that marker
#       never appears after `wait` returns, the driver never actually started
#       under the unit (a spawn/connect failure, not a genuine driver exit),
#       and `run_driver` falls through to the exact setsid+timeout fallback so
#       the driver still actually runs, exactly once.
#   (3) UNIT NAME COLLISION: a deterministic unit name can collide with a
#       lingering `failed` unit from a previous run (invisible to
#       `--state=active` reattach/census checks). `run_driver` now runs
#       `systemctl --user reset-failed <unit>` (best-effort, ignored on
#       failure) immediately before every spawn — the #2 fallback above still
#       catches this failure mode even if a stale unit somehow survives that.
#
# Env:
#   LOOP_MODEL                   model for the driver (default sonnet; read by loop-event.sh)
#   GATES_FILE                   adapter override, passed straight through the environment
#                                 (self-hosting: .claude/self/gates.json)
#   LOOP_DRIVER_TIMEOUT          wall-clock cap per driver (default 90m); becomes
#                                 systemd-run's `-p RuntimeMaxSec=` when systemd-run
#                                 is on PATH, else `timeout`'s duration (issue #119)
#   LOOP_DAEMON_SLEEP_FAST/WATCH/IDLE/FALLBACK   override the adaptive-sleep seconds (test hook)
#   LOOP_DAEMON_MAX_ITERATIONS   bound the forever loop; 0 = unbounded (test/debug hook)
#   LOOP_REATTACH_POLL_SECONDS   poll interval while re-attaching to an orphaned
#                                 driver unit at startup (default 5; issue #119 pt 3)
#   CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS   forced to 0 for the driver spawn (issue #111 pt 4)
#                                 unless the caller already set it — fail-fast on a
#                                 backgrounded driver instead of a silent half-completion.
#                                 Passed into the transient unit's own environment via
#                                 `--setenv` when spawned through systemd-run (issue #119).
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
# driver has no work product to verify yet). `feedback pr=N` and `ci-fix
# pr=N` verdicts are DELIBERATELY excluded too (fall straight into the `*`
# pass-through arm below) — both push commits onto an EXISTING PR branch
# rather than creating a new local `feat/issue-N-*` one, so there is no
# freshly-created branch/worktree for this debris check to classify; the PR
# itself already existed before the driver ran. All GitHub access goes through
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

# --- transient systemd unit naming (issue #119 pt 1; issue #96 pt ci-fix;
# issue #96 part 2 pt comment-fix) -------------------------------------------
# $1=verdict -> "pr-loop-driver-issue<N>" for "advance issue=N",
# "pr-loop-driver-pr<N>" for "feedback pr=N", "pr-loop-driver-cifix-pr<N>"
# for "ci-fix pr=N", or "pr-loop-driver-commentfix-pr<N>" for
# "comment-fix pr=N". Used both to SPAWN the unit (run_driver) and, in reverse
# (verdict_from_unit_name below), to recover the verdict from a unit already
# running when this daemon process starts up (reattach_orphaned_drivers) — the
# two must stay exact inverses of each other. ci-fix and comment-fix EACH get
# their OWN distinct unit name (neither reuses "pr-loop-driver-pr<N>") so a
# feedback driver, a comment-fix driver, and a ci-fix driver on the SAME PR
# can never collide in naming or reattach — the verdict precedence
# (feedback > comment-fix > ci-fix) makes more than one of these firing for
# the same PR in the SAME tick impossible, but a driver from a PRIOR tick
# could still be finishing up while a LATER tick, after that reaction was
# addressed, dispatches a DIFFERENT kind of driver for the identical PR
# number; distinct unit names keep those spawns/reattaches from ever being
# confused with each other.
driver_unit_name() {
  case "$1" in
    "advance issue="*)     printf 'pr-loop-driver-issue%s' "${1#advance issue=}" ;;
    "comment-fix pr="*)    printf 'pr-loop-driver-commentfix-pr%s' "${1#comment-fix pr=}" ;;
    "ci-fix pr="*)         printf 'pr-loop-driver-cifix-pr%s' "${1#ci-fix pr=}" ;;
    "feedback pr="*)       printf 'pr-loop-driver-pr%s' "${1#feedback pr=}" ;;
    *)                     printf 'pr-loop-driver-unknown' ;;
  esac
}

# --- reverse of driver_unit_name: unit name -> verdict (issue #119 pt 3) ----
# Prints nothing (not an error) for a unit name that doesn't match the
# expected naming convention — reattach_orphaned_drivers skips those rather
# than guessing. The `pr-loop-driver-cifix-pr*`/`pr-loop-driver-commentfix-pr*`
# arms MUST be checked before `pr-loop-driver-pr*` would even matter for
# disambiguation (it doesn't here — neither "cifix-pr..." nor
# "commentfix-pr..." ever matches the plain "pr..." prefix pattern either
# way — but the ordering keeps all three non-advance arms visually adjacent to
# their distinct name shapes in driver_unit_name above, so the pairing stays
# obvious on read).
verdict_from_unit_name() {
  local unit="${1%.service}"
  case "$unit" in
    pr-loop-driver-issue*)      printf 'advance issue=%s' "${unit#pr-loop-driver-issue}" ;;
    pr-loop-driver-cifix-pr*)   printf 'ci-fix pr=%s' "${unit#pr-loop-driver-cifix-pr}" ;;
    pr-loop-driver-commentfix-pr*) printf 'comment-fix pr=%s' "${unit#pr-loop-driver-commentfix-pr}" ;;
    pr-loop-driver-pr*)         printf 'feedback pr=%s' "${unit#pr-loop-driver-pr}" ;;
    *)                          : ;;
  esac
}

# --- list currently active/activating pr-loop-driver-* units ---------------
# No-op (prints nothing, never fails) when systemd/`systemctl --user` isn't
# usable here — every caller of this treats an empty result as "nothing to
# re-attach to", which is exactly correct in a non-systemd environment.
list_active_driver_units() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl --user list-units --no-legend --plain --state=active,activating \
    'pr-loop-driver-*' 2>/dev/null | awk '{print $1}' | sed 's/\.service$//'
}

# --- block until a (re-attached) driver unit finishes, print its exit code --
# $1=unit. Polls `systemctl --user is-active` every LOOP_REATTACH_POLL_SECONDS
# (default 5) while the unit is still active/activating/deactivating, then
# reads back ExecMainCode/ExecMainStatus. Best-effort: a unit garbage-collected
# out from under us (--collect) before this can read it back prints "0" rather
# than guessing — the ledger's own verify_and_classify_post_exit (GitHub +
# pure-git) is what actually tells success apart from a phantom regardless.
wait_for_driver_unit() {
  local unit="$1" state
  while :; do
    state="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
    case "$state" in
      active|activating|deactivating) sleep "${LOOP_REATTACH_POLL_SECONDS:-5}" ;;
      *) break ;;
    esac
  done
  local code status
  code="$(systemctl --user show -p ExecMainCode --value "$unit" 2>/dev/null || true)"
  status="$(systemctl --user show -p ExecMainStatus --value "$unit" 2>/dev/null || true)"
  case "$status" in ''|*[!0-9]*) status=0 ;; esac
  if [ "$code" = "killed" ]; then
    printf '124'
  else
    printf '%s' "$status"
  fi
}

# --- startup re-attach (issue #119 pt 3) ------------------------------------
# Called ONCE from main(), before the first run_once: a driver left running by
# a NOW-DEAD daemon process (the whole point of #119 — its lifetime is no
# longer tied to the daemon's) must never be double-spawned, and must never be
# silently forgotten either (a naive tick would just see no local branch yet
# and re-advance the same issue). Instead: find every still-active
# `pr-loop-driver-*` unit, WAIT for each to finish (blocking, like the
# daemon's own `systemd-run --wait` would have), then run the exact same
# post-exit verify + ledger path a fresh run_driver exit would have. No-op
# when systemd/`systemctl --user` is unavailable.
reattach_orphaned_drivers() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local unit
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    local verdict; verdict="$(verdict_from_unit_name "$unit")"
    if [ -z "$verdict" ]; then
      log "startup re-attach: active unit '$unit' doesn't match the pr-loop-driver-<issueN|prN|cifix-prN> naming — leaving it to systemd, not re-attaching"
      continue
    fi
    log "startup re-attach: found active driver unit '$unit' from a previous daemon ($verdict) — waiting instead of spawning a new one"
    local rc; rc="$(wait_for_driver_unit "$unit")"
    local ts; ts="$(date -u +%FT%TZ)"
    local extra="result=exit rc=$rc"
    case "$rc" in
      124|137) extra="result=timeout rc=$rc" ;;
    esac
    case "$verdict" in
      "advance issue="*) extra="$(verify_and_classify_post_exit "$verdict" "$rc" "$extra")" ;;
    esac
    append_ledger "unknown" "" "$verdict" "$ts" "$extra reattached=true"
    log "startup re-attach finished ($verdict): $extra reattached=true"
  done < <(list_active_driver_units)
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

  local pgid rc
  if command -v systemd-run >/dev/null 2>&1; then
    # Transient systemd unit per driver (issue #119 pt 1): the daemon's own
    # `systemd-run --wait` invocation below is a DISPOSABLE waiter — it
    # blocks and relays the unit's exit code, exactly like `wait` on a
    # backgrounded job, but the driver's actual parent is the `--user`
    # manager, not this daemon process. A daemon restart/crash kills only
    # this waiter; the driver keeps running in its own scope, unaffected.
    # --collect unloads the unit right after it stops. RuntimeMaxSec is the
    # hard wall-clock ceiling, enforced by the user manager — it replaces
    # `timeout` and, unlike `timeout`, survives even if the daemon itself
    # never comes back. --setenv threads PATH and the fail-fast bg-wait
    # ceiling into the unit's own environment: transient units do NOT inherit
    # the caller's shell environment the way a plain backgrounded child would.
    local unit; unit="$(driver_unit_name "$verdict")"
    # Post-review finding #3: clear any lingering `failed` state under this
    # exact deterministic unit name (e.g. a stale unit left behind by a prior
    # driver for the same issue/PR) BEFORE spawning — a spawn into a name
    # still occupied by a `failed` unit can otherwise hard-fail with no
    # fallback. Best-effort; a normal --collect run never leaves one behind.
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
    fi
    log "spawning driver via transient systemd unit ($unit, RuntimeMaxSec=$timeout_dur)"
    # Post-review finding #2: a plain temp file the WRAPPED command touches as
    # its very first action, before claude itself runs. Its presence after
    # `wait` returns below is how run_driver tells "the driver process
    # genuinely started under this unit" apart from "systemd-run itself never
    # got to spawn it at all" — e.g. no reachable `--user` bus (classic cron
    # with no XDG_RUNTIME_DIR/session, or the user manager not
    # running/lingering). Both failure modes otherwise look identical: some
    # nonzero rc, no driver output, no other signal to tell them apart.
    local start_marker; start_marker="$(mktemp -u "$state_dir/.driver-started.XXXXXX")"
    # --working-directory is NOT optional: a transient --user unit defaults its
    # WorkingDirectory to $HOME, and a driver started there never loads the
    # repo's .claude/settings.local.json (bypassPermissions) — every gh call
    # then dies on "requires approval" with no approver in headless mode, and
    # the driver exits phantom. Burned 5 attempts on issue #97 (2026-07-16)
    # before this line existed. The setsid fallback below doesn't need it: a
    # plain child inherits the daemon's own cwd (the repo, per the service
    # unit's WorkingDirectory).
    systemd-run --user --wait --collect --quiet \
      --unit="$unit" \
      --working-directory="$root" \
      -p "RuntimeMaxSec=$timeout_dur" \
      --setenv="CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=$CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS" \
      --setenv="PATH=$PATH" \
      -- bash -c 'touch "$4"; claude --model "$1" -p "$2" --output-format json >"$3" 2>"$3.stderr"' _ \
        "$model" "$prompt" "$out_file" "$start_marker" &
    pgid=$!
    wait "$pgid"
    rc=$?

    if [ ! -f "$start_marker" ]; then
      # Post-review finding #2 (continued): the driver never actually started
      # under the unit — degrade EXACTLY like the "no systemd-run on PATH"
      # branch below: fall through to setsid+timeout so the driver still
      # actually runs, exactly once, instead of silently ledgering a phantom
      # spawn/connect-error rc.
      log "systemd-run failed to spawn the driver unit '$unit' (rc=$rc, no start-marker seen) — falling back to setsid+timeout"
      setsid timeout --kill-after=30s "$timeout_dur" \
        claude --model "$model" -p "$prompt" --output-format json \
        >"$out_file" 2>"$out_file.stderr" &
      pgid=$!
      wait "$pgid"
      rc=$?
      kill -TERM -- "-$pgid" 2>/dev/null || true
    else
      rm -f "$start_marker"
      # Post-review finding #1: `systemd-run --wait` relays `143`
      # (128+SIGTERM) for a unit killed by hitting its RuntimeMaxSec ceiling —
      # NOT GNU timeout's `124`/`137`. Left unnormalized, the rc
      # classification below (`case 124|137`) never matches on this path: a
      # real timeout gets ledgered as a plain `result=exit rc=143` AND
      # wrongly routed into verify_and_classify_post_exit (which deliberately
      # skips 124/137/127 — there's no work product to verify yet on a killed
      # driver). Query the unit's own Result property (best-effort — a
      # --collect unit can already be garbage-collected by the time we ask,
      # same caveat wait_for_driver_unit documents above) to detect it and
      # normalize rc so BOTH spawn paths converge on the identical downstream
      # classification.
      if [ "$rc" -ne 0 ] && command -v systemctl >/dev/null 2>&1; then
        local systemd_result
        systemd_result="$(systemctl --user show -p Result --value "$unit" 2>/dev/null || true)"
        if [ "$systemd_result" = "timeout" ]; then
          log "systemd RuntimeMaxSec ceiling hit for $unit (rc=$rc) — normalizing to rc=124 for ledger/verify classification"
          rc=124
        fi
      fi
    fi
  else
    # Fallback (legacy-cron / non-systemd environments): setsid gives the
    # whole tree (claude + any bash children it spawns) its OWN process
    # group, independent of this daemon's own — timeout's --kill-after below
    # then has a single group to aim at. Backstop explicit group kill after
    # `wait` covers anything that outlives timeout's own signal delivery
    # (claude-code#29096: a bare SIGTERM to just the immediate child has been
    # observed to orphan bash children). NOTE: a process group is NOT a
    # cgroup — this path still dies WITH the daemon's own service cgroup on a
    # restart/crash/reboot; that's exactly the gap the systemd-run branch
    # above closes when it's available.
    setsid timeout --kill-after=30s "$timeout_dur" \
      claude --model "$model" -p "$prompt" --output-format json \
      >"$out_file" 2>"$out_file.stderr" &
    pgid=$!
    wait "$pgid"
    rc=$?
    kill -TERM -- "-$pgid" 2>/dev/null || true
  fi

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
    "advance issue="*|"feedback pr="*|"comment-fix pr="*|"ci-fix pr="*)
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
  # Startup re-attach (issue #119 pt 3): BEFORE the first run_once, catch any
  # driver a previous (now-dead) daemon process left running as a transient
  # systemd unit — never double-spawn it, never let a fresh tick's census
  # silently forget it either. No-op when systemd/`systemctl --user` isn't
  # usable here.
  reattach_orphaned_drivers
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
