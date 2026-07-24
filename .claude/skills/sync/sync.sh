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
# Issue #141 ("sync v2") extends this offline contract with four more DETECT-AND-REPORT
# checks (deploy-lag, environment, missing-labels, observability-plumbing) — same
# philosophy as detect_stale_vendor_copies below: read-only, never mutate anything that
# isn't sync's to manage, exit 0 for every diagnostic. Anything that needs the network
# (bot identity, label creation) is NOT run here — sync.sh only prints the exact advisory
# command; the live step is documented in SKILL.md and executed by the agent via
# bot-gh.sh, never inline in this script.
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

# Minimum plugin version the issue #141 environment check requires — this IS "the #136
# release" (issue #136 shipped as plugin version 0.2.2). Bump this alongside any future
# release that the sync v2 environment check should start requiring.
MIN_PLUGIN_VERSION="0.2.2"

# --- stale-vendor detection (issue #134) --------------------------------------------
# Prior to issue #134, this plugin vendored its own runtime subtrees — `agents/`,
# `commands/`, `hooks/`, `scripts/`, `skills/` — wholesale into a consumer's local
# `.claude/` (issue #128), gated by a single marker file `.claude/.orchestrator-vendor`.
# That model was reverted: consumer repos no longer carry local copies of these
# directories at all — agents/commands/hooks/scripts/skills are read straight from the
# plugin cache (`${CLAUDE_PLUGIN_ROOT}`), which stays the single source of truth. Sync
# does NOT delete anything on a consumer's behalf (a local copy might be a deliberate,
# legitimate override, not just stale leftovers) — it only DETECTS AND WARNS, see
# `detect_stale_vendor_copies` below. This also covers a repo that was vendored under
# the old #128 model and never cleaned up (e.g. reDeploy, the motivating case for #134).
STALE_VENDOR_DIRS=(agents commands hooks scripts skills)
LEGACY_VENDOR_MARKER_REL=".claude/.orchestrator-vendor"
plugin_root="$(cd "$script_dir/../.." && pwd)"

# self-hosting: this plugin's OWN repo running sync.sh against itself, i.e. plugin_root
# resolves to $target_root/.claude. In that case .claude/{agents,commands,hooks,scripts,
# skills} ARE the plugin's own legitimately-tracked canonical source directories, not
# vendored copies of anything — stale-vendor detection must stay completely silent (no
# warning, no migration caveat) rather than flag the plugin's own tree as a leftover.
self_hosting=0
[ "$plugin_root" = "$target_root/.claude" ] && self_hosting=1

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

