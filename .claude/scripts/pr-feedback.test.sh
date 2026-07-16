#!/usr/bin/env bash
# pr-feedback.test.sh — offline smoke test for the REAL pr-feedback.sh (issue
# #99 re-review finding #4). loop-tick.test.sh/loop-census.test.sh only ever
# stub pr-feedback.sh out entirely — this test runs the ACTUAL script, with a
# stubbed bot-gh.sh answering canned `pr list`/`api .../reviews`/`api
# .../comments` output per scenario, and asserts:
#   - an UNADDRESSED changes-requested PR is listed in the TSV AND clears any
#     earlier "awaiting re-review" needs-human flag (ball is in the bot's
#     court, not the owner's)
#   - an ADDRESSED PR (marker comment newer than the last CHANGES_REQUESTED
#     review) is NOT listed, and instead FLAGS needs-human (owner's turn) --
#     but only posts the GitHub comment on a FRESH escalation episode; a
#     REPEAT run with the label already applied skips the comment (issue #99
#     re-review finding #1, exercised here through pr-feedback.sh's own
#     wiring, not just needs-human.sh's generic seam)
#   - a PR already labeled `claude-addressing` is skipped before any review/
#     comment lookup at all
#   - PR_FEEDBACK_COUNT_ONLY=1 (finding #2) preserves the exact same TSV
#     output while suppressing every label/comment/notify side effect, on
#     BOTH the unaddressed and addressed paths -- this is the mode
#     loop-census.sh now uses so a read-only census never mutates GitHub
#     state.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/pr-feedback.test.sh
set -uo pipefail

unset GATES_FILE

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pr_feedback_src="$script_dir/pr-feedback.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/pr-feedback-test.XXXXXX")"
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

