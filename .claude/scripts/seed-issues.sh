#!/usr/bin/env bash
# seed-issues.sh — bootstrap a module-labeled ticket backlog as GitHub Issues.
#
# EXAMPLE / STARTING POINT. Labels are derived automatically from the `modules`
# in .claude/gates.json (module:<name>) plus type:feature / type:infra. The
# TICKETS section at the bottom is a placeholder — replace it with your backlog.
#
# Idempotent: existing labels are reused; an issue whose exact title already
# exists is skipped, so re-running won't create duplicates.
#
# Prereq: `gh auth login` completed for this repo, and `node` on PATH.
# Usage:  bash .claude/scripts/seed-issues.sh
set -uo pipefail

command -v gh   >/dev/null 2>&1 || { echo "gh not on PATH (try: export PATH=\"\$HOME/.local/bin:\$PATH\")"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node not on PATH"; exit 1; }
gh auth status  >/dev/null 2>&1 || { echo "Not authenticated. Run: gh auth login"; exit 1; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gates="$root/.claude/gates.json"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
echo "Seeding issues into ${REPO:-<current repo>}"

# --- labels: one module:<name> per module in gates.json, plus type:* ---------
mapfile -t modules < <(node -e "try{const g=require('$gates');(g.modules||[]).forEach(m=>console.log(m.name))}catch(e){}")
declare -a palette=(1d76db 0e8a16 5319e7 fbca04 d4c5f9 c2e0c6 bfd4f2 fef2c0 c5def5 f9d0c4)
i=0
for m in "${modules[@]}"; do
  [ -z "$m" ] && continue
  gh label create "module:$m" --color "${palette[$((i % ${#palette[@]}))]}" --description "Work scoped to the $m module" --force >/dev/null 2>&1 \
    && echo "  label ✓ module:$m" || echo "  label … module:$m (exists)"
  i=$((i+1))
done
gh label create "type:feature" --color 0052cc --description "Feature work scoped to one module" --force >/dev/null 2>&1 && echo "  label ✓ type:feature" || true
gh label create "type:infra"   --color b60205 --description "Repo-wide tooling/infra (touches root config)" --force >/dev/null 2>&1 && echo "  label ✓ type:infra" || true

# --- helper: create an issue unless an exact-title match already exists -------
existing="$(gh issue list --state all --limit 500 --json title -q '.[].title' 2>/dev/null)"
mkissue() {
  local title="$1" labels="$2" body="$3"
  if grep -Fxq "$title" <<<"$existing"; then echo "  skip (exists): $title"; return; fi
  gh issue create --title "$title" --label "$labels" --body "$body" >/dev/null \
    && echo "  created: $title" || echo "  FAILED: $title"
}

BOUND="**Module boundary:** stay within this module's path; do not edit other modules or shared root config (re-scope through the orchestrator if needed)."

# ============================ TICKETS ========================================
# Replace the lines below with your real backlog. One mkissue per ticket:
#   mkissue "<title>" "<comma,separated,labels>" "<body>"
# Keep each ticket scoped to ONE module so workers get non-overlapping boundaries.

if [ "${#modules[@]}" -gt 0 ] && [ -n "${modules[0]}" ]; then
  mkissue "[${modules[0]}] EXAMPLE — replace with a real ticket" "module:${modules[0]},type:feature" \
"This is a placeholder created by seed-issues.sh to show the pattern. Delete it and add your own.

$BOUND

**Acceptance**
- <what 'done' looks like — builds/lints/types/tests pass, coverage ≥ threshold, reviewers approve>"
else
  echo "  (no modules in gates.json yet — fill in 'modules' then add tickets here)"
fi

echo "Done."
