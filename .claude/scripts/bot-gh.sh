#!/usr/bin/env bash
# Run gh as a bot machine account, so agent-created PRs are authored by the bot
# and the human repo owner can formally review/approve them — GitHub hard-blocks
# PR authors from approving their own PRs, so PRs created with the owner's gh
# auth are un-approvable by the owner.
#
# Setup (one-time, ~10 min):
#   1. Create a free GitHub machine account (GitHub ToS allows ONE free machine
#      account alongside your personal account). Name it generically, e.g.
#      <you>-assistant-bot, and reuse it across all your repos.
#   2. Add it as a collaborator (write) on each repo it should open PRs in.
#   3. As the bot: Settings → Developer settings → Tokens (classic) → generate
#      with `repo` scope. (Classic, not fine-grained: fine-grained PATs cannot
#      reliably target repos owned by ANOTHER personal account.)
#   4. Put it in the project's .env (gitignored) as GH_BOT_TOKEN=...
#
# Only PR creation needs the bot; commits and pushes stay on the owner's auth.
#
# Usage: .claude/scripts/bot-gh.sh pr create --title "..." --body "..."
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ -f "$root/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$root/.env"
  set +a
fi
: "${GH_BOT_TOKEN:?GH_BOT_TOKEN not set — add it to .env (see setup notes in this script)}"

GH_TOKEN="$GH_BOT_TOKEN" exec gh "$@"
