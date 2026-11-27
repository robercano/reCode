#!/usr/bin/env bash
# gate.sh [--hook] <gate-name>
# Runs the command stored at .gates.<gate-name> in .claude/gates.json.
# Empty/missing command => skip with exit 0 (so pre-setup repos don't block).
# Non-zero command exit => propagates as-is when run by hand / by an agent.
#
# --hook (hook mode): use this from Claude Code hooks (Stop / SubagentStop /
# PostToolUse). Two differences from a bare run:
#   1. ROOT FOLLOWS THE EVENT'S cwd. Hook commands are spelled with
#      $CLAUDE_PROJECT_DIR / $CLAUDE_PLUGIN_ROOT, which never follow a worker
#      into its worktree, so the plain root derivation below always lands on
#      the MAIN checkout — i.e. the gate tested the owner's tree, not the
#      worker's change. In hook mode we read the hook's JSON from stdin and, if
#      its `cwd` sits inside a linked worktree of the SAME repository, gate that
#      worktree instead. Anything else (no stdin, unparsable JSON, cwd outside
#      any repo, a different repo) falls back to the plain root — never worse
#      than before.
#   2. A FAILING GATE EXITS 2 with its tail on stderr. Claude Code only treats
#      exit 2 as "block" (Stop/SubagentStop: keep working; PostToolUse: feed the
#      error back to Claude); any other non-zero code is a non-blocking hook
#      error, so the old `exit $rc` (usually 1) never actually held an agent
#      back. Claude Code itself caps consecutive Stop blocks, so this can't loop
#      forever.
set -uo pipefail

hook_mode=0
if [ "${1:-}" = "--hook" ]; then
  hook_mode=1
  shift
fi
key="${1:?usage: gate.sh [--hook] <gate-name>}"
# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer
# project (repo-tracked <root>/.claude/scripts layout wins — robust in worktrees —
# else CLAUDE_PROJECT_DIR/git-toplevel/cwd for the plugin-cache layout).
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"

if [ "$hook_mode" -eq 1 ]; then
  hook_input=""
  if [ ! -t 0 ]; then
    hook_input="$(cat 2>/dev/null || true)"
  fi
  hook_cwd=""
  if [ -n "$hook_input" ]; then
    hook_cwd="$(printf '%s' "$hook_input" | node -e '
      let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
        try { const j = JSON.parse(s); if (typeof j.cwd === "string") process.stdout.write(j.cwd) } catch (e) {}
      })' 2>/dev/null || true)"
  fi
  if [ -n "$hook_cwd" ] && [ -d "$hook_cwd" ]; then
    event_top="$(git -C "$hook_cwd" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$event_top" ] && [ "$event_top" != "$root" ]; then
      # Same repository? Compare the shared git dir of both checkouts.
      event_common="$(cd "$hook_cwd" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
      root_common="$(cd "$root" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
      if [ -n "$event_common" ] && [ "$event_common" = "$root_common" ]; then
        root="$event_top"
      fi
    fi
  fi
fi

# Which adapter to read. Defaults to the project adapter; set GATES_FILE to run a
# different one (e.g. GATES_FILE=self/gates.json for the self-host loop —
# see self/README.md). Relative paths resolve from the repo root.
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

# Dependency-freshness preflight (pnpm-gated: no-ops unless the repo uses pnpm).
# pnpm copies the resolved lockfile to node_modules/.pnpm/lock.yaml on every
# install, so a byte-diff against the working pnpm-lock.yaml is a fast, offline
# staleness check. When they differ, node_modules is behind the lockfile (e.g. a
# merged PR added a dependency) and TS builds fail with opaque "Cannot find
# module" errors printed to STDOUT — leaving Stop hooks to report an unhelpful
# "No stderr output". Surface the real cause on STDERR and abort early so the fix
# ('pnpm install') is obvious. Projects without a root pnpm-lock.yaml skip this.
# Runs AFTER the empty-gate skip above (issue #129) — a deliberately blanked gate
# (the documented "not configured" marker) is a no-op and must stay one even when
# node_modules is momentarily stale; only a gate that's actually about to execute
# needs a fresh node_modules.
if [ -f "$root/pnpm-lock.yaml" ]; then
  installed_lock="$root/node_modules/.pnpm/lock.yaml"
  if [ ! -e "$installed_lock" ] || ! cmp -s "$root/pnpm-lock.yaml" "$installed_lock"; then
    echo "gate.sh: node_modules is out of sync with pnpm-lock.yaml — run 'pnpm install' (gate '$key' aborted)." >&2
    exit 1
  fi
fi

echo "▶ gate '$key': $cmd"

# Token hygiene: gate output lands in an agent's context every time a hook fires, so a
# passing gate's full log is pure waste. Buffer the run and print a short tail on pass,
# the last GATE_TAIL_FAIL lines on fail. GATE_VERBOSE=1 streams everything (CI does too —
# its logs live server-side, not in a context window).
if [ "$hook_mode" -eq 0 ] && { [ -n "${GATE_VERBOSE:-}" ] || [ -n "${CI:-}" ]; }; then
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
elif [ "$hook_mode" -eq 1 ]; then
  # Blocking hook contract: stderr is what Claude sees, exit 2 is what blocks.
  {
    tail -n "${GATE_TAIL_FAIL:-100}" "$out"
    echo "✗ gate '$key' FAILED (exit $rc) in $root — fix it before finishing; last ${GATE_TAIL_FAIL:-100} lines shown"
  } >&2
  exit 2
else
  tail -n "${GATE_TAIL_FAIL:-100}" "$out"
  echo "✗ gate '$key' FAILED (exit $rc) — last ${GATE_TAIL_FAIL:-100} lines shown; re-run with GATE_VERBOSE=1 for full output"
fi
exit "$rc"
