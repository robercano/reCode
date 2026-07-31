# Remote SSH into the Hoppie WSL2 box — Cloudflare Tunnel + Access runbook

> **Status: DECOMMISSIONED on Hoppie 2026-07-31.** The `ssh.gabriell.es` tunnel, Access app, and
> loopback-only sshd described here were torn down as part of migrating the always-on host to a
> dedicated Linux server (see `docs/HARDENING.md` → "Worked example: dedicated Linux server").
> This runbook is kept as the reference recipe — it applies almost verbatim to any Linux box
> (the WSL2-specific gotchas, e.g. the `loopback0` ufw rule and `localhostForwarding` note, simply
> drop out on native Linux). Lived 2026-07-18 → 2026-07-31; every gotcha below was hit for real.

Goal: SSH into WSL2 Ubuntu from laptop/phone with **zero inbound exposure** and **no static SSH keys**.

Architecture (defense in depth, each layer independent):

1. `sshd` listens on **127.0.0.1 only** — invisible to the LAN, the internet, and the Windows host's
   network. Password auth off, root off, single allowed user.
2. A dedicated **outbound-only** `cloudflared` tunnel (`hoppie-ssh`) carries `ssh.gabriell.es` to
   `localhost:22`. No firewall changes, no port-forwards, ever.
3. **Cloudflare Access** in front of the hostname: only `roberto.cano@gmail.com` may connect, after
   IdP login (+ whatever MFA your Google account enforces). Every session is logged in Zero Trust.
4. **Short-lived certificates**: Cloudflare's SSH CA signs an ephemeral cert per authenticated
   session; `sshd` trusts the CA, not user keys. Nothing long-lived to steal — and it's what makes
   the **phone browser terminal** work (the browser has no keypair).

Everything below runs in a **real (non-sandboxed) terminal** unless marked *(dashboard)*.

---

## 1. sshd, loopback-only and hardened

```bash
sudo apt update && sudo apt install -y openssh-server

sudo tee /etc/ssh/sshd_config.d/99-hoppie-hardened.conf > /dev/null <<'EOF'
# Reachable ONLY via the cloudflared tunnel (and Windows-host-local processes
# through WSL2 localhostForwarding). Never expose this port.
ListenAddress 127.0.0.1
Port 22

PermitRootLogin no
AllowUsers rcano
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
# 'local' keeps `ssh -L` available (handy for reaching the cockpit through the
# session) while forbidding remote/reverse forwards.
AllowTcpForwarding local
ClientAliveInterval 120
ClientAliveCountMax 2
EOF

# Map the cert principal (email local part) to the unix user.
sudo mkdir -p /etc/ssh/principals
echo "roberto.cano" | sudo tee /etc/ssh/principals/rcano > /dev/null

# The browser-rendered terminal logs in as the EMAIL LOCAL PART (roberto.cano) with no
# username prompt — sshd must accept that name. Alias it onto the real account
# (same UID/home/shell; no password; cert-only auth still applies):
sudo useradd -o -u "$(id -u rcano)" -g "$(id -g rcano)" -d /home/rcano -M \
  -s "$(getent passwd rcano | cut -d: -f7)" roberto.cano
echo "roberto.cano" | sudo tee /etc/ssh/principals/roberto.cano > /dev/null
# ...and use `AllowUsers rcano roberto.cano` in the hardened conf above.

# Don't enable yet — the CA file from step 4 must exist first, or sshd refuses to start.
# GOTCHA (bit us 2026-07-18): `apt install openssh-server` auto-STARTS sshd before this
# config exists, and a later `enable --now` won't restart it — it keeps listening on
# 0.0.0.0. Always `sudo systemctl restart ssh` after config changes and verify with
# `ss -tln | grep :22` (must show ONLY 127.0.0.1:22). If it still shows 0.0.0.0, check
# `systemctl status ssh.socket` — socket activation also bypasses ListenAddress
# (fix: disable ssh.socket, use ssh.service).
```

## 2. Dedicated tunnel (mirrors the redeploy-studio convention)

```bash
cloudflared tunnel create hoppie-ssh          # note the tunnel UUID it prints
cloudflared tunnel route dns hoppie-ssh ssh.gabriell.es

TUNNEL_ID=$(cloudflared tunnel list --output json | python3 -c 'import json,sys; print([t["id"] for t in json.load(sys.stdin) if t["name"]=="hoppie-ssh"][0])')

cat > ~/.cloudflared/hoppie-ssh.yml <<EOF
# Dedicated SSH tunnel; independent of config.yaml (api) and redeploy-studio.yml.
tunnel: $TUNNEL_ID
credentials-file: /home/rcano/.cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: ssh.gabriell.es
    service: ssh://localhost:22
  - service: http_status:404
EOF

cat > ~/.config/systemd/user/cloudflared-hoppie-ssh.service <<'EOF'
[Unit]
Description=cloudflared tunnel for SSH access (ssh.gabriell.es, Access-gated)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --config %h/.cloudflared/hoppie-ssh.yml run hoppie-ssh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
# (linger is already enabled on this box; the unit will survive reboots via the
# WSL2 unattended-autostart Task Scheduler setup — see docs/USAGE.md.)
```

