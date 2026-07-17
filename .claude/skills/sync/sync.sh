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
# Exit code: 0 on success (including a `conflict` verdict — deciding what to do about
# a conflict is a human/SKILL.md decision, not sync.sh's). Nonzero (1) if the plugin
# install itself looks broken — a shipped template is missing or carries no valid
# version marker (see the `error:` action below). A malformed/oversized version marker
# on an INSTALLED file is a per-file `conflict`, not a broken-install error, so it does
# not by itself change the exit code.
# Prints a per-file action summary (missing / up to date / restamped / conflict / kept
# / user-owned-skipped / error).
set -euo pipefail

# --- Resolve paths ----------------------------------------------------------------
# Templates live in the sibling `setup` skill so sync.sh re-stamps with the exact same
# pristine bytes scaffold.sh would have written.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
templates_dir="$script_dir/../setup/templates"

target_root="${1:-$PWD}"
target_root="$(cd "$target_root" && pwd)"

echo "orchestrator sync: reconciling managed files in $target_root"

# --- single source of truth: the TEMPLATE's own marker line, not scaffold.sh --------
# The byte sequence that actually lands on disk on a restamp is the literal marker line
# inside the template file (e.g. `// @orchestrator-managed feature-fanout v1`), NOT
# scaffold.sh's `MANAGED_VERSION=N` shell variable. Those used to be two independently
# maintained numbers that could drift apart (e.g. someone bumps MANAGED_VERSION without
# updating the template's marker comment, or vice versa). If they drift, restamping
# from "shipped_version = scaffold.sh's MANAGED_VERSION" while the template itself still
# carries the OLD marker means the freshly-restamped file's on-disk marker no longer
# equals the version sync.sh believes it just wrote — so the very next run sees the file
# as "behind" again and restamps it forever, breaking the idempotency contract.
#
# Reading shipped_version directly out of the template file (via `managed_version_of`,
# the same helper used below for the installed file) makes this inherently idempotent:
# after a restamp, installed marker == template marker by construction (it's a
# byte-for-byte `cp`), so the next run always reports "up to date". There is
# deliberately NO parse of scaffold.sh anywhere in this script.

# --- managed-file table -------------------------------------------------------------
# One entry per managed file: "template-name|dest-relpath|marker-prefix"
#
# marker-prefix MUST match the `@orchestrator-managed <name> v` convention scaffold.sh
# stamps (scaffold.sh hardcodes its own copy of this string as MARKER_PREFIX). The two
# scripts are coupled on this format string by necessity — both write/read the same
# on-disk marker — so keep them in sync if the convention ever changes. Adding a future
# managed file is exactly one more line here; its shipped_version is derived below
# straight from its own template, so there is nothing else to wire up.
MANAGED_FILES=(
  "feature-fanout.js|.claude/workflows/feature-fanout.js|@orchestrator-managed feature-fanout v"
  "pr-loop.service|.claude/systemd/pr-loop.service|@orchestrator-managed pr-loop-service v"
  "claude-rc.service|.claude/systemd/claude-rc.service|@orchestrator-managed claude-rc-service v"
  "arm-loop.sh|.claude/scripts/arm-loop.sh|@orchestrator-managed arm-loop v"
)

# --- runtime harness vendor: ONE managed unit, not a row in MANAGED_FILES (issue #128) --
# Unlike everything in MANAGED_FILES above (a single template file -> single destination
# file), the runtime harness vendor is a whole-TREE copy — the plugin's own `agents/`,
# `commands/`, `hooks/`, `scripts/`, `skills/` subtrees, copied wholesale from the plugin
# root (not from templates_dir) into the consumer's `.claude/`. It is gated by ONE
# top-level marker file, `.claude/.orchestrator-vendor`, reusing the exact same
# managed_version_of ladder as MANAGED_FILES, just applied to a directory-tree copy
# instead of a single `cp`. See scaffold.sh's matching "runtime harness vendor" section
# and `.claude/skills/setup/templates/MANIFEST.md` for the full rationale.
#
# EXCEPTION: `.claude/scripts/arm-loop.sh` is excluded from this tree copy/diff — it is
# already a MANAGED_FILES row above with its own canonical template (`templates/arm-loop.sh`,
# placeholder-substituted at ARM time), which can legitimately differ from this plugin
# repo's own live self-hosting copy of arm-loop.sh. Double-managing the same destination
# path from two different pristine sources would make the two mechanisms disagree about
# what "up to date" even means for that one file.
VENDOR_DIRS=(agents commands hooks scripts skills)
VENDOR_MARKER_PREFIX="@orchestrator-managed runtime-vendor v"
plugin_root="$(cd "$script_dir/../.." && pwd)"
vendor_marker_src="$plugin_root/.orchestrator-vendor"
vendor_marker_dst="$target_root/.claude/.orchestrator-vendor"
vendor_dest_rel=".claude/{agents,commands,hooks,scripts,skills}"

