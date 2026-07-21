#!/usr/bin/env bash
# pr-comment-fix.test.sh — offline smoke test for pr-comment-fix.sh (issue #96
# capability #2: review-comment-thread convergence detection).
#
# Builds a throwaway .claude/scripts/ fixture containing the REAL
# pr-comment-fix.sh + resolve-roots.sh + needs-human.sh + notify.sh next to a
# FAKE bot-gh.sh (which stands in for `gh` entirely, mirroring
# pr-ci-fix.test.sh's own fake-gh convention) and a FAKE pr-feedback.sh (so
# the precedence exclusion can be exercised without any real
# feedback-detection logic). No network, no real `gh` CLI required.
#
# Issue #169: needs-human.sh's label reads/writes now go through `gh api`
# (REST) instead of `gh pr edit --*-label`/`gh pr view --json labels`. The
# fake bot-gh.sh below simulates GitHub's own label state via a marker FILE
# the REST add touches, so the post-add CONFIRM read (issue #169's
# comment-gating invariant) sees the label actually "stuck".
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/pr-comment-fix.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$script_dir/pr-comment-fix.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/pr-comment-fix-test.XXXXXX")"
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

fixture="$work/fixture1"
scripts_dir="$fixture/.claude/scripts"
mkdir -p "$scripts_dir" "$fixture/.claude/state"
cp "$src" "$scripts_dir/pr-comment-fix.sh"
cp "$resolve_roots_src" "$scripts_dir/resolve-roots.sh"
cp "$script_dir/needs-human.sh" "$scripts_dir/needs-human.sh"
cp "$script_dir/notify.sh" "$scripts_dir/notify.sh"
cp "$script_dir/log-event.sh" "$scripts_dir/log-event.sh"

cat > "$fixture/.claude/gates.json" <<'EOF'
{
  "modules": [{ "name": "test", "path": ".", "description": "", "owner": "" }],
  "merge": { "baseBranch": "main" },
  "commentFix": { "botAllowlist": ["allowed-bot"] }
}
EOF

