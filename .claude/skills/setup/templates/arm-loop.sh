#!/usr/bin/env bash
# @orchestrator-managed arm-loop v4
# arm-loop.sh — installs the cron-less PR-loop as systemd (user) units
# (issue #102). Templated + re-stamped by `/orchestrator:setup`/`sync`; do
# not hand-edit the copy scaffold.sh wrote into this repo if you want future
# plugin updates to reach it — fork it under a different name instead.
#
# MUST be run in a REAL terminal OUTSIDE Claude Code: installing units under
# ~/.config/systemd/user/, `loginctl enable-linger`, and starting a detached
# tmux session all touch $HOME and systemd, which the sandbox blocks (see
# docs/HARDENING.md -> Caveats). Safe to re-run any time — every step here is
# idempotent (systemctl --user enable/restart, tmux kill-session -t ... || true
# then recreate).
#
# Usage:
#   bash .claude/scripts/arm-loop.sh [--gates-file <path>] [--permission-mode <mode>] [--capacity N] [--rc-name <name>]
#
#   --gates-file <path>       passed to pr-loop.service as GATES_FILE (e.g.
#                              .claude/self/gates.json for the self-hosted
#                              loop). Omit for the default project adapter.
#   --permission-mode <mode>  passed to `claude remote-control --permission-mode`.
#                              Defaults to permissions.defaultMode in
#                              .claude/settings.local.json if present, else
#                              "default".
#   --capacity N               `claude remote-control --capacity`. Default 8.
#   --rc-name <name>           display name of the PRE-CREATED remote-control
#                              session (shown in claude.ai/code and the mobile
#                              Code tab). Default: <repo-slug>-planner. Extra
#                              on-demand sessions still get <repo-slug>-* names.
set -euo pipefail

gates_file=""
permission_mode=""
capacity="8"
rc_name=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --gates-file) gates_file="${2:?--gates-file needs a value}"; shift 2 ;;
    --gates-file=*) gates_file="${1#--gates-file=}"; shift ;;
    --permission-mode) permission_mode="${2:?--permission-mode needs a value}"; shift 2 ;;
    --permission-mode=*) permission_mode="${1#--permission-mode=}"; shift ;;
    --capacity) capacity="${2:?--capacity needs a value}"; shift 2 ;;
    --rc-name) rc_name="${2:?--rc-name needs a value}"; shift 2 ;;
    --rc-name=*) rc_name="${1#--rc-name=}"; shift ;;
    --capacity=*) capacity="${1#--capacity=}"; shift ;;
    -h|--help)
      sed -n '2,29p' "$0"
      exit 0
      ;;
    *) echo "arm-loop.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if ! command -v systemctl >/dev/null 2>&1; then
  echo "arm-loop.sh: 'systemctl' not found — this script only supports systemd (user) on Linux/WSL2." >&2
  exit 1
fi
if ! command -v tmux >/dev/null 2>&1; then
  echo "arm-loop.sh: 'tmux' not found — install it first (needed by claude-rc-<repo>.service)." >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Label-safe slug: lowercase, non [a-z0-9-] runs collapsed to '-'.
repo_slug="$(basename "$repo_root" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-|-$//g')"
if [ -z "$repo_slug" ]; then
  echo "arm-loop.sh: could not derive a repo slug from '$repo_root'" >&2
  exit 1
fi

if [ -z "$permission_mode" ]; then
  permission_mode="$(node -e '
    try {
      const s = require(process.argv[1]);
      if (s && s.permissions && s.permissions.defaultMode) { console.log(s.permissions.defaultMode); process.exit(0); }
    } catch (e) {}
  ' "$repo_root/.claude/settings.local.json" 2>/dev/null || true)"
  permission_mode="${permission_mode:-default}"
fi

gates_env=""
if [ -n "$gates_file" ]; then
  gates_env="Environment=GATES_FILE=$gates_file"
fi

