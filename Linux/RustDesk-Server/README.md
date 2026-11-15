README.md v1.0.1 (Last Rev: 2026-11-14)

# RustDesk-Server

## Overview

Installs the open source RustDesk server (hbbs ID server and hbbr relay)
under Docker Compose, the same way on every Linux host, with one command.
Re-running it is safe: a second run with the same inputs changes nothing and
says so. The same script verifies a running server (`status`), switches
versions with automatic rollback (`upgrade`), and prints the settings
clients need (`print-client-config`).

What it enforces:

- **Pinned image.** Exact `X.Y.Z` tag plus its `sha256` digest. `latest` and
  floating tags (such as `1`) are rejected. No Watchtower, no auto-update.
- **Host networking.** Published Docker ports bypass the host's input
  firewall chain; host mode keeps the host firewall in charge.
- **Only the needed ports.** TCP 21115-21117 and UDP 21116 are opened. The
  web client ports 21118/21119 stay closed even though hbbs and hbbr listen
  on them, and verify fails if anything opens them.
- **Key enforced on both services.** `-k _` is passed to hbbs and hbbr, and
  verify checks that both log the same key as `data/id_ed25519.pub`.
- **One firewall.** If more than one host firewall is active (for example an
  nftables table and ufw), the run stops and changes nothing.
- **Private key handling.** Never printed, mode 600, and the summary reminds
  you to back it up off the host.

## Files

- `install-rustdesk-server.sh` - the installer, verifier, and upgrader.
- `bootstrap.sh` - one-line remote runner: downloads the repo at a chosen ref
  and runs the installer with your arguments.
- `templates/compose.yaml` - the Compose file written to the install dir.
- `templates/env.example` - documents every `.env` setting; copied to the
  install dir as `.env.example`.
- `lib/common.sh` - logging and prompt helpers (a copy of Server-Setup's).

On the host (default `/opt/RustDesk`):

| Path | Contents |
|------|----------|
| `compose.yaml` | From the template. Edit the template, not this copy. |
| `.env` | Version, digest, relay host, optional bandwidth limits. Mode 600. |
| `.env.example` | Reference copy of the template. |
| `data/` | Mode 700. `id_ed25519` (private key, 600), `id_ed25519.pub`, hbbs database. |
| `backups/` | Mode 700. `data/` snapshots taken by `upgrade`. |

Logs: `/var/log/rustdesk-server/` (`install-*.log`, `upgrade-*.log`, and one
`status-YYYYMM.log` per month).

## Quick Start

Before you start:

1. The host has Docker Engine and the Compose plugin.
2. Exactly one host firewall is active: an nftables table with named port
   sets (see "Firewall Backends"), ufw, or firewalld.
3. Pick the RustDesk release: the newest one at least 14 days old. Note its
   tag and digest from Docker Hub (`rustdesk/rustdesk-server`, the
   multi-arch digest for the tag).
4. Create the relay host's DNS record (A, and AAAA if the host has a stable
   IPv6 address). DNS only, never proxied: these are raw TCP and UDP ports.
   It can come later; the installer flags it if it does not resolve yet.

Preview, then install, from a clone:

```bash
sudo ./install-rustdesk-server.sh --relay-host rd.example.com --version 1.2.3 --digest sha256:<digest> --dry-run
```

```bash
sudo ./install-rustdesk-server.sh --relay-host rd.example.com --version 1.2.3 --digest sha256:<digest>
```

