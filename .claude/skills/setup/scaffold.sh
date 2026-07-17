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

# --- 2b. runtime harness vendor: keep the consumer session-start critical path OFF the
#         plugin (issue #128) -------------------------------------------------------
# A Claude Code plugin loads (and pays its load cost, ~18s for this one) on EVERY session
# start if it's enabled, regardless of how its hooks are wired — so the only way to remove
# that cost from the consumer's runtime path is to stop depending on the plugin being loaded
# at all once setup is done. This copies the plugin's own runtime subtrees — `agents/`,
# `commands/`, `hooks/`, `scripts/`, `skills/` — wholesale from the plugin root into the
# consumer's local `.claude/`, so a session reads them straight off disk with the plugin
# disabled. The plugin is then only needed to RUN `/orchestrator:setup`/`/orchestrator:sync`
# (the install/update channel), not for everyday sessions.
#
# Managed as ONE unit (not one marker per file, since the whole tree moves together): a
# single top-level version stamp file, `.claude/.orchestrator-vendor`, gates the copy using
# the exact same managed_version_of marker-ladder as the MANAGED_FILES loop above.
#
# EXCEPTION: `.claude/scripts/arm-loop.sh` is skipped by this copy — it already has its own
# dedicated row in MANAGED_FILES above (canonical shipped copy: templates/arm-loop.sh, which
# gets `__WORKDIR__`-style placeholders substituted at ARM time and can legitimately differ
# from THIS plugin repo's own live self-hosting copy of arm-loop.sh). Vendoring it a second
# time here would create two divergent sources of truth for the same destination path.
VENDOR_DIRS=(agents commands hooks scripts skills)
VENDOR_MARKER_PREFIX="@orchestrator-managed runtime-vendor v"
plugin_root="$(cd "$script_dir/../.." && pwd)"
vendor_marker_src="$plugin_root/.orchestrator-vendor"
vendor_marker_dst="$target_root/.claude/.orchestrator-vendor"
vendor_label="runtime harness vendor (.claude/{agents,commands,hooks,scripts,skills})"

copy_vendor_dirs() {
  # Prune-then-copy of each VENDOR_DIRS subtree's CONTENTS (not the subtree itself) from
  # the plugin root into target_root/.claude, preserving executable bits (cp -a). This must
  # be idempotent AND pruning: a plain `cp -a src dst` when dst already EXISTS nests the
  # source dir inside it (src becomes dst/src) instead of refreshing it in place — that's
  # exactly the bug this replaced (a restamp/upgrade run used to leave duplicate nests like
  # .claude/skills/setup/setup and never actually update changed files). Removing the
  # destination subtree first and then copying the source's CONTENTS (`src/.` -> `dst/`)
  # both fixes the nesting and prunes files removed upstream, so a later `diff -rq` never
  # trips on stale leftovers.
  #
  # EXCEPTION: `.claude/scripts/arm-loop.sh` must survive this — it already has its own
  # dedicated MANAGED_FILES row (canonical template: templates/arm-loop.sh) and must NOT be
  # vendored/overwritten from this plugin repo's own live copy. Back it up before pruning
  # `scripts/`, then restore it (or remove whatever the plugin copy dropped in its place if
  # there was nothing to restore) after the copy.
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

vendor_shipped_version="$(managed_version_of "$vendor_marker_src" "$VENDOR_MARKER_PREFIX")"
if [ -z "$vendor_shipped_version" ]; then
  echo "  error:     $vendor_label — shipped marker $vendor_marker_src has no valid @orchestrator-managed marker; plugin install looks broken" >&2
elif [ "$plugin_root" = "$target_root/.claude" ]; then
  # Running the already-vendored copy of scaffold.sh directly (CLAUDE_PLUGIN_ROOT unset, so
  # the ${CLAUDE_PLUGIN_ROOT:-.claude} fallback resolved to this repo's own .claude) — there
  # is no distinct plugin root to vendor FROM, so there's nothing safe to do here.
  echo "  kept:      $vendor_label — running from an already-vendored copy, no distinct plugin root to vendor from; enable the plugin and re-run to pull updates"
else
  vendor_existing_version="$(managed_version_of "$vendor_marker_dst" "$VENDOR_MARKER_PREFIX")"
  if [ ! -f "$vendor_marker_dst" ]; then
    copy_vendor_dirs
    echo "  created:   $vendor_label at v$vendor_shipped_version"
  elif [ -z "$vendor_existing_version" ]; then
    copy_vendor_dirs
    echo "  restamped: $vendor_label — no marker found, now v$vendor_shipped_version"
  elif [ "$vendor_existing_version" -lt "$vendor_shipped_version" ]; then
    copy_vendor_dirs
    echo "  restamped: $vendor_label v$vendor_existing_version -> v$vendor_shipped_version"
  elif [ "$vendor_existing_version" -eq "$vendor_shipped_version" ]; then
    echo "  up to date: $vendor_label already v$vendor_shipped_version"
  else
    echo "  kept:      $vendor_label is v$vendor_existing_version, newer than this installer's v$vendor_shipped_version — left untouched"
  fi
fi

# --- 2c. consumer settings.json: user-owned from birth, create only if absent -------
# Unlike gates.json/CLAUDE.md (also user-owned), this template must NEVER be silently
# considered "just another user-owned file" without comment: it carries the runtime hook
# wiring (PostToolUse lint + log-worker-tool, Stop test_affected, PreToolUse guard-git-add)
# that used to depend on the plugin's hooks/hooks.json (which only fires while the plugin is
# loaded). If the consumer already has a settings.json (likely — it may carry their own
# enabledPlugins/extraKnownMarketplaces while installing/updating), scaffold.sh leaves it
# completely untouched; SKILL.md instructs merging the runtime hooks in by hand in that case.
copy_if_absent "$templates_dir/settings.json" "$target_root/.claude/settings.json" "consumer runtime settings (.claude/settings.json)"

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
