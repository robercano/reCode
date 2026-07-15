#!/usr/bin/env bash
# worktree.sh <setup|teardown>
# Runs the command stored at .worktree.<phase> in the adapter (gates.json) — the
# per-worktree lifecycle hook. `setup` bootstraps a freshly-created isolated
# worktree (install deps, `forge install`, link shared caches) so that EVERY gate
# is runnable in-worktree, not just in the main checkout; `teardown` runs before
# the worktree is removed (free caches, etc.).
#
# Empty/missing command => skip with exit 0 (so unconfigured repos don't block).
# Non-zero command exit => propagates (so a failed bootstrap surfaces, not hides).
# Mirrors gate.sh: honors the GATES_FILE override and resolves the repo root from
# this script's location — which, inside a worktree, IS the worktree root, so the
# hook installs into the worktree the caller is working in.
set -uo pipefail

phase="${1:?usage: worktree.sh <setup|teardown>}"
case "$phase" in
  setup|teardown) ;;
  *) echo "worktree.sh: phase must be 'setup' or 'teardown' (got '$phase')"; exit 2 ;;
esac

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"

# On `setup`, link the main checkout's gitignored .env into the worktree (same
# pattern as prepare-pr.sh for test-pr worktrees): .env is never checked out,
# so gates and app code that read it fail in a fresh worktree for lack of
# credentials rather than real defects. Resolved from the CALLER's cwd, not
# $root — in the plugin-cache layout $root is the main checkout, while the
# implementer invoking this script stands inside its worktree. Best-effort and
# skip-if-present (a worktree-local .env wins); runs before the adapter checks
# below so unconfigured repos still get it.
if [ "$phase" = setup ]; then
  wt="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  main="$(cd "${wt:-.}" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd)"
  if [ -n "$wt" ] && [ -n "$main" ] && [ "$main" != "$wt" ] && [ -f "$main/.env" ] && [ ! -e "$wt/.env" ]; then
    ln -s "$main/.env" "$wt/.env" && echo "▶ linked $wt/.env → $main/.env"
  fi
fi
# Which adapter to read. Defaults to the project adapter; set GATES_FILE to run a
# different one (e.g. GATES_FILE=.claude/self/gates.json). Relative paths resolve
# from the repo root.
gates_ref="${GATES_FILE:-.claude/gates.json}"
case "$gates_ref" in
  /*) gates="$gates_ref" ;;
  *)  gates="$root/$gates_ref" ;;
esac

if [ ! -f "$gates" ]; then
  echo "worktree.sh: no $gates found — skipping '$phase'"; exit 0
fi

cmd="$(node -e "try{const g=require('$gates');process.stdout.write((g.worktree&&g.worktree['$phase'])||'')}catch(e){process.stdout.write('')}" 2>/dev/null)"

if [ -z "$cmd" ]; then
  echo "worktree.sh: '$phase' not configured in $(basename "$gates") — skipping"; exit 0
fi

echo "▶ worktree '$phase': $cmd"
cd "$root" && eval "$cmd"
