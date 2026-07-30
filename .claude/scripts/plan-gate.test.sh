#!/usr/bin/env bash
# plan-gate.test.sh — offline smoke test for the optional spec/plan gate
# (issue #100): plan.gate = off|label|always, read once by loop-census.sh and
# threaded through as advance_mode= telemetry by loop-tick.sh, ending in one
# of three ADVANCE driver-prompt variants built by loop-event.sh.
#
# Two halves:
#   1. loop-census.sh (REAL script, mocked `gh` via a fake bot-gh.sh) — proves
#      advance_mode is derived correctly from each candidate's labels per
#      plan.gate mode, that gate=off never emits it (byte-identical to
#      pre-#100 output), and that a `plan-review`-without-`plan-approved`
#      candidate is skipped for advance_ready (awaiting the owner), mirroring
#      loop-census.test.sh's fixture/mock pattern.
#   2. loop-event.sh (REAL script, fed a FAKE loop-tick.sh that emits a
#      scripted advance_mode= line alongside its verdict) — proves the three
#      prompt variants: PLAN-ONLY (no code/branch/PR), implement-gated (the
#      approved-plan injection + "exceeds approved scope" clause), and
#      ungated/off (today's unchanged single-pass prompt) — mirroring
#      loop-event.test.sh's fixture pattern.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/plan-gate.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
census_src="$script_dir/loop-census.sh"
event_src="$script_dir/loop-event.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/plan-gate-test.XXXXXX")"
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
# PART 1: loop-census.sh — advance_mode derivation + awaiting-owner skip.
# =============================================================================

