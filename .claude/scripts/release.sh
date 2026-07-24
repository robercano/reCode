#!/usr/bin/env bash
# release.sh — the release driver for a milestone-gated "Release vX.Y.Z" issue
# (issue #176). Reuses the #97 "Blocked by #N" blocking-graph gate as the
# whole release gate: the release issue's body declares "Blocked by" every
# OTHER open issue in its milestone, so the loop's census will not advance it
# until every sibling has merged (see .github/ISSUE_TEMPLATE/release.md and
# docs/USAGE.md -> "Release cycle"). Once advanced, the implementer runs this
# script to perform the actual cut.
#
# Usage:
#   bash .claude/scripts/release.sh vX.Y.Z [--issue N] [--repo OWNER/NAME] [--dry-run]
#   bash .claude/scripts/release.sh --milestone-title "Release v0.3.0" [--dry-run]
#
# Version resolution (first match wins):
#   1. an explicit "vX.Y.Z" positional argument
#   2. --milestone-title "TITLE" — a vX.Y.Z substring is extracted locally,
#      no network call
#   3. --issue N — fetches the issue's milestone title via bot-gh.sh (NOT
#      permitted under --dry-run: dry-run must make zero network/gh calls)
#
# Steps performed (see the CRITICAL header below for the dry-run boundary):
#   1. Bump the `version` field in .claude/.claude-plugin/plugin.json AND
#      .claude/.claude-plugin/marketplace.json (top-level + the matching
#      plugins[] entry) via node -e (never a brittle sed on JSON, matching
#      checks.sh's own JSON-editing style).
#   2. Generate a dated Keep-a-Changelog section in
#      .claude/.claude-plugin/CHANGELOG.md from commits since the last git
#      tag — or, if there is no prior tag yet (this repo's current state:
#      zero tags), from the full history (first-release path). Prefers merge
#      commit subjects ("Merge pull request #N from owner/branch" -> one
#      bullet per merged PR) when any exist in range; falls back to every
#      non-merge commit subject in range otherwise (the no-merges case a
#      fresh/test repo hits).
#   3. Tag vX.Y.Z, commit the bumps + changelog, push both.
#   4. "Publish" per the existing "Updating the plugin" runbook
#      (docs/USAGE.md): this script CANNOT run the interactive
#      `/plugin marketplace update` slash command, and `npm/pnpm/yarn
#      publish` are policy-denied, so "publish" here means step 3 above,
#      followed by printing the manual owner follow-up.
#   5. Close the milestone (requires --issue N to resolve which milestone;
#      without it this step is skipped with a warning — close it by hand).
#   6. On success, auto-file a "Rollout & feedback: vX.Y.Z" issue: NOT in any
#      milestone, NO `planned` label (a census-invisible inbox — see
#      docs/USAGE.md), labelled `feedback`. Body carries (a) a consumer-sync
#      checklist for reDeploy/reDeFi via `/orchestrator:sync` v2 (issue
#      #141), (b) test-focus areas derived from the milestone's issue titles
#      (requires --issue N; a generic note otherwise), (c) a section to
#      accumulate feedback back-references. The `feedback` /
#      `from:redeploy` / `from:redefi` labels are created idempotently at
#      file time via REST (`gh api`, never `gh label create` /
#      `gh issue edit --add-label` — issue #169 found both silently no-op
#      with this repo's bot token/gh version; see needs-human.sh).
#
# --- CRITICAL: --dry-run boundary -------------------------------------------
# --dry-run performs the PURE FILE TRANSFORMS (steps 1-2 above) for real,
# against the working tree/fixtures it's pointed at (release.test.sh's temp
# git fixture) — so a caller can inspect the resulting files — but PRINTS
# every git/gh side effect (tag, push, milestone close, issue file) instead
# of executing it. No `git commit`/`git tag`/`git push`/any `bot-gh.sh`/`gh`
# call happens under --dry-run, ever.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-roots.sh
. "$script_dir/resolve-roots.sh"
# Route EVERY gh call through the bot identity (see bot-gh.sh) — never bare gh.
gh() { bash "$script_dir/bot-gh.sh" "$@"; }

