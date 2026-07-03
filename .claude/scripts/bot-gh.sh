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
# Policy: ALL agent `gh` interaction (issue/PR creation, comments, merging, and
# even reads/queries) goes through this wrapper so it runs as the bot. Only `git`
# commits and pushes stay on the owner's auth — that keeps the owner eligible to
# formally approve bot-authored PRs (GitHub blocks a PR author from approving it).
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
# a typo, not a missing grant. If a --repo/-R target is given and the bot can't see
# it, print the exact one-time grant + invite-accept commands instead. This same
# $target_repo is also reused below to resolve the correct owner for cross-repo
# `pr create` calls.
target_repo=""
prev=""
for a in "$@"; do
  if [ -n "$prev" ]; then target_repo="$a"; break; fi
  case "$a" in
    --repo|-R) prev="1"; continue;;
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

args=("$@")

# Auto-assign new bot PRs to the repo owner, so the owner gets a notification
# that a PR is waiting for review (a bot-authored PR otherwise has no assignee).
# Only applies to `pr create`, and only if the caller didn't already pass
# --assignee (or its short form -a) themselves.
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  has_assignee=0
  for a in "$@"; do
    case "$a" in
      -a|--assignee|--assignee=*) has_assignee=1; break;;
    esac
  done
  if [ "$has_assignee" -eq 0 ]; then
    # Resolve the repo owner dynamically — never hardcode it. Precedence:
    # OWNER_LOGIN env override, then the --repo/-R target (so cross-repo
    # `pr create --repo other/acct` assigns the OTHER repo's owner, not the
    # local origin's), then the local `origin` remote (works offline, unlike
    # `gh repo view`), then `gh repo view` as a last resort.
    owner="${OWNER_LOGIN:-}"
    if [ -z "$owner" ] && [ -n "$target_repo" ]; then
      owner="${target_repo%%/*}"
    fi
    if [ -z "$owner" ]; then
      origin_url="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
      case "$origin_url" in
        git@github.com:*)
          owner="${origin_url#git@github.com:}"
          owner="${owner%%/*}"
          ;;
        https://github.com/*)
          owner="${origin_url#https://github.com/}"
          owner="${owner%%/*}"
          ;;
      esac
    fi
    if [ -z "$owner" ]; then
      owner="$(GH_TOKEN="$GH_BOT_TOKEN" gh repo view --json owner --jq .owner.login 2>/dev/null || true)"
    fi
    # Fail soft: if the owner can't be resolved, create the PR unassigned
    # rather than erroring out.
    if [ -n "$owner" ]; then
      args+=(--assignee "$owner")
    fi
  fi
fi

GH_TOKEN="$GH_BOT_TOKEN" exec gh ${args[@]+"${args[@]}"}