# --- user-owned files: NEVER written by sync, only reported for visibility ---------
USER_OWNED_FILES=(
  ".claude/gates.json"
  "CLAUDE.md"
  ".claude/settings.json"
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

is_sane_version() {
  # Bounded sane-integer check: 1-9 digits (covers up to 999,999,999 — comfortably more
  # than any real version counter will ever reach). This guards against a malformed or
  # absurdly oversized marker (e.g. a 20+ digit number) reaching the `-gt`/`-eq`
  # integer comparisons below: under `set -e`, a `[ "$x" -gt "$y" ]` with a non-integer
  # or too-large operand fails with "integer expression expected", but because that
  # failure happens inside an `if` condition, `set -e` does NOT abort the script — the
  # comparison just evaluates false. Both the `-gt` (newer) and `-eq` (up to date)
  # guards would then silently evaluate false, and control would fall through to the
  # "installed_version < shipped_version" branch, restamping (i.e. potentially
  # DOWNGRADING) a file whose marker only looked newer because it was malformed. Every
  # parsed version — installed AND shipped/template — is validated with this before
  # it's used in an integer comparison.
  local v="$1"
  [[ "$v" =~ ^[0-9]{1,9}$ ]]
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

has_local_edits_vendor() {
  # Directory-tree analog of has_local_edits, used only for the runtime harness vendor
  # (issue #128): recursively diffs each VENDOR_DIRS subtree between the installed
  # .claude/ and the plugin root's own .claude/, excluding arm-loop.sh (separately
  # managed — see the EXCEPTION comment on VENDOR_DIRS above). Any residual difference —
  # including an extra locally-added file — counts as a local edit, same conservative
  # philosophy as has_local_edits.
  local installed_claude="$1" plugin_claude="$2" d
  for d in "${VENDOR_DIRS[@]}"; do
    [ -d "$plugin_claude/$d" ] || continue
    if ! diff -rq -x arm-loop.sh "$plugin_claude/$d" "$installed_claude/$d" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

copy_vendor_dirs() {
  # Prune-then-copy of each VENDOR_DIRS subtree's CONTENTS (not the subtree itself) from
  # the plugin root into $target_root/.claude, preserving executable bits (cp -a). Mirrors
  # scaffold.sh's copy_vendor_dirs exactly — see that function's comment for why a plain
  # `cp -a src dst` on an already-existing dst nests instead of refreshing (the bug this
  # replaced: a restamp used to leave duplicate nests like .claude/skills/sync/sync and
  # never actually update changed files), and why removing the destination subtree first
  # then copying the source's CONTENTS (`src/.` -> `dst/`) both fixes the nesting and prunes
  # files removed upstream.
  #
  # EXCEPTION: `.claude/scripts/arm-loop.sh` must survive this — it already has its own
  # dedicated MANAGED_FILES row and must NOT be vendored/overwritten from this plugin
  # repo's own live copy. Back it up before pruning `scripts/`, then restore it (or remove
  # whatever the plugin copy dropped in its place if there was nothing to restore) after.
  local d arm_backup=""
  for d in "${VENDOR_DIRS[@]}"; do
    [ -d "$plugin_root/$d" ] || continue
    if [ "$d" = "scripts" ] && [ -f "$target_root/.claude/scripts/arm-loop.sh" ]; then
      arm_backup="$(mktemp "${TMPDIR:-/tmp}/arm-loop.sh.XXXXXX")"
      cp -a "$target_root/.claude/scripts/arm-loop.sh" "$arm_backup"
    fi
    rm -rf "$target_root/.claude/$d"
    mkdir -p "$target_root/.claude/$d"
    cp -a "$plugin_root/$d/." "$target_root/.claude/$d/"
    if [ "$d" = "scripts" ]; then
      if [ -n "$arm_backup" ]; then
        cp -a "$arm_backup" "$target_root/.claude/scripts/arm-loop.sh"
        rm -f "$arm_backup"
        arm_backup=""
      else
        rm -f "$target_root/.claude/scripts/arm-loop.sh"
      fi
    fi
  done
  cp "$vendor_marker_src" "$vendor_marker_dst"
}

# --- 1. managed files: compare marker version + content, act per the ladder below --
had_broken_install=0

for entry in "${MANAGED_FILES[@]}"; do
  IFS='|' read -r tmpl_name dest_rel marker_prefix <<<"$entry"
  template="$templates_dir/$tmpl_name"
  dest="$target_root/$dest_rel"

  if [ ! -f "$template" ]; then
    echo "  error:      $dest_rel — no shipped template at $template; plugin install looks broken" >&2
    had_broken_install=1
    continue
  fi

  shipped_version="$(managed_version_of "$template" "$marker_prefix")"
  if ! is_sane_version "$shipped_version"; then
    echo "  error:      $dest_rel — shipped template $template has no valid @orchestrator-managed marker (got \"$shipped_version\"); plugin install looks broken" >&2
    had_broken_install=1
    continue
  fi

  if [ ! -f "$dest" ]; then
    # Sync does not create managed files — creating one is an opt-in decision that
    # belongs to /orchestrator:setup, not to a silent background reconcile.
    echo "  missing:    $dest_rel — not present; run /orchestrator:setup to create it"
    continue
  fi

  installed_version="$(managed_version_of "$dest" "$marker_prefix")"
  if [ -z "$installed_version" ]; then
    # No recognizable marker at all is treated as "version 0" (older than anything the
    # plugin ships), so it flows through the same ladder below rather than a special case.
    installed_version=0
  elif ! is_sane_version "$installed_version"; then
    # Malformed/oversized marker on the INSTALLED file — never let this reach the
    # integer comparisons below (see is_sane_version's comment for why that's unsafe).
    # Treat it like any other divergent-content case: flag for a human, don't restamp.
    echo "  conflict:   $dest_rel has a malformed or out-of-range version marker (\"$installed_version\") — needs-merge, left untouched"
    continue
  fi

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

# --- 1b. runtime harness vendor: same ladder, applied to a whole tree via ONE marker ---
if [ ! -d "$plugin_root/agents" ]; then
  echo "  error:      $vendor_dest_rel — no shipped plugin root at $plugin_root; plugin install looks broken" >&2
  had_broken_install=1
elif [ "$plugin_root" = "$target_root/.claude" ]; then
  # Running the vendored copy of sync.sh directly (CLAUDE_PLUGIN_ROOT unset, so the
  # ${CLAUDE_PLUGIN_ROOT:-.claude} fallback resolved to this repo's own .claude) — there is
  # no distinct plugin root to re-vendor FROM.
  echo "  kept:       $vendor_dest_rel — running from an already-vendored copy, no distinct plugin root to re-vendor from; enable the plugin and re-run to pull updates"
else
  vendor_shipped_version="$(managed_version_of "$vendor_marker_src" "$VENDOR_MARKER_PREFIX")"
  if ! is_sane_version "$vendor_shipped_version"; then
    echo "  error:      $vendor_dest_rel — shipped marker $vendor_marker_src has no valid @orchestrator-managed marker (got \"$vendor_shipped_version\"); plugin install looks broken" >&2
    had_broken_install=1
  elif [ ! -f "$vendor_marker_dst" ]; then
    echo "  missing:    $vendor_dest_rel — not present; run /orchestrator:setup to create it"
  else
    vendor_installed_version="$(managed_version_of "$vendor_marker_dst" "$VENDOR_MARKER_PREFIX")"
    if [ -z "$vendor_installed_version" ]; then
      vendor_installed_version=0
    elif ! is_sane_version "$vendor_installed_version"; then
      echo "  conflict:   $vendor_dest_rel has a malformed or out-of-range version marker (\"$vendor_installed_version\") — needs-merge, left untouched"
      vendor_installed_version=""
    fi

    if [ -n "$vendor_installed_version" ]; then
      if [ "$vendor_installed_version" -gt "$vendor_shipped_version" ]; then
        echo "  kept:       $vendor_dest_rel is v$vendor_installed_version, newer than this plugin's v$vendor_shipped_version — left untouched"
      elif [ "$vendor_installed_version" -eq "$vendor_shipped_version" ]; then
        if has_local_edits_vendor "$target_root/.claude" "$plugin_root"; then
          echo "  conflict:   $vendor_dest_rel is marked v$vendor_installed_version but content diverges from the pristine v$vendor_shipped_version tree — needs-merge, left untouched"
        else
          echo "  up to date: $vendor_dest_rel already v$vendor_shipped_version"
        fi
      else
        # vendor_installed_version < vendor_shipped_version
        if has_local_edits_vendor "$target_root/.claude" "$plugin_root"; then
          echo "  conflict:   $vendor_dest_rel is v$vendor_installed_version (behind v$vendor_shipped_version) AND has local edits — needs-merge, left untouched"
        else
          copy_vendor_dirs
          echo "  restamped:  $vendor_dest_rel v$vendor_installed_version -> v$vendor_shipped_version"
        fi
      fi
    fi
  fi
fi

# --- 2. user-owned files: report only, never write ----------------------------------
for f in "${USER_OWNED_FILES[@]}"; do
  echo "  user-owned — skipped by design: $f"
done

if [ "$had_broken_install" -eq 1 ]; then
  echo "orchestrator sync: reconcile finished with errors — see 'error:' lines above; plugin install looks broken." >&2
  exit 1
fi

echo "orchestrator sync: reconcile complete."