# Absolute claude path, resolved HERE — this script runs in a real terminal
# with the user's full environment, while the installed unit runs under
# systemd's minimal PATH (gh but no nvm-provisioned node/claude). A bare
# `claude` in ExecStart dies instantly inside the tmux pane and the oneshot
# unit still reports success (observed 2026-07-10, second casualty of the
# issue #107 env finding; the loop daemon was the first).
claude_bin="$(command -v claude || true)"
if [ -z "$claude_bin" ]; then
  echo "arm-loop.sh: 'claude' not found on PATH — run this from a real terminal where \`claude\` works." >&2
  exit 1
fi

rc_name="${rc_name:-$repo_slug-planner}"
claude_dir="$(dirname "$claude_bin")"

units_dir="$HOME/.config/systemd/user"
mkdir -p "$units_dir"

pr_loop_src="$repo_root/.claude/systemd/pr-loop.service"
claude_rc_src="$repo_root/.claude/systemd/claude-rc.service"
for f in "$pr_loop_src" "$claude_rc_src"; do
  if [ ! -f "$f" ]; then
    echo "arm-loop.sh: missing $f — run /orchestrator:setup (or sync) first to scaffold the unit templates." >&2
    exit 1
  fi
done

pr_loop_dst="$units_dir/pr-loop-$repo_slug.service"
claude_rc_dst="$units_dir/claude-rc-$repo_slug.service"

sed -e "s#__WORKDIR__#$repo_root#g" \
    -e "s#__REPO_SLUG__#$repo_slug#g" \
    -e "s#__GATES_ENV__#$gates_env#g" \
    "$pr_loop_src" > "$pr_loop_dst"

sed -e "s#__WORKDIR__#$repo_root#g" \
    -e "s#__REPO_SLUG__#$repo_slug#g" \
    -e "s#__PERMISSION_MODE__#$permission_mode#g" \
    -e "s#__CAPACITY__#$capacity#g" \
    -e "s#__CLAUDE_BIN__#$claude_bin#g" \
    -e "s#__RC_NAME__#$rc_name#g" \
    -e "s#__CLAUDE_DIR__#$claude_dir#g" \
    "$claude_rc_src" > "$claude_rc_dst"

echo "arm-loop.sh: wrote $pr_loop_dst"
echo "arm-loop.sh: wrote $claude_rc_dst"

systemctl --user daemon-reload
# pr-loop: enable --now on purpose (NOT restart) — never kill a daemon that
# may have a driver in flight; a re-arm only rewrites its unit file, and the
# owner restarts it explicitly when they want the new unit picked up.
systemctl --user enable --now "pr-loop-$repo_slug.service"
# claude-rc: enable + restart on purpose — Type=oneshot + RemainAfterExit
# stays "active" forever, so `enable --now` would never re-run ExecStart and
# a re-arm would silently keep serving the OLD unit. Restart is safe here
# (independent of the loop daemon) and relaunches the tmux with the fresh unit.
systemctl --user enable "claude-rc-$repo_slug.service"
systemctl --user restart "claude-rc-$repo_slug.service"

loginctl enable-linger "$USER" || echo "arm-loop.sh: warning — 'loginctl enable-linger $USER' failed; user units will only run while a login session is open." >&2

cat <<EOF

armed:
  pr-loop-$repo_slug.service       (the cron-less loop daemon; adaptive tick+sleep)
  claude-rc-$repo_slug.service     (claude remote-control, in tmux session rc-$repo_slug)

inspect:
  systemctl --user status pr-loop-$repo_slug.service
  journalctl --user -u pr-loop-$repo_slug.service -f
  tail -f "$repo_root/.claude/state/loop-runs.log"
  tmux attach -t rc-$repo_slug

WSL2 users: see docs/USAGE.md's "Cron-less loop (daemon)" section for the
systemd-in-WSL2 prerequisite and the optional Windows-logon autostart task.
EOF
