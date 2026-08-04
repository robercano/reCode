#!/usr/bin/env bash
# Follow the kernel log and push blocked-egress events to ntfy.
# Blocked egress from this box is an intrusion signal, not noise -- so keep it
# readable and de-duplicated, or it becomes noise and gets ignored.
# Runs as root: the UID-matched nft rule does not apply to this curl.
#
# NOTE: deliberately NOT `set -e`/`pipefail`. Every field here comes from a
# best-effort parse or a reverse lookup that legitimately fails (an address
# with no PTR, a log line with no DPT). Under `set -e` the first such failure
# kills the follower and events are lost SILENTLY -- which is worse than no
# alarm at all, because silence reads as safety.
set -u
TOPIC="${NTFY_TOPIC:-recode-notifications}"
COOLDOWN="${COOLDOWN:-900}"   # seconds before re-alerting on the same dst:port

declare -A seen
journalctl -k -f -n0 -o cat | while IFS= read -r line; do
	case "$line" in *recode-egress-drop*) ;; *) continue ;; esac

	dst=$(printf '%s' "$line" | grep -oE 'DST=[0-9a-fA-F.:]+' | head -1 | cut -d= -f2)
	dpt=$(printf '%s' "$line" | grep -oE 'DPT=[0-9]+'         | head -1 | cut -d= -f2)
	proto=$(printf '%s' "$line" | grep -oE 'PROTO=[A-Z0-9]+'  | head -1 | cut -d= -f2)
	[ -n "${dst:-}" ] || continue

	# Key on destination AND port: the same host on a different port is a
	# different event, and suppressing it hides real signal.
	key="${dst}:${dpt:-none}/${proto:-?}"
	now=$(date +%s)
	prev=${seen[$key]:-0}
	if [ $((now - prev)) -lt "$COOLDOWN" ]; then continue; fi
	seen[$key]=$now

	host=$(getent hosts "$dst" 2>/dev/null | awk '{print $2}' | head -1)
	[ -n "${host:-}" ] || host="$dst"

	curl -fsS -m 10 \
		-H "Title: BusyBee: agent egress BLOCKED" \
		-H "Priority: high" \
		-H "Tags: rotating_light" \
		-d "${proto:-?} -> ${host}:${dpt:-?}   (raw dst ${dst})" \
		"https://ntfy.sh/$TOPIC" >/dev/null 2>&1
done