# --- fixture PR set ----------------------------------------------------------
#   10: one unresolved thread, owner comment, no marker yet     -> EMITTED attempt=1
#   11: one unresolved thread, RANDOM (non-owner/non-allowlisted) commenter
#                                                                 -> NOT emitted (doesn't qualify)
#   12: unresolved thread, owner comment, labeled needs-human    -> NOT emitted (guard)
#   13: unresolved thread, owner comment, labeled claude-comment-fixing
#                                                                 -> NOT emitted (in-flight guard)
#   14: unresolved thread, owner comment, ALSO a pr-feedback.sh candidate
#                                                                 -> NOT emitted (precedence)
#   15: unresolved thread, owner comment, marker already posted AFTER the
#       thread's last comment (already addressed, no new activity)
#                                                                 -> NOT emitted (already-addressed cursor)
#   16: unresolved thread, owner comment, marker attempt=1 posted BEFORE a
#       newer comment (thread reopened after 1 fix)               -> EMITTED attempt=2
#   17: unresolved thread, owner comment, marker attempt=2 posted BEFORE a
#       newer comment (thread reopened after 2 fixes -- budget exhausted)
#                                                                 -> NOT emitted (escalated to needs-human)
#   18: RESOLVED thread, owner comment                            -> NOT emitted (resolved)
#   19: unresolved thread, ALLOWLISTED bot commenter               -> EMITTED attempt=1
cat > "$scripts_dir/bot-gh.sh" <<'BOTGH'
#!/usr/bin/env bash
# Log every invocation (mirrors pr-feedback.test.sh's gh-call-log convention)
# so escalation side effects (needs_human_flag's REST label add, issue #169)
# can be asserted on directly, not just inferred from "the PR wasn't emitted"
# (which can't distinguish correct escalation from a silent drop). The
# needs-human label marker FILE below simulates GitHub's own label state (the
# REST add touches it; the REST read reports it) so needs_human_flag's
# post-add CONFIRM read sees the label actually "stuck" for PR 17's
# escalation.
log_dir="$(cd "$(dirname "$0")" && pwd)"
label_marker17="$log_dir/labeled-17.marker"
printf '%s\n' "$*" >> "$log_dir/gh-calls.log"
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    case "$2" in
      comment) exit 0 ;;  # needs_human_flag's `gh pr comment`
    esac
    if printf '%s\n' "$*" | grep -q 'headRefOid'; then
      cat <<'JSON'
{"number":10,"headRefName":"feat/issue-10-a","author":{"login":"testbot"},"labels":[],"headRefOid":"sha10"}
{"number":11,"headRefName":"feat/issue-11-a","author":{"login":"testbot"},"labels":[],"headRefOid":"sha11"}
{"number":12,"headRefName":"feat/issue-12-a","author":{"login":"testbot"},"labels":[{"name":"needs-human"}],"headRefOid":"sha12"}
{"number":13,"headRefName":"feat/issue-13-a","author":{"login":"testbot"},"labels":[{"name":"claude-comment-fixing"}],"headRefOid":"sha13"}
{"number":14,"headRefName":"feat/issue-14-a","author":{"login":"testbot"},"labels":[],"headRefOid":"sha14"}
{"number":15,"headRefName":"feat/issue-15-a","author":{"login":"testbot"},"labels":[],"headRefOid":"sha15"}
{"number":16,"headRefName":"feat/issue-16-a","author":{"login":"testbot"},"labels":[],"headRefOid":"sha16"}
{"number":17,"headRefName":"feat/issue-17-a","author":{"login":"testbot"},"labels":[],"headRefOid":"sha17"}
{"number":18,"headRefName":"feat/issue-18-a","author":{"login":"testbot"},"labels":[],"headRefOid":"sha18"}
{"number":19,"headRefName":"feat/issue-19-a","author":{"login":"testbot"},"labels":[],"headRefOid":"sha19"}
JSON
    else
      echo "fake-bot-gh.sh: unexpected pr subcommand: $*" >&2
      exit 1
    fi
    ;;
  api)
    # gh receives `-F number=<N>` as separate argv entries -- "$*" joins them
    # with spaces, so " number=<N> " (padded) is an exact, unambiguous match.
    case " $* " in
      *" number=10 "*)
        echo '[{"id":"T10","isResolved":false,"comments":{"nodes":[{"author":{"login":"acme"},"createdAt":"2026-01-01T00:00:00Z"}]}}]'
        ;;
      *" number=11 "*)
        echo '[{"id":"T11","isResolved":false,"comments":{"nodes":[{"author":{"login":"random-user"},"createdAt":"2026-01-01T00:00:00Z"}]}}]'
        ;;
      *" number=12 "*)
        echo '[{"id":"T12","isResolved":false,"comments":{"nodes":[{"author":{"login":"acme"},"createdAt":"2026-01-01T00:00:00Z"}]}}]'
        ;;
      *" number=13 "*)
        echo '[{"id":"T13","isResolved":false,"comments":{"nodes":[{"author":{"login":"acme"},"createdAt":"2026-01-01T00:00:00Z"}]}}]'
        ;;
      *" number=14 "*)
        echo '[{"id":"T14","isResolved":false,"comments":{"nodes":[{"author":{"login":"acme"},"createdAt":"2026-01-01T00:00:00Z"}]}}]'
        ;;
      *" number=15 "*)
        echo '[{"id":"T15","isResolved":false,"comments":{"nodes":[{"author":{"login":"acme"},"createdAt":"2026-01-01T00:00:00Z"}]}}]'
        ;;
      *" number=16 "*)
        echo '[{"id":"T16","isResolved":false,"comments":{"nodes":[{"author":{"login":"acme"},"createdAt":"2026-01-01T00:00:00Z"},{"author":{"login":"acme"},"createdAt":"2026-03-01T00:00:00Z"}]}}]'
        ;;
      *" number=17 "*)
        echo '[{"id":"T17","isResolved":false,"comments":{"nodes":[{"author":{"login":"acme"},"createdAt":"2026-01-01T00:00:00Z"},{"author":{"login":"acme"},"createdAt":"2026-03-01T00:00:00Z"}]}}]'
        ;;
      *" number=18 "*)
        echo '[{"id":"T18","isResolved":true,"comments":{"nodes":[{"author":{"login":"acme"},"createdAt":"2026-01-01T00:00:00Z"}]}}]'
        ;;
      *" number=19 "*)
        echo '[{"id":"T19","isResolved":false,"comments":{"nodes":[{"author":{"login":"allowed-bot"},"createdAt":"2026-01-01T00:00:00Z"}]}}]'
        ;;
      *"graphql"*)
        echo '[]'
        ;;
      *"-X POST"*"/issues/17/labels --input -")
        touch "$label_marker17"
        ;;
      *"-X POST"*"repos/acme/repo/labels "*)
        : # ensure-label repo-level create (idempotent, needs_human_flag)
        ;;
      *"-q .labels[].name"*)
        [ -f "$label_marker17" ] && echo "needs-human"
        ;;
      *"issues/15/comments"*)
        echo '[{"user":{"login":"testbot"},"body":"<!-- claude-comment-addressed:T15:1 -->","created_at":"2026-02-01T00:00:00Z"}]'
        ;;
      *"issues/16/comments"*)
        echo '[{"user":{"login":"testbot"},"body":"<!-- claude-comment-addressed:T16:1 -->","created_at":"2026-02-01T00:00:00Z"}]'
        ;;
      *"issues/17/comments"*)
        echo '[{"user":{"login":"testbot"},"body":"<!-- claude-comment-addressed:T17:2 -->","created_at":"2026-02-01T00:00:00Z"}]'
        ;;
      *"issues/"*"/comments"*)
        echo '[]'
        ;;
      *)
        echo "fake-bot-gh.sh: unhandled api call: $*" >&2
        exit 1
        ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
