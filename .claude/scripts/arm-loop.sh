#!/usr/bin/env bash
# @orchestrator-managed arm-loop v7
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
#   bash .claude/scripts/arm-loop.sh [--gates-file <path>] [--permission-mode <mode>] [--capacity N] [--rc-name <name>] [--spawn <mode>] [--stop-after-days N]
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
#   --spawn <mode>             remote-control spawn mode: same-dir (default) or
#                              worktree. Passed explicitly so the server never
#                              blocks on its interactive first-run question.
#   --stop-after-days N        self-disarm horizon (issue #95): loop-tick.sh
#                              refuses every advance/feedback dispatch once
#                              armed_at + N days has passed, until re-armed.
#                              Defaults to budget.stop_after_days in the
#                              adapter picked by --gates-file (or the default
#                              .claude/gates.json when --gates-file is
#                              omitted), else 7. Every re-arm rewrites
#                              .claude/state/loop-arming.json fresh --
#                              clearing any prior expiry AND the one-time
#                              "disarmed" notification guard.
set -euo pipefail

gates_file=""
permission_mode=""
capacity="8"
rc_name=""
spawn_mode="same-dir"
stop_after_days=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --gates-file) gates_file="${2:?--gates-file needs a value}"; shift 2 ;;
    --gates-file=*) gates_file="${1#--gates-file=}"; shift ;;
    --permission-mode) permission_mode="${2:?--permission-mode needs a value}"; shift 2 ;;
    --permission-mode=*) permission_mode="${1#--permission-mode=}"; shift ;;
    --capacity) capacity="${2:?--capacity needs a value}"; shift 2 ;;
    --rc-name) rc_name="${2:?--rc-name needs a value}"; shift 2 ;;
    --rc-name=*) rc_name="${1#--rc-name=}"; shift ;;
    --spawn) spawn_mode="${2:?--spawn needs a value}"; shift 2 ;;
    --spawn=*) spawn_mode="${1#--spawn=}"; shift ;;
    --capacity=*) capacity="${1#--capacity=}"; shift ;;
    --stop-after-days) stop_after_days="${2:?--stop-after-days needs a value}"; shift 2 ;;
    --stop-after-days=*) stop_after_days="${1#--stop-after-days=}"; shift ;;
    -h|--help)
      sed -n '2,42p' "$0"
      exit 0
      ;;
    *) echo "arm-loop.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

case "$spawn_mode" in
  same-dir|worktree) ;;
  *) echo "arm-loop.sh: --spawn must be 'same-dir' or 'worktree' (got '$spawn_mode')" >&2; exit 2 ;;
esac

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

