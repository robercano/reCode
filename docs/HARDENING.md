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

### Protected-paths guard (issue #94 Layer 2)

A deterministic backstop against an injected instruction that tries to get an agent to edit the loop's
own control plane and have that change auto-merged. The adapter (`.claude/gates.json`, resolved via
`GATES_FILE`) carries a `protectedPaths` array of glob patterns; any agent-authored PR whose diff touches
a matching path is never auto-merged — `merge-ready.sh` blocks the merge and labels the PR `needs-human`
regardless of owner approval or green CI, and reviewers hard-reject it outright (see
`.claude/agents/reviewer.md`). The shipped root adapter defaults this to a protective set
(`.claude/**`, `.github/workflows/**`, `gates.json`, `**/gates.json`) so downstream adopters' harness and
CI files can't be silently rewritten by an agent. This repo's own self-adapter
(`self/gates.json`) overrides it to an empty array, which disables the guard — reCode's harness
files under `.claude/` ARE the product, so legitimate slices of work must remain mergeable when the loop
runs self-hosted. A fuller writeup is deferred to follow-up issue #166.

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
      "Bash(/mnt:*)", "Read(//mnt/**)", "Edit(//mnt/**)",
      "Edit(//etc/**)",

      // ── Edit/Write fence (PORTABLE — copy as-is, no project paths) ──────────
      // The Edit/Write TOOLS are NOT confined by the OS Bash sandbox (that only
      // confines Bash subprocesses). Their only fence is the deny list + OS file
      // ownership. Deny the sensitive paths OUTSIDE any project; the project stays
      // writable by omission (deny beats allow, so you can't "allow-back" — see note).
      //
      // USE `Edit(path)` ONLY — NOT `Write(path)`. File permission checks match
      // `Edit(...)` rules, and an Edit rule covers EVERY file-editing tool
      // (Edit, Write, NotebookEdit). A `Write(...)` rule matches nothing; Claude
      // Code emits a startup warning per rule and the path is left unfenced if
      // that is the only rule you wrote for it. Pairing both was harmless but
      // noisy, so the twins were removed here.
      // shell init & profile (run on next shell = persistence / code-exec)
      "Edit(~/.bashrc)",
      "Edit(~/.bash_profile)",
      "Edit(~/.profile)",
      "Edit(~/.zshrc)",
      "Edit(~/.zprofile)",
      "Edit(~/.zshenv)",
      // git config (hooks / aliases = code-exec on next git command)
      "Edit(~/.gitconfig)",
      "Edit(~/.config/git/**)",
      // credentials (Edit/Write — Read already denied above)
      "Edit(~/.ssh/**)",
      "Edit(~/.gnupg/**)",
      "Edit(~/.aws/**)",
      "Edit(~/.config/gcloud/**)",
      "Edit(~/.kube/**)",
      "Edit(~/.npmrc)",
      "Edit(~/.docker/config.json)",
      // login-time / startup persistence
      "Edit(~/.config/systemd/**)",
      "Edit(~/.config/autostart/**)",
      // Claude Code's OWN guardrails — surgical, NOT all of ~/.claude (memory/state live there)
      "Edit(~/.claude/settings.json)",
      "Edit(~/.claude/settings.local.json)",
      // this project's permission files (stop the agent removing its own deny rules)
      "Edit(.claude/settings.json)",
      "Edit(.claude/settings.local.json)"
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

