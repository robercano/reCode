# Remote SSH into a WSL2 box — Cloudflare Tunnel + Access runbook

> Written for WSL2 Ubuntu, but applies almost verbatim to any Linux box — the WSL2-specific
> gotchas (the `loopback0` ufw rule, the `localhostForwarding` note) simply drop out on native
> Linux. Every gotcha below was hit for real on a live deployment.
>
> Placeholders used throughout — substitute your own values:
> - `jane` — the unix account on the box
> - `jane.doe@example.com` — the identity allowed through Cloudflare Access
>   (`jane.doe` is its **email local part**, which matters in step 1)
> - `ssh.example.com` — the public hostname (a zone on your Cloudflare account)
> - `wsl-ssh` — the dedicated tunnel name

Goal: SSH into the box from laptop/phone with **zero inbound exposure** and **no static SSH keys**.

Architecture (defense in depth, each layer independent):

1. `sshd` listens on **127.0.0.1 only** — invisible to the LAN, the internet, and (on WSL2) the
   Windows host's network. Password auth off, root off, single allowed user.
2. A dedicated **outbound-only** `cloudflared` tunnel (`wsl-ssh`) carries `ssh.example.com` to
   `localhost:22`. No firewall changes, no port-forwards, ever.
3. **Cloudflare Access** in front of the hostname: only `jane.doe@example.com` may connect, after
   IdP login (+ whatever MFA that account enforces). Every session is logged in Zero Trust.
4. **Short-lived certificates**: Cloudflare's SSH CA signs an ephemeral cert per authenticated
   session; `sshd` trusts the CA, not user keys. Nothing long-lived to steal — and it's what makes
   the **phone browser terminal** work (the browser has no keypair).

Everything below runs in a **real (non-sandboxed) terminal** unless marked *(dashboard)*.

---

## 1. sshd, loopback-only and hardened

```bash
sudo apt update && sudo apt install -y openssh-server

sudo tee /etc/ssh/sshd_config.d/99-hardened.conf > /dev/null <<'EOF'
# Reachable ONLY via the cloudflared tunnel (and, on WSL2, Windows-host-local
# processes through localhostForwarding). Never expose this port.
ListenAddress 127.0.0.1
Port 22

PermitRootLogin no
AllowUsers jane jane.doe
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes

# Cloudflare Access short-lived certs (step 4)
TrustedUserCAKeys /etc/ssh/cloudflare_access_ca.pub
AuthorizedPrincipalsFile /etc/ssh/principals/%u

MaxAuthTries 3
LoginGraceTime 20
MaxSessions 4
X11Forwarding no
AllowAgentForwarding no
# 'local' keeps `ssh -L` available (handy for reaching local web UIs through the
# session) while forbidding remote/reverse forwards.
AllowTcpForwarding local
ClientAliveInterval 120
ClientAliveCountMax 2
EOF

# Map the cert principal (email local part) to the unix user.
sudo mkdir -p /etc/ssh/principals
echo "jane.doe" | sudo tee /etc/ssh/principals/jane > /dev/null

# The browser-rendered terminal logs in as the EMAIL LOCAL PART (jane.doe) with no
# username prompt — sshd must accept that name. Alias it onto the real account
# (same UID/home/shell; no password; cert-only auth still applies):
sudo useradd -o -u "$(id -u jane)" -g "$(id -g jane)" -d /home/jane -M \
  -s "$(getent passwd jane | cut -d: -f7)" jane.doe
echo "jane.doe" | sudo tee /etc/ssh/principals/jane.doe > /dev/null
# ...which is why `AllowUsers` above lists both names. (Skip the alias entirely if
# your email local part happens to equal the unix username.)

# Don't enable yet — the CA file from step 4 must exist first, or sshd refuses to start.
# GOTCHA: `apt install openssh-server` auto-STARTS sshd before this config exists, and
# a later `enable --now` won't restart it — it keeps listening on 0.0.0.0. Always
# `sudo systemctl restart ssh` after config changes and verify with
# `ss -tln | grep :22` (must show ONLY 127.0.0.1:22). If it still shows 0.0.0.0, check
# `systemctl status ssh.socket` — socket activation also bypasses ListenAddress
# (fix: disable ssh.socket, use ssh.service).
```

## 2. Dedicated tunnel

```bash
cloudflared tunnel create wsl-ssh             # note the tunnel UUID it prints
cloudflared tunnel route dns wsl-ssh ssh.example.com

TUNNEL_ID=$(cloudflared tunnel list --output json | python3 -c 'import json,sys; print([t["id"] for t in json.load(sys.stdin) if t["name"]=="wsl-ssh"][0])')

cat > ~/.cloudflared/wsl-ssh.yml <<EOF
# Dedicated SSH tunnel; keep it independent of any other tunnels on the box.
tunnel: $TUNNEL_ID
credentials-file: $HOME/.cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: ssh.example.com
    service: ssh://localhost:22
  - service: http_status:404
EOF

cat > ~/.config/systemd/user/cloudflared-ssh.service <<'EOF'
[Unit]
Description=cloudflared tunnel for SSH access (Access-gated)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --config %h/.cloudflared/wsl-ssh.yml run wsl-ssh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
# Adjust ExecStart if your cloudflared lives elsewhere (`command -v cloudflared`).
# Enable linger (`sudo loginctl enable-linger jane`) so the unit runs with nobody
# logged in. On WSL2 the VM itself must also autostart at Windows boot (Task
# Scheduler AtStartup task running `wsl.exe -d <distro> -u jane -- true`) or the
# tunnel only exists while a WSL terminal is open.
```