## 3. *(dashboard)* Access application

Zero Trust dashboard → **Access → Applications → Add → Self-hosted**:

- Application domain: `ssh.gabriell.es`.
- Session duration: keep it short — **24h max** (re-auth is one browser tap).
- Policy `allow-roberto`: Action **Allow** → Include → Emails → `roberto.cano@gmail.com`.
  Nothing else. (Access denies by default; do not add bypass/service-auth policies.)
- Under the app's **Settings → Browser rendering**, select **SSH** — this is the phone access path.
- Optional hardening: in the policy, add *Require → Login method → Google* so a One-time-PIN
  email can never satisfy it; and Zero Trust → Settings → Authentication → device posture rules
  later if you enroll devices.

## 4. *(dashboard + terminal)* Short-lived certificates

Zero Trust dashboard → **Access → Service auth → SSH**: select the `ssh.gabriell.es` app and
**Generate certificate**. Copy the public key it shows, then back in WSL:

```bash
sudo tee /etc/ssh/cloudflare_access_ca.pub > /dev/null <<'EOF'
<paste the CA public key here — single line, starts with ecdsa-sha2-... or ssh-ed25519>
EOF

sudo systemctl enable --now ssh
sudo sshd -t && systemctl status ssh --no-pager   # config check + running
systemctl --user daemon-reload
systemctl --user enable --now cloudflared-hoppie-ssh.service
```

## 5. Clients

**Laptop** (install `cloudflared` there first). GOTCHA (bit us 2026-07-18 on the phone): a bare
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
Match host hoppie,ssh.gabriell.es exec "cloudflared access ssh-gen --hostname ssh.gabriell.es"

Host hoppie ssh.gabriell.es
  HostName ssh.gabriell.es
  User rcano
  ProxyCommand cloudflared access ssh --hostname ssh.gabriell.es
  IdentityFile ~/.cloudflared/ssh.gabriell.es-cf_key
  CertificateFile ~/.cloudflared/ssh.gabriell.es-cf_key-cert.pub
```

`ssh hoppie` → Match exec mints an ephemeral key+cert into `~/.cloudflared/` (popping the
browser Access login only when the token has expired) → ssh loads the fresh cert and presents
it over the tunnel. One ssh process, no long-lived key files to manage. VERIFIED working from
Termux 2026-07-18.

**Phone (quick)**: open `https://ssh.gabriell.es` in the browser → Access login → Cloudflare
renders a terminal. Log in as `rcano`.

**Phone (proper client, Android)**: Termux from F-Droid (NOT the Play Store build — dead
repo), then `pkg install openssh cloudflared` and the same `~/.ssh/config` as above. The
Access login URL opens in the phone browser and hands the token back over localhost (shared
per-device, so this works on-device). On Samsung, exempt Termux from battery optimization
(*Settings → Battery → Never sleeping apps*) or One UI kills long sessions.

## 6. Verify the security posture

```bash
# Nothing listening beyond loopback (expect 127.0.0.1:22 only for sshd):
sudo ss -tlnp | grep -v 127.0.0.1 || true
# ufw belt-and-braces. GOTCHA (2026-07-18): under WSL2 MIRRORED networking,
# 127.0.0.1 traffic flows over a virtual interface named `loopback0` (with a MAC),
# NOT `lo` — so ufw's stock lo rules never match and loopback SYNs to sshd hit the
# deny policy ("unable to connect to origin", `[UFW BLOCK] IN=loopback0 ... DPT=22`
# in /var/log/ufw.log). BOTH rules below are required:
sudo ufw allow in on lo
sudo ufw allow in on loopback0
sudo ufw default deny incoming && sudo ufw enable
# Toggling ufw also orphans cloudflared's established edge connections (conntrack
# reset) — restart the tunnel units after any ufw enable/disable:
systemctl --user restart cloudflared-hoppie-ssh cloudflared-redeploy
# ...then reconnect once from the phone to confirm the tunnel still works.
# Auth trail: Zero Trust → Logs → Access shows every SSH session with identity.
```

Notes / accepted trade-offs:

- WSL2 `localhostForwarding` means **Windows-host-local** processes can reach WSL's
  `127.0.0.1:22`. That's Windows→WSL only (not LAN), and cert-only auth applies regardless.
  Disabling it would also break using the cockpit from a Windows browser, so it stays on.
- `fail2ban` is pointless here (nothing is exposed to brute-force); skipped deliberately.
- Rollback: `systemctl --user disable --now cloudflared-hoppie-ssh`, delete the DNS route +
  tunnel (`cloudflared tunnel delete hoppie-ssh`), `sudo systemctl disable --now ssh`.
- Scheduling Claude routines onto this box does NOT use SSH — that's the existing
  `claude-rc-*` bridge environments (Hoppie:reCode etc.).