detect_stale_vendor_copies() {
  # Issue #134: detect (never delete) local copies of the directories this plugin used to
  # vendor (issue #128). For each STALE_VENDOR_DIRS entry present under $target_root/.claude,
  # classify it:
  #   - identical to the plugin's own shipped copy (diff -rq, excluding arm-loop.sh — see
  #     the MANAGED_FILES row for why that one file is separately managed and can
  #     legitimately differ) -> "stale", almost certainly safe to delete: it just shadows
  #     the plugin cache (resolve-roots.sh deliberately makes a repo-tracked
  #     `.claude/scripts` layout win over `${CLAUDE_PLUGIN_ROOT}`, so a stale copy silently
  #     wins over a freshly-updated plugin install).
  #   - diverges from the plugin's shipped copy -> "conflict", flagged as a POSSIBLE
  #     deliberate local override rather than assumed-safe-to-delete — same conservative
  #     philosophy as has_local_edits: a false "conflict" costs a human a glance at a diff,
  #     a false "safe to delete" can silently destroy someone's local fix.
  # Self-hosting short-circuit: when this plugin's own repo runs sync.sh against itself
  # ($self_hosting=1, computed above from plugin_root/target_root), .claude/{agents,
  # commands,hooks,scripts,skills} ARE the plugin's own canonical source, not vendored
  # copies of anything — skip the whole detect-and-warn body and report "none found" so
  # self-hosted runs never flag (or suggest deleting) the plugin's own tree.
  # Returns 0 if any stale directory was found (so the caller can print the migration
  # caveat once), 1 if none were found (including the self-hosting short-circuit).
  local d dst extra any_found=0
  if [ "$self_hosting" -eq 1 ]; then
    return 1
  fi
  for d in "${STALE_VENDOR_DIRS[@]}"; do
    dst="$target_root/.claude/$d"
    [ -d "$dst" ] || continue
    if [ "$d" = "scripts" ]; then
      # .claude/scripts/arm-loop.sh is its OWN managed row (see MANAGED_FILES) and is
      # expected to exist here even with vendoring stopped — only flag scripts/ as a
      # stale-vendor leftover if it holds anything ELSE.
      extra="$(find "$dst" -mindepth 1 -maxdepth 1 ! -name arm-loop.sh -print -quit 2>/dev/null)"
      [ -n "$extra" ] || continue
    fi
    any_found=1
    if [ ! -d "$plugin_root/$d" ]; then
      echo "  stale-vendor: .claude/$d — present locally; this repo no longer vendors the runtime harness (issue #134) — verify it's not just a leftover from an old vendored install before relying on it"
    elif diff -rq -x arm-loop.sh "$plugin_root/$d" "$dst" >/dev/null 2>&1; then
      echo "  stale-vendor: .claude/$d — matches the plugin's shipped copy byte-for-byte; this repo no longer vendors the runtime harness (issue #134), so this local copy only shadows the plugin cache — safe to delete (sync will not delete it for you)"
    else
      echo "  stale-vendor conflict: .claude/$d — diverges from the plugin's shipped copy — this MAY be a deliberate local override rather than a stale leftover; review the diff yourself (e.g. diff -rq \"$plugin_root/$d\" \"$dst\") before deciding whether to delete it — sync will never delete it for you"
    fi
  done
  return $((1 - any_found))
}

# --- deploy-lag / loop-runs.log check (issue #141 item 5) ---------------------------
# The stale-vendor migration caveat above tells the operator to restart the pr-loop/
# claude-rc systemd units after cleaning up — but ONLY between drivers (a running driver
# holds its old script in memory; killing it mid-run wastes/loses work). This function
# gives that decision an offline signal: read $target_root/.claude/state/loop-runs.log
# (the run ledger loop-daemon.sh appends one line per driver to, `ts=<ISO8601>` field)
# and report how long ago the last driver ran. Report-only — never mutates anything,
# never restarts anything itself — exit 0 always.
check_deploy_lag() {
  local log="$target_root/.claude/state/loop-runs.log"
  if [ ! -f "$log" ]; then
    echo "  deploy-lag: .claude/state/loop-runs.log — not found; loop does not look armed here (nothing to check before a restart, but confirm with the operator before assuming that)"
    return 0
  fi
  local last_line
  last_line="$(tail -n 1 "$log" 2>/dev/null || true)"
  if [ -z "$last_line" ]; then
    echo "  deploy-lag: .claude/state/loop-runs.log — present but empty; no driver runs recorded yet, restarting the loop units now should be safe"
    return 0
  fi
  echo "  deploy-lag: .claude/state/loop-runs.log — last recorded run: $last_line"
  local last_ts
  last_ts="$(printf '%s' "$last_line" | grep -o 'ts=[^ ]*' | head -1 | cut -d= -f2 || true)"
  if [ -z "$last_ts" ]; then
    echo "  deploy-lag: could not parse a ts= field from the last entry — inspect the file yourself before restarting"
    return 0
  fi
  local last_epoch now_epoch age_s
  last_epoch="$(date -u -d "$last_ts" +%s 2>/dev/null || true)"
  if [ -z "$last_epoch" ]; then
    echo "  deploy-lag: could not parse timestamp \"$last_ts\" — inspect the file yourself before restarting"
    return 0
  fi
  now_epoch="$(date -u +%s)"
  age_s=$((now_epoch - last_epoch))
  if [ "$age_s" -lt 0 ]; then age_s=0; fi
  if [ "$age_s" -lt 300 ]; then
    echo "  deploy-lag: last driver run started ~${age_s}s ago — a driver may still be ACTIVE; re-arm/restart the pr-loop/claude-rc systemd units ONLY BETWEEN drivers (issue #131) — wait and re-check loop-runs.log before restarting"
  else
    echo "  deploy-lag: last driver run started ~${age_s}s ago and the loop looks idle — looks safe to re-arm/restart the pr-loop/claude-rc systemd units now (issue #131); still worth a final glance at loop-runs.log before pulling the trigger"
  fi
}

