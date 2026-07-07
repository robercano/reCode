#!/usr/bin/env bash
# smoke-fanout.sh — self-host Phase 2 (issue #64; spun off #11).
#
# Deterministic end-to-end smoke of the fan-out SCAFFOLD, run against the
# checked-in fixture target (examples/fixture-target) — never against the
# harness itself, so there is no bootstrap regress. No agents, no tokens, no
# network: a "recorded implementer" plays the worker role with a canned diff,
# which is what makes this CI-safe and deterministic (option (a) from the #11
# plan; live runs stay on-demand).
#
# What it proves, in order:
#   1. a consumer-shaped repo (fixture gates.json as .claude/gates.json + the
#      REAL gate.sh) can be staged and committed from scratch;
#   2. an isolated worktree + branch hosts the implementer's canned diff;
#   3. the diff respects the module boundary declared in the adapter;
#   4. the fixture's build/lint/test gates pass through the real gate.sh in the
#      worktree (and an unconfigured gate exits 0 — the skip path);
#   5. the branch fast-forwards into main and the change is present;
#   6. FAILURE PATH: a broken canned diff makes the build gate exit non-zero
#      (gate.sh propagates failure — what the loop's Stop hooks rely on).
#
# Sandbox-safe: everything happens under $TMPDIR (verified: git init/worktree/
# commit/merge all work there under the strict sandbox).
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$root/examples/fixture-target"
patches="$root/.claude/self/smoke"

fail() { echo "smoke: FAIL — $*" >&2; exit 1; }
step() { echo "smoke: $*"; }

command -v git  >/dev/null || fail "git not found"
command -v node >/dev/null || fail "node not found"
[ -d "$fixture" ] || fail "fixture missing: $fixture"

base="$(mktemp -d "${TMPDIR:-/tmp}/smoke-fanout.XXXXXX")" || fail "mktemp failed"
trap 'rm -rf "$base"' EXIT
repo="$base/target"

# Identity/signing via -c flags only: the temp repo must not depend on (or
# touch) any host git config — and under the sandbox it couldn't anyway.
G() { git -C "$repo" -c user.name=smoke -c user.email=smoke@local -c commit.gpgsign=false "$@"; }

# --- 1. Stage the fixture as a consumer-shaped repo --------------------------
mkdir -p "$repo/.claude/scripts"
cp -R "$fixture/src" "$fixture/test" "$repo/" || fail "copy fixture sources"
cp "$fixture/gates.json" "$repo/.claude/gates.json" || fail "copy adapter"
cp "$root/.claude/scripts/gate.sh" "$repo/.claude/scripts/gate.sh" || fail "copy gate.sh"
# gate.sh sources its sibling resolve-roots.sh (issue #63) — stage it alongside.
cp "$root/.claude/scripts/resolve-roots.sh" "$repo/.claude/scripts/resolve-roots.sh" || fail "copy resolve-roots.sh"
G init -q -b main . || fail "git init"
G add -- .claude src test
G commit -qm "fixture: initial state" || fail "initial commit"
step "staged consumer-shaped fixture repo"

# --- 2. 'Recorded implementer': isolated worktree + canned diff --------------
wt="$base/wt-task"
G worktree add -q "$wt" -b feat/smoke-task || fail "worktree add"
git -C "$wt" apply "$patches/implementer.patch" || fail "apply implementer.patch"
step "worktree feat/smoke-task created; canned diff applied"

# --- 3. Module-boundary check (the orchestrator's hard rule) -----------------
mod="$(node -e "process.stdout.write(require('$repo/.claude/gates.json').modules[0].path)")" \
  || fail "read module path from adapter"
changed="$(git -C "$wt" apply --numstat "$patches/implementer.patch" | cut -f3)"
[ -n "$changed" ] || fail "could not list changed paths"
while IFS= read -r p; do
  case "$p" in
    "$mod"/*|"$mod") ;;
    *) fail "canned diff escapes module '$mod': $p" ;;
  esac
done <<< "$changed"
# shellcheck disable=SC2086 -- $changed is newline-split file list, added by name
git -C "$wt" add -- $changed
git -C "$wt" -c user.name=smoke -c user.email=smoke@local -c commit.gpgsign=false \
  commit -qm "feat: canned implementer change" || fail "worktree commit"
step "module boundary respected ($mod); change committed on branch"

# --- 4. Gates through the REAL gate.sh, inside the worktree ------------------
# env -u GATES_FILE: when this smoke itself runs under the self adapter (CI sets
# GATES_FILE=.claude/self/gates.json), the inner gate.sh would inherit it, fail
# to find that path inside the FIXTURE repo, and skip every gate — passing
# vacuously even on broken code. The fixture is a consumer repo: it must read
# its own default .claude/gates.json. (Caught by the failure-path check below.)
in_gate() { env -u GATES_FILE bash "$1/.claude/scripts/gate.sh" "$2"; }
step "toolchain: node $(node -v), $(git --version)"
for g in build lint test; do
  # Capture output and surface it on failure — a silent gate failure on CI is
  # undebuggable from the job log (learned the hard way on PR #65).
  if ! out="$(in_gate "$wt" "$g" 2>&1)"; then
    printf '%s\n' "$out" | tail -40 >&2
    fail "gate '$g' failed in worktree (output above)"
  fi
done
step "gates build/lint/test passed in worktree"
if ! out="$(in_gate "$wt" typecheck 2>&1)"; then
  printf '%s\n' "$out" | tail -40 >&2
  fail "unconfigured gate did not skip cleanly (output above)"
fi
step "unconfigured gate skipped with exit 0"

# --- 5. Merge and verify ------------------------------------------------------
G merge -q --ff-only feat/smoke-task || fail "fast-forward merge"
[ -f "$repo/src/farewell.js" ] || fail "merged change missing on main"
G worktree remove "$wt" || fail "worktree remove"
step "branch merged; change present on main; worktree cleaned"

# --- 6. Failure path: broken diff must fail the gate --------------------------
wt2="$base/wt-broken"
G worktree add -q "$wt2" -b feat/smoke-broken || fail "worktree add (broken)"
git -C "$wt2" apply "$patches/broken.patch" || fail "apply broken.patch"
if in_gate "$wt2" build >/dev/null 2>&1; then
  fail "broken diff did NOT fail the build gate — failure propagation is broken"
fi
step "failure path verified: broken diff fails the build gate non-zero"
G worktree remove --force "$wt2" || fail "worktree remove (broken)"

echo "smoke: PASS — fan-out scaffold validated end-to-end on the fixture"
