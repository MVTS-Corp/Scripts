README.md v2.2.0 (Last Rev: 2026-08-09)

# Gitea Backup and Restore (rsync over SSH)

## Overview

`gitea-backup.sh` runs Gitea's built-in `gitea dump` inside the running
Gitea container (bundling repos, LFS data, the database dump, and config
into one archive), verifies the result, and ships it to a NAS via rsync
over SSH. This gives Gitea an independent recovery path separate from the
Docker host's full-container-set backup: a bad host backup, a host
rebuild, or an environmental event at the primary site does not take out
your only copy of Gitea.

`gitea dump` is used instead of a hand-rolled DB dump + volume tar because
it bundles repos, LFS data, a database dump, and app config into one
archive using Gitea's own DB connection from `app.ini` - the backup script
never needs to independently know or store database credentials.

`gitea-restore.sh` is the other half: it can fetch an archive back from
the NAS (or use a local file), verify it, and either run a real restore
into the production container or an on-demand test-restore into an
isolated, throwaway container that never touches production data, volumes,
or network - so "can we actually restore from this backup" is a fact you
can check on a schedule, not an assumption. See "Restore" below.

**Transport decision: rsync over SSH**, not plain SFTP and not the NAS's
native rsync daemon (port 873):

- Plain SFTP has no independent integrity check and no resume; a
  half-finished transfer means starting over and manually confirming the
  result.
- The native rsync daemon protocol transmits unencrypted unless separately
  tunneled, and authenticates against a flat secrets file rather than a key.
- rsync over SSH reuses the SSH/SFTP service already enabled on the NAS,
  encrypts in transit, supports resumable/delta transfer, and allows a
  dedicated backup key to be locked to exactly one directory.

## Files

- `gitea-backup.sh` - the backup script. Run with `--check` for a
  dependency/pre-flight/connectivity test only, `--dry-run` to run the dump
  and verification but skip the NAS transfer and any deletions, or with no
  arguments for a normal run.
- `gitea-restore.sh` - the restore script. Run with `--check`, `--list`
  (show archives on the NAS), `--dry-run` (fetch + verify only),
  `--test-restore` (full restore into an isolated throwaway container -
  safe to run any time, including on a schedule), or `--restore --confirm`
  for the real, disruptive restore into the production container. See
  "Restore" below.
- `gitea-backup.conf` - all site-specific values shared by both scripts
  (container name, NAS host, paths, retention, restore settings,
  notification settings). Copy to `/etc/gitea-backup/gitea-backup.conf`
  and edit; never edit either script for a new deployment.

## Quick Start

### 0. Get the Files

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts/Linux/Backups/Gitea
```

### 1. Confirm the Remote Path

If what you have is an SMB share path (e.g. `\\nas-host\backups\Gitea`),
SSH/rsync need the underlying filesystem path instead, which is usually
different from the share name. SSH into the NAS as an admin account and
find it, for example:

```bash
ssh admin@<nas-host>
# Synology: shares typically live under /volume<N>/<ShareName>
ls -la "/volume1/backups/Gitea"
```

If that path doesn't exist, check the share's configured location in the
NAS admin UI (DSM: Control Panel > Shared Folder > admin$ > Edit, look at
the "Location" field) rather than guessing further. Once confirmed, set
`NAS_REMOTE_PATH` in the config to the real path.

### 1b. Confirm the Repository Root (needed for restore, not backup)

`gitea-restore.sh` needs to know exactly where Gitea stores repositories
inside the container (`GITEA_REPO_ROOT` in the config) so it can restore
into the right place. Confirm it against the running container rather
than guessing:

```bash
docker exec -u git <container> grep -A5 '^\[repository\]' /data/gitea/conf/app.ini
```

If `ROOT` isn't explicitly set there, Gitea's own default is
`%(APP_DATA_PATH)s/gitea-repositories` (i.e. under the same data directory
as `app.ini`); some older docker-image layouts instead used
`/data/git/repositories`. Set `GITEA_REPO_ROOT` in the config to whichever
one actually applies. This step is only needed if you plan to use
`gitea-restore.sh` - `gitea-backup.sh` does not need it.

### 2. Create a Dedicated NAS Account

Do not use an admin account for this job. Create a NAS user (for example
`gitea-backup`) whose permissions are restricted to read/write on the
Gitea backup folder only, with no access to other shares. On Synology this
is done through Control Panel > User & Group > permissions, per shared
folder.

### 3. Generate a Dedicated SSH Key Pair

On the Docker host, as the user that will run cron:

```bash
sudo mkdir -p /etc/gitea-backup
sudo ssh-keygen -t ed25519 -f /etc/gitea-backup/id_ed25519_gitea-backup -N "" -C "gitea-backup@$(hostname)"
sudo chmod 600 /etc/gitea-backup/id_ed25519_gitea-backup
sudo chmod 644 /etc/gitea-backup/id_ed25519_gitea-backup.pub
```

Install the public key on the NAS for the `gitea-backup` account (DSM:
User & Group > the user > Advanced/SSH public key, or append to that
account's `~/.ssh/authorized_keys` if managed manually).

**Recommended hardening (if the NAS ships `rrsync`):** restrict the key to
write-only access on exactly this directory, so a leaked key cannot be
used for anything else:

```
command="/usr/bin/rrsync -wo '/volume1/backups/Gitea/'",no-port-forwarding,no-X11-forwarding,no-pty,no-agent-forwarding ssh-ed25519 AAAA... gitea-backup@dockerhost
```

If the NAS doesn't ship `rrsync`, the per-account share permission from
step 2 is your primary control instead - the key can log in, but the
account itself can't touch anything outside that folder.

### 4. Pre-Seed the Known Hosts File

Using a dedicated known_hosts file (rather than the system-wide one) keeps
this job's trust in the NAS's host key independent and easy to audit:

```bash
sudo ssh-keyscan -p 22 <nas-host> | sudo tee /etc/gitea-backup/known_hosts
```

Verify the fingerprint printed matches the NAS's actual key (check the NAS
admin UI or console) before trusting it - `ssh-keyscan` itself does not
verify anything, it just fetches whatever key is offered.

### 5. Deploy the Config and Script

```bash
sudo cp gitea-backup.conf /etc/gitea-backup/gitea-backup.conf
sudo chmod 600 /etc/gitea-backup/gitea-backup.conf
sudo nano /etc/gitea-backup/gitea-backup.conf   # fill in every value