# --- version compare helper (issue #141 item 2) --------------------------------------
version_ge() {
  # $1 = actual dotted version (e.g. "0.2.2"), $2 = minimum required (e.g. "0.2.2").
  # Component-wise numeric compare, reusing is_sane_version's bounded-digit discipline
  # per component so a malformed/non-numeric component (e.g. a "-beta" suffix) degrades
  # to "unknown" (return 2) instead of a wrong lexical/numeric compare.
  # Returns: 0 = actual >= min, 1 = actual < min, 2 = unparseable.
  local actual="$1" min="$2"
  local -a a_parts m_parts
  IFS='.' read -r -a a_parts <<<"$actual"
  IFS='.' read -r -a m_parts <<<"$min"
  local len=${#a_parts[@]}
  [ "${#m_parts[@]}" -gt "$len" ] && len=${#m_parts[@]}
  local i=0 av mv
  while [ "$i" -lt "$len" ]; do
    av="${a_parts[$i]:-0}"
    mv="${m_parts[$i]:-0}"
    is_sane_version "$av" || return 2
    is_sane_version "$mv" || return 2
    if [ "$av" -gt "$mv" ]; then return 0; fi
    if [ "$av" -lt "$mv" ]; then return 1; fi
    i=$((i + 1))
  done
  return 0
}

# --- environment check (issue #141 item 2) --------------------------------------------
# Offline parts only: (a) does $target_root/.env exist and carry a GH_BOT_TOKEN=
# assignment (grep for the KEY only — the value is NEVER read/printed); (b) is the
# installed plugin (plugin_root, resolved above — works identically in self-host and
# plugin-cache layouts) at >= MIN_PLUGIN_VERSION. The live bot-identity/repo-access check
# needs the network, so this function only PRINTS the exact advisory command for the
# agent to run via bot-gh.sh (SKILL.md documents that live step) — it never runs it here.
check_environment() {
  local env_file="$target_root/.env"
  if [ ! -f "$env_file" ]; then
    echo "  env: .env — not found at $target_root/.env; GH_BOT_TOKEN cannot be verified offline (see .claude/scripts/bot-gh.sh setup notes)"
  elif grep -qE '^GH_BOT_TOKEN=' "$env_file" 2>/dev/null; then
    echo "  env: .env — GH_BOT_TOKEN= assignment found (value not inspected)"
  else
    echo "  env: .env — present but no GH_BOT_TOKEN= assignment found; bot-gh.sh calls will fail until it's added"
  fi

  local plugin_json="$plugin_root/.claude-plugin/plugin.json"
  if [ ! -f "$plugin_json" ]; then
    echo "  env: plugin version — cannot read $plugin_json; plugin install looks unusual"
  else
    local installed_version
    installed_version="$(node -e '
      try {
        const p = require(process.argv[1]);
        process.stdout.write(typeof p.version === "string" ? p.version : "");
      } catch (e) { process.stdout.write(""); }
    ' "$plugin_json" 2>/dev/null || true)"
    if [ -z "$installed_version" ]; then
      echo "  env: plugin version — could not parse a \"version\" field from $plugin_json"
    else
      local vge_rc=0
      version_ge "$installed_version" "$MIN_PLUGIN_VERSION" || vge_rc=$?
      case "$vge_rc" in
        0) echo "  env: plugin version — v$installed_version >= required v$MIN_PLUGIN_VERSION (the issue #136 release) — OK" ;;
        1) echo "  env: plugin version — v$installed_version is BELOW required v$MIN_PLUGIN_VERSION (the issue #136 release) — update the plugin before relying on sync v2 behavior" ;;
        *) echo "  env: plugin version — could not compare \"$installed_version\" against \"$MIN_PLUGIN_VERSION\" (unexpected format) — verify manually" ;;
      esac
    fi
  fi

  echo "  env: ADVISORY (live, network — not run by sync.sh) — verify bot identity + repo access: bash \${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh api user --jq .login   (and a 'repo view' on this repo)"
}

