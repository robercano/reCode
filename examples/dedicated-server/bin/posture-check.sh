#!/usr/bin/env bash
# Root-owned tripwire, run hourly from outside every agent's trust zone.
#
# Two checks, deliberately in one script so they share one timer and one alert
# channel:
#   1. GIT DIVERGENCE -- each agent's daemon-executed paths vs origin/main.
#   2. FENCE COVERAGE -- every agent user in agents.conf is present in the
#      nftables agent_uids set. A uid missing from that set is unfenced AND
#      unalarmed (the drop rule sits in a chain only listed uids jump into), so
#      an unfenced agent is indistinguishable from a quiet one. This check is
#      the only thing that makes that failure visible.
#
# Not `set -e`: every lookup here can legitimately fail, and a follower that
# dies on the first failure reports nothing while looking healthy.
set -u

CONF="${AGENTS_CONF:-/etc/recode-agents.conf}"
TOPIC="${NTFY_TOPIC:-recode-notifications}"
PATHS=".claude/scripts self"

alert() {
	curl -fsS -m 10 -H "Title: $1" -H "Priority: high" -d "$2" \
		"https://ntfy.sh/$TOPIC" >/dev/null 2>&1
	printf '%s\n%s\n' "$1" "$2"
}

[ -r "$CONF" ] || { alert "BusyBee: posture-check misconfigured" \
	"cannot read $CONF -- no agents checked"; exit 1; }

# ---- 1. git divergence, per agent -----------------------------------------
while IFS=: read -r user repo; do
	case "${user:-}" in ''|\#*) continue ;; esac
	[ -d "$repo" ] || { alert "BusyBee: $user repo missing" "no such path: $repo"; continue; }

	as_agent() { sudo -u "$user" git -C "$repo" "$@"; }
	as_agent fetch -q origin main 2>/dev/null
	dirty=$(as_agent status --porcelain -- $PATHS 2>/dev/null)
	drift=$(as_agent diff --stat origin/main -- $PATHS 2>/dev/null)

	if [ -n "$dirty" ] || [ -n "$drift" ]; then
		alert "BusyBee: $user checkout diverges from origin/main" \
			"$(printf 'uncommitted:\n%s\n\nvs origin/main:\n%s\n' "$dirty" "$drift")"
	fi
done < "$CONF"

# ---- 2. egress-fence coverage ---------------------------------------------
# nft -j prints plain set elements as "elem":[1001] but wraps them as
# {"val":1001} when they carry attributes -- pull the numbers from either shape.
live_uids=$(nft -j list set inet recode_agent agent_uids 2>/dev/null \
	| grep -o '"elem":.*' | grep -oE '[0-9]+' | sort -u)
if [ -z "$live_uids" ]; then
	alert "BusyBee: egress fence NOT LOADED" \
		"nftables table inet recode_agent has no agent_uids set -- NO agent is fenced"
	exit 1
fi

missing=""
while IFS=: read -r user repo; do
	case "${user:-}" in ''|\#*) continue ;; esac
	uid=$(id -u "$user" 2>/dev/null) || { missing="$missing $user(no-such-user)"; continue; }
	printf '%s\n' "$live_uids" | grep -qx "$uid" || missing="$missing $user(uid $uid)"
done < "$CONF"

[ -n "$missing" ] && alert "BusyBee: agent(s) NOT covered by the egress fence" \
	"missing from nftables agent_uids:$missing

Add the uid to the set in /etc/nftables.d/recode-agent.nft, then:
  sudo nft -c -f /etc/nftables.d/recode-agent.nft
  sudo systemctl restart recode-agent-nft.service"

exit 0
