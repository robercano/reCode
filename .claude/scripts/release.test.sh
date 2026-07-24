#!/usr/bin/env bash
# release.test.sh — offline smoke test for release.sh (issue #176).
#
# Builds TWO throwaway temp git repo fixtures (mktemp -d, git init, seeded
# plugin.json/marketplace.json/CHANGELOG.md fixtures + fake commits — the
# REAL release.sh + resolve-roots.sh copied into each fixture's
# .claude/scripts/, mirroring worktree-cleanup.test.sh's fixture pattern) and
# exercises `release.sh --dry-run` against each, asserting:
#   1. WITH-A-PRIOR-TAG case: a couple of fake merge commits ("Merge pull
#      request #N from owner/branch", the real GitHub merge-commit shape)
#      land after the tag; release.sh --dry-run derives the changelog from
#      THOSE, not the pre-tag history.
#   2. version bump is applied to BOTH plugin.json and marketplace.json
#      (top-level `version` + marketplace's nested plugins[].version).
#   3. a correctly-formatted, DATED changelog section
#      ("## [X.Y.Z] - YYYY-MM-DD") is prepended ahead of the prior version's
#      section, containing one bullet per fake merged-PR commit.
#   4. NO-PRIOR-TAG (first-release) case: a fresh fixture with zero tags and
#      only plain (non-merge) commits standing in for PR titles — the
#      first-release path still bumps + generates a changelog, using the
#      full history's non-merge commit subjects since there is nothing else
#      to derive them from.
#   5. --dry-run makes NO real git tag, NO git push, and NO gh/network call
#      of any kind (no .env / GH_BOT_TOKEN is ever provided to either
#      fixture, so a stray real `gh`/`bot-gh.sh` invocation would surface as
#      a hard failure — dry-run must never reach that code path).
#   6. --milestone-title resolves the version with no --issue/network call;
#      --issue combined with --dry-run is rejected (dry-run must never
#      resolve a version via a live gh call).
#   7. an optional "## [Unreleased]" scaffold section at the top of the
#      CHANGELOG (issue #176's optional CHANGELOG addition) stays ABOVE the
#      newly-generated dated section rather than getting pushed below it.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/release.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release_src="$script_dir/release.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/release-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail=0
ok=0
check() {
  local desc="$1"; shift
  if "$@"; then
    ok=$((ok + 1))
    echo "ok - $desc"
  else
    fail=1
    echo "FAIL - $desc"
  fi
}

json_version() {
  # $1 = file, prints .version
  node -e '
    const fs = require("fs");
    const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(String(j.version || ""));
  ' "$1" 2>/dev/null
}
json_plugin_entry_version() {
  # $1 = marketplace.json, prints plugins[0].version
  node -e '
    const fs = require("fs");
    const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(String((j.plugins && j.plugins[0] && j.plugins[0].version) || ""));
  ' "$1" 2>/dev/null
}

seed_fixture() {
  # $1 = repo dir. Seeds plugin.json/marketplace.json/CHANGELOG.md at 1.0.0
  # plus the real release.sh + resolve-roots.sh under .claude/scripts/, and
  # an initial commit. Deliberately NO .env / GH_BOT_TOKEN anywhere near this
  # fixture, and NO origin remote — a stray real git-push or gh call would
  # hard-fail loudly rather than silently succeeding.
  local repo="$1"
  mkdir -p "$repo/.claude/.claude-plugin" "$repo/.claude/scripts"
  git init -q -b main "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"

  cat > "$repo/.claude/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "orchestrator",
  "version": "1.0.0",
  "description": "test fixture"
}
EOF
  cat > "$repo/.claude/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "recode",
  "version": "1.0.0",
  "plugins": [
    { "name": "orchestrator", "source": "./", "version": "1.0.0" }
  ]
}
EOF
  cat > "$repo/.claude/.claude-plugin/CHANGELOG.md" <<'EOF'
# Changelog

All notable changes are documented here.

## [1.0.0] - 2026-01-01

### Added
- Initial fixture release.
EOF

  cp "$release_src" "$repo/.claude/scripts/release.sh"
  cp "$resolve_roots_src" "$repo/.claude/scripts/resolve-roots.sh"
  chmod +x "$repo/.claude/scripts/release.sh"

  git -C "$repo" add -A
  git -C "$repo" commit -q -m "seed fixture at 1.0.0"
}

run_release() {
  # $1 = repo dir, rest = args to release.sh
  local repo="$1"; shift
  ( cd "$repo" && bash "$repo/.claude/scripts/release.sh" "$@" )
}

# =============================================================================
# Scenario A: WITH a prior tag — fake merge commits after the tag.
# =============================================================================
repo_a="$work/repo-a"
seed_fixture "$repo_a"
# Tag the seed commit itself as v1.0.0 — everything committed after this point
# is "since the last tag" and must be the ONLY thing the changelog picks up.
git -C "$repo_a" -c tag.gpgSign=false tag v1.0.0