# --- missing-labels check (issue #141 item 3) -----------------------------------------
# Offline: derive the expected label set from the TARGET's adapter (module:<name> per
# .claude/gates.json modules[].name, plus needs-human) and print the exact create
# commands — same pattern as .claude/skills/setup/SKILL.md's "Create the module +
# approval labels" step. Never queries GitHub and never creates anything itself; SKILL.md
# documents the agent-performed live step (query which labels exist via bot-gh.sh,
# create only the missing ones).
derive_module_labels() {
  # Prints "module:<name><TAB><description>" per module, or nothing (exit 1) if no
  # adapter parses. Honors $GATES_FILE (same convention as gate.sh), relative to
  # $target_root; falls back to .claude/gates.json.
  local gates_ref="${GATES_FILE:-.claude/gates.json}"
  local gates_path
  case "$gates_ref" in
    /*) gates_path="$gates_ref" ;;
    *) gates_path="$target_root/$gates_ref" ;;
  esac
  [ -f "$gates_path" ] || return 1
  node -e '
    try {
      const g = require(process.argv[1]);
      if (!g || !Array.isArray(g.modules)) process.exit(1);
      for (const m of g.modules) {
        if (m && m.name) process.stdout.write("module:" + m.name + "\t" + (m.description || "") + "\n");
      }
    } catch (e) { process.exit(1); }
  ' "$gates_path" 2>/dev/null
}

check_missing_labels() {
  local labels rc=0
  labels="$(derive_module_labels)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$labels" ]; then
    echo "  labels: cannot derive labels — no adapter found (checked \$GATES_FILE, .claude/gates.json)"
    return 0
  fi
  if [ "$self_hosting" -eq 1 ]; then
    # Self-hosting: this repo's own module/needs-human labels are already owner-managed —
    # printing "create these" advisories every run would be pure noise (design intent:
    # an advisory that implies remediation degrades to a quiet verdict in self-host).
    echo "  labels: self-hosting — skipping the module/needs-human label advisory (this repo's own labels are already managed by the owner)"
    return 0
  fi
  echo "  labels: ADVISORY (live, network — not run by sync.sh) — query existing labels via bot-gh.sh, then create only what's missing:"
  local name desc
  while IFS=$'\t' read -r name desc; do
    [ -n "$name" ] || continue
    echo "  labels:   bash \${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh label create \"$name\" --description \"$desc\" --force"
  done <<<"$labels"
  echo "  labels:   bash \${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh label create \"needs-human\" --description \"Loop is blocked on owner judgment -- see the issue/PR body/comments\" --color b60205 --force"
}

# --- observability-plumbing check (issue #141 item 4, cf. issue #137) -----------------
# DETECT don't fix: stat the two state files worker-tool/event observability lands in and
# report present-with-activity / present-but-empty / absent. Never attempts to ship the
# #137 hook itself — that's out of scope here, this only tells the human the gap exists.
check_observability_plumbing() {
  local f path lines mtime now age_h
  for f in worker-tools.jsonl events.jsonl; do
    path="$target_root/.claude/state/$f"
    if [ ! -f "$path" ]; then
      echo "  observability: .claude/state/$f — absent; this is the observability gap tracked by issue #137 (worker-tool-mirror hook not yet wired into this repo) — sync does not fix this, only reports it"
    elif [ -s "$path" ]; then
      lines="$(wc -l <"$path" 2>/dev/null | tr -d '[:space:]')"
      mtime="$(stat -c %Y "$path" 2>/dev/null || true)"
      if [ -n "$mtime" ]; then
        now="$(date -u +%s)"
        age_h=$(( (now - mtime) / 3600 ))
        echo "  observability: .claude/state/$f — present, $lines line(s), last modified ~${age_h}h ago — looks wired up"
      else
        echo "  observability: .claude/state/$f — present, $lines line(s) — looks wired up"
      fi
    else
      echo "  observability: .claude/state/$f — present but empty; no events recorded yet (freshly created, or the issue #137 gap) — worth a human glance"
    fi
  done
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

# --- 1b. stale-vendor detection: never restamp/delete, only detect + warn (issue #134) --
if detect_stale_vendor_copies; then
  legacy_marker="$target_root/$LEGACY_VENDOR_MARKER_REL"
  if [ -f "$legacy_marker" ]; then
    echo "  stale-vendor: $LEGACY_VENDOR_MARKER_REL — legacy vendor marker from the old #128 model found; this repo is a leftover of a vendored install"
  fi
  echo "  stale-vendor: found local .claude/{agents,commands,hooks,scripts,skills} copies — this plugin stopped vendoring these (issue #134); once you've reconciled the flagged directories above (deleted the safe-to-delete ones, kept/upstreamed any genuine local override), also remove $LEGACY_VENDOR_MARKER_REL if present"
  echo "  stale-vendor: MIGRATION CAVEAT — a running pr-loop/claude-rc systemd unit holds its OLD script in memory until its unit restarts; refreshing/deleting files on disk is not enough. After cleaning up, run: systemctl --user restart pr-loop-<repo-slug>.service claude-rc-<repo-slug>.service (cf. the 2026-07-16 reCode deploy-lag incident, issue #131)"
elif [ "$self_hosting" -eq 1 ]; then
  # Self-hosting: stay completely silent — no stale-vendor line, no stray-marker check, no
  # migration caveat. This is the plugin's own tree; there is nothing to reconcile.
  echo "  stale-vendor: none found — .claude/{agents,commands,hooks,scripts,skills} are not vendored locally (as expected; served from \${CLAUDE_PLUGIN_ROOT})"
else
  # No stale vendor DIRECTORIES were found, but a consumer may have deleted those by hand
  # and left a stray legacy marker file behind — warn about that leftover too (detect and
  # warn only; sync never deletes it for the operator).
  legacy_marker="$target_root/$LEGACY_VENDOR_MARKER_REL"
  if [ -f "$legacy_marker" ]; then
    echo "  stale-vendor: $LEGACY_VENDOR_MARKER_REL — legacy vendor marker from the old #128 model found, but no stale vendor directories are present; remove this stray marker file"
  fi
  echo "  stale-vendor: none found — .claude/{agents,commands,hooks,scripts,skills} are not vendored locally (as expected; served from \${CLAUDE_PLUGIN_ROOT})"
fi

# --- 1c. deploy-lag / environment / labels / observability checks (issue #141) -------
echo "  --- deploy-lag ---"
check_deploy_lag
echo "  --- environment ---"
check_environment
echo "  --- labels ---"
check_missing_labels
echo "  --- observability ---"
check_observability_plumbing

# --- 2. user-owned files: report only, never write ----------------------------------
for f in "${USER_OWNED_FILES[@]}"; do
  echo "  user-owned — skipped by design: $f"
done

if [ "$had_broken_install" -eq 1 ]; then
  echo "orchestrator sync: reconcile finished with errors — see 'error:' lines above; plugin install looks broken." >&2
  exit 1
fi

echo "orchestrator sync: reconcile complete."