DRY_RUN=0
VERSION=""
ISSUE_NUM=""
MILESTONE_TITLE=""
REPO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --issue) ISSUE_NUM="${2:?--issue requires a value}"; shift 2 ;;
    --milestone-title) MILESTONE_TITLE="${2:?--milestone-title requires a value}"; shift 2 ;;
    --repo) REPO="${2:?--repo requires a value}"; shift 2 ;;
    -*)
      echo "release.sh: unknown flag '$1'" >&2
      exit 2
      ;;
    *)
      if [ -n "$VERSION" ]; then
        echo "release.sh: unexpected extra argument '$1'" >&2
        exit 2
      fi
      VERSION="$1"
      shift
      ;;
  esac
done

# --- version resolution ------------------------------------------------------
if [ -z "$VERSION" ] && [ -n "$MILESTONE_TITLE" ]; then
  VERSION="$(printf '%s' "$MILESTONE_TITLE" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi
if [ -z "$VERSION" ] && [ -n "$ISSUE_NUM" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "release.sh: --issue resolves the version via a network call, which --dry-run must never make. Pass vX.Y.Z or --milestone-title explicitly under --dry-run." >&2
    exit 2
  fi
  repo_flag=(); [ -n "$REPO" ] && repo_flag=(-R "$REPO")
  milestone_title_probe="$(gh issue view "$ISSUE_NUM" "${repo_flag[@]}" --json milestone --jq '.milestone.title // empty' 2>/dev/null)" || true
  VERSION="$(printf '%s' "$milestone_title_probe" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi
if ! printf '%s' "$VERSION" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "release.sh: could not resolve a vX.Y.Z version — pass it as an argument, via --milestone-title, or --issue N (non-dry-run only)" >&2
  exit 2
fi
num_version="${VERSION#v}"

# --- fixed file locations ----------------------------------------------------
plugin_json="$root/.claude/.claude-plugin/plugin.json"
marketplace_json="$root/.claude/.claude-plugin/marketplace.json"
changelog_md="$root/.claude/.claude-plugin/CHANGELOG.md"
for f in "$plugin_json" "$marketplace_json" "$changelog_md"; do
  if [ ! -f "$f" ]; then
    echo "release.sh: missing $f" >&2
    exit 1
  fi
done

echo "release.sh: releasing $VERSION"

# --- step 1: bump plugin.json + marketplace.json -----------------------------
node -e '
  const fs = require("fs");
  const f = process.argv[1], v = process.argv[2];
  const j = JSON.parse(fs.readFileSync(f, "utf8"));
  j.version = v;
  fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
' "$plugin_json" "$num_version" || { echo "release.sh: failed to bump $plugin_json" >&2; exit 1; }
echo "release.sh: bumped plugin.json -> $num_version"

node -e '
  const fs = require("fs");
  const f = process.argv[1], v = process.argv[2];
  const j = JSON.parse(fs.readFileSync(f, "utf8"));
  j.version = v;
  if (Array.isArray(j.plugins)) {
    for (const p of j.plugins) p.version = v;
  }
  fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
' "$marketplace_json" "$num_version" || { echo "release.sh: failed to bump $marketplace_json" >&2; exit 1; }
echo "release.sh: bumped marketplace.json (+ plugins[].version) -> $num_version"

# --- step 2: generate the CHANGELOG section ----------------------------------
last_tag="$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$last_tag" ]; then
  range="$last_tag..HEAD"
  echo "release.sh: generating changelog from commits in $range (since last tag $last_tag)"
else
  range="HEAD"
  echo "release.sh: no prior git tag found — first-release path, using full history"
fi

merge_subjects="$(git -C "$root" log $range --merges --pretty=%s 2>/dev/null || true)"
if [ -n "$merge_subjects" ]; then
  changelog_items="$(printf '%s\n' "$merge_subjects" | sed -E 's/^Merge pull request (#[0-9]+) from [^\/]+\/(.+)$/- \1: \2/')"
