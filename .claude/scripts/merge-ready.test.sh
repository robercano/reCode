#!/usr/bin/env bash
# merge-ready.test.sh — offline smoke test for the REAL merge-ready.sh (issue
# #99 re-review finding #3). Every other suite that touches merge-ready.sh
# (loop-tick.test.sh) stubs it with a fake `echo` — this test runs the ACTUAL
# script, with a stubbed bot-gh.sh answering canned `gh pr list`/`pr view`/
# `pr merge` JSON per verdict path, and asserts the resulting
# needs_human_flag/needs_human_clear gh-call sequence (label add/remove,
# comment, `pr merge`) that flows through the real needs-human.sh seam this
# script sources.
#
# Scenarios K/L/M (issue #175 review finding #2) additionally drive the
# post-merge roadmap commit/push leg with a REAL local git repo + a local
# bare "origin" remote (the same hermetic pattern worktree.test.sh /
# release.test.sh / worktree-cleanup.test.sh / loop-census.test.sh already
# use for exercising a real git push) instead of the "no eligible local
# checkout" stub path scenarios H/I take: K asserts a real diff is committed
# AND pushed to the bare origin; L asserts a footer-only (timestamp) diff is
# correctly treated as "no changes" and never committed (issue #175 finding
# #3); M asserts a REJECTED push (simulated via a bare-repo pre-receive hook)
# rolls local $base back so it is never left diverged from origin (issue
# #175 finding #1b), while the merge itself still succeeds.
#
# Issue #169: needs-human.sh's label reads/writes now go through `gh api`
# (REST) instead of `gh pr edit --*-label`/`gh pr view --json labels`. The
# fake bot-gh.sh below simulates GitHub's own label state via a marker FILE
# the REST add touches, so the post-add CONFIRM read (issue #169's
# comment-gating invariant) sees the label actually "stuck".
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/merge-ready.test.sh
set -uo pipefail

