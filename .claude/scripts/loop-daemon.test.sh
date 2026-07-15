#!/usr/bin/env bash
# loop-daemon.test.sh — offline smoke test for loop-daemon.sh (issue #102).
#
# Two kinds of checks:
#   (A) PURE UNIT checks — `source` the REAL loop-daemon.sh directly into
#       this test's own shell (never `main`, thanks to its BASH_SOURCE guard)
#       and call cadence_to_sleep_seconds / ledger_line directly. Sourcing
#       has zero side effects (no mkdir, no network, no forever loop), so
#       this is safe against the real repo tree.
#   (B) INTEGRATION checks — build a throwaway fixture `.claude/scripts/`
#       (mirroring loop-tick.test.sh's convention) containing the REAL
#       loop-daemon.sh + resolve-roots.sh next to a FAKE loop-event.sh, and
#       fake `claude`/`setsid`/`timeout` stubs prepended onto PATH, then run
#       loop-daemon.sh as a real subprocess with LOOP_DAEMON_MAX_ITERATIONS=1
#       so `main` runs exactly one iteration and exits (instead of forever).
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/loop-daemon.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
loop_daemon_src="$script_dir/loop-daemon.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/loop-daemon-test.XXXXXX")"
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

# =============================================================================
# (A) Pure unit checks: source the real script, call its functions directly.
# =============================================================================
# shellcheck source=loop-daemon.sh
. "$loop_daemon_src"

# --- cadence -> sleep seconds mapping ---------------------------------------
s_fast="$(cadence_to_sleep_seconds 'open_prs=0
feedback_prs=0
cadence=FAST cron=* * * * *')"
check "cadence FAST -> 60s" [ "$s_fast" = "60" ]

s_watch="$(cadence_to_sleep_seconds 'open_prs=1
cadence=WATCH cron=*/5 * * * *')"
check "cadence WATCH -> 300s" [ "$s_watch" = "300" ]

s_idle="$(cadence_to_sleep_seconds 'open_prs=0
planned_issues=0
cadence=IDLE cron=*/15 * * * *')"
check "cadence IDLE -> 900s" [ "$s_idle" = "900" ]

s_missing="$(cadence_to_sleep_seconds 'some garbage output with no cadence line at all')"
check "no cadence line -> fallback 300s" [ "$s_missing" = "300" ]

s_env_override="$(LOOP_DAEMON_SLEEP_FAST=5 cadence_to_sleep_seconds 'cadence=FAST cron=* * * * *')"
check "cadence FAST honors LOOP_DAEMON_SLEEP_FAST override" [ "$s_env_override" = "5" ]

# --- ledger line format ------------------------------------------------------
line1="$(ledger_line 12345 sess-abc 'advance issue=42' '2026-07-09T00:00:00Z' 'result=exit rc=0')"
check "ledger line: exact format with all fields" [ "$line1" = "pid=12345 session=sess-abc verdict=advance issue=42 ts=2026-07-09T00:00:00Z result=exit rc=0" ]

line2="$(ledger_line 999 '' 'feedback pr=7' '2026-07-09T01:00:00Z')"
check "ledger line: empty session_id prints 'unknown'" [ "$line2" = "pid=999 session=unknown verdict=feedback pr=7 ts=2026-07-09T01:00:00Z" ]

line3="$(ledger_line 111 sess-x 'advance issue=1' '2026-07-09T02:00:00Z' 'result=timeout rc=124')"
check "ledger line: timeout result recorded verbatim" [ "$line3" = "pid=111 session=sess-x verdict=advance issue=1 ts=2026-07-09T02:00:00Z result=timeout rc=124" ]

# --- classify_debris (issue #111 pt 2): pure git, fully isolated fixture ----
# classify_debris uses $2 (worktree_dir) AS the git repo context whenever it's
# a real directory, so these checks build their own throwaway repo + worktrees
# (under $work, cleaned up by the top-level trap) and never touch the REAL
# project's own git state (the sourced $root is the real repo root, but is
# never reached here because $2 is always given).
cd_repo="$work/classify-repo"
mkdir -p "$cd_repo"
git -C "$cd_repo" init -q -b main
git -C "$cd_repo" config user.email test@example.com
git -C "$cd_repo" config user.name test
git -C "$cd_repo" commit -q --allow-empty -m init

