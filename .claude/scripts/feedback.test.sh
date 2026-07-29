#!/usr/bin/env bash
# feedback.test.sh — offline smoke test for .claude/skills/feedback/feedback.sh
# (issue #177). Builds throwaway temp git repo fixtures (mktemp -d, git init,
# an origin remote set per-scenario, the REAL feedback.sh + resolve-roots.sh
# copied alongside a fixture-local plugin.json — mirrors release.test.sh's/
# worktree-cleanup.test.sh's fixture pattern) and exercises `feedback.sh
# --dry-run` (the primary, fully offline path) plus an overridable
# $FEEDBACK_GH_BIN stub (for the non-dry-run "no partial issue" / "degrade
# without labels" paths) — NEVER the real network.
#
# Exercises:
#   1. remote -> label mapping: a "redeploy"-ish origin gets from:redeploy, a
#      "redefi"-ish origin gets from:redefi, neither still files (feedback
#      only, no from:* label), case-insensitively.
#   2. installed-plugin-version resolution: CLAUDE_PLUGIN_ROOT's manifest wins
#      when set; falls back to <repo>/.claude/.claude-plugin/plugin.json when
#      it isn't; degrades to the literal "unknown" on a corrupt manifest
#      rather than crashing.
#   3. consumer-repo guard, all three conditions: no origin remote at all; an
#      origin that resolves to robercano/reCode itself; and no resolvable
#      plugin manifest anywhere — each is a clean non-zero exit with a clear
#      stderr message and NO gh call attempted (checked via the stub log
#      staying empty).
#   4. body-template assembly: Observed/Expected/Severity-suggestion sections,
#      the description and severity text, the origin repo + plugin version
#      trailer, and the "(not specified)" severity fallback when none is
#      given.
#   5. no-partial-issue-on-guard-failure: a guard failure makes zero gh
#      invocations (verified against a logging $FEEDBACK_GH_BIN stub even
#      though --dry-run alone already proves no network call is made).
#   6. real (non-dry-run) path via the $FEEDBACK_GH_BIN stub: label-create
#      calls fire best-effort before issue-create; a failing issue-create
#      retries exactly once without --label flags and still succeeds
#      (missing-label degrade), with a warning on stderr.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/feedback.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
feedback_src="$script_dir/../skills/feedback/feedback.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/feedback-test.XXXXXX")"
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

# new_fixture NAME ORIGIN_URL [PLUGIN_VERSION]
# Builds <work>/<NAME> as a throwaway git repo: real feedback.sh +
# resolve-roots.sh under .claude/scripts/ (feedback.sh sources its sibling
# resolve-roots.sh via a fixed ../../scripts/ relative path, so it must sit
# at .claude/scripts/ regardless of where feedback.sh itself is invoked from
# in the fixture), an origin remote (skip entirely if ORIGIN_URL is the
# literal string "NONE"), and — unless PLUGIN_VERSION is the literal string
# "NOPLUGIN" — a local .claude/.claude-plugin/plugin.json fallback manifest
# stamped with PLUGIN_VERSION (default "9.9.9"). Prints the fixture root.
new_fixture() {
  local name="$1" origin="$2" version="${3:-9.9.9}"
  local repo="$work/$name"
  mkdir -p "$repo/.claude/scripts"
  git init -q -b main "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"

  # feedback.sh actually lives under .claude/skills/feedback/ in the real
  # tree (its resolve-roots.sh reference is ../../scripts/resolve-roots.sh),
  # so mirror that exact relative layout in the fixture too.
  mkdir -p "$repo/.claude/skills/feedback"
  cp "$feedback_src" "$repo/.claude/skills/feedback/feedback.sh"
  cp "$resolve_roots_src" "$repo/.claude/scripts/resolve-roots.sh"
  chmod +x "$repo/.claude/skills/feedback/feedback.sh"

  if [ "$version" != "NOPLUGIN" ]; then
    mkdir -p "$repo/.claude/.claude-plugin"
    if [ "$version" = "CORRUPT" ]; then
      printf '{ not valid json' > "$repo/.claude/.claude-plugin/plugin.json"
    else
      printf '{"name":"orchestrator","version":"%s"}\n' "$version" > "$repo/.claude/.claude-plugin/plugin.json"
    fi
  fi

  if [ "$origin" != "NONE" ]; then
    git -C "$repo" remote add origin "$origin"
  fi

  echo "seed" > "$repo/seed.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "seed fixture"

  printf '%s' "$repo"
}

