#!/usr/bin/env bash
# Root-owned tripwire: alert when the agent's daemon-executed paths diverge
# from origin/main. Enforced from OUTSIDE the agent's trust zone.
set -euo pipefail
R=/home/recode-agent/reCode
TOPIC="${NTFY_TOPIC:-recode-notifications}"
PATHS=".claude/scripts self"

as_agent() { sudo -u recode-agent git -C "$R" "$@"; }

as_agent fetch -q origin main 2>/dev/null || true
dirty=$(as_agent status --porcelain -- $PATHS 2>/dev/null || true)
drift=$(as_agent diff --stat origin/main -- $PATHS 2>/dev/null || true)

if [ -n "$dirty" ] || [ -n "$drift" ]; then
	body=$(printf 'uncommitted:\n%s\n\nvs origin/main:\n%s\n' "$dirty" "$drift")
	curl -fsS -m 10 \
		-H "Title: BusyBee: agent checkout diverges from origin/main" \
		-H "Priority: high" \
		-d "$body" "https://ntfy.sh/$TOPIC" >/dev/null || true
	echo "$body"
fi
