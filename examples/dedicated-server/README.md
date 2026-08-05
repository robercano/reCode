# Dedicated-server provisioning artifacts

Working files from a real `/orchestrator:provision` run on bare-metal **Ubuntu 26.04**, kept so the
next box doesn't rebuild them from the sketches in [`docs/HARDENING.md`](../../docs/HARDENING.md).
They implement the worked example's steps 5–6 (kernel egress fence, detection) plus the systemd
drop-in from step 4.

Substitute `recode-agent` / uid `1001` / `recode-notifications` for your own values before installing.

## What's here

| File | Installs to | Purpose |
|---|---|---|
| `nftables/recode-agent.nft` | `/etc/nftables.d/` | UID-matched egress fence for the agent user |
| `systemd/recode-agent-nft.service` | `/etc/systemd/system/` | Loads the table at boot; deletes it on stop |
| `bin/egress-alarm.sh` | `/usr/local/sbin/` | Follows the kernel log, pushes blocked egress to ntfy |
| `systemd/egress-alarm.service` | `/etc/systemd/system/` | Supervises the follower (runs as root — see below) |
| `agents.conf` | `/etc/recode-agents.conf` | **The registry.** One `user:repo` line per agent user; everything else reads it |
| `bin/posture-check.sh` | `/usr/local/sbin/` | Hourly: git divergence **and** egress-fence coverage, for every agent in the registry |
| `systemd/posture-check.{service,timer}` | `/etc/systemd/system/` | Hourly tripwire |
| `bin/gen-audit-rules.sh` | run as needed | Regenerates the auditd watch list from the registry |
| `systemd/pr-loop-hardening.conf` | `~<agent>/.config/systemd/user/pr-loop-<slug>.service.d/` | User-unit-safe hardening drop-in |

Install:

```bash
sudo mkdir -p /etc/nftables.d
sudo install -m 644 agents.conf               /etc/recode-agents.conf
sudo install -m 644 nftables/recode-agent.nft /etc/nftables.d/
sudo install -m 755 bin/*.sh                  /usr/local/sbin/
sudo install -m 644 systemd/*.service systemd/*.timer /etc/systemd/system/
sudo bash bin/gen-audit-rules.sh | sudo tee /etc/audit/rules.d/recode-agent.rules >/dev/null
sudo nft -c -f /etc/nftables.d/recode-agent.nft   # syntax check BEFORE enabling
sudo systemctl daemon-reload
sudo systemctl enable --now recode-agent-nft.service egress-alarm.service posture-check.timer
sudo augenrules --load
```

The user drop-in goes in as the agent user, not root:

```bash
mkdir -p ~/.config/systemd/user/pr-loop-<slug>.service.d
cp pr-loop-hardening.conf ~/.config/systemd/user/pr-loop-<slug>.service.d/hardening.conf
systemctl --user daemon-reload && systemctl --user restart pr-loop-<slug>.service
```

## Adding a second (or third) agent user

Everything except the nftables set is driven by `/etc/recode-agents.conf`:

```bash
echo 'redeploy-agent:/home/redeploy-agent/reDeploy' | sudo tee -a /etc/recode-agents.conf
sudo bash gen-audit-rules.sh | sudo tee /etc/audit/rules.d/recode-agent.rules >/dev/null
sudo augenrules --load
```

**Then add the uid to the nftables set by hand** — edit `elements = { ... }` in
`/etc/nftables.d/recode-agent.nft`, then `sudo nft -c -f` it and restart the unit.

That last step is deliberately manual. A generator that populated the set from the registry
would, on any failure, leave the set **empty** — and an empty set means *no agent is fenced*,
silently, because the drop rule lives in a chain only listed uids ever jump into. Fail-open is
the wrong failure for this component. Instead `posture-check.sh` cross-checks the registry
against the live set every hour and pages you if they disagree, so forgetting is noisy rather
than invisible.

## Decisions behind these files

Each of these cost real debugging time; the rationale matters more than the syntax.