run_feedback() {
  # $1 = repo dir, rest = args to feedback.sh
  local repo="$1"; shift
  ( cd "$repo" && env -u CLAUDE_PLUGIN_ROOT bash "$repo/.claude/skills/feedback/feedback.sh" "$@" )
}

run_feedback_with_plugin_root() {
  # $1 = repo dir, $2 = CLAUDE_PLUGIN_ROOT dir, rest = args to feedback.sh
  local repo="$1" plugin_root="$2"; shift 2
  ( cd "$repo" && CLAUDE_PLUGIN_ROOT="$plugin_root" bash "$repo/.claude/skills/feedback/feedback.sh" "$@" )
}

install_stub_gh() {
  # $1 = repo dir, $2 = log file, $3 = "succeed" | "fail-with-labels" |
  # "fail-always". Installs a logging stub gh binary in the fixture and
  # returns the path via stdout (feedback.sh is invoked with
  # FEEDBACK_GH_BIN=<that path>, never $PATH).
  local repo="$1" log="$2" mode="$3"
  local stub="$repo/stub-gh.sh"
  cat > "$stub" <<STUB
#!/usr/bin/env bash
log_file="\${FEEDBACK_TEST_GH_LOG:?FEEDBACK_TEST_GH_LOG must be set}"
# feedback.sh's --body arg is intentionally multi-line — collapse embedded
# newlines so each invocation lands as exactly ONE physical log line (a
# multi-line log entry would break every ^-anchored grep the test uses).
printf '%s' "\$*" | tr '\n' ' ' >> "\$log_file"
printf '\n' >> "\$log_file"
mode="$mode"
case "\$1" in
  label)
    exit 0
    ;;
  issue)
    case "\$2" in
      create)
        if printf '%s\n' "\$*" | grep -q -- '--label' && [ "\$mode" = "fail-with-labels" ]; then
          echo "stub-gh: simulated failure — labels rejected" >&2
          exit 1
        fi
        if [ "\$mode" = "fail-always" ]; then
          echo "stub-gh: simulated hard failure" >&2
          exit 1
        fi
        echo "https://github.com/robercano/reCode/issues/999"
        ;;
      *)
        echo "stub-gh: unexpected issue subcommand: \$*" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "stub-gh: unexpected command: \$*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$stub"
  printf '%s' "$stub"
}

# =============================================================================
# Scenario 1: remote -> label mapping (all via --dry-run, zero network).
# =============================================================================
repo1="$(new_fixture repo1 "git@github.com:acme/reDeploy-fork.git")"
out1="$(run_feedback "$repo1" "widget renders wrong" --dry-run 2>&1)"
rc1=$?
check "scenario 1: redeploy-ish origin exits 0" [ "$rc1" -eq 0 ]
check "scenario 1: redeploy-ish origin gets from:redeploy" bash -c 'printf "%s" "$1" | grep -q -- "--label from:redeploy"' _ "$out1"
check "scenario 1: redeploy-ish origin also keeps plain feedback label" bash -c 'printf "%s" "$1" | grep -q -- "--label feedback"' _ "$out1"

repo2="$(new_fixture repo2 "https://github.com/acme/myReDeFi-app.git")"
out2="$(run_feedback "$repo2" "gas estimate off" --dry-run 2>&1)"
rc2=$?
check "scenario 1: redefi-ish origin exits 0" [ "$rc2" -eq 0 ]
check "scenario 1: redefi-ish origin gets from:redefi" bash -c 'printf "%s" "$1" | grep -q -- "--label from:redefi"' _ "$out2"
check "scenario 1: redefi-ish origin does NOT also get from:redeploy" bash -c '! printf "%s" "$1" | grep -q -- "--label from:redeploy"' _ "$out2"

repo3="$(new_fixture repo3 "git@github.com:acme/unrelated-project.git")"
out3="$(run_feedback "$repo3" "unrelated feedback" --dry-run 2>&1)"
rc3=$?
check "scenario 1: unrelated origin still exits 0 (files anyway)" [ "$rc3" -eq 0 ]
check "scenario 1: unrelated origin gets plain feedback label" bash -c 'printf "%s" "$1" | grep -q -- "--label feedback"' _ "$out3"
check "scenario 1: unrelated origin gets NO from:* label" bash -c '! printf "%s" "$1" | grep -q -- "--label from:"' _ "$out3"
check "scenario 1: unrelated origin is still noted in the body" bash -c 'printf "%s" "$1" | grep -q "Origin repo: acme/unrelated-project"' _ "$out3"

