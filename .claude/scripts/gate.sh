#!/usr/bin/env bash
# gate.sh <gate-name>
# Runs the command stored at .gates.<gate-name> in .claude/gates.json.
# Empty/missing command => skip with exit 0 (so pre-setup repos don't block).
# Non-zero command exit => propagates (so Stop hooks force the agent to keep working).
set -uo pipefail

key="${1:?usage: gate.sh <gate-name>}"
# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer
# project (repo-tracked <root>/.claude/scripts layout wins — robust in worktrees —
# else CLAUDE_PROJECT_DIR/git-toplevel/cwd for the plugin-cache layout).
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"

# Dependency-freshness preflight (pnpm-gated: no-ops unless the repo uses pnpm).
# pnpm copies the resolved lockfile to node_modules/.pnpm/lock.yaml on every
# install, so a byte-diff against the working pnpm-lock.yaml is a fast, offline
# staleness check. When they differ, node_modules is behind the lockfile (e.g. a
# merged PR added a dependency) and TS builds fail with opaque "Cannot find
# module" errors printed to STDOUT — leaving Stop hooks to report an unhelpful
# "No stderr output". Surface the real cause on STDERR and abort early so the fix
# ('pnpm install') is obvious. Projects without a root pnpm-lock.yaml skip this.
if [ -f "$root/pnpm-lock.yaml" ]; then
  installed_lock="$root/node_modules/.pnpm/lock.yaml"
  if [ ! -e "$installed_lock" ] || ! cmp -s "$root/pnpm-lock.yaml" "$installed_lock"; then
    echo "gate.sh: node_modules is out of sync with pnpm-lock.yaml — run 'pnpm install' (gate '$key' aborted)." >&2
    exit 1
  fi
fi

# Which adapter to read. Defaults to the project adapter; set GATES_FILE to run a
# different one (e.g. GATES_FILE=.claude/self/gates.json for the self-host loop —
# see .claude/self/README.md). Relative paths resolve from the repo root.
gates_ref="${GATES_FILE:-.claude/gates.json}"
case "$gates_ref" in
  /*) gates="$gates_ref" ;;
  *)  gates="$root/$gates_ref" ;;
esac

if [ ! -f "$gates" ]; then
  echo "gate.sh: no $gates found — skipping '$key'"; exit 0
fi

cmd="$(node -e "try{const g=require('$gates');process.stdout.write((g.gates&&g.gates['$key'])||'')}catch(e){process.stdout.write('')}" 2>/dev/null)"

if [ -z "$cmd" ]; then
  echo "gate.sh: gate '$key' not configured in gates.json — skipping"; exit 0
fi

echo "▶ gate '$key': $cmd"

# Token hygiene: gate output lands in an agent's context every time a hook fires, so a
# passing gate's full log is pure waste. Buffer the run and print a short tail on pass,
# the last GATE_TAIL_FAIL lines on fail. GATE_VERBOSE=1 streams everything (CI does too —
# its logs live server-side, not in a context window).
if [ -n "${GATE_VERBOSE:-}" ] || [ -n "${CI:-}" ]; then
  cd "$root" && eval "$cmd"
  exit $?
fi

out="$(mktemp "${TMPDIR:-/tmp}/gate.$key.XXXXXX")"
trap 'rm -f "$out"' EXIT
( cd "$root" && eval "$cmd" ) >"$out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  tail -n "${GATE_TAIL_PASS:-5}" "$out"
  echo "✓ gate '$key' passed"
else
  tail -n "${GATE_TAIL_FAIL:-100}" "$out"
  echo "✗ gate '$key' FAILED (exit $rc) — last ${GATE_TAIL_FAIL:-100} lines shown; re-run with GATE_VERBOSE=1 for full output"
fi
exit "$rc"
