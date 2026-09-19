README.md v2.2.0 (Last Rev: 2026-09-18)

# Linux NTP Config

## Overview

Interactive tool to configure a Debian, Ubuntu, RHEL, CentOS, Rocky,
AlmaLinux, or Fedora host as a chrony-based NTP server for a LAN segment.
Lets the operator pick upstream time sources and set which subnets may
query the host for time. Adding or replacing an allowed subnet
automatically creates the matching firewall rule (firewalld, ufw, or
iptables); removing or replacing one out of the allow list automatically
revokes any firewall rule the script previously created for it. A subnet
change to the allow list and its firewall access move together in the same
step, in both directions. Menu option 4 (auto-create firewall rule(s)) is
still available on its own for re-syncing rules by hand, for example after
a firewall was reset outside the script. The tool can also lock a stratum
value so the host still serves reasonable time if upstream sources drop.

The tool installs its own dependency (chrony) if missing and checks for and
applies its own updates on every run. No git and no cron entries are
involved anywhere in this tool.

The Windows equivalent lives in [Windows/NTP-Config](../../Windows/NTP-Config/README.md).

## Files

- **bootstrap.sh** - one-line remote installer. Downloads a snapshot of the
  repo from GitHub to a temp directory, runs `install.sh` from it, and
  cleans up. Accepts `--insecure` or `--cacert FILE` (see Quick Start).
- **install.sh** - the installer proper. Verifies `configure-ntp-server.sh`
  with a syntax check, installs it to `/opt/ntp-config`, records the TLS
  choice for later update checks, and symlinks it into
  `/usr/local/sbin/configure-ntp-server.sh`. Can also be run directly from a
  local clone: `sudo ./install.sh`.
- **configure-ntp-server.sh** - the interactive tool itself. Menu options:
  view current configuration, configure upstream time source(s), configure
  allowed subnets (adding/removing/replacing automatically creates or
  revokes the matching firewall rule for each subnet added or removed),
  auto-create firewall rule(s) (for re-syncing by hand), set/update the
  local stratum lock, apply changes and restart chrony (auto-restores the
  last backup and retries if chrony fails to come up on the new config).
  Run with `--no-update` (or set `SKIP_SELF_UPDATE=1`) to skip the
  self-update check for a single run, useful when testing an in-progress
  change to the script itself. It can also run unattended from the command
  line (`--sources`, `--allow`, `--stratum`) or just report with `--status`;
  see Calling From Another Script.
- **/opt/ntp-config/.ntp-config-state** - written by `install.sh`. Holds
  `REF` (the branch or tag this install follows, `stable` by default),
  `TLS_MODE` (`default`, `insecure`, or `cacert`) and `CA_CERT` for update
  checks. It is only ever read, never executed.

`install.sh` and `configure-ntp-server.sh` each carry their own version
number in their header; check the header of the specific script for its
version and changelog.

## Quick Start

The installer downloads from `github.com` and `raw.githubusercontent.com`,
which present publicly trusted certificates, so on most hosts no TLS options
are needed. `curl` (the download) and the update checks the tool runs later
are separate TLS handshakes, so a host that needs a TLS workaround needs it
in both places; `--insecure` and `--cacert` handle that by saving the choice
for later updates.

**Without any certificate workaround (normal case):**

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/stable/Linux/NTP-Config/bootstrap.sh | sudo bash
```

**With a certificate workaround** (for a host behind a TLS-inspecting proxy
whose CA the host does not trust yet; pick one):

```bash
# Correct long-term option - verify TLS against your organization's CA
# (obtain the CA certificate in PEM format from whoever runs the proxy)
curl -fsSL --cacert /path/to/ca.pem https://raw.githubusercontent.com/MVTS-Corp/Scripts/stable/Linux/NTP-Config/bootstrap.sh | sudo bash -s -- --cacert /path/to/ca.pem
```

```bash
# Quick / trusted network only - skips TLS verification entirely
curl -fsSLk https://raw.githubusercontent.com/MVTS-Corp/Scripts/stable/Linux/NTP-Config/bootstrap.sh | sudo bash -s -- --insecure
```

**Pinned to one exact release** (never updates on its own; see Release
Channels and Pinning below):

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/ntp-config-v1.0.0/Linux/NTP-Config/bootstrap.sh | sudo bash -s -- --ref ntp-config-v1.0.0
```

