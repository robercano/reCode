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
#   8. the REAL (non-dry-run) mutating path: a local `git init --bare` origin
#      stands in for the network (mirrors worktree-cleanup.test.sh) and a
#      fake bot-gh.sh stub installed at the fixture's own
#      .claude/scripts/bot-gh.sh stands in for gh entirely (mirrors
#      pr-rebase.test.sh's convention — release.sh's `gh()` always shells out
#      to its own sibling bot-gh.sh, never $PATH). Asserts the version-bump
#      commit landed, the tag was created, the push actually reached the bare
#      origin (branch + tag), and the milestone-close / label-create /
#      rollout-issue-create gh calls fired with the right args (including the
#      rollout body's milestone-derived test-focus titles) — by inspecting
#      the stub's own call log.
#   9. the no-`--issue` real-path variant: milestone-close warns and skips
#      (never crashes, never guesses), while the rollout companion issue is
#      still filed with a graceful "titles unavailable" test-focus fallback.
#  10. MIXED merge-commit + squash-merge history in a single range (this
#      repo's real v0.3.0..v0.3.1 shape): every landed change is listed
#      exactly once regardless of how it landed, and a merge-committed PR's
#      internal commits are never double-listed. Guards the regression where
#      one merge commit in range caused every squash-merged PR to be dropped.
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

install_fake_bot_gh() {
  # $1 = repo dir. Installs a FAKE bot-gh.sh at the fixture's
  # .claude/scripts/bot-gh.sh — release.sh's own `gh() { bash
  # "$script_dir/bot-gh.sh" "$@"; }` always shells out to its OWN sibling
  # bot-gh.sh (resolved from release.sh's own location), never $PATH, so this
  # is the one place a stub must live to intercept every gh call (mirrors
  # pr-rebase.test.sh's / pr-comment-fix.test.sh's fake-bot-gh.sh convention).
  # Logs every invocation, verbatim, to $RELEASE_TEST_GH_LOG (an env var the
  # caller sets — never hardcoded, so parallel scenarios use separate logs)
  # so the test can assert milestone-close / label-create / issue-create
  # fired with the expected args. No real network/gh call, ever.
  local repo="$1"
  cat > "$repo/.claude/scripts/bot-gh.sh" <<'STUB'
#!/usr/bin/env bash
log_file="${RELEASE_TEST_GH_LOG:?RELEASE_TEST_GH_LOG must be set by the test}"
printf '%s\n' "$*" >> "$log_file"
case "$1" in
  repo)
    echo "acme/repo"
    ;;
  issue)
    case "$2" in
      view)
        if printf '%s\n' "$*" | grep -q '\.milestone\.number'; then
          echo "77"
        elif printf '%s\n' "$*" | grep -q '\.milestone\.title'; then
          echo "Release v1.2.0"
        fi
        ;;
      list)
        printf '%s\n' "Fix widget alignment" "Add gizmo support"
        ;;
      create)
        echo "https://github.com/acme/repo/issues/999"
        ;;
      *)
        echo "fake-bot-gh.sh: unexpected issue subcommand: $*" >&2
        exit 1
        ;;
    esac
    ;;
  api)
    exit 0
    ;;
  *)
    echo "fake-bot-gh.sh: unexpected command: $*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$repo/.claude/scripts/bot-gh.sh"
}

run_release_real() {
  # $1 = repo dir, $2 = gh-call log file (absolute path), rest = args to
  # release.sh. Exports RELEASE_TEST_GH_LOG for the fake bot-gh.sh stub above
  # — install_fake_bot_gh must have already been run against $1.
  local repo="$1" log="$2"; shift 2
  ( cd "$repo" && RELEASE_TEST_GH_LOG="$log" bash "$repo/.claude/scripts/release.sh" "$@" )
}

# =============================================================================
# Scenario A: WITH a prior tag — fake merge commits after the tag.
# =============================================================================
repo_a="$work/repo-a"
seed_fixture "$repo_a"
# Tag the seed commit itself as v1.0.0 — everything committed after this point
# is "since the last tag" and must be the ONLY thing the changelog picks up.
git -C "$repo_a" -c tag.gpgSign=false tag v1.0.0

