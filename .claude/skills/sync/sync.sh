#!/usr/bin/env bash
# sync.sh — idempotent, offline RECONCILE for `/orchestrator:sync` (issue #38).
#
# This is the sibling of `.claude/skills/setup/scaffold.sh`. scaffold.sh creates files
# the first time (`/orchestrator:setup`); sync.sh brings already-created MANAGED files
# up to date after a plugin update, using the same `@orchestrator-managed <name> vN`
# marker convention scaffold.sh stamps. It never creates a missing managed file (that's
# setup's job — creating implies opting the repo in) and it NEVER touches user-owned
# files. This script does ONLY non-interactive, non-network comparison/copy work — the
# prose flow (explaining results, offering to merge a conflict) lives in SKILL.md.
#
# Usage:
#   sync.sh [target-repo-root]
#
# target-repo-root defaults to the current working directory. Pass an explicit path
# (e.g. a $TMPDIR scratch dir) to dry-run against a throwaway target instead of a real
# checkout — this is how the idempotency/conflict demo in the sync skill is run.
#
# Exit code: 0 on success. A `conflict` verdict is reported, not treated as a script
# failure — deciding what to do about it is a human/SKILL.md decision, not sync.sh's.
# Prints a per-file action summary (missing / up to date / restamped / conflict / kept
# / user-owned-skipped).
set -euo pipefail

# --- Resolve paths ----------------------------------------------------------------
# Templates and MANAGED_VERSION are read from the sibling `setup` skill so both scripts
# share one single source of truth: sync.sh must re-stamp with the exact same pristine
# bytes scaffold.sh would have written, and use the exact same version number.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
templates_dir="$script_dir/../setup/templates"
scaffold_sh="$script_dir/../setup/scaffold.sh"

target_root="${1:-$PWD}"
target_root="$(cd "$target_root" && pwd)"

echo "orchestrator sync: reconciling managed files in $target_root"

# --- single source of truth: read MANAGED_VERSION out of scaffold.sh ---------------
# Do NOT hardcode a second version number here — that would create two sources of
# truth that could drift apart. Instead, parse the same `MANAGED_VERSION=N` line
# scaffold.sh defines, so bumping it in one place (scaffold.sh) is picked up by sync.sh
# automatically on the next run.
feature_fanout_version="$(sed -n 's/^MANAGED_VERSION=\([0-9][0-9]*\).*/\1/p' "$scaffold_sh" 2>/dev/null | head -1)"
if [ -z "$feature_fanout_version" ]; then
  echo "sync.sh: could not read MANAGED_VERSION from $scaffold_sh — plugin install looks broken" >&2
  exit 1
fi

# --- managed-file table -------------------------------------------------------------
# One entry per managed file: "template-name|dest-relpath|marker-prefix|shipped-version"
# Adding a future managed file is exactly one more line here (plus, if it needs its own
# version counter, wiring that counter's source of truth the same way as above).
MANAGED_FILES=(
  "feature-fanout.js|.claude/workflows/feature-fanout.js|@orchestrator-managed feature-fanout v|$feature_fanout_version"
)

# --- user-owned files: NEVER written by sync, only reported for visibility ---------
USER_OWNED_FILES=(
  ".claude/gates.json"
  "CLAUDE.md"
  ".claude/settings.local.json"
  ".claude/state/"
)

# --- helpers ------------------------------------------------------------------------
managed_version_of() {
  # Prints the version number found in $1's marker line (matched via the literal
  # marker prefix $2), or empty if no marker line / the file doesn't exist.
  local f="$1" prefix="$2"
  [ -f "$f" ] || { echo ""; return 0; }
  grep -F -- "$prefix" "$f" 2>/dev/null | head -1 | grep -o '[0-9]\+$' || true
}

strip_marker_line() {
  # Prints $1's content with any line containing the literal marker prefix $2 removed.
  # Used to normalize before diffing "installed" against "pristine template": the
  # marker line legitimately differs by version number alone even when nothing else
  # changed, so the version bump itself must never count as a "local edit".
  local f="$1" prefix="$2"
  grep -vF -- "$prefix" "$f" 2>/dev/null || true
}

has_local_edits() {
  # $1 = installed file, $2 = pristine template shipped by this plugin, $3 = marker
  # prefix.
  #
  # Local-edit detection mechanism (documented explicitly, since the plugin only ships
  # ONE pristine version — the current one — so a true three-way merge base isn't
  # available): strip the marker line from both the installed file and the shipped
  # template, then compare what's left byte-for-byte. Any residual difference is
  # treated as a local edit. This is deliberately conservative — a whitespace-only
  # tweak still counts as "diverged" — because the cost of a false "conflict" is a
  # human glance at a diff, while the cost of a false "safe to restamp" is silently
  # destroying someone's hand-edit. Never trade the latter for convenience.
  local installed="$1" template="$2" prefix="$3"
  local a b
  a="$(strip_marker_line "$installed" "$prefix")"
  b="$(strip_marker_line "$template" "$prefix")"
  [ "$a" != "$b" ]
}

# --- 1. managed files: compare marker version + content, act per the ladder below --
for entry in "${MANAGED_FILES[@]}"; do
  IFS='|' read -r tmpl_name dest_rel marker_prefix shipped_version <<<"$entry"
  template="$templates_dir/$tmpl_name"
  dest="$target_root/$dest_rel"

  if [ ! -f "$template" ]; then
    echo "  error:      $dest_rel — no shipped template at $template; plugin install looks broken"
    continue
  fi

  if [ ! -f "$dest" ]; then
    # Sync does not create managed files — creating one is an opt-in decision that
    # belongs to /orchestrator:setup, not to a silent background reconcile.
    echo "  missing:    $dest_rel — not present; run /orchestrator:setup to create it"
    continue
  fi

  installed_version="$(managed_version_of "$dest" "$marker_prefix")"
  # No recognizable marker at all is treated as "version 0" (older than anything the
  # plugin ships), so it flows through the same ladder below rather than a special case.
  [ -z "$installed_version" ] && installed_version=0

  if [ "$installed_version" -gt "$shipped_version" ]; then
    # Never downgrade a file that's newer than what this installer ships.
    echo "  kept:       $dest_rel is v$installed_version, newer than this plugin's v$shipped_version — left untouched"
    continue
  fi

  if [ "$installed_version" -eq "$shipped_version" ]; then
    if has_local_edits "$dest" "$template" "$marker_prefix"; then
      # Same marker version but content still diverges from pristine — inconsistent
      # state (e.g. someone hand-edited without bumping the marker). Flag rather than
      # trust the marker blindly.
      echo "  conflict:   $dest_rel is marked v$installed_version but content diverges from the pristine v$shipped_version template — needs-merge, left untouched"
    else
      echo "  up to date: $dest_rel already v$shipped_version"
    fi
    continue
  fi

  # installed_version < shipped_version
  if has_local_edits "$dest" "$template" "$marker_prefix"; then
    echo "  conflict:   $dest_rel is v$installed_version (behind v$shipped_version) AND has local edits — needs-merge, left untouched"
  else
    cp "$template" "$dest"
    echo "  restamped:  $dest_rel v$installed_version -> v$shipped_version"
  fi
done

# --- 2. user-owned files: report only, never write ----------------------------------
for f in "${USER_OWNED_FILES[@]}"; do
  echo "  user-owned — skipped by design: $f"
done

echo "orchestrator sync: reconcile complete."
