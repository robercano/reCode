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

# --- managed-file table -------------------------------------------------------------
# "template-name|dest-relpath|marker-prefix" — one entry per file scaffold.sh manages
# going forward (re-stamped, never silently clobbered once at/above the shipped
# version). shipped_version is read straight out of EACH TEMPLATE's own marker line
# (managed_version_of, below) rather than a separately hand-maintained constant — see
# sync.sh's `managed_version_of` comment for why keeping those in two places invites
# drift (issue #102 generalized this from the single-entry feature-fanout-only form).
# Adding a new managed file is exactly one more line here, plus the matching line in
# sync.sh's MANAGED_FILES table and a row in templates/MANIFEST.md.
MANAGED_FILES=(
  "feature-fanout.js|.claude/workflows/feature-fanout.js|@orchestrator-managed feature-fanout v"
  "pr-loop.service|.claude/systemd/pr-loop.service|@orchestrator-managed pr-loop-service v"
  "claude-rc.service|.claude/systemd/claude-rc.service|@orchestrator-managed claude-rc-service v"
  "arm-loop.sh|.claude/scripts/arm-loop.sh|@orchestrator-managed arm-loop v"
)

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
  # Prints the version number found in $1's marker line (matched via the literal
  # marker prefix $2), or empty if no marker line / the file doesn't exist.
  local f="$1" prefix="$2"
  [ -f "$f" ] || { echo ""; return 0; }
  grep -F -- "$prefix" "$f" 2>/dev/null | head -1 | grep -o '[0-9]\+$' || true
}

# --- 1. user-owned files: create only if absent, never overwritten -----------------
copy_if_absent "$templates_dir/gates.json" "$target_root/.claude/gates.json" "project adapter (.claude/gates.json)"
copy_if_absent "$templates_dir/CLAUDE.md"  "$target_root/CLAUDE.md"          "CLAUDE.md"

# --- 2. managed files: create if absent, re-stamp when the destination's marker is
#        older than the template's own, never downgrade a newer local marker --------
for entry in "${MANAGED_FILES[@]}"; do
  IFS='|' read -r tmpl_name dest_rel marker_prefix <<<"$entry"
  template="$templates_dir/$tmpl_name"
  dst="$target_root/$dest_rel"
  label="managed file ($dest_rel)"

  shipped_version="$(managed_version_of "$template" "$marker_prefix")"
  if [ -z "$shipped_version" ]; then
    echo "  error:     $label — shipped template $template has no valid @orchestrator-managed marker; plugin install looks broken" >&2
    continue
  fi

  existing_version="$(managed_version_of "$dst" "$marker_prefix")"
  if [ ! -f "$dst" ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$template" "$dst"
    case "$tmpl_name" in *.sh) chmod +x "$dst" ;; esac
    echo "  created:   $label at v$shipped_version"
  elif [ -z "$existing_version" ]; then
    # Present but carries no recognizable marker (e.g. hand-authored or pre-marker
    # file) — treat as older than any managed version and re-stamp.
    cp "$template" "$dst"
    case "$tmpl_name" in *.sh) chmod +x "$dst" ;; esac
    echo "  restamped: $label — no marker found, now v$shipped_version"
  elif [ "$existing_version" -lt "$shipped_version" ]; then
    cp "$template" "$dst"
    case "$tmpl_name" in *.sh) chmod +x "$dst" ;; esac
    echo "  restamped: $label v$existing_version -> v$shipped_version"
  elif [ "$existing_version" -eq "$shipped_version" ]; then
    echo "  up to date: $label already v$shipped_version"
  else
    # Destination carries a NEWER version than this scaffold.sh ships — never clobber.
    echo "  kept:      $label is v$existing_version, newer than this installer's v$shipped_version — left untouched"
  fi
done

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
