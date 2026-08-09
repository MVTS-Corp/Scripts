README.md v1.0.0 (Last Rev: 2026-08-09)

## Overview

Backup and restore tooling for self-hosted services, organized one
subfolder per service.

## Files

- **Gitea/** - backs up a self-hosted Gitea instance (via `gitea dump`)
  to a NAS over rsync/SSH, with a companion restore script including an
  isolated, safe-to-schedule test-restore mode. See `Gitea/README.md`.
