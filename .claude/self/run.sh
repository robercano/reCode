#!/usr/bin/env bash
# run.sh — CI runner entrypoint for the self-adapter (issue #11, feeds issue #25).
# Runs ALL self gates in order (build, lint, test) against .claude/self/gates.json,
# exiting non-zero on the first failure, with clear section headers. Invokes the
# real .claude/scripts/gate.sh path — the same one a consumer's gates run
# through — so this faithfully exercises the real gate contract, not a shortcut.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/../.." && pwd)"
cd "$root"

export GATES_FILE=.claude/self/gates.json

run_gate() {
  local name="$1"
  echo "=================================================="
  echo "self-host gate: $name"
  echo "=================================================="
  if ! bash .claude/scripts/gate.sh "$name"; then
    echo "run.sh: gate '$name' FAILED — stopping"
    exit 1
  fi
}

run_gate build
run_gate lint
run_gate test

echo "=================================================="
echo "run.sh: all self-host gates passed (build, lint, test)"
echo "=================================================="
