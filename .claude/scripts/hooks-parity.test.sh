#!/usr/bin/env bash
# hooks-parity.test.sh — offline smoke test for the hooks-parity check
# (issue #140) added to self/checks.sh's `do_hooks_parity` (run as
# part of `do_build`, and therefore under `gate.sh build`/`gate.sh test`).
#
# Asserts:
#   1. Born-green: the check PASSES against the real repo's
#      .claude/settings.json / .claude/hooks/hooks.json, with
#      log-worker-tool.sh's deliberate self-only entry allowlisted.
#   2. Fail-on-divergence: feeding the check a synthetic hooks.json missing
#      a non-allowlisted settings.json hook makes it fail (non-zero).
#   3. Fail-on-divergence (other direction): feeding the check a synthetic
#      hooks.json with an extra hook absent from settings.json also fails.
#
# Uses the HOOKS_SETTINGS_FILE / HOOKS_PLUGIN_FILE env-var seam in checks.sh
# to point at hermetic temp-dir fixtures instead of mutating real repo files.
# No gh/network. Exit 0 on success, non-zero if any assertion fails. Runnable
# bare:
#   bash .claude/scripts/hooks-parity.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
checks_sh="$repo_root/self/checks.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/hooks-parity-test.XXXXXX")"
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
# 1. Born-green: real repo files pass as-is.
# ---------------------------------------------------------------------------
check "check passes on the real repo settings.json/hooks.json (born-green)" \
  bash "$checks_sh" build

# ---------------------------------------------------------------------------
# 2. Synthetic divergence: settings.json has a non-allowlisted hook that
#    hooks.json lacks -> the check must fail.
# ---------------------------------------------------------------------------
missing_dir="$work/missing-from-plugin"
mkdir -p "$missing_dir"
settings_missing="$missing_dir/settings.json"
plugin_missing="$missing_dir/hooks.json"

node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    hooks: {
      PreToolUse: [
        { matcher: "Bash", hooks: [{ type: "command", command: "python3 \"$CLAUDE_PROJECT_DIR/.claude/scripts/guard-git-add.py\"" }] },
      ],
      PostToolUse: [
        // Non-allowlisted, self-only-in-this-fixture hook: no counterpart
        // in hooks.json below, and NOT in the real ALLOWLIST -> must fail.
        { matcher: "Edit|Write", hooks: [{ type: "command", command: "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/totally-new-hook.sh\"" }] },
      ],
    },
  }, null, 2));
' "$settings_missing"

node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    hooks: {
      PreToolUse: [
        { matcher: "Bash", hooks: [{ type: "command", command: "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/guard-git-add.py" }] },
      ],
    },
  }, null, 2));
' "$plugin_missing"

HOOKS_SETTINGS_FILE="$settings_missing" HOOKS_PLUGIN_FILE="$plugin_missing" \
  bash "$checks_sh" build >/dev/null 2>&1
check "check FAILS when settings.json has a non-allowlisted hook absent from hooks.json" \
  [ "$?" -ne 0 ]

# ---------------------------------------------------------------------------
# 3. Synthetic divergence, other direction: hooks.json has a hook absent
#    from settings.json -> the check must fail (consumers can never get a
#    hook the self-hosted repo itself doesn't run).
# ---------------------------------------------------------------------------
extra_dir="$work/extra-in-plugin"
mkdir -p "$extra_dir"
settings_extra="$extra_dir/settings.json"
plugin_extra="$extra_dir/hooks.json"

node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    hooks: {
      PreToolUse: [
        { matcher: "Bash", hooks: [{ type: "command", command: "python3 \"$CLAUDE_PROJECT_DIR/.claude/scripts/guard-git-add.py\"" }] },
      ],
    },
  }, null, 2));
' "$settings_extra"

node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    hooks: {
      PreToolUse: [
        { matcher: "Bash", hooks: [{ type: "command", command: "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/guard-git-add.py" }] },
      ],
      PostToolUse: [
        { matcher: "Edit|Write", hooks: [{ type: "command", command: "bash ${CLAUDE_PLUGIN_ROOT}/scripts/only-in-consumers.sh" }] },
      ],
    },
  }, null, 2));
' "$plugin_extra"

HOOKS_SETTINGS_FILE="$settings_extra" HOOKS_PLUGIN_FILE="$plugin_extra" \
  bash "$checks_sh" build >/dev/null 2>&1
check "check FAILS when hooks.json has a hook absent from settings.json" \
  [ "$?" -ne 0 ]

# ---------------------------------------------------------------------------
# 4. Sanity: a matching pair with no allowlist needed passes.
# ---------------------------------------------------------------------------
matching_dir="$work/matching"
mkdir -p "$matching_dir"
settings_matching="$matching_dir/settings.json"
plugin_matching="$matching_dir/hooks.json"

node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    hooks: {
      PreToolUse: [
        { matcher: "Bash", hooks: [{ type: "command", command: "python3 \"$CLAUDE_PROJECT_DIR/.claude/scripts/guard-git-add.py\"" }] },
      ],
      Stop: [
        { hooks: [{ type: "command", command: "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/gate.sh\" test_affected" }] },
      ],
    },
  }, null, 2));
' "$settings_matching"

node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    hooks: {
      PreToolUse: [
        { matcher: "Bash", hooks: [{ type: "command", command: "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/guard-git-add.py" }] },
      ],
      Stop: [
        { hooks: [{ type: "command", command: "bash ${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh test_affected" }] },
      ],
    },
  }, null, 2));
' "$plugin_matching"

check "check passes on a synthetic matching pair (no allowlist needed)" \
  bash -c 'HOOKS_SETTINGS_FILE="$1" HOOKS_PLUGIN_FILE="$2" bash "$3" build' \
  _ "$settings_matching" "$plugin_matching" "$checks_sh"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "hooks-parity.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "hooks-parity.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