sudo cp gitea-backup.sh /usr/local/bin/gitea-backup.sh
sudo cp gitea-restore.sh /usr/local/bin/gitea-restore.sh
sudo chmod +x /usr/local/bin/gitea-backup.sh /usr/local/bin/gitea-restore.sh
```

### 6. Test Before Scheduling

Run each stage manually and confirm it's clean before trusting it to cron:

```bash
sudo /usr/local/bin/gitea-backup.sh --check      # deps + SSH connectivity + write test
sudo /usr/local/bin/gitea-backup.sh --dry-run     # full dump + verification, no transfer
sudo /usr/local/bin/gitea-backup.sh               # full run, transfers to the NAS
```

Confirm the archive actually landed on the NAS and that
`/var/log/gitea-backup.log` shows a clean run with no WARN/ERROR lines.

## After Install Configuration

### Scheduling

```bash
sudo crontab -e
# Daily at 02:15
15 2 * * * /usr/local/bin/gitea-backup.sh >> /var/log/gitea-backup-cron.log 2>&1
```

### Notifications

Set `NOTIFY_EMAIL` and `MAIL_FROM` in the config to route failure alerts
through your existing msmtp relay. No email is sent on a routine success -
only on failure, or via the optional `HEARTBEAT_URL` (Uptime Kuma push
monitor) if you want a dead man's switch that also catches the case where
cron itself silently stops running the job.

### Retention

`RETENTION_DAYS` controls how long dumps are kept on the NAS,
`STAGING_RETENTION_DAYS` controls the short-lived local staging copy on
the Docker host. Retention cleanup failures are logged as warnings and
never fail an otherwise-successful run.

### Reliability

`DUMP_TIMEOUT` bounds the `gitea dump` step itself (seconds, default
21600 / 6 hours). If a run ever logs "did not complete within
DUMP_TIMEOUT", either something inside the container genuinely hung (a
locked DB, a full disk - check `docker logs` and disk space on the host),
or the instance has grown large enough that the dump legitimately needs
longer, in which case raise the value. Both `gitea-backup.sh` and
`gitea-restore.sh` also take an exclusive lock before doing anything
disruptive, so a slow run and a cron-triggered overlap can never race each
other; the second invocation just logs a WARN and exits cleanly.

### Restore

`gitea-restore.sh` shares `gitea-backup.conf`. Gitea has no built-in
single "restore" command upstream, so this automates everything that is
safely automatable and stops with clear instructions for the one thing it
will not guess at: importing the database dump (see `DB_RESTORE_CMD` /
`TEST_RESTORE_DB_CMD` in the config).

```bash
sudo /usr/local/bin/gitea-restore.sh --check              # deps + NAS connectivity
sudo /usr/local/bin/gitea-restore.sh --list                # what's on the NAS
sudo /usr/local/bin/gitea-restore.sh --dry-run              # fetch + verify only, touches nothing
sudo /usr/local/bin/gitea-restore.sh --test-restore         # full restore into an isolated,
                                                              # throwaway container - safe any time