**The fence restricts protocol and port, not destination.** Per-destination IP-set allowlisting was
built, tested, and abandoned: GitHub rotates within its fleet (the set held `140.82.121.3/.6/.10`
while traffic went to `.4/.5`), Google load balancers served different addresses than our resolver
for `downloads.claude.ai` and Datadog, and a DNS-refresh timer can't close that race. It dropped
real work. The decisive argument is in HARDENING.md already: **GitHub is a sanctioned exfiltration
channel** — once the agent can push branches it can move data through a permitted destination, so an
allowlist that must include GitHub was never going to close that path. What remains is worth having:
no outbound SSH, no arbitrary ports, no non-HTTPS protocols, and an alarm that only fires on
genuinely anomalous traffic. For true per-domain control, build an L7 proxy with a domain allowlist
and block direct 443 — that is the only version that actually works.

**Jump on a positive UID match; never `skuid != <uid> accept`.** Kernel-generated packets (ICMPv6
MLD/ND, DHCP renewal) have no owning socket, so a `!=` rule never matches them and they fall through
to the drop — silently filtering the host's own network stack. Observed live as dropped MLD listener
reports. The symptom arrives days later as a lease that won't renew, with nothing to connect it back.

**Link-local multicast is dropped without the log prefix.** mDNS/MLD is local discovery noise;
alarming on it trains you to ignore the channel.

**The alarm runs as root** — the nft chain matches the agent's UID, so root's `curl` to the notifier
is not subject to the allowlist it reports on. Same reason the divergence check runs as root: it must
sit outside the agent's trust zone to be meaningful.

**`egress-alarm.sh` deliberately does not use `set -e` / `pipefail`.** Every field is a best-effort
parse or a reverse lookup that legitimately fails — an address with no PTR, a log line with no `DPT`.
Under `set -e` the first such failure killed the follower and events were lost *silently*, which is
worse than no alarm at all, because silence reads as safety. Only destinations with reverse DNS ever
alerted, and nothing indicated the rest were being swallowed.

**The alarm cooldown keys on destination *and* port.** Keyed on IP alone, a different port to the
same host is suppressed — `example.com:80` vanished because `example.com:443` had alerted minutes
earlier.

**`ufw` is left alone.** If ufw is active, do not enable `nftables.service`: it runs
`/etc/nftables.conf`, which conventionally begins with `flush ruleset` and would wipe ufw's rules at
boot. `recode-agent-nft.service` only ever adds its own table, and removes it on stop.

**The systemd drop-in is the user-unit-safe subset.** `ProtectKernelModules`/`ProtectKernelTunables`/
`ProtectControlGroups` imply `CapabilityBoundingSet` changes needing `CAP_SETPCAP`, which an
unprivileged `systemd --user` manager lacks — the unit then dies with `218/CAPABILITIES` and
restart-loops while `systemctl --user is-active` still reports `active`. `ProtectSystem=strict`,
`ReadWritePaths=` and `PrivateTmp=` need mount namespaces and may also fail under the Ubuntu ≥24.04
userns restriction; test them one at a time. For the full directive set, promote the loop to a
**system** unit with `User=<agent>` — at the cost of `arm-loop.sh` recreating user units on every
re-arm.

## Verifying, not assuming

Three separate layers on this run looked correct in their configuration and did nothing in practice:
inert `Write(...)` deny rules, `is-active` on a crash-looping unit, and an alarm dying on a missing
PTR record. Test each one:

```bash
sudo -u <agent> curl -sI -m 10 https://api.github.com | head -1   # expect HTTP/2 200
sudo -u <agent> curl -sI -m 8  http://example.com     | head -1   # expect nothing + one alert
sudo -u <agent> timeout 5 ssh -o BatchMode=yes 1.1.1.1            # expect nothing + one alert
journalctl --user -u pr-loop-<slug>.service -n 20 --no-pager      # expect loop-daemon: starting
```

Two of those alerts should come from addresses with no reverse DNS and one from an address with it —
that exercises both paths through the lookup, which is where the silent failure lived.