# build_census_fixture NAME GATE LABELS -- one planned+module:test candidate
# (issue 50) carrying LABELS, adapter's plan.gate=GATE. Mirrors
# loop-census.test.sh's fixture-scaffolding pattern (fake bot-gh.sh + real git
# repo so branch=none is genuine, not fabricated).
build_census_fixture() {
  local name="$1" gate="$2" labels="$3"
  local dir="$work/$name"
  local scripts="$dir/.claude/scripts"
  mkdir -p "$scripts"
  cp "$census_src" "$scripts/loop-census.sh"
  cp "$resolve_roots_src" "$scripts/resolve-roots.sh"
  cat > "$dir/.claude/gates.json" <<EOF
{
  "modules": [{ "name": "test", "path": ".", "description": "", "owner": "" }],
  "merge": { "baseBranch": "main" },
  "plan": { "gate": "$gate" }
}
EOF
  cat > "$scripts/pr-feedback.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$scripts/pr-ci-fix.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  repo) echo "acme/repo" ;;
  pr)
    if printf '%s\n' "\$*" | grep -q 'headRefName'; then
      : # no open PRs
    else
      echo 0
    fi
    ;;
  issue)
    case "\$2" in
      list)
        if printf '%s\n' "\$*" | grep -q -- '--label'; then
          printf '50\t$labels\tCandidate fifty\n'
        else
          printf '50\n'
        fi
        ;;
      view) echo '{"body":""}' ;;
      *) echo "unhandled issue subcmd: \$*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: \$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$scripts"/*.sh
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.email=t@e.st -c user.name=t commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

run_census() {
  # $1 = fixture dir. GATES_FILE unset explicitly (a test invoked from inside
  # a GATES_FILE=self/gates.json gate run must not leak that into the
  # fixture's own default-relative gates.json — same guard as
  # loop-census.test.sh).
  env -u GATES_FILE bash "$1/.claude/scripts/loop-census.sh" "acme/repo"
}

# --- (1) gate=off: no advance_mode line at all, advance_ready picked normally
# (byte-identical to pre-#100 behavior — plan-related labels present but
# irrelevant, since the whole feature is a no-op on this path). -------------
dirOff="$(build_census_fixture off-mode off "planned,module:test,plan-first")"
outOff="$(run_census "$dirOff")"
check "(1) gate=off: no advance_mode= line emitted at all" bash -c \
  '! printf "%s\n" "$1" | grep -q "^advance_mode="' _ "$outOff"
check "(1) gate=off: advance_ready=50 picked normally" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=50"' _ "$outOff"

# Same fixture shape but the adapter has NO "plan" key at all (the realistic
# pre-#100 gates.json shape) -- proves the "missing -> off" fallback produces
# the exact same output as an explicit "off".
dirNoPlanKey="$work/no-plan-key"
scriptsNoPlanKey="$dirNoPlanKey/.claude/scripts"
mkdir -p "$scriptsNoPlanKey"
cp "$census_src" "$scriptsNoPlanKey/loop-census.sh"
cp "$resolve_roots_src" "$scriptsNoPlanKey/resolve-roots.sh"
cat > "$dirNoPlanKey/.claude/gates.json" <<'EOF'
{
  "modules": [{ "name": "test", "path": ".", "description": "", "owner": "" }],
  "merge": { "baseBranch": "main" }
}
EOF
cp "$dirOff/.claude/scripts/pr-feedback.sh" "$scriptsNoPlanKey/pr-feedback.sh"
cp "$dirOff/.claude/scripts/pr-ci-fix.sh" "$scriptsNoPlanKey/pr-ci-fix.sh"
cp "$dirOff/.claude/scripts/bot-gh.sh" "$scriptsNoPlanKey/bot-gh.sh"
chmod +x "$scriptsNoPlanKey"/*.sh
git -C "$dirNoPlanKey" init -q -b main
git -C "$dirNoPlanKey" -c user.email=t@e.st -c user.name=t commit -q --allow-empty -m init
outNoPlanKey="$(run_census "$dirNoPlanKey")"
check "(1b) missing plan.gate key falls back to off — output matches the explicit-off run" \
  bash -c '[ "$1" = "$2" ]' _ "$outOff" "$outNoPlanKey"

# --- (2) gate=label + plan-first (no plan-review/approved): needs-plan ------
dirLabelFirst="$(build_census_fixture label-first label "planned,module:test,plan-first")"
outLabelFirst="$(run_census "$dirLabelFirst")"
check "(2) gate=label+plan-first: advance_mode=plan" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_mode=plan"' _ "$outLabelFirst"
check "(2) gate=label+plan-first: advance_ready=50" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=50"' _ "$outLabelFirst"

# --- (3) gate=label + plan-review (no plan-approved): awaiting-owner, NOT
# chosen as advance_ready -- the only candidate, so it stays "none". --------
dirLabelReview="$(build_census_fixture label-review label "planned,module:test,plan-first,plan-review")"
outLabelReview="$(run_census "$dirLabelReview")"
check "(3) gate=label+plan-review: advance_ready stays none (awaiting owner)" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=none"' _ "$outLabelReview"
check "(3) gate=label+plan-review: plan_wait=50 telemetry emitted" bash -c \
  'printf "%s\n" "$1" | grep -qx "plan_wait=50"' _ "$outLabelReview"
check "(3) gate=label+plan-review: no advance_mode= line (nothing was chosen)" bash -c \
  '! printf "%s\n" "$1" | grep -q "^advance_mode="' _ "$outLabelReview"

# --- (4) gate=label + plan-approved: gated-approved -> implement-gated -----
dirLabelApproved="$(build_census_fixture label-approved label "planned,module:test,plan-first,plan-approved")"
outLabelApproved="$(run_census "$dirLabelApproved")"
check "(4) gate=label+plan-approved: advance_mode=implement-gated" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_mode=implement-gated"' _ "$outLabelApproved"
check "(4) gate=label+plan-approved: advance_ready=50" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=50"' _ "$outLabelApproved"

# --- (5) gate=label WITHOUT plan-first: ungated -> implement, normal -------
dirLabelUngated="$(build_census_fixture label-ungated label "planned,module:test")"
outLabelUngated="$(run_census "$dirLabelUngated")"
check "(5) gate=label, no plan-first: advance_mode=implement" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_mode=implement"' _ "$outLabelUngated"
check "(5) gate=label, no plan-first: advance_ready=50" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=50"' _ "$outLabelUngated"

# --- (6) gate=always WITHOUT plan-first: still gated -> needs-plan ---------
dirAlways="$(build_census_fixture always-mode always "planned,module:test")"
outAlways="$(run_census "$dirAlways")"
check "(6) gate=always, no plan-first: advance_mode=plan (gated regardless)" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_mode=plan"' _ "$outAlways"
check "(6) gate=always, no plan-first: advance_ready=50" bash -c \
  'printf "%s\n" "$1" | grep -qx "advance_ready=50"' _ "$outAlways"

# =============================================================================
# PART 2: loop-event.sh — the three ADVANCE prompt variants, driven off a
# scripted fake loop-tick.sh (mirrors loop-event.test.sh's own new_fixture
# pattern — loop-event.sh's own logic is "parse verdict + advance_mode from
# tick stdout, build a prompt", so faking tick's output is the correct unit
# boundary here; census's role in producing that same advance_mode is already
# covered end-to-end by PART 1 above).
# =============================================================================
new_event_fixture() {
  local name="$1" tick_out="$2"
  local dir="$work/$name/.claude/scripts"
  mkdir -p "$dir" "$work/$name/.claude/state"
  cp "$event_src" "$dir/loop-event.sh"
  cp "$resolve_roots_src" "$dir/resolve-roots.sh"
  cat > "$dir/loop-tick.sh" <<EOF
#!/usr/bin/env bash
cat <<'TICK'
$tick_out
TICK
EOF
  chmod +x "$dir"/*.sh
  printf '%s\n' "$work/$name"
}

run_event() {
  ( cd "$1" && PATH="/usr/bin:/bin" bash .claude/scripts/loop-event.sh )
}

# --- PLAN-ONLY prompt (advance_mode=plan) -----------------------------------
dirPlan="$(new_event_fixture evt-plan 'cadence=FAST cron=* * * * *
advance_mode=plan
action=advance issue=61')"
outPlan="$(run_event "$dirPlan")"
pfPlan="$(printf '%s\n' "$outPlan" | sed -n 's/^loop-event: prompt-file=//p')"
check "PLAN prompt: verdict line unchanged (action=advance issue=61)" bash -c \
  'printf "%s\n" "$1" | grep -qxF "loop-event: action=advance issue=61"' _ "$outPlan"
check "PLAN prompt: file exists" bash -c '[ -n "$1" ] && [ -f "$1" ]' _ "$pfPlan"
check "PLAN prompt: says PLAN ONLY" bash -c 'grep -q "PLAN ONLY" "$1"' _ "$pfPlan"
check "PLAN prompt: says Do NOT implement" bash -c 'grep -qi "Do NOT implement" "$1"' _ "$pfPlan"
check "PLAN prompt: instructs the plan-gate:plan marker comment" bash -c 'grep -qF "<!-- plan-gate:plan -->" "$1"' _ "$pfPlan"
check "PLAN prompt: instructs applying plan-review + needs-human labels" bash -c \
  'grep -q "add-label plan-review" "$1" && grep -q "add-label needs-human" "$1"' _ "$pfPlan"
check "PLAN prompt: does NOT drive the full implement flow (no orchestrator/worktree/bot-PR sentence)" bash -c \
  '! grep -qF "Drive issue #61 through the orchestrator" "$1"' _ "$pfPlan"
check "PLAN prompt: does NOT instruct opening a PR (no 'scope -> ... -> bot PR' pipeline text)" bash -c \
  '! grep -qF "reviewer lenses → bot PR" "$1"' _ "$pfPlan"

# --- implement-gated prompt (advance_mode=implement-gated) ------------------
dirGated="$(new_event_fixture evt-gated 'cadence=FAST cron=* * * * *
advance_mode=implement-gated
action=advance issue=62')"
outGated="$(run_event "$dirGated")"
pfGated="$(printf '%s\n' "$outGated" | sed -n 's/^loop-event: prompt-file=//p')"
check "implement-gated prompt: verdict line unchanged (action=advance issue=62)" bash -c \
  'printf "%s\n" "$1" | grep -qxF "loop-event: action=advance issue=62"' _ "$outGated"
check "implement-gated prompt: drives the normal implement flow" bash -c \
  'grep -qF "Drive issue #62 through the orchestrator" "$1"' _ "$pfGated"
check "implement-gated prompt: fetches the approved plan via the plan-gate:plan marker" bash -c \
  'grep -qF "<!-- plan-gate:plan -->" "$1"' _ "$pfGated"
check "implement-gated prompt: injects the plan into implementer AND every reviewer" bash -c \
  'grep -qi "implementer" "$1" && grep -qi "reviewer" "$1" && grep -qi "authoritative scope" "$1"' _ "$pfGated"
check "implement-gated prompt: exceeding scope is a valid reject reason" bash -c \
  'grep -qF "exceeds approved scope" "$1"' _ "$pfGated"

# --- ungated / off prompt (advance_mode=implement, or the line absent
# entirely -- both must produce the SAME, today's-behavior prompt). ---------
dirUngated="$(new_event_fixture evt-ungated 'cadence=FAST cron=* * * * *
advance_mode=implement
action=advance issue=63')"
outUngated="$(run_event "$dirUngated")"
pfUngated="$(printf '%s\n' "$outUngated" | sed -n 's/^loop-event: prompt-file=//p')"
check "ungated prompt: drives the normal implement flow" bash -c \
  'grep -qF "Drive issue #63 through the orchestrator" "$1"' _ "$pfUngated"
check "ungated prompt: no PLAN ONLY wording" bash -c '! grep -q "PLAN ONLY" "$1"' _ "$pfUngated"
check "ungated prompt: no approved-scope injection clause" bash -c '! grep -qF "exceeds approved scope" "$1"' _ "$pfUngated"

# advance_mode= line entirely ABSENT (plan.gate=off never emits it) must
# produce the SAME today's-behavior prompt as the explicit "implement" case
# above (structural equivalence, not byte-for-byte: each fixture's prompt
# embeds its own $script_dir path, which necessarily differs per mktemp'd
# fixture directory).
dirAbsent="$(new_event_fixture evt-absent 'cadence=FAST cron=* * * * *
action=advance issue=63')"
outAbsent="$(run_event "$dirAbsent")"
pfAbsent="$(printf '%s\n' "$outAbsent" | sed -n 's/^loop-event: prompt-file=//p')"
check "absent advance_mode= (gate=off): still drives the normal implement flow" bash -c \
  'grep -qF "Drive issue #63 through the orchestrator" "$1"' _ "$pfAbsent"
check "absent advance_mode= (gate=off): no PLAN ONLY wording" bash -c '! grep -q "PLAN ONLY" "$1"' _ "$pfAbsent"
check "absent advance_mode= (gate=off): no approved-scope injection clause" bash -c '! grep -qF "exceeds approved scope" "$1"' _ "$pfAbsent"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "plan-gate.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "plan-gate.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
