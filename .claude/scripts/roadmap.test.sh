#!/usr/bin/env bash
# roadmap.test.sh — offline smoke test for roadmap.sh (issue #175).
#
# Runs the generator against controlled FIXTURE milestones/issues/PRs/branches
# JSON (never live gh/network — see roadmap.sh's --fixtures mode), then
# asserts:
#   - open milestones render in NATURAL version order (v1.0.0 < v1.2.0 <
#     v1.10.0 — a plain string sort would get this wrong),
#   - state derivation per issue: closed / in_flight / "PR#N open" / open,
#   - the "Blocked by" edges render as a Mermaid graph,
#   - the "Feedback inbox" section lists only unmilestoned, open,
#     `feedback`-labeled issues,
#   - the top-of-file GENERATED/do-not-edit marker is present,
#   - --write persists to disk while the default mode only prints to stdout,
#   - the gh/network-unavailable degrade path never crashes the script.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/roadmap.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
roadmap="$script_dir/roadmap.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/roadmap-test.XXXXXX")"
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

# ---------------------------------------------------------------------------
# 1. Full fixture run: milestone ordering, state derivation, mermaid edges,
#    feedback inbox, generated marker.
# ---------------------------------------------------------------------------
mkdir -p "$work/fixtures"
cat_json() { printf '%s' "$1"; }

cat > "$work/fixtures/milestones.json" <<'EOF'
[
  {"number":1,"title":"v1.0.0","open_issues":1,"closed_issues":1,"state":"open"},
  {"number":2,"title":"v1.10.0","open_issues":1,"closed_issues":0,"state":"open"},
  {"number":3,"title":"v1.2.0","open_issues":0,"closed_issues":0,"state":"open"},
  {"number":4,"title":"v0.9.0 (done)","open_issues":0,"closed_issues":5,"state":"closed"}
]
EOF
cat > "$work/fixtures/issues.json" <<'EOF'
[
  {"number":10,"title":"Feature A <script>alert(1)</script>","url":"https://example.com/10","labels":[{"name":"module:harness"},{"name":"priority:critical"}],"body":"Blocked by #11","milestone":{"title":"v1.0.0"},"state":"OPEN"},
  {"number":11,"title":"Foundation piece","url":"https://example.com/11","labels":[{"name":"module:harness"}],"body":"","milestone":{"title":"v1.0.0"},"state":"CLOSED"},
  {"number":20,"title":"Feature B (has a PR)","url":"https://example.com/20","labels":[{"name":"module:docs"},{"name":"priority:low"}],"body":"","milestone":{"title":"v1.10.0"},"state":"OPEN"},
  {"number":21,"title":"Plain open issue, no branch no PR","url":"https://example.com/21","labels":[{"name":"module:docs"}],"body":"","milestone":{"title":"v1.10.0"},"state":"OPEN"},
  {"number":30,"title":"Unmilestoned feedback item","url":"https://example.com/30","labels":[{"name":"feedback"}],"body":"","milestone":null,"state":"OPEN"},
  {"number":31,"title":"Closed feedback item (must not appear)","url":"https://example.com/31","labels":[{"name":"feedback"}],"body":"","milestone":null,"state":"CLOSED"},
  {"number":32,"title":"Unmilestoned but no feedback label (must not appear)","url":"https://example.com/32","labels":[],"body":"","milestone":null,"state":"OPEN"},
  {"number":40,"title":"Milestoned feedback item (must not appear in inbox)","url":"https://example.com/40","labels":[{"name":"feedback"}],"body":"","milestone":{"title":"v1.10.0"},"state":"OPEN"}
]
EOF
cat > "$work/fixtures/prs.json" <<'EOF'
[
  {"number":99,"title":"Ship feature B","url":"https://example.com/pr/99","headRefName":"feat/issue-20-featureb"}
]
EOF
cat > "$work/fixtures/branches.json" <<'EOF'
["main","feat/issue-10-feature-a","remotes/origin/fix/issue-999-stale"]
EOF