# empty: branch off main, zero extra commits, worktree clean.
git -C "$cd_repo" branch feat/issue-1-a main
cd_wt_empty="$work/classify-wt-empty"
git -C "$cd_repo" worktree add -q "$cd_wt_empty" feat/issue-1-a
s_empty="$(classify_debris feat/issue-1-a "$cd_wt_empty")"
check "classify_debris: no commits ahead + clean worktree -> empty" [ "$s_empty" = "empty" ]

# publishable: one commit ahead of main, worktree clean.
cd_wt_pub="$work/classify-wt-pub"
git -C "$cd_repo" worktree add -q -b feat/issue-2-a "$cd_wt_pub" main
( cd "$cd_wt_pub" && echo hi > f.txt && git add f.txt && git -c user.email=test@example.com -c user.name=test commit -q -m work )
s_pub="$(classify_debris feat/issue-2-a "$cd_wt_pub")"
check "classify_debris: commits ahead + clean worktree -> publishable" [ "$s_pub" = "publishable" ]

# half-done: one commit ahead of main, worktree DIRTY (uncommitted changes).
cd_wt_half="$work/classify-wt-half"
git -C "$cd_repo" worktree add -q -b feat/issue-3-a "$cd_wt_half" main
( cd "$cd_wt_half" && echo hi > f.txt && git add f.txt && git -c user.email=test@example.com -c user.name=test commit -q -m work && echo more >> f.txt )
s_half="$(classify_debris feat/issue-3-a "$cd_wt_half")"
check "classify_debris: commits ahead + dirty worktree -> half-done" [ "$s_half" = "half-done" ]

# half-done (variant): zero commits ahead but worktree DIRTY (uncommitted-only
# work — never even committed) still counts as resumable, not empty.
cd_wt_dirty0="$work/classify-wt-dirty0"
git -C "$cd_repo" branch feat/issue-4-a main
git -C "$cd_repo" worktree add -q "$cd_wt_dirty0" feat/issue-4-a
echo untracked > "$cd_wt_dirty0/untracked.txt"
s_dirty0="$(classify_debris feat/issue-4-a "$cd_wt_dirty0")"
check "classify_debris: no commits ahead but dirty worktree -> half-done (not empty)" [ "$s_dirty0" = "half-done" ]

# absent: branch simply doesn't exist in that repo.
s_absent="$(classify_debris feat/issue-999-nope "$cd_wt_empty")"
check "classify_debris: nonexistent branch -> absent" [ "$s_absent" = "absent" ]

# --- verify_and_classify_post_exit: pure pass-through cases (no bot-gh.sh call) ---
# These never reach the bot-gh.sh query at all (guarded before it), so they're
# safe pure-unit checks even though the sourced $script_dir/$root point at the
# REAL project — no network, no git mutation.
vp_feedback="$(verify_and_classify_post_exit 'feedback pr=9' 0 'result=exit rc=0')"
check "verify_and_classify_post_exit: non-advance verdict passes extra through unchanged" [ "$vp_feedback" = "result=exit rc=0" ]

vp_timeout="$(verify_and_classify_post_exit 'advance issue=5' 124 'result=timeout rc=124')"
check "verify_and_classify_post_exit: timeout rc=124 passes extra through unchanged" [ "$vp_timeout" = "result=timeout rc=124" ]

vp_spawnerr="$(verify_and_classify_post_exit 'advance issue=5' 127 'result=spawn-error rc=127')"
check "verify_and_classify_post_exit: spawn-error rc=127 passes extra through unchanged" [ "$vp_spawnerr" = "result=spawn-error rc=127" ]