# =============================================================================
# Scenario 2: installed-plugin-version resolution + fallback + degrade.
# =============================================================================
repo4="$(new_fixture repo4 "git@github.com:acme/reDeploy.git" "3.4.5")"
out4="$(run_feedback "$repo4" "version check" --dry-run 2>&1)"
check "scenario 2: local .claude/.claude-plugin/plugin.json fallback picked up" bash -c 'printf "%s" "$1" | grep -q "Installed plugin version: 3.4.5"' _ "$out4"

plugin_root_dir="$work/plugin-cache-root"
mkdir -p "$plugin_root_dir/.claude-plugin"
printf '{"name":"orchestrator","version":"7.7.7"}\n' > "$plugin_root_dir/.claude-plugin/plugin.json"
out5="$(run_feedback_with_plugin_root "$repo4" "$plugin_root_dir" "version check via plugin root" --dry-run 2>&1)"
check "scenario 2: CLAUDE_PLUGIN_ROOT manifest wins over the local fallback" bash -c 'printf "%s" "$1" | grep -q "Installed plugin version: 7.7.7"' _ "$out5"

repo5="$(new_fixture repo5 "git@github.com:acme/reDeploy.git" "CORRUPT")"
out6="$(run_feedback "$repo5" "corrupt manifest" --dry-run 2>&1)"
check "scenario 2: corrupt local manifest degrades to 'unknown' rather than crashing" bash -c 'printf "%s" "$1" | grep -q "Installed plugin version: unknown"' _ "$out6"
check "scenario 2: corrupt manifest still exits 0 (version degrade must not block filing)" [ $? -eq 0 ]

# =============================================================================
# Scenario 3: consumer-repo guard — all three conditions, each a clean
# non-zero exit with NO gh call ever attempted (verified against the stub
# log staying empty for the FULL guard-failure set, not just --dry-run).
# =============================================================================
repo6="$(new_fixture repo6 "NONE" "9.9.9")"
gh_log6="$work/gh-log-6.log"; : > "$gh_log6"
stub6="$(install_stub_gh "$repo6" "$gh_log6" succeed)"
out7="$(cd "$repo6" && env -u CLAUDE_PLUGIN_ROOT FEEDBACK_GH_BIN="$stub6" FEEDBACK_TEST_GH_LOG="$gh_log6" bash "$repo6/.claude/skills/feedback/feedback.sh" "no origin at all" 2>&1)"
rc7=$?
check "scenario 3: no origin remote -> non-zero exit" [ "$rc7" -ne 0 ]
check "scenario 3: no origin remote -> clear error message" bash -c 'printf "%s" "$1" | grep -qi "no .origin. git remote"' _ "$out7"
check "scenario 3: no origin remote -> zero gh calls made (no partial issue)" bash -c '[ ! -s "$1" ]' _ "$gh_log6"

repo7="$(new_fixture repo7 "git@github.com:robercano/reCode.git" "9.9.9")"
gh_log7="$work/gh-log-7.log"; : > "$gh_log7"
stub7="$(install_stub_gh "$repo7" "$gh_log7" succeed)"
out8="$(cd "$repo7" && env -u CLAUDE_PLUGIN_ROOT FEEDBACK_GH_BIN="$stub7" FEEDBACK_TEST_GH_LOG="$gh_log7" bash "$repo7/.claude/skills/feedback/feedback.sh" "running from reCode itself" 2>&1)"
rc8=$?
check "scenario 3: origin is robercano/reCode itself -> non-zero exit" [ "$rc8" -ne 0 ]
check "scenario 3: refuses with a clear reCode-itself message" bash -c 'printf "%s" "$1" | grep -qi "robercano/reCode itself"' _ "$out8"
check "scenario 3: origin-is-reCode -> zero gh calls made" bash -c '[ ! -s "$1" ]' _ "$gh_log7"

repo8="$(new_fixture repo8 "git@github.com:acme/reDeploy.git" "NOPLUGIN")"
gh_log8="$work/gh-log-8.log"; : > "$gh_log8"
stub8="$(install_stub_gh "$repo8" "$gh_log8" succeed)"
out9="$(cd "$repo8" && env -u CLAUDE_PLUGIN_ROOT FEEDBACK_GH_BIN="$stub8" FEEDBACK_TEST_GH_LOG="$gh_log8" bash "$repo8/.claude/skills/feedback/feedback.sh" "plugin not installed" 2>&1)"
rc9=$?
check "scenario 3: no resolvable plugin manifest -> non-zero exit" [ "$rc9" -ne 0 ]
check "scenario 3: unresolvable manifest -> clear error message" bash -c 'printf "%s" "$1" | grep -qi "orchestrator plugin"' _ "$out9"
check "scenario 3: unresolvable manifest -> zero gh calls made" bash -c '[ ! -s "$1" ]' _ "$gh_log8"

