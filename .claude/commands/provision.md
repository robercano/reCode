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

**One agent user per repo** is the recommended isolation model, so namespace the progress file per
user — `provision-progress-<agent_user>.json` — or a second run will collide with the first. Phases
1, 5, 7 (the nftables table) and 8 are **box-global**: done once, shared by every later agent user.
Only 2, 3, 4 and 6 repeat per repo. Say so during the interview; the second and third runs are short.

## Field notes (read before phase 1 — these cost hours the first time)

- **Paste hygiene.** Long lines and heredocs frequently arrive mangled: a fullscreen-renderer terminal
  wraps them, and the copied text carries the wrap as a newline plus indentation — which breaks `<<'EOF'`
  terminators and produces `IndentationError` from Python one-liners. **Keep every command under ~80
  characters**, prefer repeated short `echo … >> file` lines over heredocs, and for anything longer
  write the file yourself into `/tmp/` and have the human `sudo install` it. This is the single
  biggest source of friction in a real run.
- **Never accept a sub-agent's diagnosis without evidence.** `/orchestrator:harden` in particular
  reports sandbox failures as "the kernel does not allow unprivileged user namespaces" and prescribes
  `sysctl kernel.apparmor_restrict_unprivileged_userns=0` or container `--cap-add SYS_ADMIN`. Both are
  wrong on a bare-metal Ubuntu box and the first strips a real mitigation machine-wide. Reproduce the
  claim yourself (`bwrap --ro-bind / / true`, `cat /proc/self/uid_map`, `strace -f -e trace=execve`)
  before changing any security setting. See HARDENING.md **4a** for the actual mechanism.
- **A permission-denied from your own account is not evidence of absence.** The agent's home is `0750`,
  so `test -e ~<agent>/.ssh/authorized_keys` fails identically whether the file exists or not. Verify
  as root.
- **`is-active` is not evidence a unit is healthy** — it reports `active` while a crash-looping unit is
  mid-restart. Always read `journalctl --user -u <unit> -n 20` and check `NRestarts`.

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
- **Ubuntu ≥24.04: also check `kernel.apparmor_restrict_unprivileged_userns`.** If it is `1`, expect the
  app-layer sandbox to fail in Phase 6 even though `bwrap` passes the smoke test — the restriction
  strips capabilities from bwrap's *children*, which is where Claude Code builds its seccomp layer.
  Read HARDENING.md **4a** and settle the decision (disable the app sandbox vs. grant
  `sys_admin` to bwrap children) with the human *before* Phase 5, so managed settings are written once.
- **If `ufw` is active, leave `nftables.service` disabled** — it runs `/etc/nftables.conf`, which
  conventionally starts with `flush ruleset` and would wipe ufw's rules at boot. Phase 7 loads its own
  table from a dedicated unit instead.
- Verify: every command above exists on PATH; `bwrap` smoke test passes; note whether `/var/log/journal`
  exists (journald persistence, a Phase 7 checklist item, is often already satisfied).

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
  read-write only if the loop may push `.github/workflows/` changes; **Actions stays *No access*** —
  CI reads go through the bot token); expiry set. It is installed in Phase 4 via
  `gh auth login --with-token`, **not** written to `.env`.
- **Bot token** for `bot-gh.sh` (`GH_BOT_TOKEN`): **classic** PAT with the single `repo` scope — and
  **not** `workflow`, or the bot can edit CI files through the Contents API regardless of the PAT's
  Workflows setting. Minted as the machine account (classic on purpose — fine-grained PATs cannot
  reliably target repos owned by another personal account; one-time bot setup notes at the top of
  `.claude/scripts/bot-gh.sh`).
- **Dedicated Anthropic API key** with a spend cap set in the console (skip if the box will use
  subscription auth via `claude` login in Phase 4). Note for the human: spend caps are set per
  **workspace**, not per key, so one workspace per project is what makes the cap per-project. With
  subscription auth there is no runaway bill to cap — it rate-limits instead — but each agent user
  needs its own `claude` login, so check current concurrent-session terms before assuming it scales
  to three boxes.
- **Rotate every token that lived on the machine being replaced** — this is part of the migration, not
  optional hygiene. Include any `.env` already sitting in the human's own clone on the new box.
- Warn the human **not to paste token values into the session** — they would land in the transcript.
  They go straight from the browser into the agent's terminal.
