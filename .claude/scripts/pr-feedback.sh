#!/usr/bin/env bash
# pr-feedback.sh — print open, bot-authored PRs that have UNADDRESSED "changes
# requested" feedback, so the notification cron can dispatch an implementer per PR
# to address it. Prints one TSV line per PR needing action:
#   <number>\t<branch>\t<reviewer>\t<changes_requested_at>
#
# A PR is listed when its latest CHANGES_REQUESTED review is NEWER than the bot's
# last "<!-- claude-addressed -->" marker comment (so already-handled feedback is
# not re-dispatched even though GitHub keeps reviewDecision=CHANGES_REQUESTED until
# you re-review), AND it is not currently labeled `claude-addressing` (a guard so
# overlapping firings don't double-dispatch). The implementer posts the marker
# comment after pushing its fix, which advances the cursor past the request.
#
# Repo derived from the git remote; override with $1. Bot login via $BOT_LOGIN.
# Invoke as `bash .claude/scripts/pr-feedback.sh` (pre-approve that exact command).
set -euo pipefail

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"
# Route EVERY gh call through the bot identity (see bot-gh.sh).
gh() { bash "$script_dir/bot-gh.sh" "$@"; }
repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
bot="${BOT_LOGIN:-robercano-ghbot}"
marker="<!-- claude-addressed -->"

gh pr list -R "$repo" --state open \
  --json number,headRefName,author,labels \
  --jq '.[] | select(.author.login=="'"$bot"'") | [.number, .headRefName, ([.labels[].name]|join(","))] | @tsv' \
| while IFS=$'\t' read -r num branch labels; do
    case ",$labels," in *,claude-addressing,*) continue;; esac

    cr=$(gh api "repos/$repo/pulls/$num/reviews" \
          --jq '[.[]|select(.state=="CHANGES_REQUESTED")]|sort_by(.submitted_at)|last|select(.!=null)|"\(.submitted_at)\t\(.user.login)"' \
          2>/dev/null || true)
    if [ -z "$cr" ]; then continue; fi
    tcr="${cr%%$'\t'*}"
    reviewer="${cr#*$'\t'}"

    ta=$(gh api "repos/$repo/issues/$num/comments" \
          --jq '[.[]|select(.user.login=="'"$bot"'" and (.body|contains("'"$marker"'")))]|sort_by(.created_at)|last|.created_at // empty' \
          2>/dev/null || true)

    if [ -z "$ta" ] || [[ "$tcr" > "$ta" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$num" "$branch" "$reviewer" "$tcr"
    fi
  done