out="$(ROADMAP_NOW="2026-01-01T00:00:00Z" bash "$roadmap" --fixtures "$work/fixtures")"

check "generated/do-not-edit marker at top of output" bash -c 'printf "%s\n" "$1" | head -1 | grep -q "GENERATED FILE"' _ "$out"
check "closed milestone (v0.9.0) is NOT rendered" bash -c '! printf "%s\n" "$1" | grep -q "v0.9.0"' _ "$out"

# Milestone ordering: v1.0.0 must appear before v1.2.0, which must appear
# before v1.10.0 (natural/version order, NOT plain string sort which would
# put "v1.10.0" before "v1.2.0").
check "milestones render in natural version order (v1.0.0 < v1.2.0 < v1.10.0)" node -e '
  const out = process.argv[1];
  const i0 = out.indexOf("## v1.0.0");
  const i2 = out.indexOf("## v1.2.0");
  const i10 = out.indexOf("## v1.10.0");
  if (i0 < 0 || i2 < 0 || i10 < 0) process.exit(1);
  if (!(i0 < i2 && i2 < i10)) process.exit(1);
' "$out"

# State derivation.
check "issue #10 (branch exists, no PR) derives in_flight" bash -c 'printf "%s\n" "$1" | grep -q "#10.*in_flight"' _ "$out"
check "issue #11 (state CLOSED) derives closed" bash -c 'printf "%s\n" "$1" | grep -q "#11.*closed"' _ "$out"
check "issue #20 (open PR #99 matches branch) derives PR#99 open" bash -c 'printf "%s\n" "$1" | grep -q "#20.*PR#99 open"' _ "$out"
check "issue #21 (no branch, no PR) derives plain open" bash -c 'printf "%s\n" "$1" | grep -qE "#21\b.*\| open \|"' _ "$out"

# Priority chip.
check "issue #10 shows a critical priority chip" bash -c 'printf "%s\n" "$1" | grep -q "critical"' _ "$out"
check "issue #21 (unprioritized) shows no chip (em-dash placeholder)" bash -c 'printf "%s\n" "$1" | grep -E "#21\b" | grep -q "| — |"' _ "$out"

# Mermaid blocking-graph edge for #11 -> #10.
check "mermaid code fence present" bash -c 'printf "%s\n" "$1" | grep -q "\`\`\`mermaid"' _ "$out"
check "mermaid edge I11 --> I10 (11 blocks 10) rendered" bash -c 'printf "%s\n" "$1" | grep -q "I11.*-->.*I10"' _ "$out"
check "milestone with zero issues (v1.2.0) has no mermaid block of its own (no edges)" node -e '
  const out = process.argv[1];
  const start = out.indexOf("## v1.2.0");
  const end = out.indexOf("## v1.10.0");
  const section = out.slice(start, end);
  if (section.includes("```mermaid")) process.exit(1);
' "$out"

# Feedback inbox: only open + feedback-labeled + unmilestoned.
check "feedback inbox section header present" bash -c 'printf "%s\n" "$1" | grep -q "## Feedback inbox"' _ "$out"
check "feedback inbox lists #30 (open, feedback, unmilestoned)" bash -c '
  section=$(printf "%s\n" "$1" | sed -n "/## Feedback inbox/,\$p")
  printf "%s\n" "$section" | grep -q "#30"
' _ "$out"
check "feedback inbox EXCLUDES #31 (closed)" bash -c '
  section=$(printf "%s\n" "$1" | sed -n "/## Feedback inbox/,\$p")
  ! printf "%s\n" "$section" | grep -q "#31"
' _ "$out"
check "feedback inbox EXCLUDES #32 (no feedback label)" bash -c '
  section=$(printf "%s\n" "$1" | sed -n "/## Feedback inbox/,\$p")
  ! printf "%s\n" "$section" | grep -q "#32"
' _ "$out"
check "feedback inbox EXCLUDES #40 (has a milestone)" bash -c '
  section=$(printf "%s\n" "$1" | sed -n "/## Feedback inbox/,\$p")
  ! printf "%s\n" "$section" | grep -q "#40"
