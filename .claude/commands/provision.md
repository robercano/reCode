---
description: Provision a dedicated Linux server for the autonomous loop — guided, resumable walkthrough of HARDENING.md's dedicated-server worked example
---

You are guiding the human through provisioning a **fresh dedicated Linux box** (server / VM / cloud
instance) as the maximum-containment home for the autonomous PR loop.
`docs/HARDENING.md` → *"Worked example: dedicated Linux server (maximum containment)"* is the source of
truth — this command turns it into an interactive, checkpointed, **resumable** flow. Never restate its
rationale from memory: read the section and use its blocks verbatim, substituting the interview answers.

Where to run: **on the new box**, as the human's own **admin** account, in a session with interactive
permission prompts (i.e. BEFORE any hardening is active — sudo and prompts must still work), inside a
clone of the target repo with the `orchestrator` plugin enabled (or this repo itself, self-hosted).
The repo must already be onboarded — `.claude/gates.json` and `.claude/scripts/arm-loop.sh` exist
(scaffolded by `/orchestrator:setup`; tracked in-repo when self-hosting). If they don't, run
`/orchestrator:setup` first and come back.

> Division of labor, stated up front and repeated per phase: you run what a sandboxed/promptable session
> can run; anything touching **another user's `$HOME`, `/etc`, systemd, or requiring a login shell** is
> printed as a copy-paste block for the human's real terminal, then **verified** by you afterwards.
> Never skip a verification because the human says it's done — check.

## State & resume

Progress lives in `.claude/state/provision-progress.json`:

```json
{ "answers": { "agent_user": "...", "repos": ["..."], "notifier": "...", "layers": ["nftables", "auditd", "remote-ssh"] },
  "phases": { "1-prereqs": "done", "2-agent-user": "pending", "...": "..." } }
```

