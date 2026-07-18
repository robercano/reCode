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
case "$1" in
  repo) echo "acme/repo" ;;
  label) exit 0 ;;  # needs_human_flag's `gh label create needs-human ...`
  pr)
    case "$2" in
      edit|comment) exit 0 ;;  # needs_human_flag's `gh pr edit`/`gh pr comment`
      view) echo ""; exit 0 ;;  # _needs_human_already_labeled's `gh pr view --json labels`
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

echo ""
if [ "$fail" -eq 0 ]; then
  echo "pr-comment-fix.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "pr-comment-fix.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