' _ "$out"

# Footer.
check "footer carries the timestamp and commit sha" bash -c 'printf "%s\n" "$1" | grep -q "Generated 2026-01-01T00:00:00Z .* commit"' _ "$out"

# XSS/escaping smoke: table pipes in a title must not break the table shape
# (a literal "|" would corrupt the row) -- titles here don't contain "|", but
# newline-stripping is asserted instead (Markdown, not HTML, so no <script>
# escaping is required the way cockpit.sh's HTML output needs it).
check "title with embedded HTML-looking text renders inline, doesn't break the table row" bash -c 'printf "%s\n" "$1" | grep -q "Feature A <script>alert(1)</script>"' _ "$out"

# ---------------------------------------------------------------------------
# 2. --write persists to disk; default (no --write) mode does not.
# ---------------------------------------------------------------------------
write_out="$work/written/ROADMAP.md"
bash "$roadmap" --fixtures "$work/fixtures" --write "$write_out" >/dev/null
check "--write creates the output file" test -f "$write_out"
check "--write output also carries the generated marker" bash -c 'head -1 "$1" | grep -q "GENERATED FILE"' _ "$write_out"

no_write_out="$work/should-not-exist/ROADMAP.md"
bash "$roadmap" --fixtures "$work/fixtures" "$no_write_out" >/dev/null
check "default (no --write) mode does NOT create a file even when given a path arg" bash -c '[ ! -f "$1" ]' _ "$no_write_out"

# ---------------------------------------------------------------------------
# 3. Empty fixtures dir (no milestones/issues at all): degrades to a clean
#    "no open milestones" / "no unmilestoned feedback issues" render, never a
#    crash, and exits 0.
# ---------------------------------------------------------------------------
mkdir -p "$work/empty"
if out_empty="$(bash "$roadmap" --fixtures "$work/empty" 2>&1)"; then
  rc_empty=0
else
  rc_empty=$?
fi
check "empty fixtures dir exits 0" bash -c '[ "$1" -eq 0 ]' _ "$rc_empty"
check "empty fixtures dir renders 'No open milestones'" bash -c 'printf "%s\n" "$1" | grep -q "No open milestones"' _ "$out_empty"
check "empty fixtures dir renders 'No unmilestoned feedback issues'" bash -c 'printf "%s\n" "$1" | grep -q "No unmilestoned feedback issues"' _ "$out_empty"

# ---------------------------------------------------------------------------
# 4. gh/network-unavailable degrade path: ROADMAP_GH_BIN stubbed to fail every
#    call. Must still exit 0 and render "unavailable" placeholders instead of
#    crashing (mirrors cockpit.sh's own degrade contract).
#    NOTE (issue #175 review finding #5): unlike every other case in this
#    suite, this one does NOT pass --fixtures, so roadmap.sh's branch-listing
#    step falls through to a REAL, un-stubbed `git -C "$root" branch -a
#    --list` against this actual checkout (there is no ROADMAP_BRANCHES_BIN
#    seam to stub it, only ROADMAP_GH_BIN for milestones/issues/PRs). This is
#    harmless -- read-only, no network, no mutation -- but it does mean this
#    one assertion isn't fully hermetic; called out here rather than adding a
#    new stub seam just for this.
# ---------------------------------------------------------------------------
fail_gh="$work/fail-gh.sh"
cat > "$fail_gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$fail_gh"
if out_unavail="$(ROADMAP_GH_BIN="$fail_gh" ROADMAP_REPO="acme/repo" bash "$roadmap" 2>&1)"; then
  rc_unavail=0
else
  rc_unavail=$?
fi
check "gh-unavailable path exits 0 (never crashes)" bash -c '[ "$1" -eq 0 ]' _ "$rc_unavail"
check "gh-unavailable path renders an 'unavailable' placeholder" bash -c 'printf "%s\n" "$1" | grep -q "unavailable"' _ "$out_unavail"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "roadmap.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "roadmap.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
