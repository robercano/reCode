#!/usr/bin/env bash
# gate.sh <gate-name>
# Runs the command stored at .gates.<gate-name> in .claude/gates.json.
# Empty/missing command => skip with exit 0 (so pre-setup repos don't block).
# Non-zero command exit => propagates (so Stop hooks force the agent to keep working).
set -uo pipefail

key="${1:?usage: gate.sh <gate-name>}"
# Repo root is two levels up from this script (<root>/.claude/scripts/gate.sh) —
# robust whether or not we're nested inside another git repo.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/../.." && pwd)"
# Which adapter to read. Defaults to the project adapter; set GATES_FILE to run a
# different one (e.g. GATES_FILE=.claude/self/gates.json for the self-host loop —
# see .claude/self/README.md). Relative paths resolve from the repo root.
gates_ref="${GATES_FILE:-.claude/gates.json}"
case "$gates_ref" in
  /*) gates="$gates_ref" ;;
  *)  gates="$root/$gates_ref" ;;
esac

if [ ! -f "$gates" ]; then
  echo "gate.sh: no $gates found — skipping '$key'"; exit 0
fi

cmd="$(node -e "try{const g=require('$gates');process.stdout.write((g.gates&&g.gates['$key'])||'')}catch(e){process.stdout.write('')}" 2>/dev/null)"

if [ -z "$cmd" ]; then
  echo "gate.sh: gate '$key' not configured in gates.json — skipping"; exit 0
fi

echo "▶ gate '$key': $cmd"
cd "$root" && eval "$cmd"
