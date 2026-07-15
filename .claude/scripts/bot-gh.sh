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

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"
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
#
# Assignment is a SEPARATE follow-up call after `pr create` succeeds, not an
# inline `--assignee` flag on the create itself. Some bot tokens (classic PATs
# scoped to `repo` only, no `read:org`) can create PRs fine but have the
# assignee-resolution step rejected — if that were inline, the whole
# `pr create` would fail and no PR would exist at all. As a follow-up, a
# scope-rejected assignment just leaves the PR unassigned (soft failure,
# warned on stderr) instead of losing the PR.
has_assignee=1
owner=""
repo_full=""
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
    origin_url="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
    if [ -z "$owner" ]; then
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
    # repo_full (owner/name) is needed for the follow-up assignees API call
    # below; reuse target_repo/origin-parsing where possible, gh repo view as
    # a last resort.
    repo_full="$target_repo"
    if [ -z "$repo_full" ]; then
      case "$origin_url" in
        git@github.com:*) repo_full="${origin_url#git@github.com:}"; repo_full="${repo_full%.git}";;
        https://github.com/*) repo_full="${origin_url#https://github.com/}"; repo_full="${repo_full%.git}";;
      esac
    fi
    if [ -z "$repo_full" ]; then
      repo_full="$(GH_TOKEN="$GH_BOT_TOKEN" gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    fi
  fi
fi

if [ "$has_assignee" -eq 0 ] && [ -n "$owner" ]; then
  # Create WITHOUT an inline --assignee (stdout captured only for the PR URL;
  # stderr still streams live), then assign as a soft-fail follow-up.
  if pr_url="$(GH_TOKEN="$GH_BOT_TOKEN" gh "${args[@]}")"; then
    status=0
  else
    status=$?
  fi
  printf '%s\n' "$pr_url"
  if [ "$status" -ne 0 ]; then exit "$status"; fi
  pr_number="${pr_url##*/}"
  if [ -n "$repo_full" ] && [ -n "$pr_number" ]; then
    # Send the payload as an explicit JSON --input body, NEVER as
    # `-f "assignees[]=..."`: gh only grew the bracket array syntax in later
    # 2.x releases — on older gh (e.g. Ubuntu 22.04's packaged 2.4.0) it
    # sends a literal "assignees[]" STRING field, which the API silently
    # ignores while still returning 200. Exit code 0, nobody assigned, no
    # warning — this exact silent no-op shipped for weeks. Same lesson for
    # verification: don't trust the exit code, check the response actually
    # names the owner (the closing quote in the grep keeps '<owner>-bot'
    # style logins from matching as a prefix).
    resp="$(printf '{"assignees":["%s"]}' "$owner" \
      | GH_TOKEN="$GH_BOT_TOKEN" gh api -X POST "repos/$repo_full/issues/$pr_number/assignees" --input - 2>/dev/null)" || resp=""
    if ! printf '%s' "$resp" | grep -q "\"login\":\"$owner\""; then
      echo "bot-gh.sh: warning — created $pr_url but could not assign it to '$owner' (bot token may lack read:org); PR left unassigned." >&2
    fi
    # Also request a formal review from the owner: assignment alone does not
    # put the PR in the owner's GitHub review queue or fire the
    # review-requested notification. The author is always the bot here (the
    # whole point of bot-gh.sh), so GitHub's no-self-review-request rule
    # cannot trip on the owner. Soft-fail like the assignment.
    resp="$(printf '{"reviewers":["%s"]}' "$owner" \
      | GH_TOKEN="$GH_BOT_TOKEN" gh api -X POST "repos/$repo_full/pulls/$pr_number/requested_reviewers" --input - 2>/dev/null)" || resp=""
    if ! printf '%s' "$resp" | grep -q "\"login\":\"$owner\""; then
      echo "bot-gh.sh: warning — created $pr_url but could not request a review from '$owner'; request it by hand so the owner is notified." >&2
    fi
  fi
  exit 0
fi

GH_TOKEN="$GH_BOT_TOKEN" exec gh ${args[@]+"${args[@]}"}
