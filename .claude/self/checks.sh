#!/usr/bin/env bash
# Self-host gate implementations (issue #11). node + bash only — no external
# linters — so the loop can validate harness changes in a bare environment.
# Invoked via .claude/self/gates.json, e.g. `bash .claude/self/checks.sh lint`.
#
#   build → every JSON config parses and each adapter has the required shape
#   lint  → `bash -n` every shell script + `node --check` every workflow
#   test  → build + lint, PLUS every .claude/scripts/*.test.sh smoke test
#           (cockpit.test.sh, log-event.test.sh, ...) — each is a standalone,
#           offline (no gh/network) script that exits non-zero on failure, so
#           new *.test.sh files are picked up automatically without touching
#           this file again.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
cmd="${1:?usage: checks.sh build|lint|test}"

json_parse() { node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$1"; }

do_build() {
  local rc=0
  for f in .claude/gates.json .claude/self/gates.json .claude/settings.json .claude/.claude-plugin/plugin.json .claude/.claude-plugin/marketplace.json .claude/hooks/hooks.json; do
    if [ ! -f "$f" ]; then echo "build: missing $f"; rc=1; continue; fi
    if ! json_parse "$f" 2>/dev/null; then echo "build: invalid JSON — $f"; rc=1; fi
  done
  # each ADAPTER must have the shape the generic agents rely on
  node -e '
    for (const f of [".claude/gates.json", ".claude/self/gates.json"]) {
      const g = require(process.cwd() + "/" + f);
      if (!g.project || !Array.isArray(g.modules) || typeof g.gates !== "object") {
        console.error("build: bad adapter shape —", f); process.exit(1);
      }
    }
  ' || rc=1
  [ "$rc" -eq 0 ] && echo "build: JSON configs valid + adapters well-shaped"
  return "$rc"
}

do_lint() {
  local rc=0 f
  # .claude/skills/*/*.sh (scaffold.sh, sync.sh) and .claude/skills/*/templates/*.sh
  # (issue #102's arm-loop.sh template) are included so a syntax regression in the
  # setup/sync machinery or a scaffolded script template is caught here too, not just
  # .claude/scripts/*.sh and .claude/self/*.sh.
  for f in .claude/scripts/*.sh .claude/self/*.sh .claude/skills/*/*.sh .claude/skills/*/templates/*.sh; do
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