else
  changelog_items="$(git -C "$root" log $range --no-merges --pretty=%s 2>/dev/null | sed 's/^/- /')"
fi
[ -n "$changelog_items" ] || changelog_items="- (no changes recorded)"

release_date="$(date -u +%Y-%m-%d)"
section="## [$num_version] - $release_date

### Changed
$changelog_items"

# Insert ahead of the first DATED entry, skipping past an optional leading
# "## [Unreleased]" scaffold section (Keep-a-Changelog convention: Unreleased
# always stays on top, above every dated release) so a repo that scaffolds
# one doesn't get it pushed below the new dated section.
tmp_changelog="$(mktemp "${TMPDIR:-/tmp}/release-changelog.XXXXXX")"
if grep -qEi '^## \[[0-9]' "$changelog_md"; then
  awk -v section="$section" '
    !inserted && /^## \[/ && !/^## \[[Uu]nreleased\]/ { print section; print ""; inserted=1 }
    { print }
  ' "$changelog_md" > "$tmp_changelog"
else
  cat "$changelog_md" > "$tmp_changelog"
  printf '\n%s\n' "$section" >> "$tmp_changelog"
fi
mv "$tmp_changelog" "$changelog_md"
echo "release.sh: prepended CHANGELOG section for $num_version"

# --- dry-run boundary: pure file transforms are done; print every remaining
# git/gh side effect instead of performing it. -------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo "release.sh: [dry-run] would run: git add -- '$plugin_json' '$marketplace_json' '$changelog_md'"
  echo "release.sh: [dry-run] would run: git commit -m 'release: $VERSION'"
  echo "release.sh: [dry-run] would run: git tag $VERSION"
  echo "release.sh: [dry-run] would run: git push origin HEAD"
  echo "release.sh: [dry-run] would run: git push origin $VERSION"
  if [ -n "$ISSUE_NUM" ]; then
    echo "release.sh: [dry-run] would resolve the milestone from issue #$ISSUE_NUM and close it via bot-gh.sh"
  else
    echo "release.sh: [dry-run] would close the milestone via bot-gh.sh (pass --issue N to resolve which one)"
  fi
  echo "release.sh: [dry-run] would create labels (feedback, from:redeploy, from:redefi) idempotently via bot-gh.sh api, then file a 'Rollout & feedback: $VERSION' issue (no milestone, no planned label, labelled feedback)"
  echo "release.sh: [dry-run] complete — file transforms applied, no git/gh mutation performed"
  exit 0
fi

# =============================================================================
# Everything below this line performs REAL git/gh side effects and is never
# reached under --dry-run.
# =============================================================================

# --- step 3: commit, tag, push -----------------------------------------------
git -C "$root" add -- "$plugin_json" "$marketplace_json" "$changelog_md" \
  || { echo "release.sh: git add failed" >&2; exit 1; }
# -c commit.gpgSign=false / tag.gpgSign=false: override an operator's global
# gpgsign defaults for THESE invocations only (never writes to any gitconfig)
# — an unattended release commit/tag doesn't need GPG signing, and an
# operator with `commit.gpgsign=true`/`tag.gpgsign=true` and no agent
# configured would otherwise hang here waiting on a signature. Applied
# symmetrically to both the commit and the tag.
git -C "$root" -c commit.gpgSign=false commit -q -m "release: $VERSION" \
  || { echo "release.sh: git commit failed" >&2; exit 1; }
git -C "$root" -c tag.gpgSign=false tag "$VERSION" \
  || { echo "release.sh: git tag failed" >&2; exit 1; }
git -C "$root" push origin HEAD \
  || { echo "release.sh: git push (branch) failed" >&2; exit 1; }
git -C "$root" push origin "$VERSION" \
  || { echo "release.sh: git push (tag) failed" >&2; exit 1; }

echo ""
echo "release.sh: MANUAL OWNER FOLLOW-UP REQUIRED (cannot be automated — see docs/USAGE.md 'Updating the plugin'):"
echo "  /plugin marketplace update recode"
echo ""