## 3. *(dashboard)* Access application

Zero Trust dashboard → **Access → Applications → Add → Self-hosted**:

- Application domain: `ssh.example.com`.
- Session duration: keep it short — **24h max** (re-auth is one browser tap).
- Policy `allow-jane`: Action **Allow** → Include → Emails → `jane.doe@example.com`.
  Nothing else. (Access denies by default; do not add bypass/service-auth policies.)
- Under the app's **Settings → Browser rendering**, select **SSH** — this is the phone access path.
- Optional hardening: in the policy, add *Require → Login method → <your IdP>* so a One-time-PIN
  email can never satisfy it; and Zero Trust → Settings → Authentication → device posture rules
  later if you enroll devices.

## 4. *(dashboard + terminal)* Short-lived certificates

Zero Trust dashboard → **Access → Service auth → SSH**: select the `ssh.example.com` app and
**Generate certificate**. Copy the public key it shows, then back on the box:

```bash
sudo tee /etc/ssh/cloudflare_access_ca.pub > /dev/null <<'EOF'
<paste the CA public key here — single line, starts with ecdsa-sha2-... or ssh-ed25519>
EOF

sudo systemctl enable --now ssh
sudo sshd -t && systemctl status ssh --no-pager   # config check + running
systemctl --user daemon-reload
systemctl --user enable --now cloudflared-ssh.service
```

## 5. Clients

**Laptop** (install `cloudflared` there first). GOTCHA: a bare
`ProxyCommand cloudflared access ssh` only proxies the TCP stream — it never fetches the
short-lived cert, and since sshd trusts ONLY the Cloudflare CA the result is
`Permission denied (publickey)`. The cert must be minted per-session with
`cloudflared access ssh-gen` — and it must run BEFORE ssh starts, because OpenSSH preloads
CertificateFile at startup, before the ProxyCommand runs (GOTCHA #3: minting the cert inside
the ProxyCommand looks right but ssh offers the PREVIOUS, already-expired cert — auth.log
shows `Certificate invalid: expired` with the prior session's serial; certs live ~4 min).
That preload is the reason Cloudflare's documented two-host "cfpipe" config
(`cloudflared access ssh-config --short-lived-cert`) nests a second ssh inside the
ProxyCommand — but that hack hijacks the tty and on Termux the abandoned outer ssh kills the
session on the first keypress (GOTCHA #2). The config that avoids both: `Match exec` runs
ssh-gen at config-parse time, before the cert is loaded, with a single ssh process:

```
# ~/.ssh/config on the client
Match host mybox,ssh.example.com exec "cloudflared access ssh-gen --hostname ssh.example.com"

Host mybox ssh.example.com
  HostName ssh.example.com
  User jane
  ProxyCommand cloudflared access ssh --hostname ssh.example.com
  IdentityFile ~/.cloudflared/ssh.example.com-cf_key
  CertificateFile ~/.cloudflared/ssh.example.com-cf_key-cert.pub
```

`ssh mybox` → Match exec mints an ephemeral key+cert into `~/.cloudflared/` (popping the
browser Access login only when the token has expired) → ssh loads the fresh cert and presents
it over the tunnel. One ssh process, no long-lived key files to manage. Verified working from
Termux.

**Phone (quick)**: open `https://ssh.example.com` in the browser → Access login → Cloudflare
renders a terminal. Log in as `jane`.

**Phone (proper client, Android)**: Termux from F-Droid (NOT the Play Store build — dead
repo), then `pkg install openssh cloudflared` and the same `~/.ssh/config` as above. The
Access login URL opens in the phone browser and hands the token back over localhost (shared
per-device, so this works on-device). On Samsung, exempt Termux from battery optimization
(*Settings → Battery → Never sleeping apps*) or One UI kills long sessions.

## 6. Verify the security posture

```bash
# Nothing listening beyond loopback (expect 127.0.0.1:22 only for sshd):
sudo ss -tlnp | grep -v 127.0.0.1 || true
# ufw belt-and-braces. GOTCHA: under WSL2 MIRRORED networking, 127.0.0.1 traffic
# flows over a virtual interface named `loopback0` (with a MAC), NOT `lo` — so
# ufw's stock lo rules never match and loopback SYNs to sshd hit the deny policy
# ("unable to connect to origin", `[UFW BLOCK] IN=loopback0 ... DPT=22` in
# /var/log/ufw.log). BOTH rules below are required:
sudo ufw allow in on lo
sudo ufw allow in on loopback0
sudo ufw default deny incoming && sudo ufw enable
# Toggling ufw also orphans cloudflared's established edge connections (conntrack
# reset) — restart ALL cloudflared-* user units after any ufw enable/disable:
systemctl --user restart cloudflared-ssh
# ...then reconnect once from the phone to confirm the tunnel still works.
# Auth trail: Zero Trust → Logs → Access shows every SSH session with identity.
```

Notes / accepted trade-offs:

- WSL2 `localhostForwarding` means **Windows-host-local** processes can reach WSL's
  `127.0.0.1:22`. That's Windows→WSL only (not LAN), and cert-only auth applies regardless.
  Disable it if you don't need Windows-side access to WSL services.
- `fail2ban` is pointless here (nothing is exposed to brute-force); skipped deliberately.
- Rollback: `systemctl --user disable --now cloudflared-ssh`, delete the DNS route +
  tunnel (`cloudflared tunnel delete wsl-ssh`), `sudo systemctl disable --now ssh`, then
  remove the Access application and SSH CA in the dashboard.
