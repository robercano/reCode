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

# needs_human_flag/needs_human_clear (issue #99): the ONE shared label+notify
# seam for "CHANGES_REQUESTED round-trip done, owner re-review needed" (see
# the per-PR loop below). Sourced AFTER the `gh` wrapper above; guarded (not
# a bare `&&`) so a missing file under `set -e` never aborts the script.
# Bash functions are inherited by the `| while read; do ... done` subshell
# below, so defining these at top level is enough for the loop to use them.
# shellcheck source=needs-human.sh
if [ -f "$script_dir/needs-human.sh" ]; then . "$script_dir/needs-human.sh"; fi

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
      # Needs bot action, not owner action -- ball is NOT in the owner's
      # court right now, so clear any earlier "awaiting re-review" flag
      # (issue #99). Best-effort no-op when needs-human.sh isn't sourced.
      if command -v needs_human_clear >/dev/null 2>&1; then
        needs_human_clear "pr:$num" "changes-requested"
      fi
      printf '%s\t%s\t%s\t%s\n' "$num" "$branch" "$reviewer" "$tcr"
    elif command -v needs_human_flag >/dev/null 2>&1; then
      # Addressed (marker comment is newer than the last CHANGES_REQUESTED
      # review) but GitHub still reports reviewDecision=CHANGES_REQUESTED
      # until the owner submits a fresh review (see the file header) -- this
      # IS the "round-trip done, re-review needed" block-on-owner point
      # (issue #99). Cleared above the moment a FRESH CHANGES_REQUESTED
      # arrives (back in the bot's court), or by merge-ready.sh once the PR
      # merges.
      needs_human_flag "pr:$num" "changes-requested" "low" \
        "PR #$num addressed feedback -- ready for re-review" \
        "$reviewer's changes-requested review was addressed; awaiting re-review."
    fi
  done
