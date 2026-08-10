README.md v1.1.0 (Last Rev: 2026-08-09)

## Overview

Backup and restore tooling for self-hosted services, organized one
subfolder per service.

## Files

- **Gitea/** - backs up a self-hosted Gitea instance (via `gitea dump`)
  to a NAS (transport is pluggable - SFTP, rsync over SSH, or the NAS's
  native rsync daemon), with a companion restore script including an
  isolated, safe-to-schedule test-restore mode. See `Gitea/README.md`.
