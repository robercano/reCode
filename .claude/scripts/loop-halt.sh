#!/usr/bin/env bash
# loop-halt.sh — ops helper: stop one driver / all drivers / everything
# (issue #119). Companion to loop-daemon.sh's transient-systemd-unit driver
# spawn (`pr-loop-driver-issue<N>` / `pr-loop-driver-pr<N>`): a daemon
# restart no longer stops an in-flight driver (that is the whole point of
# #119 — its lifetime is decoupled from the daemon's), so an operator needs
# an explicit, obvious way to stop one/all/everything instead of relying on
# `systemctl --user restart pr-loop-<repo>.service` to do it as a side effect.
#
# Usage:
#   loop-halt.sh <issueN|prN|unit>       stop ONE driver:
#     loop-halt.sh issue106                 -> stops pr-loop-driver-issue106
#     loop-halt.sh pr42                     -> stops pr-loop-driver-pr42
#     loop-halt.sh pr-loop-driver-issue106   -> stops that unit name verbatim
#   loop-halt.sh --drivers | all-drivers    stop ALL driver units (pr-loop-driver-*)
#   loop-halt.sh --all                      stop the daemon unit AND all driver units
#   loop-halt.sh -h | --help                show this help
#
# Degrades cleanly when systemd/`systemctl --user` is unavailable (legacy-cron
# / non-systemd environments): logs a message and exits 0 — drivers spawned
# via that fallback are plain daemon children, already covered by stopping
# the daemon itself (see docs/USAGE.md's cron-less loop / failure-contract
# sections).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-roots.sh
. "$script_dir/resolve-roots.sh"

log() { printf '%s loop-halt: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- same repo_slug derivation arm-loop.sh uses for the daemon unit name ----
repo_slug() {
  basename "$root" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-|-$//g'
}

stop_unit() {
  local unit="$1"
  log "stopping $unit"
  if systemctl --user stop "$unit" 2>&1 | while IFS= read -r line; do log "  $line"; done; then
    log "stopped (or already stopped) $unit"
  else
    log "failed to stop $unit (may not exist)"
  fi
}

stop_all_drivers() {
  local units
  units="$(systemctl --user list-units --no-legend --plain --state=active,activating \
    'pr-loop-driver-*' 2>/dev/null | awk '{print $1}')"
  if [ -z "$units" ]; then
    log "no active pr-loop-driver-* units"
    return 0
  fi
  local u
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    stop_unit "$u"
  done <<< "$units"
}

if [ "$#" -lt 1 ]; then
  usage
  exit 2
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if ! command -v systemctl >/dev/null 2>&1; then
  log "systemctl not found on PATH — systemd is unavailable here, nothing to stop (legacy-cron drivers are daemon children; stop/restart the daemon itself to reap them)"
  exit 0
fi

case "$1" in
  --drivers|all-drivers)
    stop_all_drivers
    ;;
  --all)
    slug="$(repo_slug)"
    stop_unit "pr-loop-$slug.service"
    stop_all_drivers
    ;;
  pr-loop-driver-*)
    stop_unit "$1"
    ;;
  issue*)
    n="${1#issue}"
    case "$n" in
      *[!0-9]*|'') log "invalid argument '$1' — expected issue<N>"; usage; exit 2 ;;
    esac
    stop_unit "pr-loop-driver-issue$n"
    ;;
  pr*)
    n="${1#pr}"
    case "$n" in
      *[!0-9]*|'') log "invalid argument '$1' — expected pr<N>"; usage; exit 2 ;;
    esac
    stop_unit "pr-loop-driver-pr$n"
    ;;
  *)
    log "unrecognized argument '$1' — expected issue<N>, pr<N>, a pr-loop-driver-* unit name, --drivers, or --all"
    usage
    exit 2
    ;;
esac
