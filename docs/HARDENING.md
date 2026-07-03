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

> **Shortcut:** the **`/harden`** command materializes the Step 1 config below into
> `.claude/settings.local.json` (merge-safe with existing entries, checks the sandbox backend is
> installed, ensures the file is gitignored) and prints the steps only you can finish — sudo, OS-level
> isolation, restart. Run it *before* enabling bypass, while the agent can still edit `settings*.json`.
> This page stays the reference for what it writes and for Steps 2–4.

---

## Security model (the one paragraph to internalize)

Layers, in order of how hard they are for the agent to get around — this ordering is the whole point:

1. **Deny list** (`permissions.deny`) — evaluated *before any tool runs* and **always enforced, even
   under `bypassPermissions`, even with the sandbox disabled**. This is your hard backstop: it blocks
   privilege escalation, secret/credential reads, network-exfil tools, destructive ops, and (on WSL)
   host/Windows interop — regardless of what the model decides, and the agent cannot talk its way
   around it. (Disabling the sandbox does *not* let a denied command run.)
2. **OS sandbox** — Claude Code's `sandbox` confines `Bash` writes to the repo + temp dirs and blocks
   reads of credential directories and host mounts at the kernel level (`bubblewrap` on Linux,
   Seatbelt on macOS). **Caveat under `bypassPermissions`:** by default (`allowUnsandboxedCommands:
   true`) the agent can retry any command with `dangerouslyDisableSandbox: true`, and because bypass
   skips the prompt, that retry just *runs*. So out of the box the sandbox stops **accidental**
   escapes, not a determined/injected agent. **Set `allowUnsandboxedCommands: false` ("strict sandbox
   mode")** to close that hole — then a command that can't run sandboxed *fails* instead of escaping.
3. **OS-level isolation** (Step 2) and **managed settings** (Step 4) — these live *below* Claude Code;
   no tool flag or local-settings edit can touch them. This is the only layer that contains the agent
   itself rather than its accidents.

`bypassPermissions` only removes the *prompt*. The deny list is your always-on backstop; strict-mode
sandbox + OS isolation are what actually contain a misbehaving agent. Never enable bypass without all
of them — and don't mistake the default (non-strict) sandbox for a cage.

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
      "Edit(//etc/**)", "Write(//etc/**)",

      // ── Edit/Write fence (PORTABLE — copy as-is, no project paths) ──────────
      // The Edit/Write TOOLS are NOT confined by the OS Bash sandbox (that only
      // confines Bash subprocesses). Their only fence is the deny list + OS file
      // ownership. Deny the sensitive paths OUTSIDE any project; the project stays
      // writable by omission (deny beats allow, so you can't "allow-back" — see note).
      // shell init & profile (run on next shell = persistence / code-exec)
      "Edit(~/.bashrc)", "Write(~/.bashrc)",
      "Edit(~/.bash_profile)", "Write(~/.bash_profile)",
      "Edit(~/.profile)", "Write(~/.profile)",
      "Edit(~/.zshrc)", "Write(~/.zshrc)",
      "Edit(~/.zprofile)", "Write(~/.zprofile)",
      "Edit(~/.zshenv)", "Write(~/.zshenv)",
      // git config (hooks / aliases = code-exec on next git command)
      "Edit(~/.gitconfig)", "Write(~/.gitconfig)",
      "Edit(~/.config/git/**)", "Write(~/.config/git/**)",
      // credentials (Edit/Write — Read already denied above)
      "Edit(~/.ssh/**)", "Write(~/.ssh/**)",
      "Edit(~/.gnupg/**)", "Write(~/.gnupg/**)",
      "Edit(~/.aws/**)", "Write(~/.aws/**)",
      "Edit(~/.config/gcloud/**)", "Write(~/.config/gcloud/**)",
      "Edit(~/.kube/**)", "Write(~/.kube/**)",
      "Edit(~/.npmrc)", "Write(~/.npmrc)",
      "Edit(~/.docker/config.json)", "Write(~/.docker/config.json)",
      // login-time / startup persistence
      "Edit(~/.config/systemd/**)", "Write(~/.config/systemd/**)",
      "Edit(~/.config/autostart/**)", "Write(~/.config/autostart/**)",
      // Claude Code's OWN guardrails — surgical, NOT all of ~/.claude (memory/state live there)
      "Edit(~/.claude/settings.json)", "Write(~/.claude/settings.json)",
      "Edit(~/.claude/settings.local.json)", "Write(~/.claude/settings.local.json)",
      // this project's permission files (stop the agent removing its own deny rules)
      "Edit(.claude/settings.json)", "Write(.claude/settings.json)",
      "Edit(.claude/settings.local.json)", "Write(.claude/settings.local.json)"
    ]
  },
  "sandbox": {
    "enabled": true,
    "allowUnsandboxedCommands": false,   // strict: agent can't escape the sandbox per-command
    "failIfUnavailable": true,           // fail-closed if bwrap/socat missing — don't silently run unsandboxed
    "excludedCommands": [],              // glob patterns that legitimately MUST run outside the sandbox
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

> **The Edit/Write fence — and why it's a denylist, not "everything except the project".** The OS
> sandbox confines *Bash subprocesses* only; the **`Edit`/`Write` tools are not sandboxed** — their
> sole fences are the deny list and OS file ownership. So under bypass, an unfenced agent could write
> `~/.bashrc`, `~/.gitconfig`, or its own `.claude/settings*.json` even though it can't `cd` out of the
> repo in Bash. You'd like to say "deny all of `~` except this project," but **deny always beats allow
> in Claude Code — there's no allow-back exception** — so a blanket `~/**` deny would block the project
> too. The portable workaround is the block above: deny the *sensitive paths outside any project*
> (shell init, git config, credentials, startup persistence, Claude's own guardrails). It contains
> **zero project-specific paths**, so it's copy-paste identical across every repo — the project is
> writable purely *by omission*.
>
> Two consequences to know: (1) This is a curated denylist, **not hermetic** — sibling repos and other
> home files you didn't enumerate stay writable. For true "only the project is writable" containment,
> use the **OS layer** (Step 2): run the agent as a dedicated user/distro that *owns nothing but the
> repo*, so every other write fails on file permissions regardless of Claude Code's policy. The denylist
> is defense-in-depth on top of that. (2) Denying `.claude/settings*.json` means the **agent can no
> longer edit its own permission files** — exactly the point (it can't quietly remove its guardrails),
> but it also means *you* change that file directly or via `!`, not by asking the agent.

> **Strict mode (`allowUnsandboxedCommands: false`) is the high-leverage setting.** With the default
> `true`, the agent can retry any failing command with `dangerouslyDisableSandbox: true` and — under
> bypass — that retry runs with no prompt, so the agent can self-serve its way out of the sandbox.
> `false` makes such a command *fail* instead. The cost: commands that genuinely can't run sandboxed
> (e.g. git worktrees created *outside* the repo, or committing to a sibling repo) now fail rather than
> falling back. Handle those explicitly:
> - Keep worktree paths *inside* the repo (the loop's default) so they don't need to break out.
> - For the rare command that truly must run unsandboxed, add a glob to `excludedCommands` (e.g.
>   `"git -C /other/repo *"`) — an allowlist you control, not a blanket escape hatch.
>
> **`failIfUnavailable: true`** refuses to start if the sandbox backend (`bwrap`/`socat`) is missing,
> instead of silently falling back to *no* sandbox — fail-closed, so a broken install can't quietly
> drop your containment.

> **Toolchain caches will trip strict mode — allowlist the *paths*, not the commands.** Your gate
> commands write to package-manager caches *outside* the repo: pnpm → `~/.local/share/pnpm` +
> `~/.cache/pnpm`, npm → `~/.npm`, Foundry → `~/.foundry` + solc downloads to `~/.svm`, and similarly
> Cargo `~/.cargo`, Go `~/.cache/go-build`, Maven `~/.m2`, etc. Under strict mode these *fail*. Add the
> specific cache dirs to **`sandbox.filesystem.allowWrite`** — this keeps the command sandboxed while
> permitting just its cache. Do **not** reach for `excludedCommands` here: that runs the *whole* command
> unsandboxed, and `pnpm install` / `npm install` execute untrusted dependency lifecycle scripts you do
> *not* want loose. Reserve `excludedCommands` for commands that genuinely can't be sandboxed at all
> (e.g. a git op against a repo outside the sandbox root). Network access (registry, GitHub) is a
> separate axis — see `sandbox.network.allowedDomains` in Step 3.

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
5. Confirm strict mode bites: ask for a command that must write outside the repo — it should *fail*
   (not silently escape). If it falls back instead, `allowUnsandboxedCommands` isn't `false` yet.

### Checklist
- [ ] `.claude/settings.local.json` exists, gitignored, with `bypassPermissions` + deny list + sandbox.
- [ ] Sandbox backend installed (`bwrap`/`socat` on Linux); `/sandbox` resolves.
- [ ] `allowUnsandboxedCommands: false` (strict) + `failIfUnavailable: true` set.
- [ ] A denied command (e.g. `sudo`) is blocked under bypass.
- [ ] Edit/Write fence in place (deny block above) — an `Edit`/`Write` to `~/.bashrc` is blocked.
- [ ] A write outside the repo *fails* rather than escaping (proves strict mode).
- [ ] Host bridges cut (e.g. on WSL: `ls /mnt/c` fails, `cmd.exe` not found).
- [ ] Agent user not in `sudo`/`docker` groups (or running as a dedicated isolated user/VM/distro).
- [ ] `.env` readable by the loop scripts (NOT added to sandbox credentials) but denied to the Read tool.

---

## Step 4 — Make the policy un-overridable (managed settings)

Everything above lives in `settings.local.json` — which the agent itself (or a clone, or a careless
edit) can rewrite. For a genuinely autonomous box, lift the policy *above* the agent into **managed
settings**, a root-owned file the agent can't touch:

- Linux/WSL: `/etc/claude-code/managed-settings.json`
- macOS: `/Library/Application Support/ClaudeCode/managed-settings.json`
- Windows: `C:\Program Files\ClaudeCode\managed-settings.json`

```jsonc
{
  "permissions": {
    "disableBypassPermissionsMode": "disable"   // pins the bypass decision; local settings can't widen it
  },
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "allowManagedReadPathsOnly": true,          // local settings can't widen read scope
    "allowManagedDomainsOnly": true             // local settings can't widen network allowlist
  }
}
```

Managed settings win over every other scope, and deny rules from any scope still beat allow rules from
a lower one. This is the software-side equivalent of the OS-level isolation in Step 2: a boundary the
agent operates *inside*, not one it configures.

> **Choosing the permission mode.** `bypassPermissions` is one of several `defaultMode` values. For a
> **fully headless / CI** box where no human will ever approve a prompt, consider `"dontAsk"` instead —
> it *fail-closes*, auto-denying anything not explicitly in `permissions.allow` (vs. bypass, which
> fail-*opens* on everything except the deny list). Bypass suits an attended-but-quiet loop; `dontAsk`
> suits a locked-down pipeline.

---

## Caveats

- **Worktrees outside the repo** aren't writable under the sandbox. Under strict mode
  (`allowUnsandboxedCommands: false`, recommended) such a write *fails* rather than escaping — so keep
  worktree paths inside the repo, or allowlist the specific command via `excludedCommands`.
- **Open PRs gate loop advancement.** A typical loop won't start a new ticket while a PR is open —
  that's by design (it keeps you the merge gate). Review/merge to let it advance.
- **The committed `settings.json` is owned by the harness at runtime** (it may rewrite the working-tree
  copy with its session grant list). Keep bypass/sandbox in `settings.local.json`; if you ever do harden
  the committed file, see the `git update-index` note in its `_README`.
- **Sandbox masks show up in `git status`.** The sandbox masks sensitive config paths inside the repo
  (shell rc files, `.gitconfig`, `.mcp.json`, `.claude/{hooks,skills,routines}`, editor dirs like
  `.vscode`/`.idea`) as `/dev/null` **character-device nodes**, and `git status` lists them as untracked
  (`crw-` in `ls -l`). They're expected sandbox artifacts, not real files: never stage them — a blanket
  `git add -A`/`git commit -a` can try to index a device node and abort the commit. Stage explicit paths
  instead. The `implementer` and `orchestrator` agent prompts already encode this rule for workers.

## See also
- [`USAGE.md`](USAGE.md) — driving the loop and closing it automatically (cron / `/loop`).
- [`TOKEN_BUDGET.md`](TOKEN_BUDGET.md) — unattended runs spend continuously; set a budget.