# new_fixture: a throwaway <dir>/.claude/{scripts,state} tree with the REAL
# pr-feedback.sh + resolve-roots.sh + needs-human.sh + notify.sh copied in.
new_fixture() {
  local name="$1"
  local dir="$work/$name"
  local scripts="$dir/.claude/scripts"
  mkdir -p "$scripts" "$dir/.claude/state"
  cp "$pr_feedback_src" "$scripts/pr-feedback.sh"
  cp "$script_dir/resolve-roots.sh" "$scripts/resolve-roots.sh"
  cp "$script_dir/needs-human.sh" "$scripts/needs-human.sh"
  cp "$script_dir/notify.sh" "$scripts/notify.sh"
  chmod +x "$scripts"/*.sh
  cat > "$dir/.claude/gates.json" <<EOF
{ "notify": "printf 'fired\\n' >> $work/$name-notify-fired.txt" }
EOF
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# A. UNADDRESSED changes-requested PR (no "claude-addressed" marker at all):
#    listed in the TSV, AND clears any earlier "awaiting re-review" flag
#    (ball is in the bot's court right now, not the owner's).
# ---------------------------------------------------------------------------
dirA="$(new_fixture scenarioA)"
gh_logA="$work/scenarioA-gh.log"
cat > "$dirA/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logA"
case "\$1" in
  pr)
    case "\$2" in
      list) printf '20\tfeat/issue-20-x\t\n' ;;
      view) : ;; # not queried on this path before the clear
      edit) : ;;
      comment) : ;;
      *) : ;;
    esac
    ;;
  api)
    case "\$2" in
      repos/*/pulls/*/reviews) printf '2026-02-01T00:00:00Z\treviewer1\n' ;;
      repos/*/issues/*/comments) : ;; # no addressed-marker comment at all
      *) : ;;
    esac
    ;;
  label) : ;;
  issue) : ;;
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirA/.claude/scripts/bot-gh.sh"
outA="$(env -u GATES_FILE bash "$dirA/.claude/scripts/pr-feedback.sh" "acme/repo" 2>&1)"

check "A: unaddressed PR 20 IS listed in the TSV" bash -c 'printf "%s\n" "$1" | grep -qF "20	feat/issue-20-x	reviewer1	2026-02-01T00:00:00Z"' _ "$outA"
check "A: earlier 'awaiting re-review' flag is CLEARED (ball back in bot's court)" grep -q "pr edit 20 --remove-label needs-human" "$gh_logA"
check "A: no comment posted on the clear path" bash -c '! grep -q "^pr comment" "$1"' _ "$gh_logA"

# ---------------------------------------------------------------------------
# A-count-only. Same PR/situation, PR_FEEDBACK_COUNT_ONLY=1 -- the census's
# read-only invocation (issue #99 re-review finding #2): TSV output must be
# IDENTICAL, but the clear's gh label mutation must NOT happen at all.
# ---------------------------------------------------------------------------
gh_logAc="$work/scenarioA-count-gh.log"
cat > "$dirA/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logAc"
case "\$1" in
  pr)
    case "\$2" in
      list) printf '20\tfeat/issue-20-x\t\n' ;;
      *) : ;;
    esac
    ;;
  api)
    case "\$2" in
      repos/*/pulls/*/reviews) printf '2026-02-01T00:00:00Z\treviewer1\n' ;;
      repos/*/issues/*/comments) : ;;
      *) : ;;
    esac
    ;;
  label) : ;;
  issue) : ;;
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirA/.claude/scripts/bot-gh.sh"
outAc="$(env -u GATES_FILE PR_FEEDBACK_COUNT_ONLY=1 bash "$dirA/.claude/scripts/pr-feedback.sh" "acme/repo" 2>&1)"

check "A-count-only: TSV output identical to the real (non-count-only) run" \
  bash -c '[ "$1" = "$2" ]' _ "$outA" "$outAc"
check "A-count-only: NO gh label mutation at all (pure counter, finding #2)" bash -c '! grep -q "pr edit" "$1"' _ "$gh_logAc"

# ---------------------------------------------------------------------------
# B. ADDRESSED PR (marker comment newer than the last CHANGES_REQUESTED
#    review): NOT listed; instead FLAGS needs-human (owner's turn to
#    re-review). Run TWICE in a row (simulating two loop ticks with the same
#    still-addressed state) via a label marker FILE that persists across runs
#    -- proves the REAL pr-feedback.sh wiring posts the comment only on the
#    FIRST (fresh) episode and skips it on the repeat (issue #99 re-review
#    finding #1).
# ---------------------------------------------------------------------------
dirB="$(new_fixture scenarioB)"
gh_logB="$work/scenarioB-gh.log"
labeled_markerB="$work/scenarioB-labeled.marker"
cat > "$dirB/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logB"
case "\$1" in
  pr)
    case "\$2" in
      list) printf '21\tfeat/issue-21-y\t\n' ;;
      view)
        if printf '%s\n' "\$*" | grep -q -- '--json labels'; then
          [ -f "$labeled_markerB" ] && printf 'needs-human\n'
        fi
        ;;
      edit)
        if printf '%s\n' "\$*" | grep -q -- '--add-label needs-human'; then
          touch "$labeled_markerB"
        fi
        ;;
      comment) : ;;
      *) : ;;
    esac
    ;;
  api)
    case "\$2" in
      repos/*/pulls/*/reviews) printf '2026-02-01T00:00:00Z\treviewer2\n' ;;
      repos/*/issues/*/comments) printf '2026-02-02T00:00:00Z\n' ;; # marker AFTER the CR
      *) : ;;
    esac
    ;;
  label) : ;;
  issue) : ;;
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirB/.claude/scripts/bot-gh.sh"
outB1="$(env -u GATES_FILE bash "$dirB/.claude/scripts/pr-feedback.sh" "acme/repo" 2>&1)"
outB2="$(env -u GATES_FILE bash "$dirB/.claude/scripts/pr-feedback.sh" "acme/repo" 2>&1)"

check "B: addressed PR 21 is NOT listed on run 1" bash -c '[ -z "$1" ]' _ "$outB1"
check "B: addressed PR 21 is NOT listed on run 2 either" bash -c '[ -z "$1" ]' _ "$outB2"
check "B: label add attempted on BOTH runs" bash -c '[ "$(grep -c "pr edit 21 --add-label needs-human" "$1")" -eq 2 ]' _ "$gh_logB"
check "B: exactly ONE comment across BOTH runs (episode-gated, finding #1)" bash -c '[ "$(grep -c "pr comment 21 --body" "$1")" -eq 1 ]' _ "$gh_logB"

# ---------------------------------------------------------------------------
# B-count-only. Same addressed-PR situation, PR_FEEDBACK_COUNT_ONLY=1 -- no
# label add, no comment, no notify at all (finding #2).
# ---------------------------------------------------------------------------
gh_logBc="$work/scenarioB-count-gh.log"
cat > "$dirB/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logBc"
case "\$1" in
  pr)
    case "\$2" in
      list) printf '21\tfeat/issue-21-y\t\n' ;;
      *) : ;;
    esac
    ;;
  api)
    case "\$2" in
      repos/*/pulls/*/reviews) printf '2026-02-01T00:00:00Z\treviewer2\n' ;;
      repos/*/issues/*/comments) printf '2026-02-02T00:00:00Z\n' ;;
      *) : ;;
    esac
    ;;
  label) : ;;
  issue) : ;;
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirB/.claude/scripts/bot-gh.sh"
outBc="$(env -u GATES_FILE PR_FEEDBACK_COUNT_ONLY=1 bash "$dirB/.claude/scripts/pr-feedback.sh" "acme/repo" 2>&1)"

check "B-count-only: still not listed (same as non-count-only)" bash -c '[ -z "$1" ]' _ "$outBc"
check "B-count-only: no label add, no comment at all" bash -c '! grep -qE "add-label|^pr comment" "$1"' _ "$gh_logBc"

# ---------------------------------------------------------------------------
# C. A PR already labeled `claude-addressing` is skipped entirely -- not even
#    the reviews/comments lookup runs (the early `continue`).
# ---------------------------------------------------------------------------
dirC="$(new_fixture scenarioC)"
gh_logC="$work/scenarioC-gh.log"
cat > "$dirC/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logC"
case "\$1" in
  pr)
    case "\$2" in
      list) printf '22\tfeat/issue-22-z\tclaude-addressing\n' ;;
      *) : ;;
    esac
    ;;
  api) echo "should not be called: \$*" >&2; exit 1 ;;
  *) : ;;
esac
EOF
chmod +x "$dirC/.claude/scripts/bot-gh.sh"
outC="$(env -u GATES_FILE bash "$dirC/.claude/scripts/pr-feedback.sh" "acme/repo" 2>&1)"

check "C: claude-addressing-labeled PR 22 is NOT listed" bash -c '[ -z "$1" ]' _ "$outC"
check "C: no 'api' lookups happened at all (early continue)" bash -c '! grep -q "^api" "$1"' _ "$gh_logC"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "pr-feedback.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "pr-feedback.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