- Verify (after Phase 4's clone exists): `.env` present in the agent's clone, mode `600`, owned by the
  agent user, containing **only** `GH_BOT_TOKEN`; bot write access confirmed with
  `bot-gh.sh api repos/<owner>/<repo> --jq .permissions` showing `"push": true` (a bare
  `bot-gh.sh repo view` succeeds on any public repo and proves nothing); old tokens confirmed revoked.

## Phase 4 — the agent's clone (`4-clone`)

Print for the human's terminal (needs a login shell as the agent user — `sudo -iu <agent_user>`):
- Install node (nvm) and the `claude` CLI in the agent's own home; authenticate `claude` once.
  Install **`gh` system-wide** (`sudo apt-get install -y gh`, as the admin) rather than per-home — the
  loop's systemd unit needs it on a predictable `PATH`, and later agent users get it for free.
- Install the fine-grained PAT as the push identity: `gh auth login --with-token` then
  `gh auth setup-git`. **Do not** put it in `.env` — the scripts source `.env` with `set -a`, so a
  `GH_TOKEN`/`GITHUB_TOKEN` there would shadow `bot-gh.sh`'s bot identity and break the
  bot-authored-PR property the owner's Approve depends on.
- `git clone` the target repo; write `.env` (Phase 3, `GH_BOT_TOKEN` only) and machine-local state —
  e.g. `.claude/state/ntfy-topic` if ntfy was chosen. If the topic is a public ntfy.sh one, mention
  that anyone who knows it can both read the alerts and publish fake ones; a random suffix fixes both.
- Re-run the `bwrap` smoke test **as the agent user** — a pass under the admin account does not
  transfer, and on Ubuntu ≥24.04 the AppArmor userns policy is per-executable.
- Verify from your side where possible (`sudo -u <agent_user> test -f ...` style checks via the human if
  your session can't): clone exists, `.env` mode `600`, `claude --version` and `gh --version` run as the
  agent user, `git ls-remote` succeeds, and `bot-gh.sh api user --jq .login` returns the **bot**, not
  the owner — the two identities must differ.

## Phase 5 — managed settings (`5-managed`, HARDENING steps 3–4)

- Materialize `/etc/claude-code/managed-settings.json` from HARDENING.md **Step 4**, root-owned `644`,
  with the sandbox **network allowlist here** (not in `settings.local.json`): Anthropic API, GitHub, the
  notifier host, package registries the gates need. **Read the adapter first** — if `install` is empty
  and the gates shell out to node/bash/git only, no package registry belongs in the list at all.
- **Do not include `permissions.disableBypassPermissionsMode`** unless the human has deliberately
  chosen `dontAsk`: it disables the bypass mode the loop runs in. See HARDENING.md Step 4's warning.
- If Phase 1 flagged the Ubuntu userns restriction, this is where `{"sandbox": {"enabled": false}}`
  gets written instead of the full block — per the decision taken in Phase 1.
- Verify: file parses as JSON; `ls -l` shows `root root 644`; a write attempt as the agent user fails.

## Phase 6 — harden profile + arm the loop (`6-arm`)

- In a Claude Code session **as the agent user, inside the agent's clone** (not the human's — see the
  field notes): run `/orchestrator:harden`, restart, `/sandbox`, and its backstop checks (`sudo true`
  blocked under bypass; an edit of `~/.bashrc` blocked). Note the "write outside the repo fails" check
  only applies when the app sandbox is on; with it disabled, the deny list and Unix permissions are
  the fence, and the check should be recorded as N/A rather than skipped silently.
- Confirm `settings.local.json` actually landed in the agent's clone before arming — it is gitignored
  and does not travel with a clone, and `/orchestrator:harden` reports success either way.
- Then, in the agent's real terminal: `bash .claude/scripts/arm-loop.sh` (self-hosting this repo:
  add `--gates-file self/gates.json`). Check the adapter's `budget.stop_after_days` — if it is large,
  pass an explicit short `--stop-after-days` for a first arming so the loop fails safe unattended.
- Units are named `pr-loop-<slug>.service` and `claude-rc-<slug>.service`, `<slug>` = repo directory
  name lowercased.
- Add the **user-unit-safe** hardening drop-in (HARDENING.md worked example step 4) by writing
  `~/.config/systemd/user/pr-loop-<slug>.service.d/hardening.conf`, then `daemon-reload` + restart.
  The full system-unit block crash-loops a `--user` unit with `218/CAPABILITIES`.
- To stop the loop, use `bash .claude/scripts/loop-halt.sh --all` — drivers run in transient units
  whose lifetime is decoupled from the daemon, so stopping the daemon alone leaves them running. Do
  this before Phase 7, or an in-flight driver will be severed by the new egress rules.
- Verify with `journalctl --user -u pr-loop-<slug>.service -n 20` showing a clean
  `loop-daemon: starting` line and `NRestarts` staying at 0 across a minute — **not** `is-active`,
  which reports `active` mid-restart. `systemd-analyze security --user` grades user units against
  system-unit expectations, so read its score as indicative only.

## Phase 7 — kernel egress + detection (`7-egress`, optional layers; HARDENING steps 5–6)

If chosen in the interview — and **after** halting the loop, so an in-flight driver isn't severed:
- nftables: materialize the worked example's UID-matched output chain for the agent user, allowed set =
  exactly the hosts from Phase 5's allowlist; **log the drops** and wire the drop log into the notifier —
  blocked egress from this box is the intrusion alarm. Run that notifier as **root**, since the chain
  matches the agent's UID. Load the table from its own oneshot unit if `ufw` is active (never enable
  `nftables.service` alongside ufw — it flushes the ruleset), use `policy accept` plus a trailing
  explicit `drop` rather than `policy drop`, and refresh the address set from DNS on a ~5-minute timer
  because CDN addresses rotate. Warn the human that the refresh race can produce occasional spurious
  drops, and that the coarse alternative (any-destination TCP 443) yields no exfiltration alarm.
- auditd watches on `.claude/scripts/`, `self/` (if self-hosting), `.env`, `settings.local.json`, the
  unit files, and the managed-settings file; journald `Storage=persistent` (often already satisfied if
  `/var/log/journal` exists); the root-owned origin/main divergence timer if the human wants it.
- Because the human's terminal mangles long pastes, **write these files yourself** into a scratch
  directory and hand over `sudo install` one-liners rather than heredocs.
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
