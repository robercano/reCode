#!/usr/bin/env bash
# resolve-roots.sh — the ONE implementation of the two-root derivation
# (issue #63). SOURCE this from a sibling script; do not execute it.
#
# There are two distinct roots, and the plugin install cache broke scripts
# that conflated them with a single `../..` hop:
#
#   script_dir — where SIBLING scripts live (bot-gh.sh, gate.sh, …). This is
#     simply this file's own directory, correct in BOTH layouts:
#       repo/worktree checkout:  <root>/.claude/scripts/
#       plugin install cache:    ~/.claude/plugins/cache/<mp>/<plugin>/<ver>/scripts/
#     (the cache strips the .claude/ prefix, so `../..` lands outside the plugin).
#
#   root — the CONSUMER PROJECT root, where .env (GH_BOT_TOKEN), gates.json,
#     .claude/state/, worktrees, and the git repo live. Resolution order:
#       1. repo-tracked layout (<x>/.claude/scripts) → <x>. This must win over
#          CLAUDE_PROJECT_DIR: worktree implementers run the WORKTREE's copy of
#          gate.sh and need the worktree as root, while the harness env var
#          points at the main checkout.
#       2. $CLAUDE_PROJECT_DIR — set by the harness; the only reliable signal
#          when running from the plugin cache.
#       3. git toplevel of the cwd, then cwd — callers invoke these scripts
#          from the consumer repo, so this is the right last resort.
#
# Never exits/fails (log-event.sh sources this and must never block a worker):
# every step has a fallback.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
case "$script_dir" in
  */.claude/scripts) root="${script_dir%/.claude/scripts}" ;;
  *) root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" ;;
esac