On start: if the file exists, summarize where the run left off and continue from the first
non-`done` phase (re-running a phase's verification before trusting its `done`). If not, start at the
interview. Update the file after every phase. Phases the human declines are recorded `skipped`, never
silently dropped from the final report.

## 0. Interview (once — stored in `answers`)

Ask, with defaults:
1. **Agent username** (default `recode-agent`).
2. **Repo(s) the loop will host** (owner/name; first one is cloned in Phase 4).
3. **Notifier** — ntfy topic (recommended; also receives the egress-drop alarm), other command, or none.
4. **Optional layers** — kernel egress allowlist (nftables), detection (auditd + divergence timer),
   remote SSH access for humans (`docs/REMOTE_SSH_RUNBOOK.md` — on native Linux its WSL2 gotchas drop out).

Substitute the answers everywhere below (the docs' `recode-agent` placeholder = answer 1).

## Phase 1 — prerequisites (`1-prereqs`)

- Toolchain the box needs: `git`, `tmux`, `bubblewrap`, `socat` (sandbox backend), plus `nftables` /
  `auditd` if those layers were chosen. Install what's missing (`sudo apt-get install -y ...` or distro
  equivalent).
- On Debian-family kernels, verify unprivileged user namespaces are enabled
  (`sysctl kernel.unprivileged_userns_clone` where present, else confirm `bwrap --ro-bind / / true` runs).
- Verify: every command above exists on PATH; `bwrap` smoke test passes.

## Phase 2 — the agent user (`2-agent-user`, HARDENING step 1)

- Create it exactly per the worked example: `useradd`, **not** in `sudo`/`wheel`/`docker`/`adm`,
  `loginctl enable-linger`, no `~/.ssh/authorized_keys` — reachable only via the admin account + `sudo -iu`.
- Verify: `id -nG <agent_user>` shows no privileged groups; `sudo -l -U <agent_user>` shows no sudo;
  linger is on (`loginctl show-user <agent_user> -p Linger`).

## Phase 3 — fresh credentials (`3-credentials`, HARDENING step 2)

You cannot mint these; guide the human through each and verify the result. The worked example's
**step 2** now carries the full mint walkthrough (click-path + exact permission table) — print it
verbatim, substituting the target repo(s):
- **Fine-grained PAT** for the loop's push identity: *Only select repositories* = the target repo(s);
  repository permissions exactly Contents/Issues/Pull-requests read-write + Metadata read (Workflows
  read-write only if the loop may push `.github/workflows/` changes); expiry set.
- **Bot token** for `bot-gh.sh` (`GH_BOT_TOKEN`): **classic** PAT with the single `repo` scope, minted
  as the machine account (classic on purpose — fine-grained PATs cannot reliably target repos owned by
  another personal account; one-time bot setup notes at the top of `.claude/scripts/bot-gh.sh`).
- **Dedicated Anthropic API key** with a spend cap set in the console (skip if the box will use
  subscription auth via `claude` login in Phase 4).
- **Rotate every token that lived on the machine being replaced** — this is part of the migration, not
  optional hygiene.
- Verify (after Phase 4's clone exists): `.env` present in the agent's clone, mode `600`, owned by the
  agent user; old tokens confirmed revoked by the human.

## Phase 4 — the agent's clone (`4-clone`)

Print for the human's terminal (needs a login shell as the agent user — `sudo -iu <agent_user>`):
- Install node (nvm), the `claude` CLI, and `gh` in the agent's own home; authenticate `claude` once.
- `git clone` the target repo; write `.env` (Phase 3) and machine-local state — e.g.
  `.claude/state/ntfy-topic` if ntfy was chosen.
- Verify from your side where possible (`sudo -u <agent_user> test -f ...` style checks via the human if
  your session can't): clone exists, `.env` mode `600`, `claude --version` and `gh --version` run as the
  agent user.

## Phase 5 — managed settings (`5-managed`, HARDENING steps 3–4)

- Materialize `/etc/claude-code/managed-settings.json` from HARDENING.md **Step 4**, root-owned `644`,
  with the sandbox **network allowlist here** (not in `settings.local.json`): Anthropic API, GitHub, the
  notifier host, package registries the gates need.
- Verify: file parses as JSON; `ls -l` shows `root root 644`; a write attempt as the agent user fails.

## Phase 6 — harden profile + arm the loop (`6-arm`)

- In a Claude Code session **as the agent user** inside the clone: run `/orchestrator:harden`, restart,
  `/sandbox`, and its backstop checks (`sudo true` blocked under bypass; a write outside the repo fails).
- Then, in the agent's real terminal: `bash .claude/scripts/arm-loop.sh` (self-hosting this repo:
  add `--gates-file self/gates.json`).
- Add the systemd hardening drop-in from the worked example (step 4's `[Service]` block) via
  `systemctl --user edit pr-loop-<repo>.service`, then `daemon-reload` + restart.
- Verify: both units active as the agent user; `systemd-analyze security pr-loop-<repo>.service` reflects
  the drop-in (score improves; `NoNewPrivileges=yes` shown).

## Phase 7 — kernel egress + detection (`7-egress`, optional layers; HARDENING steps 5–6)

If chosen in the interview:
- nftables: materialize the worked example's UID-matched output chain for the agent user, allowed set =
  exactly the hosts from Phase 5's allowlist; **log the drops** and wire the drop log into the notifier —
  blocked egress from this box is the intrusion alarm.
- auditd watches on `.claude/scripts/`, `self/` (if self-hosting), `.env`, and the unit files;
  journald `Storage=persistent`; the root-owned origin/main divergence timer if the human wants it.
- Verify: `curl https://example.com` **as the agent user** is dropped AND the drop is logged/notified;
  the loop's own hosts still work (`curl -sI https://api.github.com` as the agent user succeeds).

## Phase 8 — remote SSH for humans (`8-remote-ssh`, optional layer; `docs/REMOTE_SSH_RUNBOOK.md`)

If chosen in the interview — this gives the human's **admin** account zero-inbound-exposure SSH
(Cloudflare Tunnel + Access + short-lived certs); it is **never** a path into the agent user, whose
no-`authorized_keys` invariant from Phase 2 stands:
- Walk the runbook top to bottom; on native Linux its WSL2-specific gotchas (the `loopback0` ufw rule,
  `localhostForwarding`) drop out. Almost everything is human-terminal or Cloudflare-dashboard work
  (sshd config, `cloudflared` install + tunnel, the Access app and SSH CA) — print the blocks, then verify.
- Interplay with Phase 7's egress allowlist: `cloudflared` runs as its own system user, not the agent
  user, so the UID-matched nftables chain does not (and must not) allowlist anything for it.
- Verify: `sshd -T` shows loopback-only `ListenAddress`, `PasswordAuthentication no`,
  `PermitRootLogin no`, and `AllowUsers` limited to the admin (+ email-local-part alias); the
  `cloudflared` tunnel unit is active; the human confirms a real login from another device lands as
  the admin account; `~<agent_user>/.ssh/authorized_keys` still does not exist.

## Phase 9 — final verification (`9-verify`)

Walk HARDENING.md's **"Checklist deltas"** for the worked example plus:
- One loop tick landed in `.claude/state/loop-ticks.jsonl` (or the census explains why not).
- A test notification arrived through the `notify` seam.
- The old machine: its loop/daemons decommissioned and its tokens rotated (Phase 3).
- If remote SSH was set up (Phase 8): the runbook's §6 "Verify the security posture" block passes.

## Report

End with a compact table: phase → done/skipped + the one-line evidence used to verify it, the collected
answers, and anything the human still owes (with the exact command). If everything is `done`, say so
plainly: the box is provisioned and the loop is armed.