# A commit landing AFTER the tag but BEFORE the merge commits below — a direct
# commit to the base branch. It is in-range and ON the first-parent chain, so
# it is a real shipped change and MUST appear in the changelog even though
# merge commits also exist in range. (This inverts the pre-fix behaviour, which
# discarded every non-merge commit as soon as one merge commit was present —
# the bug that dropped five squash-merged PRs from the v0.3.1 range.)
echo "pre-merge" > "$repo_a/premerge.txt"
git -C "$repo_a" add premerge.txt
git -C "$repo_a" commit -q -m "premerge: a direct-to-main commit alongside merge commits"

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
check "scenario A: in-range direct-to-main commit is INCLUDED alongside merge commits" bash -c 'printf "%s" "$1" | grep -q -- "- premerge: a direct-to-main commit alongside merge commits"' _ "$changelog_a"
# The real anti-double-listing guarantee: a merged PR contributes its merge
# subject ONCE, never also its internal commits (which are off the first-parent
# chain). Without this, #42 would be listed as both "#42: feat/thing-one" and
# "feat: thing one".
check "scenario A: merged PRs' internal commits are NOT double-listed" bash -c '
  ! printf "%s" "$1" | grep -q -- "- feat: thing one" &&
  ! printf "%s" "$1" | grep -q -- "- feat: thing two"
' _ "$changelog_a"
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

# =============================================================================
# Scenario F: the REAL (non-dry-run) mutating path — a local `git init --bare`
# origin stands in for the network (mirrors worktree-cleanup.test.sh's own
# bare-repo-as-origin pattern) and a fake bot-gh.sh stub (installed above)
# stands in for gh entirely (mirrors pr-rebase.test.sh's convention). Asserts
# every one of release.sh's real side effects actually happened: (a) the
# version-bump commit landed, (b) the vX.Y.Z tag was created, (c) the push
# actually reached the bare origin (branch AND tag), (d) the milestone-close,
# label-create, and rollout-issue-create gh calls fired with the correct
# args — including the rollout issue body carrying the milestone-derived
# test-focus titles.
# =============================================================================
origin_bare="$work/origin.git"
git init -q --bare "$origin_bare"

repo_f="$work/repo-f"
seed_fixture "$repo_f"
git -C "$repo_f" remote add origin "$origin_bare"
git -C "$repo_f" push -q origin main

install_fake_bot_gh "$repo_f"
gh_log_f="$work/gh-calls-f.log"
: > "$gh_log_f"

out_f="$(run_release_real "$repo_f" "$gh_log_f" v1.2.0 --issue 501 --repo acme/repo 2>&1)"
rc_f=$?

check "scenario F: exits 0" [ "$rc_f" -eq 0 ]

check "scenario F: (a) version-bump commit landed (HEAD subject)" bash -c '
  [ "$(git -C "$1" log -1 --pretty=%s)" = "release: v1.2.0" ]
' _ "$repo_f"
check "scenario F: (a) plugin.json version bump is IN the commit, not just on disk" bash -c '
  git -C "$1" show HEAD:.claude/.claude-plugin/plugin.json | grep -q "\"version\": \"1.2.0\""
' _ "$repo_f"
check "scenario F: (a) marketplace.json version bump is IN the commit" bash -c '
  git -C "$1" show HEAD:.claude/.claude-plugin/marketplace.json | grep -q "\"version\": \"1.2.0\""
' _ "$repo_f"

check "scenario F: (b) tag v1.2.0 was actually created locally" bash -c 'git -C "$1" tag --list | grep -qx v1.2.0' _ "$repo_f"

check "scenario F: (c) push actually reached the bare origin (main branch commit)" bash -c '
  [ "$(git -C "$1" log -1 --pretty=%s refs/heads/main)" = "release: v1.2.0" ]
' _ "$origin_bare"
check "scenario F: (c) push actually reached the bare origin (tag)" bash -c 'git -C "$1" tag --list | grep -qx v1.2.0' _ "$origin_bare"

check "scenario F: (d) milestone-close API call fired against the resolved milestone number" bash -c '
  grep -qF "api -X PATCH repos/acme/repo/milestones/77 -f state=closed" "$1"
' _ "$gh_log_f"
check "scenario F: (d) all three rollout labels created idempotently via gh api" bash -c '
  grep -qF "labels -f name=feedback" "$1" &&
  grep -qF "labels -f name=from:redeploy" "$1" &&
  grep -qF "labels -f name=from:redefi" "$1"
' _ "$gh_log_f"
check "scenario F: (d) rollout issue created with the right title and feedback label" bash -c '
  grep -qF "issue create" "$1" &&
  grep -qF "Rollout & feedback: v1.2.0" "$1" &&
  grep -qF -- "--label feedback" "$1"
' _ "$gh_log_f"
check "scenario F: rollout issue body carries the milestone-derived test-focus titles" bash -c '
  grep -qF "Fix widget alignment" "$1" && grep -qF "Add gizmo support" "$1"
' _ "$gh_log_f"

# =============================================================================
# Scenario G: REAL path with NO --issue given — the milestone-close step must
# warn-and-skip (never crash, never guess a milestone), while the rollout
# companion issue is STILL filed (it does not depend on milestone
# resolution), falling back to the "titles unavailable" test-focus note.
# =============================================================================
origin_bare_g="$work/origin-g.git"
git init -q --bare "$origin_bare_g"

