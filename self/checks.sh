#!/usr/bin/env bash
# Self-host gate implementations (issue #11). node + bash only — no external
# linters — so the loop can validate harness changes in a bare environment.
# Invoked via self/gates.json, e.g. `bash self/checks.sh lint`.
#
#   build → every JSON config parses and each adapter has the required shape
#   lint  → `bash -n` every shell script + `node --check` every workflow
#   test  → build + lint, PLUS every .claude/scripts/*.test.sh smoke test
#           (cockpit.test.sh, log-event.test.sh, ...) — each is a standalone,
#           offline (no gh/network) script that exits non-zero on failure, so
#           new *.test.sh files are picked up automatically without touching
#           this file again.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
cmd="${1:?usage: checks.sh build|lint|test}"

json_parse() { node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$1"; }

do_build() {
  local rc=0
  for f in .claude/gates.json self/gates.json .claude/settings.json .claude/.claude-plugin/plugin.json .claude/.claude-plugin/marketplace.json .claude/hooks/hooks.json; do
    if [ ! -f "$f" ]; then echo "build: missing $f"; rc=1; continue; fi
    if ! json_parse "$f" 2>/dev/null; then echo "build: invalid JSON — $f"; rc=1; fi
  done
  # each ADAPTER must have the shape the generic agents rely on
  node -e '
    for (const f of [".claude/gates.json", "self/gates.json"]) {
      const g = require(process.cwd() + "/" + f);
      if (!g.project || !Array.isArray(g.modules) || typeof g.gates !== "object") {
        console.error("build: bad adapter shape —", f); process.exit(1);
      }
    }
  ' || rc=1
  [ "$rc" -eq 0 ] && echo "build: JSON configs valid + adapters well-shaped"
  do_hooks_parity || rc=1
  return "$rc"
}

# do_hooks_parity (issue #140) — the repo-local .claude/settings.json (self-
# hosted sessions, $CLAUDE_PROJECT_DIR paths) and the shipped
# .claude/hooks/hooks.json (consumers, ${CLAUDE_PLUGIN_ROOT} paths) hand-
# duplicate the same hook set under two different path prefixes. Nothing
# checked they stayed in sync, which is how a hook ended up reCode-only for
# weeks (empty cockpit workers panel in every consumer). This normalizes
# both files' `.hooks` into (event, matcher, command) triples — stripping the
# environment-specific path prefix so the two forms collapse to the same
# value — and fails on any divergence that isn't explicitly allowlisted as
# deliberately self-only.
#
# File paths are overridable via HOOKS_SETTINGS_FILE / HOOKS_PLUGIN_FILE so
# tests can point this at hermetic temp-dir fixtures instead of the real repo
# files.
do_hooks_parity() {
  local rc=0
  local settings_file="${HOOKS_SETTINGS_FILE:-.claude/settings.json}"
  local plugin_file="${HOOKS_PLUGIN_FILE:-.claude/hooks/hooks.json}"

  if [ ! -f "$settings_file" ]; then echo "build: hooks-parity — missing $settings_file"; return 1; fi
  if [ ! -f "$plugin_file" ]; then echo "build: hooks-parity — missing $plugin_file"; return 1; fi

  node -e '
    const fs = require("fs");
    const settingsFile = process.argv[1];
    const pluginFile = process.argv[2];

    // Deliberate self-only hooks: present in settings.json (self-hosted repo)
    // but intentionally absent from hooks.json (shipped to consumers).
    // Key format: "event|matcher|normalizedCommand".
    const ALLOWLIST = new Set([
      // log-worker-tool.sh mirrors a worker session'"'"'s tool calls into the
      // cockpit workers panel. That panel — and the whole notion of a
      // worker session to mirror — only exists in reCode'"'"'s own
      // self-hosted orchestration loop; consumer projects have no cockpit
      // worker-session view to feed, so this hook is deliberately
      // self-only and must never be added to hooks.json.
      "PostToolUse|Bash|Edit|Write|bash scripts/log-worker-tool.sh",
    ]);

    // Collapse the two environment-specific path prefixes
    // ($CLAUDE_PROJECT_DIR/.claude/... in settings.json, quoted, vs.
    // ${CLAUDE_PLUGIN_ROOT}/... in hooks.json, unquoted) down to the same
    // plugin-root-relative form, and drop any remaining quoting, so
    // "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/gate.sh\" lint" and
    // "bash ${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh lint" both normalize to
    // "bash scripts/gate.sh lint".
    function normalizeCommand(cmd) {
      return cmd
        .replace(/"\$CLAUDE_PROJECT_DIR\/\.claude\//g, "")
        .replace(/\$CLAUDE_PROJECT_DIR\/\.claude\//g, "")
        .replace(/\$\{CLAUDE_PLUGIN_ROOT\}\//g, "")
        .replace(/"/g, "")
        .trim()
        .replace(/\s+/g, " ");
    }

    function triples(file) {
      const data = JSON.parse(fs.readFileSync(file, "utf8"));
      const hooksObj = data.hooks || {};
      const out = [];
      for (const [event, entries] of Object.entries(hooksObj)) {
        for (const entry of entries || []) {
          const matcher = entry.matcher || "";
          for (const h of entry.hooks || []) {
            const cmd = normalizeCommand(h.command || "");
            out.push({ event, matcher, cmd, key: `${event}|${matcher}|${cmd}` });
          }
        }
      }
      return out;
    }

    const settingsTriples = triples(settingsFile);
    const pluginTriples = triples(pluginFile);
    const settingsKeys = new Set(settingsTriples.map((t) => t.key));
    const pluginKeys = new Set(pluginTriples.map((t) => t.key));

    let failed = false;

    // In settings.json (self) but not hooks.json (consumers) — OK only if
    // explicitly allowlisted as deliberately self-only.
    for (const t of settingsTriples) {
      if (!pluginKeys.has(t.key) && !ALLOWLIST.has(t.key)) {
        console.error(
          `build: hooks-parity — event="${t.event}" matcher="${t.matcher}" cmd="${t.cmd}" ` +
          `present in ${settingsFile} but missing from ${pluginFile} (not in allowlist)`
        );
        failed = true;
      }
    }

    // In hooks.json (consumers) but not settings.json (self) — never
    // allowed: every hook shipped to consumers must also run self-hosted.
    for (const t of pluginTriples) {
      if (!settingsKeys.has(t.key)) {
        console.error(
          `build: hooks-parity — event="${t.event}" matcher="${t.matcher}" cmd="${t.cmd}" ` +
          `present in ${pluginFile} but missing from ${settingsFile}`
        );
        failed = true;
      }
    }

    if (failed) process.exit(1);
  ' "$settings_file" "$plugin_file" || rc=1

  [ "$rc" -eq 0 ] && echo "build: hooks parity OK — settings.json and hooks.json hook triples match (mod allowlist)"
  return "$rc"
}

do_lint() {
  local rc=0 f
  # .claude/skills/*/*.sh (scaffold.sh, sync.sh) and .claude/skills/*/templates/*.sh
  # (issue #102's arm-loop.sh template) are included so a syntax regression in the
  # setup/sync machinery or a scaffolded script template is caught here too, not just
  # .claude/scripts/*.sh and self/*.sh.
  for f in .claude/scripts/*.sh self/*.sh .claude/skills/*/*.sh .claude/skills/*/templates/*.sh; do
    [ -e "$f" ] || continue
    bash -n "$f" || { echo "lint: shell syntax error — $f"; rc=1; }
  done
  # Workflow files are a workflow-DSL: they mix ESM-only `export` syntax with
  # top-level `return`/`await`, so they're valid as neither plain CommonJS nor
  # plain ESM and `node --check` can't validate them directly. Instead, strip
  # the `export` keywords and wrap the body in an async IIFE (which makes
  # top-level `return`/`await` legal), then parse it with vm.Script — parsing
  # never executes the code, so undefined harness globals (agent, phase, log,
  # ...) don't matter, but real syntax errors still surface as SyntaxError.
  for f in .claude/workflows/*.js; do
    [ -e "$f" ] || continue
    node -e '
      const fs = require("fs");
      const vm = require("vm");
      const f = process.argv[1];
      let src = fs.readFileSync(f, "utf8");
      src = src.replace(/^\s*export\s+default\s+/gm, "").replace(/^\s*export\s+/gm, "");
      const wrapped = "(async () => {\n" + src + "\n})";
      try {
        new vm.Script(wrapped, { filename: f });
      } catch (e) {
        if (e instanceof SyntaxError) {
          console.error("lint: JS syntax error — " + f + ": " + e.message);
          process.exit(1);
        }
        throw e;
      }
    ' "$f" || rc=1
  done
  [ "$rc" -eq 0 ] && echo "lint: shell + workflow syntax OK"
  return "$rc"
}

do_test() {
  local rc=0 f
  for f in .claude/scripts/*.test.sh; do
    [ -e "$f" ] || continue
    echo "test: running $f"
    bash "$f" || { echo "test: FAILED — $f"; rc=1; }
  done
  return "$rc"
}

case "$cmd" in
  build) do_build ;;
  lint)  do_lint ;;
  test)  do_build && do_lint && do_test && echo "test: harness smoke OK" ;;
  *) echo "checks.sh: unknown check '$cmd' (build|lint|test)"; exit 2 ;;
esac