> **Git config/hook writes are denied by default — and you can't re-enable them in-sandbox. Use a real
> terminal.** The sandbox lets `git commit` update refs and the index but keeps `.git/config` **and**
> `.git/hooks/` writes denied (see the [sandbox docs](https://code.claude.com/docs/en/sandboxing):
> *"Writes to `hooks/` and `config` inside that directory remain denied"*). That's on purpose — git
> config and hooks are an **arbitrary-code-execution surface** (`core.pager`, `core.fsmonitor`,
> `core.hooksPath`, `alias.* = !cmd`, `filter.*.clean/smudge`, a committed `pre-commit` hook…), any of
> which fires the next time git runs. So the mask is *why* `git config --local`, `git remote add`, and
> upstream tracking fail under strict mode while ordinary `git commit`/`diff`/`log` work. It's enforced
> as a **`/dev/null` bind-mount over `.git/config.lock`**: git creates that lockfile with
> `O_CREAT|O_EXCL` before renaming it over `config`, and the device node already occupying the path makes
> the exclusive-create fail — hence `error: could not lock config file .git/config: File exists`. It's
> also the phantom `crw-` `config.lock` you see in `git status` (see Caveats).
>
> **`sandbox.filesystem.allowWrite` does *not* lift this** — verified 2026-07-07: with
> `allowWrite: [".git/config", ".git/config.lock", ".git/worktrees"]` set and Claude Code restarted, the
> `/dev/null` mask on `.git/config.lock` persisted and `git config --local` still failed with `File
> exists`. The mask is applied at the **mount layer** as a built-in git protection; `allowWrite` only
> adjusts the **permission layer**, so it can't dislodge the bind-mount. Don't add these paths to
> `allowWrite` expecting config writes to work — they won't.
>
> The only setting that removes the mask is `excludedCommands: ["git"]`, and you should **not** use it:
> that runs git *and every subprocess it spawns* fully **unsandboxed**, so a poisoned pager/hook/alias
> executes with network, credential-dir, and host-filesystem access — you've handed the ACE surface a way
> out (and `excludedCommands` has a [write/unlink bug, #39078](https://github.com/anthropics/claude-code/issues/39078)
> on top). Keeping git sandboxed is the whole point; the config mask is a feature, not a bug.
>
> **So when you genuinely need a git config/hook write** (`git config`, `git remote add`, setting
> upstreams, installing a hook), run it in a **real terminal outside Claude Code** — the mask exists only
> inside the sandbox, so the same command works normally there. This is the same rule as `git config
> --global` / `~/.gitconfig` edits (see Caveats). Note `git commit`, `git worktree add` (basic), and ref
> updates are *not* affected — those write refs/index/HEAD, which the sandbox allows.

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

> **Gotcha — cutting `/mnt` breaks any tool pinned to a Windows binary.** WSL+Windows setups often
> point Linux tools at Windows executables under `/mnt/c`. Once `/mnt` is gone those fail with
> `cannot run /mnt/c/.../foo.exe: No such file or directory`. The common one is **git's SSH**: a global
> `core.sshCommand = /mnt/c/Windows/System32/OpenSSH/ssh.exe` (and often a `~/.zshrc`/`~/.bashrc`
> `alias ssh=...exe`) makes `git push` fail. Fix — switch to the Linux toolchain:
> ```bash
> sudo apt-get install -y openssh-client          # provides /usr/bin/ssh
> git config --global --unset core.sshCommand      # fall back to the Linux ssh on PATH
> # then either add a Linux SSH key to GitHub, or move the remote to https + `gh auth setup-git`
> ```
> Also scrub any `alias ssh=/mnt/...exe` from your shell rc. Same applies to editors, credential
> helpers, or `GIT_*` vars pointed at `.exe` paths.

### Worked example: dedicated Linux server (maximum containment)

> **Working files:** [`examples/dedicated-server/`](../examples/dedicated-server/) carries the
> nftables fence, egress alarm, auditd rules, divergence tripwire and systemd drop-in from a real
> run of this section on bare-metal Ubuntu 26.04, with the reasoning behind each choice.

> **Guided:** run **`/orchestrator:provision`** on the new box to be walked through this section
> interactively — an interview, phase-by-phase checkpoints with verification, and resumable progress in
> `.claude/state/provision-progress.json`. This section stays the source of truth; the command executes it.

A dedicated server (or VM/cloud box) is the strongest home for the loop, because it fixes the two
things a shared machine can't: a **real privilege boundary** between the agent and you (on WSL you and
the agent are the same user, so Step 4's root-owned policy is decoration), and **kernel-level egress
control**. The goal state: when something gets through, it lands in a disposable box holding one
narrow token — containment, not immunity. The residual risks (your PR review as the merge gate,
GitHub as a sanctioned exfil channel, supply chain of `claude`/`gh`/`node`/kernel) are irreducible;
everything below is about making compromise cheap to survive and easy to notice.

**1. A dedicated user that owns nothing but the loop.** You SSH in as yourself and drop *down* into
the agent; the agent's account has no keys, no sudo, no way back up:

```bash
sudo useradd -m -s /bin/bash recode-agent      # NOT in sudo/wheel/docker/adm
sudo loginctl enable-linger recode-agent        # user units run without a login session
sudo -iu recode-agent                           # how YOU inspect/operate it
```

No `~/.ssh/authorized_keys` for `recode-agent` — it is reachable only via your account + `sudo -u`.

**2. Fresh credentials, minted for the box (never copied from your workstation):**
- A **fine-grained GitHub PAT** — the loop's **push identity**. Install it with
  `gh auth login --with-token` + `gh auth setup-git` as the agent user; **do not put it in `.env`.**
  The scripts source `.env` with `set -a`, so a `GH_TOKEN`/`GITHUB_TOKEN` there would be exported into
  *every* `gh` call — including `bot-gh.sh`, which would then run as the owner instead of the bot, and
  the owner could no longer formally approve the resulting PRs. `.env` holds `GH_BOT_TOKEN` and
  nothing else token-shaped. Mint it at github.com → *Settings → Developer settings → Personal access
  tokens → Fine-grained tokens → Generate new token*:
  - **Resource owner**: the account/org that owns the target repo(s).
  - **Repository access**: *Only select repositories* → the target repo(s), nothing else.
  - **Repository permissions** — exactly these, everything else stays *No access*:
    | Permission | Level | Why the loop needs it |
    |---|---|---|
    | Contents | Read and write | push branches / read the repo |
    | Issues | Read and write | file + label loop issues |
    | Pull requests | Read and write | open, update, comment on PRs |
    | Metadata | Read-only | mandatory (auto-selected) |
    | Workflows | Read and write — **only if** the loop may push changes under `.github/workflows/` | without it such pushes are refused (workflow-scope push restriction); leave at *No access* and keep CI files human-edited otherwise |
    | Actions | **No access** | the loop reads CI state (`statusCheckRollup`, failing-check detection) through `bot-gh.sh`, i.e. on the *bot's* classic token — whose `repo` scope already covers the Actions API. Granting Actions here adds reach nothing consumes. |
  - **No account permissions, nothing administrative.** Set an **expiration** (≤90 days) and put the
    rotation date somewhere you'll see it.
- The **bot token** (`GH_BOT_TOKEN` for `bot-gh.sh`) is a separate credential and deliberately
  **classic**, not fine-grained — fine-grained PATs cannot reliably target repos owned by another
  personal account, and the bot is its own machine account. Mint it *as the bot*: *Settings →
  Developer settings → Tokens (classic) → Generate new token (classic)* with the single `repo` scope,
  expiry set. Full one-time bot setup (machine account, write-collaborator invite) is in the notes at
  the top of `.claude/scripts/bot-gh.sh`.
  **`repo` only — never add `workflow`.** With `workflow` the bot could edit `.github/workflows/`
  through the Contents API, re-opening from the bot's side the boundary you closed by leaving
  *Workflows* at *No access* on the fine-grained PAT. Verify the grant with
  `bot-gh.sh api repos/<owner>/<repo> --jq .permissions` → expect `"push": true` (a bare
  `bot-gh.sh repo view` proves nothing on a public repo).
  **One bot, many repos = one shared credential.** `bot-gh.sh` reuses a single machine account across
  every repo (GitHub ToS allows one free one), so the same `GH_BOT_TOKEN` ends up in each agent user's
  `.env`. Per-repo Unix users isolate the *fine-grained* PATs from each other but **not** the bot
  token: compromise of any one agent user yields bot-write on all of them. Org-owned repos avoid this
  (fine-grained PATs work reliably there, so each agent can hold its own per-repo bot token).
- A **dedicated Anthropic API key** with a spend cap set in the console.
- Rotate whatever token previously lived on the old machine as part of the migration.

**3. Managed settings, now with teeth (Step 4).** Install the Step 4 file at
`/etc/claude-code/managed-settings.json`, root-owned `644`. Because the agent user can't write it or
escalate, `disableBypassPermissionsMode` / `allowManagedDomainsOnly` / `allowManagedReadPathsOnly`
become structural guarantees rather than conventions. Put the sandbox network allowlist here, not in
`settings.local.json`.

**4. systemd unit hardening.** `arm-loop.sh` stamps **user** units (`pr-loop-<slug>.service` and
`claude-rc-<slug>.service`, where `<slug>` is the repo directory name lowercased). Add a drop-in as
`recode-agent` at `~/.config/systemd/user/pr-loop-<slug>.service.d/hardening.conf`:

```ini
[Service]
NoNewPrivileges=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
UMask=0077
MemoryMax=8G
CPUQuota=200%
```

> ⚠️ **This is the user-unit-safe set. Do not paste the full system-unit block into a `--user` unit.**
> `ProtectKernelModules=`, `ProtectKernelTunables=` and `ProtectControlGroups=` imply
> `CapabilityBoundingSet=` changes, and `PR_CAPBSET_DROP` requires `CAP_SETPCAP` — which an
> unprivileged `systemd --user` manager does not have. The daemon then dies before it starts with
> `status=218/CAPABILITIES` ("Failed to drop capabilities: Operation not permitted") and restart-loops
> indefinitely; `systemctl --user is-active` may still report `active` because it catches the unit
> mid-restart, so **always confirm with `journalctl --user -u pr-loop-<slug>.service -n 20`**.
>
> `ProtectSystem=strict`, `ReadWritePaths=` and `PrivateTmp=` need **mount** namespaces, which need
> `CAP_SYS_ADMIN` in a user namespace — unavailable under the Ubuntu ≥24.04 userns restriction (see
> the AppArmor subsection below). Test them one at a time and drop them if the unit fails to start.
>
> For the **full** directive set — including real filesystem confinement — promote the loop to a
> **system** unit with `User=recode-agent`, where systemd has the privileges to enforce it. The
> trade-off: `arm-loop.sh` writes user units, so every re-arm re-creates them and your system unit
> must be maintained alongside.

This constrains even *merged, reviewed* daemon code — the layer nothing else on this page provides.
(`MemoryMax`/`CPUQuota` also stop a runaway driver from taking the box down.)

**4a. Ubuntu ≥24.04: the app-layer sandbox and the userns restriction collide.** On a stock
bare-metal Ubuntu 24.04+ install (unlike WSL2, whose Microsoft kernel does not enforce the policy),
`kernel.apparmor_restrict_unprivileged_userns=1` is active and `/etc/apparmor.d/bwrap-userns-restrict`
stacks every process `bwrap` execs into the `unpriv_bwrap` profile, which contains `audit deny
capability`. Claude Code shells out to `/usr/bin/bwrap` and then builds a **second** namespace inside
it for its seccomp layer — which needs `CAP_SYS_ADMIN` in that child. Result: every Bash call fails
with

```
apply-seccomp: write /proc/self/setgroups
  (nested userns is capability-restricted; caller must provide CAP_SYS_ADMIN): Permission denied
```

and, because `failIfUnavailable: true` is fail-closed, **the loop cannot run at all**. Diagnosis
notes, so you don't re-derive them: `bwrap --ro-bind / / true` *passes* (the restriction is not a
kernel-wide userns block); `cat /proc/self/attr/current` returns `unconfined` outside bwrap and
`bwrap//&unpriv_bwrap (enforce)` inside; `strace -f -e trace=execve` shows the `execve("/usr/bin/bwrap", …)`.
Flatpak-style single-layer bwrap use is unaffected — only nested sandboxing collides.

Three ways out, in the order we'd pick them:

| Option | What it costs |
|---|---|
| **Disable the app sandbox** (`{"sandbox": {"enabled": false}}` in managed settings) and rely on the dedicated UID, `0750` home, the `Edit()` deny fence, systemd hardening, and step 5's egress allowlist | Loses filesystem confinement *within* the agent's own home. Coherent on a dedicated box, where the OS boundaries are real — which is exactly what WSL never had. |
| **Grant the capability back to bwrap children**: `echo 'allow capability sys_admin,' > /etc/apparmor.d/local/unpriv_bwrap && apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict` | Re-opens the userns→`CAP_SYS_ADMIN` kernel attack surface for anything that can run bwrap — i.e. the agent you are containing. Keep the kernel patched if you take it. |
| **`sysctl kernel.apparmor_restrict_unprivileged_userns=0`** | **Don't.** Removes the mitigation for *every* binary on the box to fix one program's nesting. |

Note that dropping only `sandbox.network` does **not** help — the capability is required by the core
seccomp layer, not just the domain-filtering proxy. (Tested; it fails identically.)

**5. Kernel-level egress allowlist.** The app-layer sandbox can in principle be escaped; an nftables
rule matched on the agent's UID cannot be talked around by an injected model. Allow only what the
loop needs — the Anthropic API, GitHub, your notifier — and **log the drops**:

```bash
# /etc/nftables.d/recode-agent.nft — adjust the resolver/set mechanics to taste;
# domain-based filtering needs a resolving frontend (e.g. a local proxy) or periodic set refresh.
table inet recode_agent {
  set allowed_v4 { type ipv4_addr; }
  set allowed_v6 { type ipv6_addr; }

  chain output {
    type filter hook output priority 0; policy accept;
    # JUMP on a positive UID match — do NOT write `meta skuid != <uid> accept`.
    # Kernel-generated packets (ICMPv6 MLD/ND, DHCP renewal) have NO owning
    # socket, so `skuid != N` never matches them and they fall through to the
    # drop below — silently filtering the host's own network stack. The symptom
    # arrives days later as a lease that won't renew or IPv6 quietly degrading,
    # with nothing to connect it back to this file.
    meta skuid 1001 jump agent_out             # numeric uid; `id -u <agent>`
  }

  chain agent_out {
    oifname "lo" accept
    ct state established,related accept
    # Link-local multicast is local discovery noise: deny WITHOUT the log
    # prefix, or mDNS/MLD will page you forever and the alarm stops being read.
    ip  daddr 224.0.0.0/4 drop
    ip6 daddr ff00::/8 drop
    udp dport 53 accept                        # DNS (or pin to a local resolver)
    tcp dport 53 accept
    ip  daddr @allowed_v4 tcp dport 443 accept # refreshed from DNS on a timer
    ip6 daddr @allowed_v6 tcp dport 443 accept
    counter log prefix "recode-agent-egress-drop " level warn drop
  }
}
```

Wire the drop log to your notifier — blocked egress from this box is your intrusion alarm, not noise.
(Run that notifier as **root**: the chain matches the agent's UID, so root's own `curl` to the notifier
is not subject to the allowlist it is reporting on.)

Three things the sketch above glosses over, learned the hard way:

- **Coexisting with `ufw`.** If `ufw` is active, do **not** enable `nftables.service` — it runs
  `/etc/nftables.conf`, which conventionally starts with `flush ruleset` and would wipe ufw's rules at
  boot. Load your table from its own `oneshot` unit (`ExecStart=/usr/sbin/nft -f …`,
  `ExecStop=/usr/sbin/nft delete table inet recode_agent`, `After=ufw.service`) so it only ever adds
  its own table.
- **`policy accept` + an explicit trailing `drop`,** not `policy drop`. A UID-matched chain with a drop
  policy will bite anything you forgot, including your own recovery shell, on a box you may only reach
  over SSH.
- **The allowlist rots.** GitHub and Anthropic sit behind CDNs whose addresses rotate, so a static IP
  set silently breaks the loop days later. Refresh it from DNS on a timer (5 minutes works) and accept
  a small race: the loop can resolve an address the set does not yet contain and get dropped. If you
  would rather not run a resolver-refresh loop, the alternative is coarse — permit DNS and TCP 443 to
  *any* destination — but understand that this stops odd ports and non-HTTPS exfil only, and gives you
  no meaningful exfiltration alarm, which is most of the value.
- **Resolve the hosts the agent actually contacts, not the ones you assume.** `statsig.anthropic.com`
  (in an earlier version of this list) has **no A record**; Claude Code's feature-flag traffic goes to
  `api.statsig.com` / `statsigapi.net` / `events.statsigapi.net` / `featureassets.org`, on Google
  Cloud. Leaving them out is defensible — the loop works without telemetry — but it pages you forever,
  and an alarm that cries wolf gets ignored. Decide deliberately; don't discover it as noise.
- **Alerts must be readable and de-duplicated.** A raw kernel log line (`IN= OUT= SRC= DST= LEN=…`)
  is unreadable on a phone. Parse `DST`/`DPT`/`PROTO`, reverse-resolve the address, and suppress
  repeats per destination (15 minutes works) — otherwise one blocked endpoint produces dozens of
  identical pushes and the channel becomes noise.

**6. Detection.** Single-purpose boxes make auditing cheap:
- `auditd` watches on `.claude/scripts/`, `.claude/self/`, `.env`, and the unit files — any write
  outside an expected driver window is an alert.
- A root-owned timer that alerts when the checkout's daemon-executed paths diverge from
  `origin/main` (the census's `main_dirty=` line, enforced from *outside* the agent's trust zone).
- Persistent journald (`Storage=persistent`) so a post-incident timeline survives a reboot.

**7. Migration mechanics** (from a WSL/workstation install): install `bubblewrap` + `socat` (on
Debian-family kernels check unprivileged user namespaces are enabled — and read **4a** first, because
on Ubuntu ≥24.04 "enabled" does not mean the app sandbox will work), fresh clone as `recode-agent`,
write `.env` and any machine-local state (e.g. `.claude/state/ntfy-topic`), apply Steps 1–4, then
re-arm with `arm-loop.sh`. WSL-specific mitigations (interop/`/mnt` severing, the Windows-side
watchdog) retire with the old host — as do any `//mnt/**` deny rules, which are dead weight elsewhere.

Two traps in that sequence:

- **Run `/orchestrator:harden` *inside the agent's clone*, as the agent user.** It writes
  `.claude/settings.local.json`, which is **gitignored** — so it does not travel with a `git clone`,
  and running the command in your own checkout silently hardens the wrong copy while reporting
  success. Symptom: the agent's Claude Code sessions print only the committed-`settings.json`
  warnings and none of the local deny rules. Verify with
  `ls -l ~<agent>/<repo>/.claude/settings.local.json` before arming, and confirm
  `grep defaultMode` shows `bypassPermissions`.
- **Install a per-repo agent user per repo, not one shared account.** Three loops under one UID means
  three repos' `.env` files readable by one compromised process, which makes the per-repo PAT scoping
  decorative. Ubuntu's default `HOME_MODE=0750` plus a private user group already prevents one agent
  user from traversing another's home — no `chmod` needed. Box-global phases (prerequisites, managed
  settings, the nftables table, remote SSH) are done once and shared; only the user, credentials,
  clone, and arming repeat.