repo_g="$work/repo-g"
seed_fixture "$repo_g"
git -C "$repo_g" remote add origin "$origin_bare_g"
git -C "$repo_g" push -q origin main

install_fake_bot_gh "$repo_g"
gh_log_g="$work/gh-calls-g.log"
: > "$gh_log_g"

out_g="$(run_release_real "$repo_g" "$gh_log_g" v1.3.0 --repo acme/repo 2>&1)"
rc_g=$?

check "scenario G: exits 0 even though no --issue was given" [ "$rc_g" -eq 0 ]
check "scenario G: warns that no milestone was resolved / not closed automatically" bash -c '
  printf "%s" "$1" | grep -qi "no milestone resolved"
' _ "$out_g"
check "scenario G: milestone-close API call was NEVER made (nothing to resolve it from)" bash -c '
  ! grep -q "milestones/" "$1"
' _ "$gh_log_g"
check "scenario G: rollout issue is STILL filed regardless of milestone resolution" bash -c '
  grep -qF "issue create" "$1" && grep -qF "Rollout & feedback: v1.3.0" "$1"
' _ "$gh_log_g"
check "scenario G: test-focus list falls back to the titles-unavailable note" bash -c '
  grep -qF "milestone issue titles unavailable" "$1"
' _ "$gh_log_g"
check "scenario G: version was still bumped and pushed for real (only milestone-close is skipped)" bash -c '
  [ "$(git -C "$1" log -1 --pretty=%s refs/heads/main)" = "release: v1.3.0" ] &&
  git -C "$1" tag --list | grep -qx v1.3.0
' _ "$origin_bare_g"

# =============================================================================
# Scenario H: MIXED merge-commit and squash-merge history in one range — the
# exact shape of this repo's real v0.3.0..v0.3.1 range, and the regression that
# motivated the --first-parent generator. Before the fix, the presence of ANY
# merge commit made release.sh discard every squash-merged PR: the real range
# generated 2 bullets instead of 7. Both styles must now be represented, and
# the merge-committed PR must still contribute exactly one bullet.
# =============================================================================
repo_h="$work/repo-h"
seed_fixture "$repo_h"
git -C "$repo_h" -c tag.gpgSign=false tag v1.0.0

# (a) a merge-committed PR, with an internal commit that must NOT be listed
git -C "$repo_h" checkout -q -b feat/merged-style
echo "m" > "$repo_h/m.txt"
git -C "$repo_h" add m.txt
git -C "$repo_h" commit -q -m "internal: implementation detail of the merged PR"
git -C "$repo_h" checkout -q main
git -C "$repo_h" merge -q --no-ff -m "Merge pull request #90 from robercano/feat/merged-style" feat/merged-style

# (b) two squash-merged PRs — single commits on main, GitHub's "(#N)" subject
echo "s1" > "$repo_h/s1.txt"
git -C "$repo_h" add s1.txt
git -C "$repo_h" commit -q -m "fix(notify): use https:// in the ntfy notify command (#91)"
echo "s2" > "$repo_h/s2.txt"
git -C "$repo_h" add s2.txt
git -C "$repo_h" commit -q -m "feat(server): support multiple agent users on one box (#92)"

out_h="$(run_release "$repo_h" v1.4.0 --dry-run)"
rc_h=$?

check "scenario H: exits 0" [ "$rc_h" -eq 0 ]
changelog_h="$(cat "$repo_h/.claude/.claude-plugin/CHANGELOG.md")"
check "scenario H: merge-committed PR #90 is listed" bash -c 'printf "%s" "$1" | grep -q -- "- #90: feat/merged-style"' _ "$changelog_h"
check "scenario H: squash-merged PR #91 is listed despite a merge commit in range" bash -c '
  printf "%s" "$1" | grep -q -- "- fix(notify): use https:// in the ntfy notify command (#91)"
' _ "$changelog_h"
check "scenario H: squash-merged PR #92 is listed despite a merge commit in range" bash -c '
  printf "%s" "$1" | grep -q -- "- feat(server): support multiple agent users on one box (#92)"
' _ "$changelog_h"
check "scenario H: the merged PR's internal commit is not double-listed" bash -c '
  ! printf "%s" "$1" | grep -q -- "- internal: implementation detail"
' _ "$changelog_h"
check "scenario H: the 1.4.0 section holds exactly 3 bullets (one per landed change)" bash -c '
  n=$(printf "%s\n" "$1" | awk "/^## \[1\.4\.0\]/{s=1;next} s&&/^## \[/{s=0} s&&/^- /{c++} END{print c+0}")
  [ "$n" -eq 3 ]
' _ "$changelog_h"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "release.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "release.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