BOTGH
chmod +x "$scripts_dir/bot-gh.sh"

# 14 is a feedback candidate (precedence: feedback outranks comment-fix).
cat > "$scripts_dir/pr-feedback.sh" <<'EOF'
#!/usr/bin/env bash
printf '14\tfeat/issue-14-a\towner\t2026-01-01T00:00:00Z\n'
EOF
chmod +x "$scripts_dir/pr-feedback.sh"

# Unset GATES_FILE explicitly: this test may itself run from inside a gate
# invocation that exports GATES_FILE=.claude/self/gates.json for the OUTER
# repo (mirrors loop-census.test.sh's own guard) — which would leak in here
# and make pr-comment-fix.sh read the outer self-adapter's commentFix.botAllowlist
# instead of this fixture's own gates.json.
out="$(env -u GATES_FILE BOT_LOGIN=testbot OWNER_LOGIN=acme bash "$scripts_dir/pr-comment-fix.sh" "acme/repo")"

check "PR 10 (unresolved, owner comment, no marker): emitted attempt=1" bash -c '
  printf "%s\n" "$1" | grep -qF "$(printf "10\tfeat/issue-10-a\tT10:1\tsha10")"' _ "$out"
check "PR 11 (unresolved, non-qualifying commenter): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^11\b"' _ "$out"
check "PR 12 (needs-human guard): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^12\b"' _ "$out"
check "PR 13 (claude-comment-fixing in-flight guard): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^13\b"' _ "$out"
check "PR 14 (also a feedback candidate -- precedence): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^14\b"' _ "$out"
check "PR 15 (already-addressed marker, no new activity): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^15\b"' _ "$out"
check "PR 16 (thread reopened after 1 fix): emitted attempt=2" bash -c '
  printf "%s\n" "$1" | grep -qF "$(printf "16\tfeat/issue-16-a\tT16:2\tsha16")"' _ "$out"
check "PR 17 (thread reopened after 2 fixes -- budget exhausted): NOT emitted (escalated)" bash -c '! printf "%s\n" "$1" | grep -qE "^17\b"' _ "$out"
check "PR 18 (resolved thread): NOT emitted" bash -c '! printf "%s\n" "$1" | grep -qE "^18\b"' _ "$out"
check "PR 19 (allowlisted bot commenter): emitted attempt=1" bash -c '
  printf "%s\n" "$1" | grep -qF "$(printf "19\tfeat/issue-19-a\tT19:1\tsha19")"' _ "$out"
check "exactly 3 PRs emitted total (10, 16, 19)" bash -c '[ "$(printf "%s\n" "$1" | grep -c .)" -eq 3 ]' _ "$out"

# --- anti-livelock escalation: positive assertion on the ACTUAL gh side
# effect, not just "PR 17 wasn't emitted" (which can't tell correct
# escalation apart from a silent bug that just drops the thread).
gh_log1="$scripts_dir/gh-calls.log"
check "PR 17 (budget exhausted): needs-human label ACTUALLY applied via REST (issue #169)" \
  grep -qF -- "-X POST repos/acme/repo/issues/17/labels --input -" "$gh_log1"
