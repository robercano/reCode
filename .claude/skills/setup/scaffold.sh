#!/usr/bin/env bash
# scaffold.sh — idempotent FILE materialization for `/orchestrator:setup` (issue #37).
#
# This script does ONLY the non-interactive, non-network file work: copy user-owned
# templates if absent, re-stamp the managed workflow file, install CI templates if
# absent, fix up .gitignore, and ensure .claude/state/ exists. The interview, gh
# calls (labels, bot verification), and PR-loop/harden offers stay in prose in
# SKILL.md — this script never shells out to `gh` and never touches the network.
#
# Usage:
#   scaffold.sh [target-repo-root]
#
# target-repo-root defaults to the current working directory. Pass an explicit path
# (e.g. a $TMPDIR scratch dir) to dry-run against a throwaway target instead of a
# real checkout — this is how the idempotency demo in the setup skill is run.
#
# Exit code: 0 on success. Prints a per-file action summary (created / kept /
# restamped / up to date / appended).
set -euo pipefail

# --- Resolve paths ----------------------------------------------------------------
# Template dir is relative to THIS script, so it resolves correctly whether invoked
# from an installed plugin root ($CLAUDE_PLUGIN_ROOT/skills/setup/scaffold.sh) or a
# plain .claude/skills/setup/scaffold.sh checkout.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
templates_dir="$script_dir/templates"

target_root="${1:-$PWD}"
mkdir -p "$target_root"
target_root="$(cd "$target_root" && pwd)"

# Single source of truth for the managed workflow's version. Bump this whenever
# templates/feature-fanout.js's behavior changes; scaffold.sh will then re-stamp any
# destination whose marker is older (see issue #38, which drives re-stamping on
# plugin upgrade).
MANAGED_VERSION=1
MARKER_PREFIX="@orchestrator-managed feature-fanout v"

echo "orchestrator setup: scaffolding into $target_root"

# --- helpers ------------------------------------------------------------------------
copy_if_absent() {
  # $1 = template path, $2 = destination path, $3 = label for the summary line
  local src="$1" dst="$2" label="$3"
  if [ -e "$dst" ]; then
    echo "  kept:      $label ($dst already exists — user-owned, left untouched)"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  echo "  created:   $label -> $dst"
}

managed_version_of() {
  # Prints the version number found in the marker line of $1, or empty if none.
  local f="$1"
  [ -f "$f" ] || { echo ""; return 0; }
  grep -o "${MARKER_PREFIX}[0-9]\+" "$f" 2>/dev/null | head -1 | grep -o '[0-9]\+$' || true
}

# --- 1. user-owned files: create only if absent, never overwritten -----------------
copy_if_absent "$templates_dir/gates.json" "$target_root/.claude/gates.json" "project adapter (.claude/gates.json)"
copy_if_absent "$templates_dir/CLAUDE.md"  "$target_root/CLAUDE.md"          "CLAUDE.md"

# --- 2. managed workflow: re-stamp when the destination's marker is older ----------
fanout_dst="$target_root/.claude/workflows/feature-fanout.js"
existing_version="$(managed_version_of "$fanout_dst")"
if [ ! -f "$fanout_dst" ]; then
  mkdir -p "$(dirname "$fanout_dst")"
  cp "$templates_dir/feature-fanout.js" "$fanout_dst"
  echo "  created:   managed workflow (.claude/workflows/feature-fanout.js) at v$MANAGED_VERSION"
elif [ -z "$existing_version" ]; then
  # Present but carries no recognizable marker (e.g. hand-authored or pre-marker file)
  # — treat as older than any managed version and re-stamp.
  cp "$templates_dir/feature-fanout.js" "$fanout_dst"
  echo "  restamped: managed workflow (.claude/workflows/feature-fanout.js) — no marker found, now v$MANAGED_VERSION"
elif [ "$existing_version" -lt "$MANAGED_VERSION" ]; then
  cp "$templates_dir/feature-fanout.js" "$fanout_dst"
  echo "  restamped: managed workflow (.claude/workflows/feature-fanout.js) v$existing_version -> v$MANAGED_VERSION"
elif [ "$existing_version" -eq "$MANAGED_VERSION" ]; then
  echo "  up to date: managed workflow (.claude/workflows/feature-fanout.js) already v$MANAGED_VERSION"
else
  # Destination carries a NEWER version than this scaffold.sh ships — never clobber.
  echo "  kept:      managed workflow (.claude/workflows/feature-fanout.js) is v$existing_version, newer than this installer's v$MANAGED_VERSION — left untouched"
fi

# --- 3. CI templates: create only if absent ----------------------------------------
copy_if_absent "$templates_dir/gates.yml"  "$target_root/.github/workflows/gates.yml"      "CI gate workflow (.github/workflows/gates.yml)"
copy_if_absent "$templates_dir/action.yml" "$target_root/.github/actions/setup/action.yml" "CI setup action (.github/actions/setup/action.yml)"

# --- 4. .gitignore hygiene: append-if-missing, never duplicate ---------------------
gitignore="$target_root/.gitignore"
touch "$gitignore"
required_entries=(
  ".env"
  ".env.*"
  "!.env.example"
  ".claude/settings.local.json"
  ".claude/state/"
)
appended=()
for entry in "${required_entries[@]}"; do
  if grep -qxF -- "$entry" "$gitignore"; then
    continue
  fi
  printf '%s\n' "$entry" >> "$gitignore"
  appended+=("$entry")
done
if [ "${#appended[@]}" -gt 0 ]; then
  echo "  appended:  .gitignore <- ${appended[*]}"
else
  echo "  kept:      .gitignore already has all required entries"
fi

# --- 5. runtime state dir ------------------------------------------------------------
mkdir -p "$target_root/.claude/state"
echo "  ensured:   .claude/state/"

echo "orchestrator setup: scaffold complete."