**Checklist deltas** (on top of the Step 3 checklist):
- [ ] Agent user has no sudo/docker membership, no SSH keys, reachable only via your account
      (`sudo -l -U <agent>` and `sudo ls ~<agent>/.ssh` — check as root; a permission-denied from your
      own account proves nothing).
- [ ] Managed settings root-owned; agent cannot edit `/etc/claude-code/`.
- [ ] `settings.local.json` exists **in the agent's clone** with `defaultMode: bypassPermissions`.
- [ ] Unit hardening drop-in uses the **user-unit-safe** directive set, and
      `journalctl --user -u pr-loop-<slug>.service` shows a clean `loop-daemon: starting` line
      (not `218/CAPABILITIES`). `is-active` alone is not evidence — it reports `active` mid-restart.
- [ ] Egress allowlist live; a `curl https://example.com` as `recode-agent` is dropped AND logged AND
      lands a notification; `curl -sI https://api.github.com` as the same user still succeeds.
- [ ] PAT is fine-grained + repo-scoped + expiring and lives in `gh auth`, not `.env`; bot token is
      classic `repo`-only with `"push": true`; API key spend-capped (or subscription auth chosen
      deliberately); old tokens rotated.
- [ ] auditd + divergence timer alerting into the same channel as the loop's `notify` seam.

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
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "allowManagedReadPathsOnly": true,          // local settings can't widen read scope
    "allowManagedDomainsOnly": true             // local settings can't widen network allowlist
  }
}
```

> ⚠️ **Do NOT add `permissions.disableBypassPermissionsMode: "disable"` while the loop runs in
> `bypassPermissions`.** Despite the name reading like "pin the bypass decision", this key *disables*
> bypass mode outright. `/orchestrator:harden` writes `defaultMode: "bypassPermissions"` and
> `arm-loop.sh` reads that value to launch the daemon, so setting it stalls every driver on permission
> prompts no human is there to answer. Use it **only** together with a deliberate switch to `dontAsk`
> (see the note below) and a `permissions.allow` list covering every command the loop runs.

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
- **In-session commands are sandboxed too — including the `!` prefix.** Anything Claude Code runs,
  whether a tool call or a command you type with the `!` prefix, runs inside the Bash sandbox (writes
  confined to repo + `$TMPDIR`). Under strict mode that means **host/home config changes fail even when
  you type them yourself** — `git config --global` (`~/.gitconfig`), editing `~/.zshrc`, `ssh-keygen`
  (`~/.ssh`), `gh auth` (`~/.config/gh`), etc. all error with `Read-only file system`. Run those in a
  **real terminal outside Claude Code**. (This is the containment working as intended, not a bug — but
  it surprises people the first time.)
- **Sandboxed sessions mask config paths as `/dev/null` — expect phantom `git status` noise.** The
  sandbox bind-mounts `/dev/null` over sensitive paths it won't let the agent read (shell rc, `.gitconfig`,
  editor dirs, `.mcp.json`, and Claude's own `.claude/{hooks,skills,routines,launch.json}`). In a
  sandboxed view these appear as **character-device files** (`ls -l` shows `crw-rw-rw- … 1, 3`), which
  `git status` reports as untracked/modified even though they aren't real project files. This is expected,
  not corruption. (The `.git/config.lock` device is the same thing — a mask, not a stale lock; there's no
  lock to remove, and `allowWrite` can't dislodge it. If you need git's config writes to land, run them in
  a real terminal — see the git-config note in the strict-mode section above.) Two consequences: (1)
  **never `git add -A` / `git commit -a`** — git
  can't index a device node and the commit may abort; stage explicit paths instead. This is enforced by
  the agent prompts **and** a plugin `PreToolUse` hook (`.claude/scripts/guard-git-add.py`) that blocks
  blanket `git add -A/./--all` and `git commit -a`. Note the hook runs *outside* the sandbox, so it can't
  see the `/dev/null` masks directly (`os.stat` reports them absent); it keys off `sandbox.enabled` in
  settings instead — active only when the sandbox is on, a no-op for non-hardened repos.
  (2) The unambiguous personal dotfiles are gitignored so they don't surface; `.mcp.json`/`.gitmodules`/
  `.claude/*` are deliberately *not* ignored (they can be real), so rely on explicit staging there.
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
