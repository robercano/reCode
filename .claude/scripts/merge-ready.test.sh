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

echo ""
if [ "$fail" -eq 0 ]; then
  echo "merge-ready.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "merge-ready.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