**From a local clone (no download at all):**

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
sudo Scripts/Linux/NTP-Config/install.sh
```

Once installed, run it:

```bash
sudo configure-ntp-server.sh
```

## After Install Configuration

### Updating

Nothing to do manually. On every run, `configure-ntp-server.sh`:

1. Downloads the published copy of itself (one small file) and reads its
   version.
2. Does nothing if that version is not strictly newer than the running one
   (an older or equal published version is never applied).
3. Otherwise verifies the download (it must start with a bash shebang and
   pass `bash -n`), then swaps it into place with a single atomic rename
   and re-executes itself.
4. If the site cannot be reached, or any check fails, it prints a warning
   and keeps running the version already installed. An update problem never
   blocks use of the tool.

Re-running the bootstrap one-liner does the same thing on demand and is
also the way to change the saved TLS choice. If no TLS flag is given on a
re-run, the previously saved choice is kept.

### Release Channels and Pinning

Every host follows one git *ref*, saved as `REF` in
`/opt/ntp-config/.ntp-config-state`:

| Ref | What it means |
| --- | --- |
| `stable` (default) | A branch that only ever points at a tagged release. The host updates when a new release is promoted, and never sees unfinished work on `main`. |
| `ntp-config-vX.Y.Z` | A release tag. The host is **pinned** to exactly that release and never moves. |
| any other branch or tag | Allowed (for testing a branch, for example), at your own risk. |

Check what a host follows, and which version it runs:

```bash
grep '^REF=' /opt/ntp-config/.ntp-config-state
grep -m1 '^# Version' /opt/ntp-config/configure-ntp-server.sh
```

Change it by re-running the installer with `--ref` (the script itself is
replaced by that ref's copy):

```bash
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/stable/Linux/NTP-Config/bootstrap.sh | sudo bash -s -- --ref ntp-config-v1.0.0   # pin
curl -fsSL https://raw.githubusercontent.com/MVTS-Corp/Scripts/stable/Linux/NTP-Config/bootstrap.sh | sudo bash -s -- --ref stable            # back on the channel
```

Re-running the installer or the one-liner **without** `--ref` keeps the ref the
host already follows, so a pinned host stays pinned. The self-update never
installs a version older than the one running, so if a release turns out to be
bad, publish a fixed newer release rather than moving `stable` backwards; to
put one host back on an older release immediately, re-run with
`--ref <older tag>`. How releases are cut is described in the repository's
top-level README.

### Calling From Another Script

The tool can be driven by a larger setup script with no terminal at all: give
it the settings on the command line and it never prompts.

```bash
sudo configure-ntp-server.sh --sources preferred --allow 192.168.1.0/24
```

| Flag | Meaning |
| --- | --- |
| `--sources VALUE` | `native`, `usa`, `preferred`, or a comma/space separated list of hostnames or IPs |
| `--allow CIDRS` | The complete list of subnets allowed to query this host (comma/space separated), or `none`. It replaces the current list, and matching firewall rules are added and removed to follow. Repeatable. |
| `--stratum N` | Local stratum lock, 0 to 15, or `none` to remove it |
| `--no-firewall` | Do not create or revoke firewall rules (with `--allow`) |
| `--status` | Print the current configuration and change nothing |
| `--update` | Also check for a self-update (off by default when unattended, so the caller decides which version runs) |
| `--unattended`, `-y` | Never prompt (implied by `--sources`, `--allow`, `--stratum`) |

How it behaves, so a caller can rely on it:

- **Idempotent.** Each setting is compared with what chrony already has and
  only written if it differs. Repeating the same command changes nothing and
  does not restart chrony. The last line printed is `RESULT: changed` or
  `RESULT: unchanged`.
- **One backup per run**, taken before the first write, so the automatic
  restore always returns to the state the run started from.
- **Arguments are checked first.** A bad value (invalid CIDR, empty
  `--sources`, unknown flag) exits with code 2 before anything on the host is
  touched.
- **Fresh hosts work.** If chrony is not installed it is installed first,
  non-interactively (waiting for the dpkg lock rather than failing).
- **No working-directory dependence and no terminal needed.** Run it with
  stdin closed (`</dev/null`) if the caller might otherwise leave it open.

| Exit code | Meaning |
| --- | --- |
| 0 | Success (changes applied, or nothing needed changing) |
| 1 | Runtime failure (not root, unsupported OS, chrony would not start) |
| 2 | Invalid arguments; nothing was touched |

```bash
if out="$(sudo configure-ntp-server.sh --sources preferred --allow 192.168.1.0/24 </dev/null 2>&1)"; then
    echo "NTP: ${out##*$'\n'}"        # RESULT: changed | RESULT: unchanged
