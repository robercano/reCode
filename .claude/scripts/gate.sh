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
gates="$root/.claude/gates.json"

if [ ! -f "$gates" ]; then
  echo "gate.sh: no $gates found — skipping '$key'"; exit 0
fi

cmd="$(node -e "try{const g=require('$gates');process.stdout.write((g.gates&&g.gates['$key'])||'')}catch(e){process.stdout.write('')}" 2>/dev/null)"

if [ -z "$cmd" ]; then
  echo "gate.sh: gate '$key' not configured in gates.json — skipping"; exit 0
fi

echo "▶ gate '$key': $cmd"
cd "$root" && eval "$cmd"