# --- spend-ceiling arming state (issue #95) ---------------------------------
# Resolve the stop-after horizon: --stop-after-days wins; else
# budget.stop_after_days from the SAME adapter the armed daemon will read
# (gates_file, defaulting to .claude/gates.json); else 7. Always WRITE a
# fresh .claude/state/loop-arming.json on every arm/re-arm -- this is what
# clears a prior expiry and the one-time "disarmed" notification guard.
if [ -z "$stop_after_days" ]; then
  adapter_for_stop_after="${gates_file:-.claude/gates.json}"
  case "$adapter_for_stop_after" in
    /*) ;;
    *) adapter_for_stop_after="$repo_root/$adapter_for_stop_after" ;;
  esac
  stop_after_days="$(node -e '
    try {
      const g = require(process.argv[1]);
      const d = g && g.budget && g.budget.stop_after_days;
      if (Number.isFinite(d) && d > 0) { console.log(d); process.exit(0); }
    } catch (e) {}
  ' "$adapter_for_stop_after" 2>/dev/null || true)"
  stop_after_days="${stop_after_days:-7}"
fi
case "$stop_after_days" in
  ''|*[!0-9.]*) echo "arm-loop.sh: --stop-after-days must be a positive number (got '$stop_after_days')" >&2; exit 2 ;;
esac

arming_state_dir="$repo_root/.claude/state"
mkdir -p "$arming_state_dir"
arm_now="$(date -u +%FT%TZ)"
node -e '
  const fs = require("fs");
  const now = process.argv[2];
  const days = parseFloat(process.argv[3]);
  const expires = new Date(Date.parse(now) + days * 86400000).toISOString();
  fs.writeFileSync(process.argv[1], JSON.stringify({
    armed_at: now, expires_at: expires, stop_after_days: days,
    notified_expired: false, notice_issue: null,
  }, null, 2) + "\n");
' "$arming_state_dir/loop-arming.json" "$arm_now" "$stop_after_days"
echo "arm-loop.sh: armed until $(node -e 'const j=require(process.argv[1]);console.log(j.expires_at)' "$arming_state_dir/loop-arming.json") (stop_after_days=$stop_after_days) -- .claude/state/loop-arming.json"

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

# Same rationale as claude_bin above, plus issue #107: the installed
# pr-loop.service unit (the loop daemon itself, NOT claude-rc) previously got
# NO baked PATH at all and ran under systemd's minimal PATH — which has `gh`
# but neither `node` nor `claude`, silently stalling node-dependent tick steps
# (loop-census.sh, merge-ready.sh, write_tick_record) until the daemon's own
# runtime ensure_claude_on_path fallback (loop-daemon.sh) kicked in. Bake the
# resolved node/claude dirs in here too so the unit starts with a working PATH
# from the first tick, with the nvm-sourcing fallback staying as a safety net
# for installs that predate this change or use fnm/volta/system node.
node_bin="$(command -v node || true)"
if [ -z "$node_bin" ]; then
  echo "arm-loop.sh: 'node' not found on PATH — run this from a real terminal where \`node\` works." >&2
  exit 1
fi
node_dir="$(dirname "$node_bin")"

# Compose the baked PATH: node_dir, claude_dir, then the standard system dirs
# — deduped, since under nvm node_dir and claude_dir are frequently identical.
baked_path="$(printf '%s\n' "$node_dir" "$claude_dir" "/usr/local/sbin" "/usr/local/bin" "/usr/sbin" "/usr/bin" "/sbin" "/bin" | awk '!seen[$0]++' | paste -sd: -)"

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
    -e "s#__PATH__#$baked_path#g" \
    "$pr_loop_src" > "$pr_loop_dst"

sed -e "s#__WORKDIR__#$repo_root#g" \
    -e "s#__REPO_SLUG__#$repo_slug#g" \
    -e "s#__PERMISSION_MODE__#$permission_mode#g" \
    -e "s#__CAPACITY__#$capacity#g" \
    -e "s#__CLAUDE_BIN__#$claude_bin#g" \
    -e "s#__RC_NAME__#$rc_name#g" \
    -e "s#__CLAUDE_DIR__#$claude_dir#g" \
    -e "s#__SPAWN_MODE__#$spawn_mode#g" \
    "$claude_rc_src" > "$claude_rc_dst"

echo "arm-loop.sh: wrote $pr_loop_dst"
echo "arm-loop.sh: wrote $claude_rc_dst"

# Guard against template/script skew (issue #130): if either sed block above
# is missing a substitution for a placeholder the template still contains
# (e.g. a new __FOO__ added to the .service template without a matching -e
# here), the installed unit silently keeps the literal token and systemd
# fails it at the NEXT boot with an opaque status=127 -- long after this
# script has exited 0. Fail loudly, right here, instead.
for dst in "$pr_loop_dst" "$claude_rc_dst"; do
  # Scan only directive (non-comment) lines: the template header comments carry
  # the literal doc token __PLACEHOLDER__, which is not a sed target and must
  # not false-positive. A REAL leftover lives in a directive line. `|| true`
  # keeps the no-leftover healthy path from aborting under `set -euo pipefail`
  # (grep exits 1 on no match). Fail loudly on genuine skew (issue #130).
  leftover="$(grep -v '^[[:space:]]*#' "$dst" | grep -o '__[A-Z_]*__' | sort -u | tr '\n' ' ' || true)"
  if [ -n "$leftover" ]; then
    echo "arm-loop.sh: unsubstituted placeholder(s) leaked into $dst: ${leftover}-- the sed block that generated this file is missing a substitution (issue #130); fix arm-loop.sh before re-running." >&2
    exit 1
  fi
done

systemctl --user daemon-reload
# pr-loop: enable --now on purpose (NOT restart) — never kill a daemon that
# may have a driver in flight; a re-arm only rewrites its unit file, and the
# owner restarts it explicitly when they want the new unit picked up.
systemctl --user enable --now "pr-loop-$repo_slug.service"
# claude-rc: enable + restart on purpose — even with Type=simple +
# Restart=on-failure (issue #124), `systemctl --user enable --now` on an
# ALREADY-enabled, already-running unit is a no-op: it does not re-run
# ExecStart. So a re-arm's freshly-written unit file (new PATH, capacity,
# permission-mode, spawn mode, etc.) would silently keep being ignored by the
# still-running OLD supervisor process until something restarts it. `restart`
# is what actually loads the new unit; it is safe here (independent of the
# loop daemon) — the inline supervisor's ExecStop/kill-session step tears
# down the old tmux session cleanly before the fresh ExecStart relaunches it.
systemctl --user enable "claude-rc-$repo_slug.service"
systemctl --user restart "claude-rc-$repo_slug.service"

loginctl enable-linger "$USER" || echo "arm-loop.sh: warning — 'loginctl enable-linger $USER' failed; user units will only run while a login session is open." >&2

cat <<EOF

armed:
  pr-loop-$repo_slug.service       (the cron-less loop daemon; adaptive tick+sleep)
  claude-rc-$repo_slug.service     (claude remote-control, supervised tmux session
                                     rc-$repo_slug; auto-restarts within RestartSec=10s
                                     if the planner process dies)

inspect:
  systemctl --user status pr-loop-$repo_slug.service
  systemctl --user status claude-rc-$repo_slug.service
  journalctl --user -u pr-loop-$repo_slug.service -f
  journalctl --user -u claude-rc-$repo_slug.service -f
  tail -f "$repo_root/.claude/state/loop-runs.log"
  tmux attach -t rc-$repo_slug

WSL2 users: see docs/USAGE.md's "Cron-less loop (daemon)" section for the
systemd-in-WSL2 prerequisite and the optional Windows-logon autostart task.
EOF