# Isolate from the CALLER's environment, matching needs-human.test.sh /
# loop-census.test.sh: an ambient GATES_FILE (e.g. from a self-host gate run)
# would leak into every fixture's own gates.json lookup below.
unset GATES_FILE

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
merge_ready_src="$script_dir/merge-ready.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/merge-ready-test.XXXXXX")"
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
# merge-ready.sh + resolve-roots.sh + needs-human.sh + notify.sh copied in
# (never reimplemented), a minimal gates.json (base=main, notify command a
# local file append so the notify.sh leg of the seam is also exercised
# offline), and a no-op worktree-cleanup.sh (its own behavior is covered by
# worktree-cleanup.test.sh; here it must just not blow up merge-ready.sh's
# `while read` over its stdout when a PR merges).
new_fixture() {
  local name="$1"
  local dir="$work/$name"
  local scripts="$dir/.claude/scripts"
  mkdir -p "$scripts" "$dir/.claude/state"
  cp "$merge_ready_src" "$scripts/merge-ready.sh"
  cp "$script_dir/resolve-roots.sh" "$scripts/resolve-roots.sh"
  cp "$script_dir/needs-human.sh" "$scripts/needs-human.sh"
  cp "$script_dir/notify.sh" "$scripts/notify.sh"
  cp "$script_dir/log-event.sh" "$scripts/log-event.sh"
  chmod +x "$scripts"/*.sh
  cat > "$dir/.claude/gates.json" <<EOF
{ "merge": { "baseBranch": "main" }, "notify": "printf 'fired\\n' >> $work/$name-notify-fired.txt" }
EOF
  cat > "$scripts/worktree-cleanup.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$scripts/worktree-cleanup.sh"
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# A. SKIP:no-owner-review, run TWICE in a row (simulating two loop ticks with
#    the PR still unreviewed) -- proves the real merge-ready.sh wiring only
#    posts ONE GitHub comment across the whole episode (issue #99 re-review
#    finding #1), while the label is (re-)applied and the verdict is skipped
#    both times. The fake bot-gh.sh tracks "was the label already applied?"
#    via a marker FILE (persists across the two invocations, exactly like a
#    real needs-human label persists across real loop ticks), so the second
#    run's `_needs_human_already_labeled` read reports "yes" and the comment
#    is skipped on that second run.
# ---------------------------------------------------------------------------
dirA="$(new_fixture scenarioA)"
gh_logA="$work/scenarioA-gh.log"
labeled_markerA="$work/scenarioA-labeled.marker"
cat > "$dirA/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logA"
case "\$1" in
  pr)
    case "\$2" in
      list)
        if printf '%s\n' "\$*" | grep -q -- '--json number'; then
          echo "10"
        fi
        ;;
      view)
        cat <<'JSON'
{"number":10,"title":"Add widget","isDraft":false,"baseRefName":"main","headRefName":"feat/issue-10-widget","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[],"commits":[{"committedDate":"2026-01-01T00:00:00Z"}]}
JSON
        ;;
      comment) : ;;
      merge) exit 1 ;;
      *) : ;;
    esac
    ;;
  api)
    case "\$*" in
      *"-X POST"*"/issues/10/labels --input -")
        touch "$labeled_markerA"
        ;;
      *"-q .labels[].name"*)
        [ -f "$labeled_markerA" ] && printf 'needs-human\n'
        ;;
      *) : ;;
    esac
    ;;
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirA/.claude/scripts/bot-gh.sh"

outA1="$(env -u GATES_FILE bash "$dirA/.claude/scripts/merge-ready.sh" "acme/repo" 2>&1)"
outA2="$(env -u GATES_FILE bash "$dirA/.claude/scripts/merge-ready.sh" "acme/repo" 2>&1)"

check "A: first run's verdict is skip:no-owner-review" bash -c 'printf "%s\n" "$1" | grep -q "\"reason\":\"no-owner-review\""' _ "$outA1"
check "A: second run's verdict is ALSO skip:no-owner-review (still unreviewed)" bash -c 'printf "%s\n" "$1" | grep -q "\"reason\":\"no-owner-review\""' _ "$outA2"
check "A: needs-human label add attempted (REST) on BOTH runs" bash -c '[ "$(grep -c -- "-X POST repos/acme/repo/issues/10/labels --input -" "$1")" -eq 2 ]' _ "$gh_logA"
check "A: exactly ONE comment across BOTH runs (episode-gated, finding #1)" bash -c '[ "$(grep -c "pr comment 10 --body" "$1")" -eq 1 ]' _ "$gh_logA"
check "A: no merge was attempted (skip path)" bash -c '! grep -q "^pr merge" "$1"' _ "$gh_logA"

# ---------------------------------------------------------------------------
# B. SKIP:approval-stale (an APPROVED review exists but predates the PR's
#    latest commit -- a push landed after the approval) -- same flag path,
#    different verdict reason. Single run: proves the OTHER skip-reason that
#    triggers needs_human_flag, distinct from "no review at all".
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
      list)
        if printf '%s\n' "\$*" | grep -q -- '--json number'; then
          echo "11"
        fi
        ;;
      view)
        cat <<'JSON'
{"number":11,"title":"Fix bug","isDraft":false,"baseRefName":"main","headRefName":"fix/issue-11-bug","mergeable":"MERGEABLE","reviews":[{"author":{"login":"acme"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"}],"statusCheckRollup":[],"commits":[{"committedDate":"2026-01-02T00:00:00Z"}]}
JSON
        ;;
      comment) : ;;
      merge) exit 1 ;;
      *) : ;;
    esac
    ;;
  api)
    case "\$*" in
      *"-X POST"*"/issues/11/labels --input -")
        touch "$labeled_markerB"
        ;;
      *"-q .labels[].name"*)
        [ -f "$labeled_markerB" ] && printf 'needs-human\n'
        ;;
      *) : ;;
    esac
    ;;
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirB/.claude/scripts/bot-gh.sh"
outB="$(env -u GATES_FILE bash "$dirB/.claude/scripts/merge-ready.sh" "acme/repo" 2>&1)"

check "B: verdict is skip:approval-stale" bash -c 'printf "%s\n" "$1" | grep -q "approval-stale"' _ "$outB"
check "B: label add attempted via REST (fresh episode)" grep -qF -- "-X POST repos/acme/repo/issues/11/labels --input -" "$gh_logB"
check "B: comment posted (fresh, CONFIRMED episode, ready-for-review body)" bash -c 'grep -q "pr comment 11 --body" "$1"' _ "$gh_logB"

# ---------------------------------------------------------------------------
# C. Successful MERGE: owner-approved, CI-green, head_branch matches
#    feat/issue-<N>-*. Asserts the on-merge clear fan-out: pr:12's pr-review
#    AND changes-requested flags clear, AND (via the head_branch->issue-number
#    regex) issue:77's attempt-budget AND stall flags clear too.
# ---------------------------------------------------------------------------
dirC="$(new_fixture scenarioC)"
gh_logC="$work/scenarioC-gh.log"
cat > "$dirC/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logC"
case "\$1" in
  pr)
    case "\$2" in
      list)
        if printf '%s\n' "\$*" | grep -q -- '--json number'; then
          echo "12"
        fi
        ;;
      view)
        cat <<'JSON'
{"number":12,"title":"Ship feature","isDraft":false,"baseRefName":"main","headRefName":"feat/issue-77-thing","mergeable":"MERGEABLE","reviews":[{"author":{"login":"acme"},"state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z"}],"statusCheckRollup":[],"commits":[{"committedDate":"2026-01-01T00:00:00Z"}]}
JSON
        ;;
      merge) exit 0 ;;
      comment) : ;;
      *) : ;;
    esac
    ;;
  api) : ;;  # every REST call here is a needs_human_clear DELETE no-op
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirC/.claude/scripts/bot-gh.sh"
outC="$(env -u GATES_FILE bash "$dirC/.claude/scripts/merge-ready.sh" "acme/repo" 2>&1)"

check "C: PR merged" bash -c 'printf "%s\n" "$1" | grep -q "\"action\":\"merged\""' _ "$outC"
check "C: gh pr merge invoked with --merge --delete-branch" grep -q "pr merge 12 -R acme/repo --merge --delete-branch" "$gh_logC"
check "C: no comment posted on the merge path (verdict never hits the flag case)" bash -c '! grep -q "^pr comment" "$1"' _ "$gh_logC"
check "C: pr:12 pr-review/changes-requested cleared via REST DELETE -- appears 3x (case-default once, success block twice)" \
  bash -c '[ "$(grep -c -- "-X DELETE repos/acme/repo/issues/12/labels/needs-human" "$1")" -eq 3 ]' _ "$gh_logC"
check "C: head_branch->issue-number regex clears issue 77's attempt-budget AND stall (2x REST DELETE .../issues/77/labels/needs-human)" \
  bash -c '[ "$(grep -c -- "-X DELETE repos/acme/repo/issues/77/labels/needs-human" "$1")" -eq 2 ]' _ "$gh_logC"
check "C: no needs-human label ever ADDED (REST POST) on the merge path" bash -c '! grep -q -- "-X POST" "$1"' _ "$gh_logC"

# ---------------------------------------------------------------------------
# D. Protected-paths guard BLOCKS+LABELS (issue #94 Layer 2): an otherwise-
#    MERGEable PR (owner-approved, CI-green) whose diff touches a path
#    matching the fixture's protectedPaths (.claude/**) must NOT be merged --
#    verdict flips to SKIP:protected-paths, the needs-human label is added
#    (REST POST), and the skip line in the output carries reason
#    "protected-paths".
# ---------------------------------------------------------------------------
dirD="$(new_fixture scenarioD)"
cat > "$dirD/.claude/gates.json" <<EOF
{ "merge": { "baseBranch": "main" }, "protectedPaths": [".claude/**"], "notify": "printf 'fired\\n' >> $work/scenarioD-notify-fired.txt" }
EOF
gh_logD="$work/scenarioD-gh.log"
labeled_markerD="$work/scenarioD-labeled.marker"
cat > "$dirD/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logD"
case "\$1" in
  pr)
    case "\$2" in
      list)
        if printf '%s\n' "\$*" | grep -q -- '--json number'; then
          echo "13"
        fi
        ;;
      view)
        cat <<'JSON'
{"number":13,"title":"Touch harness","isDraft":false,"baseRefName":"main","headRefName":"feat/issue-13-harness","mergeable":"MERGEABLE","reviews":[{"author":{"login":"acme"},"state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z"}],"statusCheckRollup":[],"commits":[{"committedDate":"2026-01-01T00:00:00Z"}],"files":[{"path":".claude/scripts/x.sh"}]}
JSON
        ;;
      comment) : ;;
      merge) exit 1 ;;
      *) : ;;
    esac
    ;;
  api)
    case "\$*" in
      *"-X POST"*"/issues/13/labels --input -")
        touch "$labeled_markerD"
        ;;
      *"-q .labels[].name"*)
        [ -f "$labeled_markerD" ] && printf 'needs-human\n'
        ;;
      *) : ;;
    esac
    ;;
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirD/.claude/scripts/bot-gh.sh"
outD="$(env -u GATES_FILE bash "$dirD/.claude/scripts/merge-ready.sh" "acme/repo" 2>&1)"

check "D: no merge was attempted (protected-paths blocks an otherwise-MERGE verdict)" bash -c '! grep -q "^pr merge" "$1"' _ "$gh_logD"
check "D: needs-human label add attempted (REST POST)" grep -qF -- "-X POST repos/acme/repo/issues/13/labels --input -" "$gh_logD"
check "D: skip line reason is protected-paths" bash -c 'printf "%s\n" "$1" | grep -q "\"reason\":\"protected-paths\""' _ "$outD"

# ---------------------------------------------------------------------------
# E. Protected-paths guard CLEAN PROCEEDS: same protectedPaths config as D,
#    but the PR's diff touches an ordinary source file -- verdict stays MERGE
#    and the PR merges normally, with no protected-paths reason anywhere in
#    the output.
# ---------------------------------------------------------------------------
dirE="$(new_fixture scenarioE)"
cat > "$dirE/.claude/gates.json" <<EOF
{ "merge": { "baseBranch": "main" }, "protectedPaths": [".claude/**"], "notify": "printf 'fired\\n' >> $work/scenarioE-notify-fired.txt" }
EOF
gh_logE="$work/scenarioE-gh.log"
cat > "$dirE/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logE"
case "\$1" in
  pr)
    case "\$2" in
      list)
        if printf '%s\n' "\$*" | grep -q -- '--json number'; then
          echo "14"
        fi
        ;;
      view)
        cat <<'JSON'
{"number":14,"title":"Ship app feature","isDraft":false,"baseRefName":"main","headRefName":"feat/issue-14-app","mergeable":"MERGEABLE","reviews":[{"author":{"login":"acme"},"state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z"}],"statusCheckRollup":[],"commits":[{"committedDate":"2026-01-01T00:00:00Z"}],"files":[{"path":"src/app.js"}]}
JSON
        ;;
      merge) exit 0 ;;
      comment) : ;;
      *) : ;;
    esac
    ;;
  api) : ;;  # every REST call here is a needs_human_clear DELETE no-op
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirE/.claude/scripts/bot-gh.sh"
outE="$(env -u GATES_FILE bash "$dirE/.claude/scripts/merge-ready.sh" "acme/repo" 2>&1)"

check "E: PR merged (protected-paths does not fire on a clean diff)" bash -c 'printf "%s\n" "$1" | grep -q "\"action\":\"merged\""' _ "$outE"
check "E: gh pr merge invoked" grep -q "pr merge 14 -R acme/repo --merge --delete-branch" "$gh_logE"
# NOTE: don't assert "output doesn't contain 'protected-paths'" verbatim -- the
# post-merge local_sync leg reports the CALLER's real checked-out branch name,
# which could itself contain that substring (e.g. this very branch). Assert on
# the specific skip-reason/label-add shapes protected-paths would produce instead.
check "E: no protected-paths skip reason in output" bash -c '! printf "%s\n" "$1" | grep -q "\"reason\":\"protected-paths\""' _ "$outE"
check "E: no needs-human label add attempted (nothing to flag)" bash -c '! grep -qF -- "-X POST repos/acme/repo/issues/14/labels --input -" "$1"' _ "$gh_logE"

# ---------------------------------------------------------------------------
# F. Protected-paths EMPTY OVERRIDE DISABLES the guard (issue #94 Layer 2 self-
#    host override): protectedPaths:[] in the fixture's gates.json means the
#    check is disabled even though the diff touches a path that WOULD match
#    ".claude/**" if the guard were enabled -- PR merges normally.
# ---------------------------------------------------------------------------
dirF="$(new_fixture scenarioF)"
cat > "$dirF/.claude/gates.json" <<EOF
{ "merge": { "baseBranch": "main" }, "protectedPaths": [], "notify": "printf 'fired\\n' >> $work/scenarioF-notify-fired.txt" }
EOF
gh_logF="$work/scenarioF-gh.log"
cat > "$dirF/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logF"
case "\$1" in
  pr)
    case "\$2" in
      list)
        if printf '%s\n' "\$*" | grep -q -- '--json number'; then
          echo "15"
        fi
        ;;
      view)
        cat <<'JSON'
{"number":15,"title":"Self-host harness slice","isDraft":false,"baseRefName":"main","headRefName":"feat/issue-15-harness","mergeable":"MERGEABLE","reviews":[{"author":{"login":"acme"},"state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z"}],"statusCheckRollup":[],"commits":[{"committedDate":"2026-01-01T00:00:00Z"}],"files":[{"path":".claude/scripts/x.sh"}]}
JSON
        ;;
      merge) exit 0 ;;
      comment) : ;;
      *) : ;;
    esac
    ;;
  api) : ;;  # every REST call here is a needs_human_clear DELETE no-op
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirF/.claude/scripts/bot-gh.sh"
outF="$(env -u GATES_FILE bash "$dirF/.claude/scripts/merge-ready.sh" "acme/repo" 2>&1)"

check "F: PR merged (empty protectedPaths override disables the guard)" bash -c 'printf "%s\n" "$1" | grep -q "\"action\":\"merged\""' _ "$outF"
check "F: gh pr merge invoked despite touching .claude/**" grep -q "pr merge 15 -R acme/repo --merge --delete-branch" "$gh_logF"

# ---------------------------------------------------------------------------
# G. GATES_FILE actually SET (issue #94 Layer 2 crux, TESTS reviewer finding):
#    scenarios A-F never run merge-ready.sh with GATES_FILE actually set --
#    they all resolve the ROOT gates.json by DEFAULT. This scenario is the one
#    that proves gates_rel="${GATES_FILE:-.claude/gates.json}" plus the
#    `case "$gates_rel" in /*) ...; *) gates="$root/$gates_rel";; esac` split
#    actually SELECTS which adapter's protectedPaths governs the guard.
#
#    ONE fixture, ONE PR (#16, touches .claude/scripts/x.sh), THREE runs that
#    differ ONLY in GATES_FILE, with OPPOSITE outcomes:
#      G1 - GATES_FILE unset            -> ROOT gates.json  (protectedPaths:[])
#                                           -> guard DISABLED -> PR MERGES.
#      G2 - GATES_FILE=<relative path>   -> SELF adapter (protectedPaths:[".claude/**"])
#                                           via the `*)` branch (gates="$root/$gates_rel")
#                                           -> guard ENABLED -> PR BLOCKED.
#      G3 - GATES_FILE=<absolute path>   -> SAME self adapter, via the `/*)`
#                                           branch this time -> guard ENABLED
#                                           -> PR BLOCKED.
#    G1-vs-G2 on the IDENTICAL fixture/PR, differing only in GATES_FILE, is the
#    load-bearing assertion; G3 additionally proves the absolute-path branch.
#
#    Each run gets its OWN gh.log (via GH_LOG, read by the fake bot-gh.sh
#    below) so G1's merge call can never pollute a "no merge happened" assertion
#    on G2/G3 (mirrors scenario A's separate-log-per-run discipline). Assertions
#    are specific JSON-shape / gh-call greps, never a raw substring match on the
#    whole output (the post-merge local_sync line echoes the caller's own
#    checked-out branch name -- the false positive that bit scenario E).
# ---------------------------------------------------------------------------
dirG="$(new_fixture scenarioG)"
cat > "$dirG/.claude/gates.json" <<EOF
{ "merge": { "baseBranch": "main" }, "protectedPaths": [], "notify": "printf 'fired\\n' >> $work/scenarioG-notify-fired.txt" }
EOF
mkdir -p "$dirG/.claude/self"
cat > "$dirG/.claude/self/gates.json" <<EOF
{ "merge": { "baseBranch": "main" }, "protectedPaths": [".claude/**"] }
EOF
labeled_markerG="$work/scenarioG-labeled.marker"
cat > "$dirG/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
log="\${GH_LOG:-$work/scenarioG-default-gh.log}"
printf '%s\n' "\$*" >> "\$log"
case "\$1" in
  pr)
    case "\$2" in
      list)
        if printf '%s\n' "\$*" | grep -q -- '--json number'; then
          echo "16"
        fi
        ;;
      view)
        cat <<'JSON'
{"number":16,"title":"Touch harness via adapter","isDraft":false,"baseRefName":"main","headRefName":"feat/issue-16-adapter","mergeable":"MERGEABLE","reviews":[{"author":{"login":"acme"},"state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z"}],"statusCheckRollup":[],"commits":[{"committedDate":"2026-01-01T00:00:00Z"}],"files":[{"path":".claude/scripts/x.sh"}]}
JSON
        ;;
      merge) exit 0 ;;
      comment) : ;;
      *) : ;;
    esac
    ;;
  api)
    case "\$*" in
      *"-X POST"*"/issues/16/labels --input -")
        touch "$labeled_markerG"
        ;;
      *"-q .labels[].name"*)
        [ -f "$labeled_markerG" ] && printf 'needs-human\n'
        ;;
      *) : ;;
    esac
    ;;
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirG/.claude/scripts/bot-gh.sh"

gh_logG1="$work/scenarioG-run1-gh.log"
outG1="$(env -u GATES_FILE GH_LOG="$gh_logG1" bash "$dirG/.claude/scripts/merge-ready.sh" "acme/repo" 2>&1)"

gh_logG2="$work/scenarioG-run2-gh.log"
outG2="$(GATES_FILE=.claude/self/gates.json GH_LOG="$gh_logG2" bash "$dirG/.claude/scripts/merge-ready.sh" "acme/repo" 2>&1)"

gh_logG3="$work/scenarioG-run3-gh.log"
outG3="$(GATES_FILE="$dirG/.claude/self/gates.json" GH_LOG="$gh_logG3" bash "$dirG/.claude/scripts/merge-ready.sh" "acme/repo" 2>&1)"

check "G1: GATES_FILE unset -> ROOT adapter (protectedPaths:[]) -> guard DISABLED -> PR MERGES" \
  bash -c 'printf "%s\n" "$1" | grep -q "\"action\":\"merged\""' _ "$outG1"
check "G1: no protected-paths reason in output (guard disabled)" \
  bash -c '! printf "%s\n" "$1" | grep -q "\"reason\":\"protected-paths\""' _ "$outG1"
check "G1: gh pr merge invoked" \
  grep -q "pr merge 16 -R acme/repo --merge --delete-branch" "$gh_logG1"

check "G2: GATES_FILE=relative self-adapter path -> resolves protectedPaths:[\".claude/**\"] -> guard ENABLED -> PR BLOCKED (opposite of G1 on the SAME fixture/PR)" \
  bash -c 'printf "%s\n" "$1" | grep -q "\"reason\":\"protected-paths\""' _ "$outG2"
check "G2: no merge attempted for PR 16" \
  bash -c '! grep -q "pr merge 16" "$1"' _ "$gh_logG2"
check "G2: needs-human label add attempted (REST POST)" \
  grep -qF -- "-X POST repos/acme/repo/issues/16/labels --input -" "$gh_logG2"

check "G3: GATES_FILE=absolute self-adapter path (exercises the /* branch) also BLOCKS" \
  bash -c 'printf "%s\n" "$1" | grep -q "\"reason\":\"protected-paths\""' _ "$outG3"
check "G3: no merge attempted for PR 16 (absolute-path adapter selection)" \
  bash -c '! grep -q "pr merge 16" "$1"' _ "$gh_logG3"
check "G3: needs-human label add attempted (REST POST) via absolute-path adapter" \
  grep -qF -- "-X POST repos/acme/repo/issues/16/labels --input -" "$gh_logG3"

# ---------------------------------------------------------------------------
# H. Post-merge roadmap regen (issue #175) is INVOKED on a successful merge.
#    The fixture's roadmap.sh is a stub that touches a marker file (proving
#    invocation) whenever it's called with --write, then exits 0. Reuses the
#    same scenario-C-shaped MERGE fixture (owner-approved, CI-green PR).
# ---------------------------------------------------------------------------
dirH="$(new_fixture scenarioH)"
gh_logH="$work/scenarioH-gh.log"
roadmap_markerH="$work/scenarioH-roadmap-invoked.marker"
cat > "$dirH/.claude/scripts/roadmap.sh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "--write" ]; then
  touch "$roadmap_markerH"
fi
exit 0
EOF
chmod +x "$dirH/.claude/scripts/roadmap.sh"
cat > "$dirH/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logH"
case "\$1" in
  pr)
    case "\$2" in
      list)
        if printf '%s\n' "\$*" | grep -q -- '--json number'; then
          echo "17"
        fi
        ;;
      view)
        cat <<'JSON'
{"number":17,"title":"Ship roadmap-adjacent feature","isDraft":false,"baseRefName":"main","headRefName":"feat/issue-17-thing","mergeable":"MERGEABLE","reviews":[{"author":{"login":"acme"},"state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z"}],"statusCheckRollup":[],"commits":[{"committedDate":"2026-01-01T00:00:00Z"}]}
JSON
        ;;
      merge) exit 0 ;;
      comment) : ;;
      *) : ;;
    esac
    ;;
  api) : ;;  # every REST call here is a needs_human_clear DELETE no-op
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirH/.claude/scripts/bot-gh.sh"
outH="$(env -u GATES_FILE bash "$dirH/.claude/scripts/merge-ready.sh" "acme/repo" 2>&1)"

check "H: PR merged" bash -c 'printf "%s\n" "$1" | grep -q "\"action\":\"merged\""' _ "$outH"
check "H: roadmap.sh --write was actually invoked (marker file created)" test -f "$roadmap_markerH"
check "H: output reports roadmap_regen generated" bash -c 'printf "%s\n" "$1" | grep -q "\"roadmap_regen\":\"generated\""' _ "$outH"

# ---------------------------------------------------------------------------
# I. Post-merge roadmap regen FAILURE is NON-FATAL: the fixture's roadmap.sh
#    always exits 1 (simulating a generator crash). The merge itself must
#    still be reported as merged, and the overall merge-ready.sh invocation
#    must still exit 0 -- a broken roadmap generator must never break, abort,
#    or roll back a merge that already succeeded.
# ---------------------------------------------------------------------------
dirI="$(new_fixture scenarioI)"
gh_logI="$work/scenarioI-gh.log"
cat > "$dirI/.claude/scripts/roadmap.sh" <<'EOF'
#!/usr/bin/env bash
echo "boom: simulated roadmap generator crash" >&2
exit 1
EOF
chmod +x "$dirI/.claude/scripts/roadmap.sh"
cat > "$dirI/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logI"
case "\$1" in
  pr)
    case "\$2" in
      list)
        if printf '%s\n' "\$*" | grep -q -- '--json number'; then
          echo "18"
        fi
        ;;
      view)
        cat <<'JSON'
{"number":18,"title":"Ship another feature","isDraft":false,"baseRefName":"main","headRefName":"feat/issue-18-thing","mergeable":"MERGEABLE","reviews":[{"author":{"login":"acme"},"state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z"}],"statusCheckRollup":[],"commits":[{"committedDate":"2026-01-01T00:00:00Z"}]}
JSON
        ;;
      merge) exit 0 ;;
      comment) : ;;
      *) : ;;
    esac
    ;;
  api) : ;;
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirI/.claude/scripts/bot-gh.sh"
set +e
outI="$(env -u GATES_FILE bash "$dirI/.claude/scripts/merge-ready.sh" "acme/repo" 2>&1)"
rcI=$?
set -e

check "I: merge-ready.sh exits 0 despite the roadmap generator crashing" bash -c '[ "$1" -eq 0 ]' _ "$rcI"
check "I: PR still reported merged (roadmap failure did not roll back the merge)" bash -c 'printf "%s\n" "$1" | grep -q "\"action\":\"merged\""' _ "$outI"
check "I: roadmap_regen skip reason surfaced (generator failed)" bash -c 'printf "%s\n" "$1" | grep -q "roadmap_regen.*generator failed"' _ "$outI"

# ---------------------------------------------------------------------------
# J. Roadmap regen is NEVER invoked on a SKIP-only run (no merge happened at
#    all) -- it lives inside the `if [ "$merged" -gt 0 ]` post-merge block,
#    same as the existing local_sync leg. Reuses scenario A's SKIP:no-owner-
#    review shape with a marker-touching roadmap.sh stub, proving the marker
#    stays absent.
# ---------------------------------------------------------------------------
dirJ="$(new_fixture scenarioJ)"
gh_logJ="$work/scenarioJ-gh.log"
roadmap_markerJ="$work/scenarioJ-roadmap-invoked.marker"
labeled_markerJ="$work/scenarioJ-labeled.marker"
cat > "$dirJ/.claude/scripts/roadmap.sh" <<EOF
#!/usr/bin/env bash
touch "$roadmap_markerJ"
exit 0
EOF
chmod +x "$dirJ/.claude/scripts/roadmap.sh"
cat > "$dirJ/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logJ"
case "\$1" in
  pr)
    case "\$2" in
      list)
        if printf '%s\n' "\$*" | grep -q -- '--json number'; then
          echo "19"
        fi
        ;;
      view)
        cat <<'JSON'
{"number":19,"title":"Add widget","isDraft":false,"baseRefName":"main","headRefName":"feat/issue-19-widget","mergeable":"MERGEABLE","reviews":[],"statusCheckRollup":[],"commits":[{"committedDate":"2026-01-01T00:00:00Z"}]}
JSON
        ;;
      comment) : ;;
      merge) exit 1 ;;
      *) : ;;
    esac
    ;;
  api)
    case "\$*" in
      *"-X POST"*"/issues/19/labels --input -")
        touch "$labeled_markerJ"
        ;;
      *"-q .labels[].name"*)
        [ -f "$labeled_markerJ" ] && printf 'needs-human\n'
        ;;
      *) : ;;
    esac
    ;;
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirJ/.claude/scripts/bot-gh.sh"
outJ="$(env -u GATES_FILE bash "$dirJ/.claude/scripts/merge-ready.sh" "acme/repo" 2>&1)"

check "J: verdict is skip:no-owner-review (no merge happened)" bash -c 'printf "%s\n" "$1" | grep -q "\"reason\":\"no-owner-review\""' _ "$outJ"
check "J: roadmap.sh was NEVER invoked on a skip-only run (no marker file)" bash -c '[ ! -f "$1" ]' _ "$roadmap_markerJ"

# ---------------------------------------------------------------------------
# init_git_repo_fixture <fixture-dir> <origin-bare-dir>: turns a fixture dir
# (already created via new_fixture) into a REAL git repo on branch "main"
# (repo-LOCAL user.email/user.name only -- never touches global git config)
# with a local bare "origin" remote at <origin-bare-dir>. Does not commit or
# push anything itself -- each K/L/M scenario below seeds + pushes its own
# initial commit so it controls exactly what's "already committed" before
# merge-ready.sh runs.
# ---------------------------------------------------------------------------
init_git_repo_fixture() {
  local dir="$1" origin_bare="$2"
  git init -q -b main "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  git init -q --bare -b main "$origin_bare"
  git -C "$dir" remote add origin "$origin_bare"
}

# ---------------------------------------------------------------------------
# K. Real post-merge roadmap COMMIT + PUSH (issue #175 review finding #2): a
#    real git repo, on main, clean, in sync with a local bare "origin" -- the
#    fixture's roadmap.sh stub writes a docs/ROADMAP.md that doesn't exist in
#    HEAD yet, so the change-detection must see a real diff. Asserts the
#    commit lands locally AND is actually pushed to the bare origin's main
#    ref (not just a stubbed/skipped path like scenarios H/I).
# ---------------------------------------------------------------------------
dirK="$(new_fixture scenarioK)"
originK="$work/scenarioK-origin.git"
init_git_repo_fixture "$dirK" "$originK"
printf 'seed\n' > "$dirK/seed.txt"
git -C "$dirK" add seed.txt
git -C "$dirK" commit -q -m "seed"
git -C "$dirK" push -q origin main

cat > "$dirK/.claude/scripts/roadmap.sh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--write" ]; then
  mkdir -p docs
  cat > docs/ROADMAP.md <<'ROADMAP'
# Roadmap

- issue #1 open

---
_Generated 2026-01-01T00:00:00Z · commit `abc1234`_
ROADMAP
fi
exit 0
EOF
chmod +x "$dirK/.claude/scripts/roadmap.sh"
gh_logK="$work/scenarioK-gh.log"
cat > "$dirK/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logK"
case "\$1" in
  pr)
    case "\$2" in
      list)
        if printf '%s\n' "\$*" | grep -q -- '--json number'; then
          echo "20"
        fi
        ;;
      view)
        cat <<'JSON'
{"number":20,"title":"Ship widget","isDraft":false,"baseRefName":"main","headRefName":"feat/issue-20-widget","mergeable":"MERGEABLE","reviews":[{"author":{"login":"acme"},"state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z"}],"statusCheckRollup":[],"commits":[{"committedDate":"2026-01-01T00:00:00Z"}]}
JSON
        ;;
      merge) exit 0 ;;
      comment) : ;;
      *) : ;;
    esac
    ;;
  api) : ;;  # every REST call here is a needs_human_clear DELETE no-op
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirK/.claude/scripts/bot-gh.sh"
outK="$( (cd "$dirK" && env -u GATES_FILE bash .claude/scripts/merge-ready.sh "acme/repo") 2>&1 )"

check "K: PR merged" bash -c 'printf "%s\n" "$1" | grep -q "\"action\":\"merged\""' _ "$outK"
check "K: roadmap_regen reports committed:true" bash -c 'printf "%s\n" "$1" | grep -q "roadmap_regen.*\"committed\":true"' _ "$outK"
check "K: the regen commit actually landed locally on main" bash -c '
  [ "$(git -C "$1" log -1 --pretty=%s)" = "chore: regenerate docs/ROADMAP.md [skip ci]" ]
' _ "$dirK"
check "K: the push actually reached the bare origin (main ref advanced)" bash -c '
  [ "$(git -C "$1" log -1 --pretty=%s refs/heads/main)" = "chore: regenerate docs/ROADMAP.md [skip ci]" ]
' _ "$originK"
check "K: the bare origin content matches the regenerated roadmap" bash -c '
  git -C "$1" show refs/heads/main:docs/ROADMAP.md | grep -q "issue #1 open"
' _ "$originK"
check "K: local main and origin main are in sync after the push" bash -c '
  [ "$(git -C "$1" rev-parse main)" = "$(git -C "$2" rev-parse refs/heads/main)" ]
' _ "$dirK" "$originK"

# ---------------------------------------------------------------------------
# L. "No changes" path is taken when the regenerated roadmap is semantically
#    UNCHANGED (issue #175 review finding #3): docs/ROADMAP.md is already
#    committed (and pushed) with some body + a footer timestamp; the
#    fixture's roadmap.sh stub regenerates the SAME body but a DIFFERENT
#    footer timestamp/commit line, mimicking roadmap.sh's real footer churn.
#    Asserts NO commit is made and the bare origin's main ref never moves.
# ---------------------------------------------------------------------------
dirL="$(new_fixture scenarioL)"
originL="$work/scenarioL-origin.git"
init_git_repo_fixture "$dirL" "$originL"
mkdir -p "$dirL/docs"
cat > "$dirL/docs/ROADMAP.md" <<'EOF'
# Roadmap

- issue #1 open

---
_Generated 2026-01-01T00:00:00Z · commit `seed0001`_
EOF
git -C "$dirL" add docs/ROADMAP.md
git -C "$dirL" commit -q -m "chore: regenerate docs/ROADMAP.md [skip ci]"
git -C "$dirL" push -q origin main

cat > "$dirL/.claude/scripts/roadmap.sh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--write" ]; then
  mkdir -p docs
  cat > docs/ROADMAP.md <<'ROADMAP'
# Roadmap

- issue #1 open

---
_Generated 2026-06-06T12:00:00Z · commit `deadbee1`_
ROADMAP
fi
exit 0
EOF
chmod +x "$dirL/.claude/scripts/roadmap.sh"
gh_logL="$work/scenarioL-gh.log"
cat > "$dirL/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logL"
case "\$1" in
  pr)
    case "\$2" in
      list)
        if printf '%s\n' "\$*" | grep -q -- '--json number'; then
          echo "21"
        fi
        ;;
      view)
        cat <<'JSON'
{"number":21,"title":"Ship gizmo","isDraft":false,"baseRefName":"main","headRefName":"feat/issue-21-gizmo","mergeable":"MERGEABLE","reviews":[{"author":{"login":"acme"},"state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z"}],"statusCheckRollup":[],"commits":[{"committedDate":"2026-01-01T00:00:00Z"}]}
JSON
        ;;
      merge) exit 0 ;;
      comment) : ;;
      *) : ;;
    esac
    ;;
  api) : ;;  # every REST call here is a needs_human_clear DELETE no-op
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirL/.claude/scripts/bot-gh.sh"
preShaL="$(git -C "$originL" rev-parse refs/heads/main)"
outL="$( (cd "$dirL" && env -u GATES_FILE bash .claude/scripts/merge-ready.sh "acme/repo") 2>&1 )"
postShaL="$(git -C "$originL" rev-parse refs/heads/main)"

check "L: PR merged" bash -c 'printf "%s\n" "$1" | grep -q "\"action\":\"merged\""' _ "$outL"
check "L: roadmap_regen reports committed:false, reason no changes (footer-only diff ignored)" bash -c '
  printf "%s\n" "$1" | grep -q "roadmap_regen.*\"committed\":false" && printf "%s\n" "$1" | grep -q "no changes"
' _ "$outL"
check "L: no new commit was made locally (still just the single seeded roadmap commit)" bash -c '
  [ "$(git -C "$1" log --oneline | wc -l)" -eq 1 ]
' _ "$dirL"
check "L: the bare origin main ref never moved" bash -c '[ "$1" = "$2" ]' _ "$preShaL" "$postShaL"

# ---------------------------------------------------------------------------
# M. Push FAILURE rolls back local $base so it is never left diverged from
#    origin (issue #175 review finding #1b): the bare origin's pre-receive
#    hook rejects every push (simulating branch protection / offline), so
#    the regen commit is created locally but the push fails. Asserts (a) the
#    merge itself still succeeds and merge-ready.sh still exits 0, and (b)
#    local main ends up IDENTICAL to origin main (rolled back), never a
#    dangling local commit diverging main from origin.
# ---------------------------------------------------------------------------
dirM="$(new_fixture scenarioM)"
originM="$work/scenarioM-origin.git"
init_git_repo_fixture "$dirM" "$originM"
printf 'seed\n' > "$dirM/seed.txt"
git -C "$dirM" add seed.txt
git -C "$dirM" commit -q -m "seed"
git -C "$dirM" push -q origin main
mkdir -p "$originM/hooks"
cat > "$originM/hooks/pre-receive" <<'EOF'
#!/usr/bin/env bash
echo "remote: rejected (branch protection)" >&2
exit 1
EOF
chmod +x "$originM/hooks/pre-receive"

cat > "$dirM/.claude/scripts/roadmap.sh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--write" ]; then
  mkdir -p docs
  cat > docs/ROADMAP.md <<'ROADMAP'
# Roadmap

- issue #1 open

---
_Generated 2026-01-01T00:00:00Z · commit `abc1234`_
ROADMAP
fi
exit 0
EOF
chmod +x "$dirM/.claude/scripts/roadmap.sh"
gh_logM="$work/scenarioM-gh.log"
cat > "$dirM/.claude/scripts/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_logM"
case "\$1" in
  pr)
    case "\$2" in
      list)
        if printf '%s\n' "\$*" | grep -q -- '--json number'; then
          echo "22"
        fi
        ;;
      view)
        cat <<'JSON'
{"number":22,"title":"Ship sprocket","isDraft":false,"baseRefName":"main","headRefName":"feat/issue-22-sprocket","mergeable":"MERGEABLE","reviews":[{"author":{"login":"acme"},"state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z"}],"statusCheckRollup":[],"commits":[{"committedDate":"2026-01-01T00:00:00Z"}]}
JSON
        ;;
      merge) exit 0 ;;
      comment) : ;;
      *) : ;;
    esac
    ;;
  api) : ;;  # every REST call here is a needs_human_clear DELETE no-op
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$dirM/.claude/scripts/bot-gh.sh"
preShaM="$(git -C "$originM" rev-parse refs/heads/main)"
set +e
outM="$( (cd "$dirM" && env -u GATES_FILE bash .claude/scripts/merge-ready.sh "acme/repo") 2>&1 )"
rcM=$?
set -e
postShaM="$(git -C "$originM" rev-parse refs/heads/main)"
localShaM="$(git -C "$dirM" rev-parse main)"

check "M: merge-ready.sh exits 0 despite the roadmap push being rejected" bash -c '[ "$1" -eq 0 ]' _ "$rcM"
check "M: PR still reported merged (roadmap push failure did not roll back the merge)" bash -c 'printf "%s\n" "$1" | grep -q "\"action\":\"merged\""' _ "$outM"
check "M: roadmap_regen surfaces the rolled-back commit/push failure" bash -c 'printf "%s\n" "$1" | grep -q "commit or push failed (rolled back)"' _ "$outM"
check "M: the bare origin main ref never moved (push was rejected)" bash -c '[ "$1" = "$2" ]' _ "$preShaM" "$postShaM"
check "M: local main was rolled back and is NOT diverged from origin main" bash -c '[ "$1" = "$2" ]' _ "$localShaM" "$postShaM"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "merge-ready.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "merge-ready.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
