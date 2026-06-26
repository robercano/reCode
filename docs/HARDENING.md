# Hardening for Hands-Off (Autonomous) Operation

Running the loop **interactively** — you watch each tool call and approve it — is safe by default and
needs nothing here. This guide is for the next step: running the PR loop **hands-off** so the
orchestrator can scope → implement → review → open PRs without a human approving every command
(Claude Code `defaultMode: bypassPermissions`).

`bypassPermissions` removes the per-command prompt. That convenience is only safe if you replace the
prompt with two independent guardrails that don't depend on a human being awake. This guide explains
that security model, gives you a copy-paste starting config, and walks an OS-level lockdown (with a
concrete WSL2 example).

> **You do not need this to use the template.** Skip it entirely until you actually want unattended
> runs. When you do, treat the steps below as the price of admission — don't enable bypass without them.

---

## Security model (the one paragraph to internalize)

Two layers, each enforced **without a human in the loop**:

1. **Deny list** (`permissions.deny`) — evaluated *before any tool runs* and **always enforced, even
   under `bypassPermissions`**. This is your hard backstop: it blocks privilege escalation, secret/
   credential reads, network-exfil tools, destructive ops, and (on WSL) host/Windows interop —
   regardless of what the model decides to do.
2. **OS sandbox** — Claude Code's `sandbox` confines `Bash` writes to the repo + temp dirs and blocks
   reads of credential directories and host mounts at the kernel level (via `bubblewrap` on Linux). A
   bug or prompt-injection that slips past the deny list still can't write outside the repo or read
   your keys.

`bypassPermissions` only removes the *prompt*. The deny list and the sandbox are what keep an
unattended agent contained. Never enable bypass without both.

---

## Step 1 — Machine-local hardened profile (`settings.local.json`)

Put the hardened, bypass-enabled config in **`.claude/settings.local.json`**, not the committed
`settings.json`. Rationale:

- `settings.local.json` is **machine-local and gitignored** — bypass is a per-machine decision (your
  isolated agent box ≠ a teammate's laptop), so it should never be force-inherited by a clone.
- The committed `settings.json` stays at the safe interactive default (allow-list + small deny list).
- **Add it to `.gitignore`** if it isn't already:
  ```
  .claude/settings.local.json
  ```

Starting point — adapt the lists to your stack, then drop into `.claude/settings.local.json`:

```jsonc
{
  "permissions": {
    "defaultMode": "bypassPermissions",
    "deny": [
      // privilege escalation
      "Bash(sudo:*)", "Bash(doas:*)", "Bash(su:*)",
      // container escape (docker socket == root on host)
      "Bash(docker:*)",
      // raw network / exfil tools (let pnpm/gh do their own network)
      "Bash(curl:*)", "Bash(wget:*)", "Bash(nc:*)", "Bash(ncat:*)", "Bash(telnet:*)",
      // publishing / releasing — never from an unattended loop
      "Bash(npm publish:*)", "Bash(pnpm publish:*)", "Bash(yarn publish:*)",
      // credential & secret exfil via gh
      "Bash(gh auth token)", "Bash(gh auth token:*)", "Bash(gh secret:*)",
      // history rewrites & destructive fs ops
      "Bash(git push --force:*)", "Bash(git push -f:*)", "Bash(rm -rf:*)",
      // secret files — deny to the Read TOOL (see note below about .env)
      "Read(//**/.env)", "Read(//**/.env.*)",
      "Read(~/.ssh/**)", "Read(~/.aws/**)", "Read(~/.config/gcloud/**)",
      "Read(~/.kube/**)", "Read(~/.gnupg/**)", "Read(~/.npmrc)",
      "Read(~/.docker/config.json)",
      // host filesystem — WSL only; see Step 2
      "Bash(cmd.exe:*)", "Bash(powershell.exe:*)", "Bash(pwsh:*)", "Bash(wsl.exe:*)",
      "Bash(/mnt:*)", "Read(//mnt/**)", "Edit(//mnt/**)", "Write(//mnt/**)",
      "Edit(//etc/**)", "Write(//etc/**)"
    ]
  },
  "sandbox": {
    "enabled": true,
    "allowUnsandboxedCommands": true,
    "filesystem": { "denyRead": ["/mnt"] },
    "credentials": {
      "files": [
        { "path": "~/.ssh", "mode": "deny" },
        { "path": "~/.aws", "mode": "deny" },
        { "path": "~/.config/gcloud", "mode": "deny" },
        { "path": "~/.kube", "mode": "deny" },
        { "path": "~/.gnupg", "mode": "deny" },
        { "path": "~/.npmrc", "mode": "deny" },
        { "path": "~/.docker/config.json", "mode": "deny" }
      ]
    }
  }
}
```

> **`.env` gotcha (read this before you copy):** the PR loop scripts (`bot-gh.sh`, `notify-poll.sh`)
> `source .env` at the *shell* level to read `GH_BOT_TOKEN`. So `.env` is denied to the **Read tool**
> (the model can't open it) but must **not** be added to `sandbox.credentials` / `denyRead` — or the
> scripts can't read the token and the loop breaks. Tool-level deny ≠ shell-level block; that asymmetry
> is intentional.

> **`allowUnsandboxedCommands: true`** lets commands that genuinely can't run sandboxed (e.g. git
> worktrees created *outside* the repo) fall back to unsandboxed rather than fail. To keep full
> containment, keep worktree paths *inside* the repo.

---

## Step 2 — OS-level isolation

The deny list and sandbox are Claude Code's layers. Underneath them, lock the OS so a sandbox escape
has nowhere to go. The ideal is a **dedicated, disposable environment** for the agent (a separate VM,
container, cloud box, or a throwaway WSL distro) that holds only the repos and the bot token — if it's
ever compromised, you discard it with zero blast radius.

General principles, any OS:

- **No passwordless `sudo`** for the agent user (the deny list blocks `sudo`, but defense in depth).
- **Drop the agent user from the `docker` group** (docker socket access == root on the host). Run the
  agent as a user that is in neither `sudo`/`wheel` nor `docker`.
- **No standing cloud credentials** on the box beyond what a run needs.
- **Cut host-filesystem bridges** so the agent can't reach files outside the repo.

### Worked example: WSL2 (the reference setup)

This is the concrete lockdown used to develop the template. Adapt paths to your machine.

**Prerequisites** (the Linux sandbox backend):
```bash
sudo apt-get install -y bubblewrap socat
command -v bwrap socat        # both should resolve
```

**Sever Windows access at the WSL level** — edit `/etc/wsl.conf` (sudo):
```ini
[automount]
enabled = false
mountFsTab = false

[interop]
enabled = false
appendWindowsPath = false
```
- `automount enabled=false` → `/mnt/c,d,…` no longer mounted; the agent can't see Windows files.
- `interop enabled=false` + `appendWindowsPath=false` → can't launch `.exe` / `cmd.exe` / `powershell.exe`.

Apply from **Windows PowerShell**, then reopen WSL:
```powershell
wsl --shutdown
```
Verify inside WSL:
```bash
ls /mnt/c            # should fail — no such directory
command -v cmd.exe   # should print nothing
```

> ⚠️ This affects the **whole distro** — you lose `/mnt/c` in your own work too. If you need Windows
> access daily, use a **dedicated agent distro** instead: `wsl --install -d Ubuntu-24.04`, apply this
> `wsl.conf` there, install `bwrap`+`socat`, clone the repos, and run the agent only in it. If
> compromised: `wsl --unregister Ubuntu-24.04` — zero blast radius.

**Drop the docker group** (optional but recommended for true isolation):
```bash
sudo gpasswd -d "$USER" docker     # if you don't need Docker in this distro
```

---

## Step 3 — Activate and verify

1. **Restart Claude Code.** Settings changes don't always hot-reload, and bypass may require accepting
   the dangerous-mode dialog once.
2. Run **`/sandbox`** → confirm it resolves (sandbox backend detected).
3. If the loop's `gh` / package-manager network calls start prompting *under* the sandbox, allow the
   hosts it needs in `settings.local.json` → `sandbox.network.allowedDomains`, e.g.:
   ```json
   ["github.com", "*.github.com", "*.githubusercontent.com", "registry.npmjs.org", "*.npmjs.org"]
   ```
4. Confirm the deny list bites: ask the agent to run a denied command (e.g. `sudo true`) — it should be
   **blocked even though bypass is on**. That single check proves your backstop is live.

### Checklist
- [ ] `.claude/settings.local.json` exists, gitignored, with `bypassPermissions` + deny list + sandbox.
- [ ] Sandbox backend installed (`bwrap`/`socat` on Linux); `/sandbox` resolves.
- [ ] A denied command (e.g. `sudo`) is blocked under bypass.
- [ ] Host bridges cut (e.g. on WSL: `ls /mnt/c` fails, `cmd.exe` not found).
- [ ] Agent user not in `sudo`/`docker` groups (or running as a dedicated isolated user/VM/distro).
- [ ] `.env` readable by the loop scripts (NOT added to sandbox credentials) but denied to the Read tool.

---

## Caveats

- **Worktrees outside the repo** aren't writable under the sandbox; `allowUnsandboxedCommands: true`
  lets them fall back to unsandboxed instead of failing. Keep worktree paths inside the repo for full
  containment.
- **Open PRs gate loop advancement.** A typical loop won't start a new ticket while a PR is open —
  that's by design (it keeps you the merge gate). Review/merge to let it advance.
- **The committed `settings.json` is owned by the harness at runtime** (it may rewrite the working-tree
  copy with its session grant list). Keep bypass/sandbox in `settings.local.json`; if you ever do harden
  the committed file, see the `git update-index` note in its `_README`.

## See also
- [`USAGE.md`](USAGE.md) — driving the loop and closing it automatically (cron / `/loop`).
- [`TOKEN_BUDGET.md`](TOKEN_BUDGET.md) — unattended runs spend continuously; set a budget.