# --- step 5: close the milestone (requires --issue N) ------------------------
repo_flag=(); [ -n "$REPO" ] && repo_flag=(-R "$REPO")
repo_full="$REPO"
[ -n "$repo_full" ] || repo_full="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || true

milestone_number=""
milestone_title_for_focus=""
if [ -n "$ISSUE_NUM" ]; then
  milestone_number="$(gh issue view "$ISSUE_NUM" "${repo_flag[@]}" --json milestone --jq '.milestone.number // empty' 2>/dev/null)" || true
  milestone_title_for_focus="$(gh issue view "$ISSUE_NUM" "${repo_flag[@]}" --json milestone --jq '.milestone.title // empty' 2>/dev/null)" || true
fi

if [ -n "$milestone_number" ] && [ -n "$repo_full" ]; then
  if gh api -X PATCH "repos/$repo_full/milestones/$milestone_number" -f state=closed >/dev/null 2>&1; then
    echo "release.sh: closed milestone #$milestone_number"
  else
    echo "release.sh: warning — could not close milestone #$milestone_number via the API; close it by hand" >&2
  fi
else
  echo "release.sh: warning — no milestone resolved (pass --issue N); NOT closed automatically — close it by hand" >&2
fi

# --- step 6: test-focus areas from the milestone's issue titles --------------
test_focus=""
if [ -n "$milestone_title_for_focus" ]; then
  test_focus="$(gh issue list "${repo_flag[@]}" --state all --milestone "$milestone_title_for_focus" --json title --jq '.[].title' 2>/dev/null)" || true
fi
if [ -n "$test_focus" ]; then
  test_focus_list="$(printf '%s\n' "$test_focus" | sed 's/^/- /')"
else
  test_focus_list="- (milestone issue titles unavailable — pass --issue N to derive them)"
fi

# --- step 6: idempotently ensure the rollout labels exist (REST, matching the
# proven-working pattern from needs-human.sh; `gh label create`/
# `gh issue edit --add-label` silently no-op with this repo's bot token, see
# issue #169) -----------------------------------------------------------------
if [ -n "$repo_full" ]; then
  gh api -X POST "repos/$repo_full/labels" -f name=feedback -f color=0e8a16 \
    -f description="Post-release consumer feedback inbox (census-invisible -- no milestone, no planned label)" \
    >/dev/null 2>&1 || true
  gh api -X POST "repos/$repo_full/labels" -f name=from:redeploy -f color=1d76db \
    -f description="Feedback originating from the reDeploy consumer sync" \
    >/dev/null 2>&1 || true
  gh api -X POST "repos/$repo_full/labels" -f name=from:redefi -f color=5319e7 \
    -f description="Feedback originating from the reDeFi consumer sync" \
    >/dev/null 2>&1 || true
fi

rollout_body="## Rollout & feedback: $VERSION

Version **$VERSION** has been released. This issue is the post-release feedback inbox: it
carries NO milestone and NO \`planned\` label by design (a census-invisible inbox — see
docs/USAGE.md \"Release cycle\") until the owner triages incoming feedback.

## Consumer-sync checklist
Run \`/orchestrator:sync\` (sync v2, issue #141) against each downstream consumer and record
the result here:
- [ ] reDeploy — \`/orchestrator:sync\` (deploy-lag, env, labels, observability checks)
- [ ] reDeFi — \`/orchestrator:sync\` (deploy-lag, env, labels, observability checks)

## Test-focus areas (from milestone issues)
$test_focus_list

## Feedback
Accumulate feedback references here as they come in. Link the originating issue/PR from
reDeploy/reDeFi and tag it with \`from:redeploy\`/\`from:redefi\`:
- (none yet)
"

create_out="$(gh issue create "${repo_flag[@]}" --title "Rollout & feedback: $VERSION" --body "$rollout_body" --label feedback 2>&1)"
if [ $? -eq 0 ]; then
  echo "release.sh: filed rollout issue: $create_out"
else
  echo "release.sh: warning — failed to file the rollout issue: $create_out" >&2
fi

echo "release.sh: done — $VERSION released"
