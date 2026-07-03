#!/usr/bin/env bash
# Self-host gate implementations (issue #11). node + bash are REQUIRED —
# shellcheck/markdownlint/ajv are OPTIONAL and probed for; when absent, those
# sub-checks are skipped with a clear message (never hard-fail on missing
# tooling) so the loop can validate harness changes in a bare environment.
# Invoked via .claude/self/gates.json, e.g. `bash .claude/self/checks.sh lint`.
#
#   build → every JSON config parses, each adapter (incl. the fixture's) has
#           the required shape — via ajv if installed, else a node shape check.
#   lint  → `bash -n` every shell script (+ shellcheck if installed), the
#           wrap-based syntax check on every workflow DSL file (see smoke.sh
#           for why plain `node --check` is wrong here), and markdownlint on
#           docs/*.md if installed.
#   test  → runs .claude/self/smoke.sh — the real end-to-end smoke harness
#           (workflow syntax + phase shape + fixture-target's own gates).
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
cmd="${1:?usage: checks.sh build|lint|test}"

json_parse() { node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$1"; }

# Wrap-based syntax check for workflow DSL files — see .claude/self/smoke.sh
# for the full rationale (top-level await/return, engine-injected globals).
check_workflow_syntax() {
  local f="$1" tmp wf_rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/checks-wf-XXXXXX.mjs")"
  node -e '
    const fs = require("fs")
    const [src_path, out_path] = process.argv.slice(1)
    let src = fs.readFileSync(src_path, "utf8")
    src = src.replace(/^\s*export\s+/gm, "")
    fs.writeFileSync(out_path, "async function __wf(){\n" + src + "\n}\n")
  ' "$f" "$tmp"
  node --check "$tmp" || wf_rc=1
  rm -f "$tmp"
  return "$wf_rc"
}

do_build() {
  local rc=0
  for f in .claude/gates.json .claude/self/gates.json .claude/settings.json examples/fixture-target/.claude/gates.json; do
    if [ ! -f "$f" ]; then echo "build: missing $f"; rc=1; continue; fi
    if ! json_parse "$f" 2>/dev/null; then echo "build: invalid JSON — $f"; rc=1; fi
  done

  if command -v ajv >/dev/null 2>&1; then
    echo "build: ajv found — validating adapters against schema"
    local schema
    schema="$(mktemp "${TMPDIR:-/tmp}/checks-schema-XXXXXX.json")"
    cat > "$schema" <<'EOF'
{
  "type": "object",
  "required": ["project", "modules", "gates"],
  "properties": {
    "project": { "type": "object" },
    "modules": { "type": "array" },
    "gates": { "type": "object" }
  }
}
EOF
    for f in .claude/gates.json .claude/self/gates.json examples/fixture-target/.claude/gates.json; do
      ajv validate -s "$schema" -d "$f" >/dev/null 2>&1 || { echo "build: ajv schema check failed — $f"; rc=1; }
    done
    rm -f "$schema"
  else
    echo "build: ajv not installed — using shape check"
    # each ADAPTER must have the shape the generic agents rely on
    node -e '
      for (const f of [".claude/gates.json", ".claude/self/gates.json", "examples/fixture-target/.claude/gates.json"]) {
        const g = require(process.cwd() + "/" + f);
        if (!g.project || !Array.isArray(g.modules) || typeof g.gates !== "object") {
          console.error("build: bad adapter shape —", f); process.exit(1);
        }
      }
    ' || rc=1
  fi

  [ "$rc" -eq 0 ] && echo "build: JSON configs valid + adapters (incl. fixture) well-shaped"
  return "$rc"
}

do_lint() {
  local rc=0 f

  for f in .claude/scripts/*.sh .claude/self/*.sh; do
    [ -e "$f" ] || continue
    bash -n "$f" || { echo "lint: shell syntax error — $f"; rc=1; }
  done

  if command -v shellcheck >/dev/null 2>&1; then
    echo "lint: shellcheck found — running it"
    shellcheck .claude/scripts/*.sh .claude/self/*.sh || { echo "lint: shellcheck reported issues"; rc=1; }
  else
    echo "lint: shellcheck not installed — skipping"
  fi

  for f in .claude/workflows/*.js; do
    [ -e "$f" ] || continue
    check_workflow_syntax "$f" || { echo "lint: workflow syntax error (wrap-based check) — $f"; rc=1; }
  done

  if command -v markdownlint >/dev/null 2>&1; then
    echo "lint: markdownlint found — running it"
    markdownlint docs/*.md || { echo "lint: markdownlint reported issues"; rc=1; }
  else
    echo "lint: markdownlint not installed — skipping"
  fi

  [ "$rc" -eq 0 ] && echo "lint: shell + workflow syntax OK"
  return "$rc"
}

do_test() {
  bash "$root/.claude/self/smoke.sh"
}

case "$cmd" in
  build) do_build ;;
  lint)  do_lint ;;
  test)  do_test ;;
  *) echo "checks.sh: unknown check '$cmd' (build|lint|test)"; exit 2 ;;
esac