# =============================================================================
# (B) Integration checks: real subprocess, fake loop-event.sh + fake claude.
# =============================================================================
new_fixture() {
  # $1=name $2=fake loop-event.sh body (full script text) -> prints fixture root
  local name="$1" body="$2"
  local dir="$work/$name"
  mkdir -p "$dir/.claude/scripts" "$dir/.claude/state" "$dir/bin"
  cp "$loop_daemon_src" "$dir/.claude/scripts/loop-daemon.sh"
  cp "$resolve_roots_src" "$dir/.claude/scripts/resolve-roots.sh"
  printf '%s\n' "$body" > "$dir/.claude/scripts/loop-event.sh"
  chmod +x "$dir/.claude/scripts"/*.sh
  printf '%s\n' "$dir"
}

fake_bin() {
  # $1=fixture root $2=binary name $3=script body -> installs bin/$2 on that fixture's PATH dir
  local dir="$1" name="$2" body="$3"
  printf '%s\n' "$body" > "$dir/bin/$name"
  chmod +x "$dir/bin/$name"
}

fake_bot_gh() {
  # $1=fixture root $2=script body -> installs a fake .claude/scripts/bot-gh.sh,
  # since verify_and_classify_post_exit always calls "$script_dir/bot-gh.sh" as
  # an explicit path (mirroring every OTHER script in this repo's bot-gh.sh
  # policy), never a bare `bot-gh.sh` resolved off PATH like fake_bin's targets.
  local dir="$1" body="$2"
  printf '%s\n' "$body" > "$dir/.claude/scripts/bot-gh.sh"
  chmod +x "$dir/.claude/scripts/bot-gh.sh"
}

run_daemon_once() {
  # $1=fixture root; runs loop-daemon.sh for exactly one iteration. NVM_DIR
  # points inside the fixture (nothing there) so ensure_claude_on_path's nvm
  # fallback can never resolve the HOST's ~/.nvm — otherwise scenarios without
  # a claude stub pass on a dev box with nvm but fail on CI runners without it.
  ( cd "$1" && PATH="$1/bin:/usr/bin:/bin" NVM_DIR="$1/no-such-nvm" LOOP_DAEMON_MAX_ITERATIONS=1 LOOP_DAEMON_SLEEP_FAST=0 LOOP_DAEMON_SLEEP_WATCH=0 LOOP_DAEMON_SLEEP_IDLE=0 LOOP_DAEMON_SLEEP_FALLBACK=0 bash .claude/scripts/loop-daemon.sh )
}

run_daemon_once_stripped_path() {
  # $1=fixture root $2=NVM_DIR to expose; like run_daemon_once but with a PATH
  # that has NEITHER node NOR claude (mirroring pr-loop.service's minimal
  # systemd PATH before issue #107's baked-PATH fix), to exercise main()'s
  # startup ensure_claude_on_path nvm fallback instead of the fixture's own
  # bin/ dir.
  ( cd "$1" && PATH="/usr/bin:/bin" NVM_DIR="$2" LOOP_DAEMON_MAX_ITERATIONS=1 LOOP_DAEMON_SLEEP_FAST=0 LOOP_DAEMON_SLEEP_WATCH=0 LOOP_DAEMON_SLEEP_IDLE=0 LOOP_DAEMON_SLEEP_FALLBACK=0 bash .claude/scripts/loop-daemon.sh )
}

# ---------------------------------------------------------------------------
# 1. action=none: fake loop-event.sh reports nothing actionable. Assert no
#    DRIVER ledger line is written — i.e. ZERO drivers spawned. Note there is
#    deliberately NO 'claude' stub installed for this scenario: if
#    loop-daemon.sh ever tried to spawn one on action=none, the whole run
#    would blow up with "command not found" instead of quietly passing. With
#    claude unresolvable, main()'s startup check (issue #107) writes exactly
#    one 'verdict=startup result=env-error' line — the ONLY line allowed here.
# ---------------------------------------------------------------------------
dir1="$(new_fixture scenario1 '#!/usr/bin/env bash
echo "cadence=IDLE cron=*/15 * * * *"
echo "loop-event: action=none"
exit 0')"
run_daemon_once "$dir1" >/dev/null 2>&1
ledger1="$dir1/.claude/state/loop-runs.log"
check "scenario 1 (action=none): startup env-error is the ONLY ledger line" bash -c '
  [ "$(wc -l < "$1" 2>/dev/null || echo 0)" -eq 1 ] && grep -q "verdict=startup .*result=env-error" "$1"' _ "$ledger1"
check "scenario 1: no driver ledger line was written" bash -c '! grep -q "verdict=advance" "$1"' _ "$ledger1"

# ---------------------------------------------------------------------------
# 2. Broken tick (loop-event.sh exits non-zero): must not spawn a driver
#    either, same as action=none (same startup env-error caveat as scenario 1).
# ---------------------------------------------------------------------------
dir2="$(new_fixture scenario2 '#!/usr/bin/env bash
echo "cadence=WATCH cron=*/5 * * * *"
echo "some diagnostic on a broken tick" >&2
exit 1')"
run_daemon_once "$dir2" >/dev/null 2>&1
ledger2="$dir2/.claude/state/loop-runs.log"
check "scenario 2 (broken tick): startup env-error is the ONLY ledger line" bash -c '
  [ "$(wc -l < "$1" 2>/dev/null || echo 0)" -eq 1 ] && grep -q "verdict=startup .*result=env-error" "$1"' _ "$ledger2"
check "scenario 2: no driver ledger line was written" bash -c '! grep -q "verdict=advance" "$1"' _ "$ledger2"

# ---------------------------------------------------------------------------
# 3. action=advance issue=N: fake claude/setsid/timeout stubs record they ran
#    and emit a fake --output-format json line with a session_id; assert the
#    driver stub actually ran, and the ledger line has the right shape.
# ---------------------------------------------------------------------------
prompt3_dir="$work/scenario3-support"
mkdir -p "$prompt3_dir"
printf 'Run the ADVANCE step of the autonomous PR loop for issue #55.\n' > "$prompt3_dir/prompt.txt"
dir3="$(new_fixture scenario3 "#!/usr/bin/env bash
echo 'cadence=FAST cron=* * * * *'
echo 'loop-event: action=advance issue=55'
echo 'loop-event: model=sonnet'
echo 'loop-event: prompt-file=$prompt3_dir/prompt.txt'
exit 0")"
fake_bin "$dir3" setsid '#!/usr/bin/env bash
# Real setsid re-execs its argv; this stub just execs straight through so the
# fake timeout/claude below still run, but records that it was invoked first.
echo "setsid-ran" >> "'"$dir3"'/setsid.marker"
exec "$@"'
fake_bin "$dir3" timeout '#!/usr/bin/env bash
echo "timeout-ran args=$*" >> "'"$dir3"'/timeout.marker"
# Drop the leading --kill-after=... and the duration positional, exec the rest.
shift # --kill-after=30s
shift # duration (e.g. 90m)
exec "$@"'
fake_bin "$dir3" claude '#!/usr/bin/env bash
echo "claude-ran args=$*" >> "'"$dir3"'/claude.marker"
echo "$CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS" > "'"$dir3"'/claude.bg-ceiling-env"
echo "{\"session_id\":\"sess-fixture-55\",\"result\":\"ok\"}"
exit 0'
# Post-exit verification (issue #111) now queries bot-gh.sh for an open PR on
# every advance verdict that exits without timing out. Stub it as an already-
# open PR #77, so this scenario's ledger keeps recording a genuine success
# (result=exit, not phantom) — the phantom/offline/classifier paths get their
# own dedicated scenarios below.
fake_bot_gh "$dir3" '#!/usr/bin/env bash
echo "bot-gh-ran args=$*" >> "'"$dir3"'/bot-gh.marker"
echo "77"
exit 0'
run_daemon_once "$dir3" >/dev/null 2>&1
check "scenario 3 (advance): setsid stub was invoked" [ -f "$dir3/setsid.marker" ]
check "scenario 3: timeout stub was invoked" [ -f "$dir3/timeout.marker" ]
check "scenario 3: claude stub was invoked" [ -f "$dir3/claude.marker" ]
check "scenario 3: claude stub received the prompt text" bash -c 'grep -qF "issue #55" "$1"' _ "$dir3/claude.marker"
check "scenario 3: CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 was exported to the driver (issue #111 pt 4 fail-fast spawn)" bash -c '
  [ "$(cat "$1" 2>/dev/null)" = "0" ]' _ "$dir3/claude.bg-ceiling-env"
ledger3="$dir3/.claude/state/loop-runs.log"
check "scenario 3: exactly one ledger line was appended" [ "$(wc -l < "$ledger3" 2>/dev/null || echo 0)" -eq 1 ]
check "scenario 3: ledger line has pid=/session=/verdict=/ts=/result=/pr= fields (post-exit verify found PR #77)" bash -c '
  grep -Eq "^pid=[0-9]+ session=sess-fixture-55 verdict=advance issue=55 ts=[0-9T:Z-]+ result=exit rc=0 pr=77$" "$1"
' _ "$ledger3"
check "scenario 3: prompt file was cleaned up after the driver ran" [ ! -f "$prompt3_dir/prompt.txt" ]

# ---------------------------------------------------------------------------
# 4. action=feedback pr=N: same driver path, different verdict text, session
#    id missing from the (malformed) driver output -> ledger records 'unknown'.
# ---------------------------------------------------------------------------
prompt4_dir="$work/scenario4-support"
mkdir -p "$prompt4_dir"
printf 'Run the ADDRESS FEEDBACK step for PR #9.\n' > "$prompt4_dir/prompt.txt"
dir4="$(new_fixture scenario4 "#!/usr/bin/env bash
echo 'cadence=FAST cron=* * * * *'
echo 'loop-event: action=feedback pr=9'
echo 'loop-event: model=sonnet'
echo 'loop-event: prompt-file=$prompt4_dir/prompt.txt'
exit 0")"
fake_bin "$dir4" setsid '#!/usr/bin/env bash
exec "$@"'
fake_bin "$dir4" timeout '#!/usr/bin/env bash
shift; shift
exec "$@"'
fake_bin "$dir4" claude '#!/usr/bin/env bash
echo "not valid json output, no session_id here"
exit 0'
run_daemon_once "$dir4" >/dev/null 2>&1
ledger4="$dir4/.claude/state/loop-runs.log"
check "scenario 4 (feedback, no parseable session_id): ledger records session=unknown" bash -c '
  grep -Eq "^pid=[0-9]+ session=unknown verdict=feedback pr=9 ts=[0-9T:Z-]+ result=exit rc=0$" "$1"
' _ "$ledger4"

# ---------------------------------------------------------------------------
# 5. Driver timeout: fake timeout stub exits 124 (as GNU timeout does on a
#    real kill) without ever invoking claude; ledger must record
#    result=timeout rc=124.
# ---------------------------------------------------------------------------
prompt5_dir="$work/scenario5-support"
mkdir -p "$prompt5_dir"
printf 'Run the ADVANCE step for issue #3.\n' > "$prompt5_dir/prompt.txt"
dir5="$(new_fixture scenario5 "#!/usr/bin/env bash
echo 'cadence=FAST cron=* * * * *'
echo 'loop-event: action=advance issue=3'
echo 'loop-event: model=sonnet'
echo 'loop-event: prompt-file=$prompt5_dir/prompt.txt'
exit 0")"
fake_bin "$dir5" setsid '#!/usr/bin/env bash
exec "$@"'
fake_bin "$dir5" timeout '#!/usr/bin/env bash
# Simulate a real timeout: the wrapped command never gets to run.
exit 124'
fake_bin "$dir5" claude '#!/usr/bin/env bash
echo "claude-should-not-run" >> "'"$dir5"'/claude.should-not-run"
exit 0'
run_daemon_once "$dir5" >/dev/null 2>&1
ledger5="$dir5/.claude/state/loop-runs.log"
check "scenario 5 (timeout): ledger records result=timeout rc=124" bash -c '
  grep -Eq "^pid=[0-9]+ session=unknown verdict=advance issue=3 ts=[0-9T:Z-]+ result=timeout rc=124$" "$1"
' _ "$ledger5"

# ---------------------------------------------------------------------------
# 6. Startup PATH resolution regression guard (issue #107): the daemon's own
#    PATH lacks BOTH node and claude (mirroring pr-loop.service's minimal
#    systemd PATH before this issue's baked-PATH fix), but a FAKE nvm install
#    is reachable via NVM_DIR. Assert main()'s startup ensure_claude_on_path
#    call (the 4bf7dbb hotfix) resolves node/claude onto PATH BEFORE run_once
#    spawns loop-event.sh, so a node-dependent tick step (stood in here by the
#    fake loop-event.sh itself checking `command -v node`/`command -v claude`)
#    sees them already resolved in the child.
# ---------------------------------------------------------------------------
dir6="$work/scenario6"
fake_nvm_dir="$work/scenario6-nvm"
mkdir -p "$fake_nvm_dir/bin"
cat > "$fake_nvm_dir/nvm.sh" <<EOF
# fake nvm.sh (test fixture only): mimics a real nvm install's auto
# "use default" behavior by prepending a bin dir with fake node/claude onto
# PATH when sourced.
PATH="$fake_nvm_dir/bin:\$PATH"
export PATH
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_nvm_dir/bin/node"
chmod +x "$fake_nvm_dir/bin/node"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_nvm_dir/bin/claude"
chmod +x "$fake_nvm_dir/bin/claude"

new_fixture scenario6 "#!/usr/bin/env bash
if command -v node >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
  : > '$dir6/node-resolved.marker'
else
  : > '$dir6/node-missing.marker'
fi
echo 'cadence=IDLE cron=*/15 * * * *'
echo 'loop-event: action=none'
exit 0" >/dev/null
run_daemon_once_stripped_path "$dir6" "$fake_nvm_dir" >/dev/null 2>&1
check "scenario 6 (startup PATH resolution): node+claude resolved in child before run_once" [ -f "$dir6/node-resolved.marker" ]
check "scenario 6: no node-missing marker was left (node/claude never resolved)" [ ! -f "$dir6/node-missing.marker" ]

# ---------------------------------------------------------------------------
# git_fixture: like new_fixture, but ALSO git-inits the fixture root itself as
# a real repo with an initial commit on `main` — the repo context
# verify_and_classify_post_exit's `git -C "$root" ...` calls operate on for
# scenarios 7-10 below (issue #111 pts 1-2: post-exit verification + the
# debris classifier need a real branch/worktree to classify, not just a
# scripted loop-event.sh).
# ---------------------------------------------------------------------------
git_fixture() {
  local name="$1" body="$2"
  local dir; dir="$(new_fixture "$name" "$body")"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# 7. Phantom + debris (no deletion): advance issue=77, claude exits 0, fake
#    bot-gh.sh reports NO open PR. issue #77's branch is in the `half-done`
#    state (a commit ahead of main, worktree dirty) — real, unpushed work.
#    Assert the ledger corrects result=exit -> result=phantom (issue #111 pt
#    1's ledger-honesty fix) AND records debris=half-done resumable, and
#    (Case B/C safety) NEITHER the branch NOR its worktree get touched.
# ---------------------------------------------------------------------------
prompt7_dir="$work/scenario7-support"
mkdir -p "$prompt7_dir"
printf 'Run the ADVANCE step for issue #77.\n' > "$prompt7_dir/prompt.txt"
dir7="$(git_fixture scenario7 "#!/usr/bin/env bash
echo 'cadence=FAST cron=* * * * *'
echo 'loop-event: action=advance issue=77'
echo 'loop-event: model=sonnet'
echo 'loop-event: prompt-file=$prompt7_dir/prompt.txt'
exit 0")"
wt7="$work/scenario7-wt"
git -C "$dir7" worktree add -q -b feat/issue-77-broken "$wt7" main
( cd "$wt7" && echo hi > f.txt && git add f.txt && git -c user.email=test@example.com -c user.name=test commit -q -m work && echo dirty >> f.txt )
fake_bin "$dir7" setsid '#!/usr/bin/env bash
exec "$@"'
fake_bin "$dir7" timeout '#!/usr/bin/env bash
shift; shift
exec "$@"'
fake_bin "$dir7" claude '#!/usr/bin/env bash
echo "{\"session_id\":\"sess-77\",\"result\":\"ok\"}"
exit 0'
fake_bot_gh "$dir7" '#!/usr/bin/env bash
# No open PR for this issue — empty stdout, rc=0 (a genuine "queried fine, found nothing").
exit 0'
run_daemon_once "$dir7" >/dev/null 2>&1
ledger7="$dir7/.claude/state/loop-runs.log"
check "scenario 7 (phantom+half-done): ledger corrects result=exit -> result=phantom rc=0" bash -c '
  grep -q "result=phantom rc=0" "$1"' _ "$ledger7"
check "scenario 7: ledger records debris=half-done resumable" bash -c '
  grep -q "debris=half-done resumable" "$1"' _ "$ledger7"
check "scenario 7: ledger never claims action=deleted for half-done debris" bash -c '! grep -q "action=deleted" "$1"' _ "$ledger7"
check "scenario 7 (Case B/C safety): the branch was NOT deleted" bash -c '
  git -C "$1" rev-parse --verify --quiet refs/heads/feat/issue-77-broken >/dev/null 2>&1' _ "$dir7"
check "scenario 7: the worktree was NOT removed" [ -d "$wt7" ]

# ---------------------------------------------------------------------------
# 8. Case A (the ONLY destructive path): advance issue=88, claude exits 0, no
#    open PR, and issue #88's branch is provably `empty` (no commits ahead of
#    main, clean worktree) — the #91/#92 half-born-branch incident this whole
#    feature exists to clean up safely. Assert the branch + worktree ARE
#    deleted and the ledger records result=phantom ... debris=empty action=deleted.
# ---------------------------------------------------------------------------
prompt8_dir="$work/scenario8-support"
mkdir -p "$prompt8_dir"
printf 'Run the ADVANCE step for issue #88.\n' > "$prompt8_dir/prompt.txt"
dir8="$(git_fixture scenario8 "#!/usr/bin/env bash
echo 'cadence=FAST cron=* * * * *'
echo 'loop-event: action=advance issue=88'
echo 'loop-event: model=sonnet'
echo 'loop-event: prompt-file=$prompt8_dir/prompt.txt'
exit 0")"
wt8="$work/scenario8-wt"
git -C "$dir8" branch feat/issue-88-empty main
git -C "$dir8" worktree add -q "$wt8" feat/issue-88-empty
fake_bin "$dir8" setsid '#!/usr/bin/env bash
exec "$@"'
fake_bin "$dir8" timeout '#!/usr/bin/env bash
shift; shift
exec "$@"'
fake_bin "$dir8" claude '#!/usr/bin/env bash
echo "{\"session_id\":\"sess-88\",\"result\":\"ok\"}"
exit 0'
fake_bot_gh "$dir8" '#!/usr/bin/env bash
exit 0'
run_daemon_once "$dir8" >/dev/null 2>&1
ledger8="$dir8/.claude/state/loop-runs.log"
check "scenario 8 (Case A): ledger records result=phantom rc=0 debris=empty action=deleted" bash -c '
  grep -q "result=phantom rc=0.*debris=empty.*action=deleted" "$1"' _ "$ledger8"
check "scenario 8: the empty local branch WAS deleted" bash -c '
  ! git -C "$1" rev-parse --verify --quiet refs/heads/feat/issue-88-empty >/dev/null 2>&1' _ "$dir8"
check "scenario 8: the worktree WAS removed" [ ! -d "$wt8" ]

# ---------------------------------------------------------------------------
# 9. Case C safety, with an open PR (not phantom): advance issue=99, claude
#    exits 0, bot-gh.sh reports an OPEN PR #42, but issue #99's branch is
#    `half-done` (unpushed local changes on top of the pushed commit — e.g. a
#    driver that opened the PR but was killed before pushing a final fixup).
#    Assert NOTHING gets deleted, the PR is still recorded (not phantom), and
#    the ledger records debris=half-done resumable.
# ---------------------------------------------------------------------------
prompt9_dir="$work/scenario9-support"
mkdir -p "$prompt9_dir"
printf 'Run the ADVANCE step for issue #99.\n' > "$prompt9_dir/prompt.txt"
dir9="$(git_fixture scenario9 "#!/usr/bin/env bash
echo 'cadence=FAST cron=* * * * *'
echo 'loop-event: action=advance issue=99'
echo 'loop-event: model=sonnet'
echo 'loop-event: prompt-file=$prompt9_dir/prompt.txt'
exit 0")"
wt9="$work/scenario9-wt"
git -C "$dir9" worktree add -q -b feat/issue-99-mid "$wt9" main
( cd "$wt9" && echo hi > f.txt && git add f.txt && git -c user.email=test@example.com -c user.name=test commit -q -m work && echo dirty >> f.txt )
fake_bin "$dir9" setsid '#!/usr/bin/env bash
exec "$@"'
fake_bin "$dir9" timeout '#!/usr/bin/env bash
shift; shift
exec "$@"'
fake_bin "$dir9" claude '#!/usr/bin/env bash
echo "{\"session_id\":\"sess-99\",\"result\":\"ok\"}"
exit 0'
fake_bot_gh "$dir9" '#!/usr/bin/env bash
echo "42"
exit 0'
run_daemon_once "$dir9" >/dev/null 2>&1
ledger9="$dir9/.claude/state/loop-runs.log"
check "scenario 9 (Case C safety, open PR): ledger records result=exit (NOT phantom), pr=42, debris=half-done resumable" bash -c '
  grep -Eq "result=exit rc=0 pr=42 debris=half-done resumable" "$1"' _ "$ledger9"
check "scenario 9: nothing was deleted — branch still exists" bash -c '
  git -C "$1" rev-parse --verify --quiet refs/heads/feat/issue-99-mid >/dev/null 2>&1' _ "$dir9"
check "scenario 9: nothing was deleted — worktree still exists" [ -d "$wt9" ]

# ---------------------------------------------------------------------------
# 10. Graceful degrade: bot-gh.sh is offline/missing entirely (no stub
#     installed) for an otherwise textbook-empty issue #100 branch. Assert
#     verify_and_classify_post_exit NEVER falsely declares phantom and NEVER
#     deletes anything on a network hiccup — it just records verify=skipped.
# ---------------------------------------------------------------------------
prompt10_dir="$work/scenario10-support"
mkdir -p "$prompt10_dir"
printf 'Run the ADVANCE step for issue #100.\n' > "$prompt10_dir/prompt.txt"
dir10="$(git_fixture scenario10 "#!/usr/bin/env bash
echo 'cadence=FAST cron=* * * * *'
echo 'loop-event: action=advance issue=100'
echo 'loop-event: model=sonnet'
echo 'loop-event: prompt-file=$prompt10_dir/prompt.txt'
exit 0")"
wt10="$work/scenario10-wt"
git -C "$dir10" branch feat/issue-100-empty main
git -C "$dir10" worktree add -q "$wt10" feat/issue-100-empty
fake_bin "$dir10" setsid '#!/usr/bin/env bash
exec "$@"'
fake_bin "$dir10" timeout '#!/usr/bin/env bash
shift; shift
exec "$@"'
fake_bin "$dir10" claude '#!/usr/bin/env bash
echo "{\"session_id\":\"sess-100\",\"result\":\"ok\"}"
exit 0'
# Deliberately NO bot-gh.sh stub installed at all in this fixture.
run_daemon_once "$dir10" >/dev/null 2>&1
ledger10="$dir10/.claude/state/loop-runs.log"
check "scenario 10 (offline bot-gh.sh): ledger records verify=skipped, NOT phantom" bash -c '
  grep -q "verify=skipped" "$1" && ! grep -q "phantom" "$1"' _ "$ledger10"
check "scenario 10: no debris/action fields were recorded (verify never even ran)" bash -c '
  ! grep -Eq "debris=|action=deleted" "$1"' _ "$ledger10"
check "scenario 10: nothing was deleted on the offline path — branch still exists" bash -c '
  git -C "$1" rev-parse --verify --quiet refs/heads/feat/issue-100-empty >/dev/null 2>&1' _ "$dir10"
check "scenario 10: nothing was deleted on the offline path — worktree still exists" [ -d "$wt10" ]

echo ""
if [ "$fail" -eq 0 ]; then
  echo "loop-daemon.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "loop-daemon.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