check "PR 16 (attempt 2, budget not yet exhausted): needs-human label NOT applied" \
  bash -c '! grep -qF -- "-X POST repos/acme/repo/issues/16/labels --input -" "$1"' _ "$gh_log1"

# --- fixture2: the SHIPPED DEFAULT (commentFix.botAllowlist: []) must
# actually be exercised -- fixture1 above hardcodes a non-empty allowlist for
# every scenario, so an empty allowlist (bots disabled by default; only the
# owner qualifies) is never exercised without this fixture.
#   30: unresolved thread, only a BOT (non-owner, non-allowlisted) commenter
#                                                                 -> NOT emitted (empty allowlist = no bots qualify)
#   31: unresolved thread, owner comment, same run                -> EMITTED attempt=1 (owner always qualifies)
fixture2="$work/fixture2"
scripts_dir2="$fixture2/.claude/scripts"
mkdir -p "$scripts_dir2" "$fixture2/.claude/state"
cp "$src" "$scripts_dir2/pr-comment-fix.sh"
cp "$resolve_roots_src" "$scripts_dir2/resolve-roots.sh"
cp "$script_dir/needs-human.sh" "$scripts_dir2/needs-human.sh"
cp "$script_dir/notify.sh" "$scripts_dir2/notify.sh"
cp "$script_dir/log-event.sh" "$scripts_dir2/log-event.sh"

cat > "$fixture2/.claude/gates.json" <<'EOF'
{
  "modules": [{ "name": "test", "path": ".", "description": "", "owner": "" }],
  "merge": { "baseBranch": "main" },
  "commentFix": { "botAllowlist": [] }
}
EOF

cat > "$scripts_dir2/bot-gh.sh" <<'BOTGH'
#!/usr/bin/env bash
# Neither PR here reaches the anti-livelock escalation (needs_human_flag),
# so no label/comment REST calls are ever expected in this fixture.
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    case "$2" in
      comment) exit 0 ;;
    esac
    if printf '%s\n' "$*" | grep -q 'headRefOid'; then
      cat <<'JSON'
{"number":30,"headRefName":"feat/issue-30-a","author":{"login":"testbot"},"labels":[],"headRefOid":"sha30"}
{"number":31,"headRefName":"feat/issue-31-a","author":{"login":"testbot"},"labels":[],"headRefOid":"sha31"}
JSON
    else
      echo "fake-bot-gh.sh: unexpected pr subcommand: $*" >&2
      exit 1
    fi
    ;;
  api)
    case " $* " in
      *" number=30 "*)
        echo '[{"id":"T30","isResolved":false,"comments":{"nodes":[{"author":{"login":"some-bot"},"createdAt":"2026-01-01T00:00:00Z"}]}}]'
        ;;
      *" number=31 "*)
        echo '[{"id":"T31","isResolved":false,"comments":{"nodes":[{"author":{"login":"acme"},"createdAt":"2026-01-01T00:00:00Z"}]}}]'
        ;;
      *"graphql"*)
        echo '[]'
        ;;
      *"issues/"*"/comments"*)
        echo '[]'
        ;;
      *)
        echo "fake-bot-gh.sh: unhandled api call: $*" >&2
        exit 1
        ;;
    esac
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
BOTGH
chmod +x "$scripts_dir2/bot-gh.sh"

# No feedback candidates in this fixture -- empty stub.
cat > "$scripts_dir2/pr-feedback.sh" <<'EOF'
#!/usr/bin/env bash
EOF
chmod +x "$scripts_dir2/pr-feedback.sh"

out2="$(env -u GATES_FILE BOT_LOGIN=testbot OWNER_LOGIN=acme bash "$scripts_dir2/pr-comment-fix.sh" "acme/repo")"

check "fixture2/PR 30 (empty allowlist, only a bot commenter): NOT emitted (default-disabled)" \
  bash -c '! printf "%s\n" "$1" | grep -qE "^30\b"' _ "$out2"
check "fixture2/PR 31 (empty allowlist, owner commenter, same run): emitted attempt=1 (owner always qualifies)" bash -c '
  printf "%s\n" "$1" | grep -qF "$(printf "31\tfeat/issue-31-a\tT31:1\tsha31")"' _ "$out2"
check "fixture2: exactly 1 PR emitted total (31 only)" bash -c '[ "$(printf "%s\n" "$1" | grep -c .)" -eq 1 ]' _ "$out2"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "pr-comment-fix.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "pr-comment-fix.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
