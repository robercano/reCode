#!/usr/bin/env bash
# GitHub notification poll: prints new issues, PR review comments,
# issue-comments on PRs, and PR reviews since the last run, then advances the
# cursor. Intended to be invoked by a notification cron job / /loop.
#
# IMPORTANT: invoke this as `bash .claude/scripts/notify-poll.sh` and add that
# exact command to the settings.json permissions allow list. An inline compound
# command (loops, $(), redirects) never matches a permission rule, so a cron
# that polls inline will block on a permission prompt every firing.
#
# Repo is derived from the current git remote; override with $1 (owner/repo).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
state_dir="$root/.claude/state"          # add .claude/state/ to .gitignore
cursor_file="$state_dir/notify-cursor"

mkdir -p "$state_dir"
cursor=$(cat "$cursor_file" 2>/dev/null || date -u -d '30 minutes ago' +%FT%TZ)
now=$(date -u +%FT%TZ)
echo "CURSOR=$cursor NOW=$now"

echo "=== issues ==="
gh api "repos/$repo/issues?state=all&since=$cursor" \
  --jq '[.[] | select(.pull_request == null) | {n:.number,title:.title,user:.user.login,created:.created_at,updated:.updated_at,url:.html_url}]'

echo "=== pr review comments ==="
gh api "repos/$repo/pulls/comments?sort=updated&direction=desc&since=$cursor" \
  --jq '[.[] | {pr:.pull_request_url,user:.user.login,body:.body,updated:.updated_at,url:.html_url}]'

echo "=== issue-comments on PRs ==="
gh api "repos/$repo/issues/comments?sort=updated&direction=desc&since=$cursor" \
  --jq '[.[] | select(.html_url | contains("/pull/")) | {user:.user.login,body:.body,updated:.updated_at,url:.html_url}]'

echo "=== reviews on open PRs ==="
for n in $(gh pr list -R "$repo" --json number -q '.[].number'); do
  gh api "repos/$repo/pulls/$n/reviews" \
    --jq "[.[] | select(.submitted_at > \"$cursor\") | {pr:$n,user:.user.login,state:.state,body:.body,submitted:.submitted_at,url:.html_url}]"
done

echo "$now" > "$cursor_file"
echo "=== cursor advanced to $now ==="