# =============================================================================
# Scenario 4: body-template assembly — sections, description, severity
# fallback, and explicit severity text.
# =============================================================================
repo9="$(new_fixture repo9 "git@github.com:acme/reDeFi.git" "1.2.3")"
out10="$(run_feedback "$repo9" "loop stalls on empty queue" --dry-run 2>&1)"
check "scenario 4: body has an Observed section with the description" bash -c '
  printf "%s" "$1" | grep -q "## Observed" &&
  printf "%s" "$1" | grep -q "loop stalls on empty queue"
' _ "$out10"
check "scenario 4: body has an Expected section" bash -c 'printf "%s" "$1" | grep -q "## Expected"' _ "$out10"
check "scenario 4: body has a Severity suggestion section" bash -c 'printf "%s" "$1" | grep -q "## Severity suggestion"' _ "$out10"
check "scenario 4: no severity given -> '(not specified)' fallback" bash -c 'printf "%s" "$1" | grep -q "(not specified)"' _ "$out10"

out11="$(run_feedback "$repo9" "another one" --severity "high" --dry-run 2>&1)"
check "scenario 4: explicit severity text appears verbatim" bash -c 'printf "%s" "$1" | grep -q "^high$"' _ "$out11"

# =============================================================================
# Scenario 5 (real, non-dry-run path via $FEEDBACK_GH_BIN): label-create
# fires best-effort, and a failing labeled issue-create retries exactly once
# without --label and still succeeds (missing-label degrade).
# =============================================================================
repo10="$(new_fixture repo10 "git@github.com:acme/reDeploy.git" "9.9.9")"
gh_log10="$work/gh-log-10.log"; : > "$gh_log10"
stub10="$(install_stub_gh "$repo10" "$gh_log10" fail-with-labels)"
out12="$(cd "$repo10" && env -u CLAUDE_PLUGIN_ROOT FEEDBACK_GH_BIN="$stub10" FEEDBACK_TEST_GH_LOG="$gh_log10" bash "$repo10/.claude/skills/feedback/feedback.sh" "labels rejected case" 2>&1)"
rc12=$?
check "scenario 5: overall call still succeeds after the label-degrade retry" [ "$rc12" -eq 0 ]
check "scenario 5: label create calls were attempted (best-effort)" bash -c 'grep -q "^label create feedback" "$1" && grep -q "^label create from:redeploy" "$1"' _ "$gh_log10"
check "scenario 5: first issue-create attempt carried --label flags" bash -c 'grep -q "^issue create .*--label feedback" "$1"' _ "$gh_log10"
check "scenario 5: a second issue-create attempt (retry) has NO --label flags" bash -c '
  grep "^issue create" "$1" | grep -qv -- "--label"
' _ "$gh_log10"
check "scenario 5: warns on stderr about the label degrade" bash -c 'printf "%s" "$1" | grep -qi "without labels"' _ "$out12"
check "scenario 5: still prints the created issue URL" bash -c 'printf "%s" "$1" | grep -q "https://github.com/robercano/reCode/issues/999"' _ "$out12"

repo11="$(new_fixture repo11 "git@github.com:acme/reDeploy.git" "9.9.9")"
gh_log11="$work/gh-log-11.log"; : > "$gh_log11"
stub11="$(install_stub_gh "$repo11" "$gh_log11" fail-always)"
out13="$(cd "$repo11" && env -u CLAUDE_PLUGIN_ROOT FEEDBACK_GH_BIN="$stub11" FEEDBACK_TEST_GH_LOG="$gh_log11" bash "$repo11/.claude/skills/feedback/feedback.sh" "hard failure case" 2>&1)"
rc13=$?
check "scenario 5b: a hard gh failure (both attempts fail) exits non-zero" [ "$rc13" -ne 0 ]
check "scenario 5b: reports the final failure clearly" bash -c 'printf "%s" "$1" | grep -qi "could not file the feedback issue"' _ "$out13"
check "scenario 5b: retried exactly once without labels before giving up" bash -c '
  n=$(grep -c "^issue create" "$1")
  [ "$n" -eq 2 ]
' _ "$gh_log11"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "feedback.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "feedback.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
