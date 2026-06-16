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

# Preflight: the bot needs collaborator access to EACH (private) repo it acts on
# (setup step 2). Without it, gh fails with an opaque
# "Could not resolve to a Repository with the name '<owner>/<repo>'" that reads like
# a typo, not a missing grant. If a --repo target is given and the bot can't see it,
# print the exact one-time grant + invite-accept commands instead.
target_repo=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--repo" ]; then target_repo="$a"; break; fi
  case "$a" in
    --repo) prev="--repo"; continue;;
    --repo=*) target_repo="${a#--repo=}"; break;;
  esac
done
if [ -n "$target_repo" ] && ! GH_TOKEN="$GH_BOT_TOKEN" gh repo view "$target_repo" >/dev/null 2>&1; then
  bot="$(GH_TOKEN="$GH_BOT_TOKEN" gh api user --jq .login 2>/dev/null || echo '<bot>')"
  cat >&2 <<EOF
bot-gh.sh: bot account '$bot' cannot access '$target_repo' (private repo + not a collaborator?).
One-time setup — run as the repo OWNER, then accept the invite as the bot:
  gh api -X PUT repos/$target_repo/collaborators/$bot -f permission=push
  id=\$("$0" api user/repository_invitations --jq ".[] | select(.repository.full_name==\"$target_repo\") | .id")
  "$0" api -X PATCH user/repository_invitations/\$id
EOF
  exit 1
fi

GH_TOKEN="$GH_BOT_TOKEN" exec gh "$@"