Or without cloning, pinned to a release tag of this repo (recommended for
fleet use so every host runs the same installer):

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/<ref>/Linux/RustDesk-Server/bootstrap.sh | sudo RD_REF=<ref> bash -s -- --relay-host rd.example.com --version 1.2.3 --digest sha256:<digest> --yes
```

Then:

```bash
sudo ./install-rustdesk-server.sh print-client-config
```

## Modes

| Mode | What it does | Changes the host |
|------|--------------|------------------|
| `install` (default) | Preflight, firewall, files, deploy, verify, report. Re-run to re-apply. | Yes |
| `status` | Every verify check, nothing else. Safe for cron or a monitor. | No |
| `upgrade --version TAG` | Pull and check the new image, back up `data/`, switch, verify. Rolls back on failure. | Yes |
| `print-client-config` | Prints relay host and public key for clients. | No |

`install` on an existing host reads the version, digest, and relay host from
`.env` when flags are omitted, and refuses a different `--version` (use
`upgrade`) or a different `--digest` for the same tag (the tag may have been
re-pushed; investigate first).

## Options

Every option has an environment variable; a flag wins over its variable.

| Flag | Variable | Default | Notes |
|------|----------|---------|-------|
| `--relay-host HOST` | `RD_RELAY_HOST` | | Required on first install. Public DNS name. |
| `--version TAG` | `RD_VERSION` | | Required on first install and for `upgrade`. |
| `--digest DIGEST` | `RD_DIGEST` | | `sha256:...`. If omitted, the pulled digest is recorded and flagged (exit 3) so you confirm it. |
| `--install-dir DIR` | `RD_INSTALL_DIR` | `/opt/RustDesk` | |
| `--firewall MODE` | `RD_FIREWALL` | `auto` | `auto`, `nft`, `ufw`, `firewalld`, `none`. |
| `--alert` | `RD_ALERT=1` | off | On a non-zero exit, mails the log tail with `send-alert` (Linux/Notifications). |
| `--yes` | `RD_ASSUME_YES=1` | off | Required when there is no terminal. |
| `--dry-run` | `RD_DRY_RUN=1` | off | Prints the plan, including the exact firewall file diff. Changes nothing, writes no log. |

Environment only: `RD_NFT_TABLE` (`vps_filter`), `RD_NFT_CHAIN` (`input`),
`RD_NFT_FILE` (`/etc/nftables.d/vps-filter.nft`), `RD_NFT_TCP_SET`
(`public_tcp_ports`), `RD_NFT_UDP_SET` (`public_udp_ports`),
`RD_FIREWALLD_ZONE` (default zone), `RD_LOG_DIR`
(`/var/log/rustdesk-server`), `RD_WAIT_SECS` (`90`), `RD_REF` (bootstrap
only, `main`).

Exit codes: `0` success, `1` failure, `3` completed with items flagged for
review (for example DNS not resolving yet, or a digest recorded on first use).

## Firewall Backends

`auto` uses whichever single firewall is active. With none active it stops,
because 21118/21119 would be reachable; pass `--firewall none` only when a
firewall outside the host blocks them (the run is then flagged).

- **nft:** a table `inet vps_filter` (name configurable) whose input chain
  has policy drop and accepts `tcp dport @public_tcp_ports` and
  `udp dport @public_udp_ports`, persisted by a file that a systemd unit
  loads at boot. The installer adds the ports to the live sets
  (`nft add element`) and edits **only** the two set lines in the file,
  after keeping a dated backup and checking the result with `nft -c -f`.
  Sets must be single-line `type inet_service` definitions without
  `flags interval`; anything else stops the run rather than guessing.
  Ports are added one by one (no ranges). Adding accept elements cannot
  lock anyone out, so there is no rollback timer. A table the installer
  accepts (the layout the lab tests used):

  ```
  table inet vps_filter
  delete table inet vps_filter

  table inet vps_filter {
  	set public_tcp_ports { type inet_service; elements = { 22 } }
  	set public_udp_ports { type inet_service; }

  	chain input {
  		type filter hook input priority filter; policy drop;
  		iif "lo" accept
  		ct state established,related accept
  		ct state invalid drop
  		meta l4proto { icmp, ipv6-icmp } accept
  		tcp dport @public_tcp_ports counter accept
  		udp dport @public_udp_ports counter accept
  	}
  }
  ```
- **ufw:** `21115:21117/tcp` and `21116/udp` with a `RustDesk` comment.
- **firewalld:** a `rustdesk` service (21115-21117/tcp, 21116/udp) enabled in
  the default zone, or `RD_FIREWALLD_ZONE`, permanent and runtime.

Verify checks that the ports are allowed, that 21118/21119 are not opened by
that firewall, that the default is deny, and (nft) that the file on disk
matches the live sets so a reboot keeps them.

**Known conflict:** Server-Setup's firewall step enables ufw. On a host that
already filters with an nftables table, that gives two firewalls and this
installer stops. Run Server-Setup with `--skip-firewall` on such hosts, or
disable and remove ufw, restart Docker, and confirm the nftables table is
still loaded.

## Key Enforcement

From the RustDesk server 1.1.16 source:

- hbbs enforces the key by default (its default key `-` loads
  `id_ed25519`), refusing connection requests from clients without it.
- hbbr only checks the key when given one. Its default is empty, which
  relays for anyone.

So both services get `-k _`, preflight stops if either binary in the pinned
image lacks `-k`, and verify confirms both log the key from
`id_ed25519.pub`.

What the key is and is not: clients are given the **public** key. It proves
the server's identity and keeps casual strangers off the relay, but anyone
who extracts it from a configured client can use the relay. It is not a
password. hbbr's bandwidth limits (`TOTAL_BANDWIDTH`, `SINGLE_BANDWIDTH`,
`LIMIT_SPEED`, in Mb/s, set in `.env`) cap the damage if it leaks.

hbbs checks the key when a client asks to **connect**, not when it
**registers**, so a client without the key may still get an ID; its
connections fail with a key mismatch.

Testing note: hbbr treats TCP connections from a loopback address as its
local admin command port and never applies the key check to them. Probe
21117 from a non-loopback address (the host's own LAN or public IP works).

**First start:** whichever service starts first without a key file
generates one, and hbbr waits only 300 ms. Starting both together on an empty
`data/` can leave them with different keys. The installer starts hbbs alone,
waits for the key files, then starts hbbr. Later restarts are safe in any
order because the files exist.

## Upgrade and Rollback

```bash
sudo ./install-rustdesk-server.sh upgrade --version 1.2.4 --digest sha256:<digest>
```

1. Pull the new image and confirm `-k` support. A bad tag stops here with
   nothing changed.
2. Stop hbbs/hbbr and back up `data/` to `backups/data-<time>-<old tag>.tar.gz`.
3. Write `.env` with the new tag and digest, start, verify.
4. On any failure: move the failed `data/` aside, restore the backup and the
   old `.env`, start the old version, verify, exit 1.

`upgrade` also moves to an older tag, which is how you roll back by hand
later. Old backups are not pruned automatically.

## Monitoring

`status` changes nothing and exits 0, 1, or 3, so it suits cron or a
monitoring push check. With Linux/Notifications installed, `--alert` mails
the log tail on failure. Adjust the path to wherever the tool lives on the
host:

```bash
echo '17 * * * * root /opt/scripts/RustDesk-Server/install-rustdesk-server.sh status --alert >/dev/null 2>&1' | sudo tee /etc/cron.d/rustdesk-status
```

Also add an external TCP check on `<relay host>:21116`.

## Client Setup

`print-client-config` prints the ID server, relay server (both the relay
host), and public key, to enter under Settings > Network in the client. The
API server stays blank on the OSS server.

Aliases (extra DNS names for the same server) need no server change: point
the extra records at the host. hbbs advertises the relay host given at
install for relayed sessions.

Not yet verified, so not documented as a method: pre-configuring clients by
installer file name or by an exported config string.

## Tested vs Assumed

"Lab VM" below means a disposable WSL 2 VM (Ubuntu 26.04, systemd, NAT
networking) running its own Docker Engine 29.9 and Compose 5.7, with the
installer at v1.0.1 and RustDesk 1.1.16/1.1.15 pinned by digest.

| Item | State |
|------|-------|
| Input validation (`latest`, floating tags, missing relay host, bad digest, bad firewall mode) rejected before any change | Tested 2026-11-14 |
| Install with RustDesk 1.1.16, nft backend against the table layout above: `--dry-run` changes nothing, all 21 verify checks pass, both services log the same key, exit 3 only for DNS | Tested 2026-11-14, lab VM |
| Second run reports no changes | Tested 2026-11-14, lab VM |
| nftables file edit: correct, idempotent, passes `nft -c`; multi-line or `flags interval` sets refused | Tested 2026-11-14 |
| `upgrade` to a missing tag fails with nothing changed | Tested 2026-11-14, lab VM |
| `upgrade` between 1.1.16 and 1.1.15 both ways, digest recorded and flagged on first use | Tested 2026-11-14, lab VM |
| Rollback after a failed verify restores the old version, data, and `.env` | Tested 2026-11-14 with a deliberately failing check in a throwaway copy (not repeated in the lab VM) |
| nft plus active ufw stops with the conflict message and changes nothing (nft file, `.env`, compose file, live table unchanged) | Tested 2026-11-14, lab VM, real ufw 0.36.2 |
| ufw backend alone: install, all 18 checks pass, re-run changes nothing | Tested 2026-11-14, lab VM, ufw 0.36.2 |
| firewalld backend alone: install, all 18 checks pass, re-run changes nothing | Tested 2026-11-14, lab VM, firewalld 2.3.1 with `IPv6_rpfilter=no` (the WSL kernel lacks IPv6 fib support; a normal kernel does not need this) |
| No firewall: `auto` refuses with nothing changed; `--firewall none` installs and flags | Tested 2026-11-14, lab VM |
| hbbs refuses a connect request (PunchHoleRequest) with an empty or wrong key (`LICENSE_MISMATCH`); the right key gets past the check (`ID_NOT_EXIST` for an unknown ID) | Tested 2026-11-14, lab VM, protocol-level client built from the 1.1.16 protos |
| hbbr closes a RequestRelay with an empty or wrong key and logs "Relay authentication failed ... invalid key"; the right key is accepted with no such line | Tested 2026-11-14, lab VM, same client |
| Without `-k _` on hbbr, the same wrong-key and empty-key relay requests are accepted; re-running the installer restores `-k _` and status passes | Tested 2026-11-14, lab VM (control test) |
| 21115-21117/tcp reachable from outside, 21118/21119 time out, UDP 21116 reaches the accept rule (nft counter) | Tested 2026-11-14, lab VM from its Windows host over WSL NAT, nft backend only |
| `--alert` passes the current run's log tail to send-alert on failure (also on exit 3, by design) | Tested 2026-11-14, lab VM, stub send-alert (delivery by the real Linux/Notifications not tested) |
| Clients with the key register and connect | Tested 2026-11-14, lab VM (WSL mirrored networking): Windows desktop client and a phone on the same LAN; session ran direct |
| A real session through the relay (forced relay) | Assumed: relay pairing proven at protocol level only, not with real clients |
| A real client without the key is refused when it initiates | Assumed: proven at protocol level only. Seen with real clients: a client without the key still registers and can still be reached by a client that has the key, as described under Key Enforcement |
| Reachability through a real public network and provider firewall | Assumed: needs a test on the production host |

## Operator Checklist After Install

- Back up `data/id_ed25519` off the host (password manager or encrypted
  storage). Losing it means re-configuring every client.
- Add the install dir's `data/` to container backups.
- Add the external TCP check on port 21116 and, if wanted, the `status` cron.
- Run the client tests in "Tested vs Assumed" before production use.