# A commit landing AFTER the tag but BEFORE the merge commits below — it is
# in-range but not a merge commit, so with merge commits present it must be
# excluded from the changelog (merge subjects win over plain commits when any
# exist in range — see release.sh's changelog-generation comment).
echo "pre-merge" > "$repo_a/premerge.txt"
git -C "$repo_a" add premerge.txt
git -C "$repo_a" commit -q -m "premerge: should not show up once merge commits exist in range"

# Two fake merged-PR commits, real GitHub merge-commit shape.
git -C "$repo_a" checkout -q -b feat/thing-one
echo "one" > "$repo_a/one.txt"
git -C "$repo_a" add one.txt
git -C "$repo_a" commit -q -m "feat: thing one"
git -C "$repo_a" checkout -q main
git -C "$repo_a" merge -q --no-ff -m "Merge pull request #42 from robercano/feat/thing-one" feat/thing-one

git -C "$repo_a" checkout -q -b feat/thing-two
echo "two" > "$repo_a/two.txt"
git -C "$repo_a" add two.txt
git -C "$repo_a" commit -q -m "feat: thing two"
git -C "$repo_a" checkout -q main
git -C "$repo_a" merge -q --no-ff -m "Merge pull request #43 from robercano/feat/thing-two" feat/thing-two

out_a="$(run_release "$repo_a" v1.1.0 --dry-run)"
rc_a=$?

check "scenario A: exits 0" [ "$rc_a" -eq 0 ]
check "scenario A: plugin.json version bumped to 1.1.0" bash -c '[ "$(cat "$1")" = "1.1.0" ]' _ <(json_version "$repo_a/.claude/.claude-plugin/plugin.json")
check "scenario A: marketplace.json top-level version bumped to 1.1.0" bash -c '[ "$(cat "$1")" = "1.1.0" ]' _ <(json_version "$repo_a/.claude/.claude-plugin/marketplace.json")
check "scenario A: marketplace.json plugins[0].version bumped to 1.1.0" bash -c '[ "$(cat "$1")" = "1.1.0" ]' _ <(json_plugin_entry_version "$repo_a/.claude/.claude-plugin/marketplace.json")

changelog_a="$(cat "$repo_a/.claude/.claude-plugin/CHANGELOG.md")"
check "scenario A: changelog has a dated 1.1.0 section" bash -c 'printf "%s" "$1" | grep -qE "^## \[1\.1\.0\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$"' _ "$changelog_a"
check "scenario A: new 1.1.0 section is ABOVE the prior 1.0.0 section" bash -c '
  printf "%s\n" "$1" > "$2/order.txt"
  n1=$(grep -n "^## \[1.1.0\]" "$2/order.txt" | head -1 | cut -d: -f1)
  n0=$(grep -n "^## \[1.0.0\]" "$2/order.txt" | head -1 | cut -d: -f1)
  [ -n "$n1" ] && [ -n "$n0" ] && [ "$n1" -lt "$n0" ]
' _ "$changelog_a" "$work"
check "scenario A: changelog references merged PR #42" bash -c 'printf "%s" "$1" | grep -q "#42: feat/thing-one"' _ "$changelog_a"
check "scenario A: changelog references merged PR #43" bash -c 'printf "%s" "$1" | grep -q "#43: feat/thing-two"' _ "$changelog_a"
check "scenario A: in-range non-merge commit is excluded once merge commits exist" bash -c '! printf "%s" "$1" | grep -q "premerge:"' _ "$changelog_a"
check "scenario A: no real tag v1.1.0 was created" bash -c '! git -C "$1" tag --list | grep -qx v1.1.0' _ "$repo_a"
check "scenario A: original tag v1.0.0 untouched" bash -c 'git -C "$1" tag --list | grep -qx v1.0.0' _ "$repo_a"
check "scenario A: HEAD has no new commit (dry-run never commits)" bash -c '
  msg=$(git -C "$1" log -1 --pretty=%s)
  [ "$msg" != "release: v1.1.0" ]
' _ "$repo_a"
check "scenario A: dry-run output announces every side effect instead of performing it" bash -c '
  printf "%s" "$1" | grep -q "\[dry-run\] would run: git tag v1.1.0" &&
  printf "%s" "$1" | grep -q "\[dry-run\] would run: git push origin v1.1.0" &&
  printf "%s" "$1" | grep -qi "\[dry-run\].*rollout"
' _ "$out_a"

# =============================================================================
# Scenario B: NO prior tag (first-release path) — plain, non-merge commits
# standing in for PR titles, exactly the case a brand-new repo (this repo
# today: zero git tags) will hit on its very first release.
# =============================================================================
repo_b="$work/repo-b"
seed_fixture "$repo_b"

echo "alpha" > "$repo_b/alpha.txt"
git -C "$repo_b" add alpha.txt
git -C "$repo_b" commit -q -m "feat: alpha capability"
echo "beta" > "$repo_b/beta.txt"
git -C "$repo_b" add beta.txt
git -C "$repo_b" commit -q -m "fix: beta bug"

out_b="$(run_release "$repo_b" v0.1.0 --dry-run)"
rc_b=$?