else
    echo "NTP configuration failed (exit $?):" >&2; echo "${out}" >&2
fi
```

A caller does not have to install the tool at all: run
`Linux/NTP-Config/configure-ntp-server.sh` straight out of a repo snapshot it
already has (it does not self-update from there). To install it on the
target first, call `Linux/NTP-Config/install.sh` (also non-interactive; exit
codes 0, 1, and 2 as above).

### Migrating From an Earlier Self-Hosted Install

Hosts that were set up from an earlier self-hosted copy of this tool (a git
clone in `/opt/ntp-config` that pulls from a private server) keep updating
from that server until re-installed. Re-run the Quick Start one-liner on
each such host once. `install.sh` detects the old git clone, replaces it
(only if it verifiably is an `ntp-config` clone; any other git repository at
that path is left alone and the install stops), and repoints
`/usr/local/sbin/configure-ntp-server.sh`. Chrony settings are not touched;
they live in chrony's own config file, not in the install directory.

### Configuration Storage

There is no separate config file. All settings (time sources, allowed
subnets, stratum lock) are written directly into chronyd's own config file
(`/etc/chrony/chrony.conf` on Debian/Ubuntu, `/etc/chrony.conf` on
RHEL/Fedora family) inside clearly marked, script-managed blocks. A
timestamped backup of that file is created before every change.

## Troubleshooting

**TLS / Certificate Errors During Download or Update**
The bootstrap prints both options when curl reports a certificate problem:
`--cacert FILE` (verifies TLS; preferred) or `--insecure` (skips
verification; trusted networks only). To change the saved choice later,
re-run the bootstrap with the other flag. Once the CA is installed
system-wide (`update-ca-certificates` on Debian/Ubuntu, `update-ca-trust` on
RHEL/Fedora family), no flag is needed.

**"could not reach the update source" on every run**
Non-fatal; the tool keeps working on the installed version. Check outbound
HTTPS to `raw.githubusercontent.com` (for example
`curl -I https://raw.githubusercontent.com`), or set `SKIP_SELF_UPDATE=1` on
hosts that are intentionally offline.

**chronyd fails to start after a change**
Option 6 (apply changes and restart) automatically restores the backup
taken just before the change and retries the restart if the first attempt
fails, so the service should already be back up on the last-known-good
config. Check `journalctl -u chronyd -n 50 --no-pager` (RHEL/Fedora family)
or `journalctl -u chrony -n 50 --no-pager` (Debian/Ubuntu) either way. Every
backup taken this run is at `<chrony.conf path>.bak.<timestamp>` if a
different one needs restoring manually. This tool writes no log file of its
own; service logs are in the journal.

**No NTP clients showing up under `chronyc clients`**
Adding or replacing a subnet under option 3 automatically creates its
firewall rule, so first confirm the querying device is actually in a subnet
that was added there. If the rule still looks missing (for example the
firewall was reset or reconfigured outside this script since), re-run
option 4 to re-sync it. Also confirm UDP 123 is not being blocked by
anything upstream of this host (a router ACL or another firewall) if the
clients are not on the exact same broadcast domain.
