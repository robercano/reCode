#!/usr/bin/env bash
# smoke.sh — real end-to-end smoke harness for the self-adapter (issue #11).
# Invoked by `.claude/self/checks.sh test` (via .claude/self/gates.json "test").
#
# Three checks, each must pass:
#   (a) syntax-check every .claude/workflows/*.js DSL file using the wrap-based
#       check (plain `node --check` fails on them — see below).
#   (b) assert feature-fanout.js's `meta.phases` exposes the Scope/Implement/
#       Review loop shape.
#   (c) drive the FIXTURE repo's (examples/fixture-target) OWN gates.json and
#       assert build/lint/test all exit 0 — a real filled adapter, run for real.
#
# Workflow DSL files are NOT plain JS modules: the Workflow engine wraps them
# and injects globals (phase, agent, parallel, pipeline, log, args, Workflow),
# so files legitimately use `export const meta`, top-level `await`, and
# top-level `return`. Plain `node --check` fails on top-level await/return
# outside a function — that was the latent lint bug this harness fixes. We
# instead strip leading `export ` keywords and wrap the body in an async
# function before syntax-checking it, mirroring how the engine actually runs it.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

rc=0
fail() { echo "smoke: $1"; rc=1; }

# ---------------------------------------------------------------------------
# (a) wrap-based syntax check for every workflow DSL file
# ---------------------------------------------------------------------------
check_workflow_syntax() {
  local f="$1"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/smoke-wf-XXXXXX.mjs")"
  node -e '
    const fs = require("fs")
    const [src_path, out_path] = process.argv.slice(1)
    let src = fs.readFileSync(src_path, "utf8")
    src = src.replace(/^\s*export\s+/gm, "")
    fs.writeFileSync(out_path, "async function __wf(){\n" + src + "\n}\n")
  ' "$f" "$tmp"
  local wf_rc=0
  node --check "$tmp" || wf_rc=1
  rm -f "$tmp"
  return "$wf_rc"
}

for f in .claude/workflows/*.js; do
  [ -e "$f" ] || continue
  if check_workflow_syntax "$f"; then
    echo "smoke(a): wrap-syntax OK — $f"
  else
    fail "(a) wrap-based syntax check failed — $f"
  fi
done

# ---------------------------------------------------------------------------
# (b) assert feature-fanout.js exposes the Scope/Implement/Review loop shape
# ---------------------------------------------------------------------------
fanout=".claude/workflows/feature-fanout.js"
if [ -f "$fanout" ]; then
  missing=""
  for phase in "Scope" "Implement" "Review"; do
    grep -q "title: '$phase'" "$fanout" || missing="$missing $phase"
  done
  if [ -z "$missing" ]; then
    echo "smoke(b): meta.phases contains Scope, Implement, Review — $fanout"
  else
    fail "(b) meta.phases missing phase(s):$missing — $fanout"
  fi
else
  fail "(b) $fanout not found"
fi

# ---------------------------------------------------------------------------
# (c) drive the fixture-target's own gates and assert green
# ---------------------------------------------------------------------------
fixture_dir="examples/fixture-target"
fixture_gates="$fixture_dir/.claude/gates.json"
if [ ! -f "$fixture_gates" ]; then
  fail "(c) fixture gates file not found — $fixture_gates"
else
  for gate in build lint test; do
    cmd="$(node -e "try{const g=require(process.cwd()+'/$fixture_gates');process.stdout.write((g.gates&&g.gates['$gate'])||'')}catch(e){process.stdout.write('')}")"
    if [ -z "$cmd" ]; then
      fail "(c) fixture gate '$gate' not configured in $fixture_gates"
      continue
    fi
    gate_log="$(mktemp "${TMPDIR:-/tmp}/smoke-fixture-${gate}-XXXXXX.log")"
    if (cd "$fixture_dir" && eval "$cmd") >"$gate_log" 2>&1; then
      echo "smoke(c): fixture gate '$gate' PASSED — $cmd"
    else
      fail "(c) fixture gate '$gate' FAILED — $cmd (see $gate_log)"
    fi
    rm -f "$gate_log"
  done
fi

if [ "$rc" -eq 0 ]; then
  echo "smoke: ALL checks passed (workflow syntax, phase shape, fixture gates)"
else
  echo "smoke: FAILED — see above"
fi
exit "$rc"