check "scenario B: exits 0" [ "$rc_b" -eq 0 ]
check "scenario B: plugin.json version bumped to 0.1.0" bash -c '[ "$(cat "$1")" = "0.1.0" ]' _ <(json_version "$repo_b/.claude/.claude-plugin/plugin.json")
check "scenario B: marketplace.json version bumped to 0.1.0" bash -c '[ "$(cat "$1")" = "0.1.0" ]' _ <(json_version "$repo_b/.claude/.claude-plugin/marketplace.json")
check "scenario B: announces the no-prior-tag / full-history path" bash -c 'printf "%s" "$1" | grep -qi "no prior git tag found"' _ "$out_b"

changelog_b="$(cat "$repo_b/.claude/.claude-plugin/CHANGELOG.md")"
check "scenario B: changelog has a dated 0.1.0 section" bash -c 'printf "%s" "$1" | grep -qE "^## \[0\.1\.0\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$"' _ "$changelog_b"
check "scenario B: changelog derived from the plain (non-merge) commit subjects" bash -c '
  printf "%s" "$1" | grep -q -- "- feat: alpha capability" &&
  printf "%s" "$1" | grep -q -- "- fix: beta bug"
' _ "$changelog_b"
check "scenario B: no tag was created at all" bash -c '[ -z "$(git -C "$1" tag --list)" ]' _ "$repo_b"

# =============================================================================
# Scenario C: version resolution — --milestone-title (no network) works;
# --issue combined with --dry-run is rejected (never allowed to resolve the
# version via a live gh call under dry-run).
# =============================================================================
repo_c="$work/repo-c"
seed_fixture "$repo_c"
echo "gamma" > "$repo_c/gamma.txt"
git -C "$repo_c" add gamma.txt
git -C "$repo_c" commit -q -m "feat: gamma"

out_c="$(run_release "$repo_c" --milestone-title "Release v2.3.4" --dry-run)"
rc_c=$?
check "scenario C: --milestone-title resolves the version offline" [ "$rc_c" -eq 0 ]
check "scenario C: plugin.json bumped to the milestone-derived version 2.3.4" bash -c '[ "$(cat "$1")" = "2.3.4" ]' _ <(json_version "$repo_c/.claude/.claude-plugin/plugin.json")

repo_d="$work/repo-d"
seed_fixture "$repo_d"
out_d="$(run_release "$repo_d" --issue 176 --dry-run 2>&1)"
rc_d=$?
check "scenario D: --issue combined with --dry-run is rejected (non-zero exit)" [ "$rc_d" -ne 0 ]
check "scenario D: rejection message explains --dry-run can't resolve the version via network" bash -c 'printf "%s" "$1" | grep -qi "dry-run must never make"' _ "$out_d"
check "scenario D: plugin.json left untouched (still 1.0.0)" bash -c '[ "$(cat "$1")" = "1.0.0" ]' _ <(json_version "$repo_d/.claude/.claude-plugin/plugin.json")

# =============================================================================
# Scenario E: an optional "## [Unreleased]" scaffold section (issue #176) at
# the top of the CHANGELOG must stay ABOVE the newly-generated dated section,
# not get pushed below it — Keep-a-Changelog convention.
# =============================================================================
repo_e="$work/repo-e"
seed_fixture "$repo_e"
cat > "$repo_e/.claude/.claude-plugin/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]
- scaffold section, no dated entry yet

## [1.0.0] - 2026-01-01

### Added
- Initial fixture release.
EOF
git -C "$repo_e" add .claude/.claude-plugin/CHANGELOG.md
git -C "$repo_e" commit -q -m "seed: add Unreleased scaffold"
git -C "$repo_e" -c tag.gpgSign=false tag v1.0.0
echo "delta" > "$repo_e/delta.txt"
git -C "$repo_e" add delta.txt
git -C "$repo_e" commit -q -m "feat: delta capability"

run_release "$repo_e" v1.1.0 --dry-run >/dev/null
changelog_e="$(cat "$repo_e/.claude/.claude-plugin/CHANGELOG.md")"
check "scenario E: Unreleased scaffold stays above the new dated section" bash -c '
  printf "%s\n" "$1" > "$2/order-e.txt"
  nu=$(grep -n "^## \[Unreleased\]" "$2/order-e.txt" | head -1 | cut -d: -f1)
  n1=$(grep -n "^## \[1.1.0\]" "$2/order-e.txt" | head -1 | cut -d: -f1)
  [ -n "$nu" ] && [ -n "$n1" ] && [ "$nu" -lt "$n1" ]
' _ "$changelog_e" "$work"
check "scenario E: new dated section still lands above the prior 1.0.0 section" bash -c '
  printf "%s\n" "$1" > "$2/order-e2.txt"
  n1=$(grep -n "^## \[1.1.0\]" "$2/order-e2.txt" | head -1 | cut -d: -f1)
  n0=$(grep -n "^## \[1.0.0\]" "$2/order-e2.txt" | head -1 | cut -d: -f1)
  [ -n "$n1" ] && [ -n "$n0" ] && [ "$n1" -lt "$n0" ]
' _ "$changelog_e" "$work"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "release.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "release.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
