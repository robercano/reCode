---
description: Arm hands-off mode — write the bypass + strict-sandbox profile into settings.local.json (per docs/HARDENING.md)
---

You are arming this project for **hands-off (autonomous) operation**: `bypassPermissions` + a strict OS
sandbox + an always-on deny list, so the PR loop can run without a human approving every command.
`docs/HARDENING.md` is the source of truth — this command materializes its **Step 1** config and then
tells the human which steps only they can finish (sudo / OS-level / restart).

> Run this **before** hardening (while still in the safe interactive mode). Once the hardened profile is
> active, the agent can no longer edit `.claude/settings*.json` (it's in the Edit/Write fence) — by design.

Do these in order. Stop and report if any step can't be completed.

## 1. Preconditions
- Read `docs/HARDENING.md` — its Step 1 JSON block is the canonical config; use it verbatim as the base.
- Confirm the sandbox backend: `command -v bwrap socat`. If either is MISSING, do NOT enable strict mode
  blindly — report it and point the user at HARDENING.md Step 2 (`sudo apt-get install -y bubblewrap socat`).
  You can still write the file, but warn that `failIfUnavailable: true` will refuse to start until they're installed.

## 2. Ensure `.claude/settings.local.json` is gitignored
- Check `git check-ignore .claude/settings.local.json`. If NOT ignored, append `.claude/settings.local.json`
  to `.gitignore`. Bypass is a per-machine decision and must never be inherited by a clone.

## 3. Write / merge the hardened profile into `.claude/settings.local.json`
- Materialize the **Step 1 block from `docs/HARDENING.md`**: `permissions.defaultMode = "bypassPermissions"`,
  the full `permissions.deny` list (privilege escalation, container escape, raw-network/exfil, publish,
  `gh auth token`/`secret`, force-push/`rm -rf`, secret-file Reads, WSL host interop, and the portable
  Edit/Write fence), and the strict `sandbox` block (`enabled: true`, `allowUnsandboxedCommands: false`,
  `failIfUnavailable: true`, the `denyRead`/`credentials` lists).
- **Merge, don't clobber:** if `settings.local.json` already exists, preserve any existing
  `permissions.allow` entries and merge the deny list (union, no dupes). Keep the result valid JSON.
- Do **not** touch the committed `.claude/settings.json` — it stays at the safe interactive default, and
  the harness owns it at runtime.
- Honor the `.env` gotcha: `.env` is denied to the **Read tool** but must **not** be added to
  `sandbox.credentials`/`denyRead`, or the loop scripts can't source `GH_BOT_TOKEN`.

## 4. Report what only the human can finish
Print a short checklist of the steps this command cannot do (they need a real terminal / sudo / restart):
- **Restart Claude Code** — bypass + sandbox changes don't hot-reload, and bypass needs the dangerous-mode
  dialog accepted once. Then run `/sandbox` to confirm the backend resolves.
- **OS-level isolation (HARDENING.md Step 2)** — cut host bridges (on WSL: `/etc/wsl.conf` automount+interop
  off), drop the agent user from `docker`/`sudo` groups, prefer a dedicated disposable distro/VM.
- **Verify the backstop bites:** after restart, ask the agent to run `sudo true` (should be **blocked**
  under bypass) and a write outside the repo (should **fail**, proving strict mode).
- Optional **managed settings (Step 4)** to make the policy un-overridable, and a **token budget** for
  unattended runs (see `docs/TOKEN_BUDGET.md`).

Finish with one line: the path written, whether the backend is present, and "restart required".
