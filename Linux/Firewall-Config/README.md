README.md v1.0.0 (Last Rev: 2026-10-17)

# Firewall-Config

## Overview

Applies a baseline host firewall to a Linux server, unattended and safe to
re-run. Debian and Ubuntu hosts use **ufw**; RHEL, Fedora, Rocky, and
AlmaLinux hosts use **firewalld**. A firewall that is already active is kept,
and the other one is never started alongside it.

The baseline:

- Block all inbound traffic by default; allow all outbound.
- Allow SSH on the port(s) `sshd` is actually using (`sshd -T`), rate limited
  on ufw (6 new connections per 30 seconds per address).
- Allow Cockpit (TCP 9090) when it is installed, or when told to.
- Allow any extra ports you name.

It will not lock you out of a remote session:

- The SSH rules go in **before** the firewall is switched on.
- If SSH is restricted to certain sources (`--ssh-from`) and a session is open
  right now from an address outside them, it refuses and changes nothing
  (exit code 1). It reads the established connections itself, so this works
  through `sudo`, which hides `SSH_CONNECTION`.

It is called by `Linux/Server-Setup/setup-server.sh` as its firewall step, and
works fine on its own.

## Files

- `configure-firewall.sh` - the tool. No installer and no self-update; run it
  from a clone, or straight from the repo (see Quick Start).

## Quick Start

From a clone:

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts/Linux/Firewall-Config
sudo ./configure-firewall.sh
```

Straight from the repo, passing options through `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/main/Linux/Firewall-Config/configure-firewall.sh | sudo bash -s -- --ssh-from 10.0.0.0/24
```

Show the current firewall without changing anything:

```bash
sudo ./configure-firewall.sh --status
```

## Options

| Option | Meaning |
| --- | --- |
| `--ssh-port N` | SSH port to allow. Repeatable. Default: every port `sshd -T` reports, or 22. With no sshd installed and no `--ssh-port`, no SSH rule is added. |
| `--ssh-from CIDRS` | Limit SSH to these sources (comma separated IPv4 or IPv6 CIDRs), or `any` (default). |
| `--cockpit-from V` | Cockpit: `any`, comma separated CIDRs, `none`, or `auto` (default: open to any only when Cockpit is installed). |
| `--allow SPEC` | Also allow an inbound port, such as `443/tcp` or `8000:8100/udp`. Repeatable. |
| `--no-enable` | Add the rules but do not switch the firewall on. |
| `--skip-lockout-check` | Do not refuse when a restricted `--ssh-from` would cut off an open session. |
| `--status` | Show the firewall and change nothing. |

The last line printed is `RESULT: changed` or `RESULT: unchanged`.

Exit codes: `0` success, `1` runtime failure or refused to avoid a lockout,
`2` invalid arguments (nothing touched).

## Behavior Notes

- **Idempotent.** Running it twice changes nothing the second time.
- **It never removes rules it did not add**, with one exception: on firewalld,
  restricting SSH removes the default `ssh` service (which opens port 22 to
  everyone), and restricting Cockpit removes the `cockpit` service. Both only
  happen after the restricted rules are in.
- **NTP-Config's rules** (the subnets allowed to query this host for time) are
  untouched and coexist with this baseline.
- **Docker bypasses it.** Docker publishes container ports through its own
  iptables rules, ahead of ufw and firewalld, so a published port stays
  reachable whatever this tool allows. Publish to `127.0.0.1` or use the
  `DOCKER-USER` chain to restrict it.
- **fail2ban** (set up by Server-Setup) bans through ufw when ufw is active,
  so its rules sit with the rest of the firewall.

## Troubleshooting

**"refusing to continue: SSH is restricted to ..."**
The tool found an open SSH session from an address that is not in
`--ssh-from`. Add that address to the list, or pass `--skip-lockout-check` if
you are sure.

**"ufw is active on this ... host" (RHEL family)**
This tool will not run firewalld beside an active ufw. Disable one of them
first.

**A port is open that the tool did not open.**
Check `--status`. Rules from other tools (NTP-Config, hand-added rules,
Docker) are left alone.