sudo /usr/local/bin/gitea-restore.sh --restore --confirm    # the real, disruptive restore
```

All modes default to the most recent archive on the NAS; pass
`--archive gitea-dump-YYYYMMDD-HHMMSS.zip` for a specific one, or
`--local-file /path/to/archive.zip` to use an archive that isn't on the
NAS at all.

**`--test-restore` is the important one to run regularly.** It always
creates a brand-new container on its own isolated Docker network with its
own throwaway volume - it never touches the production container, its
volumes, or `DB_RESTORE_CMD` - so it is safe to schedule (e.g. weekly) the
same way the backup itself is scheduled. Put it on its own cron entry:

```bash
sudo crontab -e
# Weekly test-restore, Sundays at 03:00
0 3 * * 0 /usr/local/bin/gitea-restore.sh --test-restore >> /var/log/gitea-restore-cron.log 2>&1
```

Unless `TEST_RESTORE_DB_CMD` is set to a real non-production test
database, a test-restore does not exercise the database import step (that
would require reaching a real DB, which isolation deliberately prevents by
default) - it validates that the archive is fetchable and intact and that
repository/data files place correctly into a real Gitea container layout,
which is most of what actually goes wrong in a real restore. The
completion email states whether the DB step was exercised.

**`--restore --confirm`** is the real thing: it stops the production
container (`GITEA_CONTAINER_NAME`), renames its existing repository and
app-data directories aside (`*.pre-restore-<timestamp>` - never deleted),
copies in the restored files, runs `DB_RESTORE_CMD` if configured, and
restarts it. Run `--dry-run` or `--test-restore` first. After a real
restore, manually verify: the web UI is reachable, SSO login works if
configured (redirect URI and any internal CA trust as applicable), a
known repo clones successfully, and any CI runner (e.g. `act_runner`) can
still authenticate - none of that is safely automatable without touching
things this project doesn't manage.

## Troubleshooting

**`--check` fails with "Cannot reach ... or path does not exist / is not
writable"** - either the SSH key isn't authorized for that account yet, or
`NAS_REMOTE_PATH` is wrong. Re-run the path confirmation in step 1; the
SMB share name is never the same string as the filesystem path.

**Dependency check fails on `rsync` or `ssh`** - install `rsync` and
`openssh-client` on the Docker host: `sudo apt-get install rsync
openssh-client`.

**Remote checksum always shows "skipping independent verification"** - the
NAS shell doesn't have `sha256sum` (common on BusyBox-based NAS shells).
This is non-fatal; rsync's own transfer-level integrity checking still
applies. If you find an equivalent command available on the NAS (e.g.
`md5sum`), point `REMOTE_SHA256SUM_CMD` at it, understanding it becomes an
MD5 comparison instead.

**A run fails and the log shows "Checksum mismatch after transfer"** - the
script has already deleted the bad copy from the NAS before failing, so
you won't be left trusting a corrupt backup. Just re-run.

**A backup or restore run logs "Another ... run appears to be in
progress" and exits 0** - a previous run (likely a slow `gitea dump` on a
large instance) is still holding the lock. Not an error; wait for it to
finish. If nothing is actually running, remove the stale lock file
(named `.gitea-backup.lock` / `.gitea-restore.lock` under `STAGING_DIR`) -
this should only happen if the lock file itself was manually tampered
with, since the lock is released automatically on process exit, including
a crash.

**`gitea-restore.sh` dies with "GITEA_REPO_ROOT is not set"** - this value
has no safe default and is required before any restore mode, including
`--check`, will run. See Quick Start step 1b.

**A `--test-restore` run logs a WARN that the HTTP health endpoint didn't
respond** - informational only, not a failure. Expected when Gitea is
normally backed by an external DB it cannot reach from the isolated test
network; the run still confirms the archive is intact and files placed
correctly. Set `TEST_RESTORE_DB_CMD` to a non-production test database if
you want test-restore to validate the full stack.

**`--restore` completes but the site looks empty or serves stale data** -
check the log for "No DB restore hook configured": if `DB_RESTORE_CMD` is
unset, the database was deliberately not touched and needs a manual
import from the path the log prints (`gitea-db.sql` inside the restore
work directory) before the instance will serve correct data.

**Log location** - `/var/log/gitea-backup.log` (both scripts' log, lines
tagged `[RESTORE]` for gitea-restore.sh) and `/var/log/gitea-backup-cron.log`
/ `/var/log/gitea-restore-cron.log` (cron's stdout/stderr, if configured as
above).
