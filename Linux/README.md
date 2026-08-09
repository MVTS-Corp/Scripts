README.md v1.0.0 (Last Rev: 2026-08-09)

## Overview

This is the root directory for scripts used on Linux. Each subfolder is a
self-contained tool with its own README.

## Files

- **Group-MGMT/** - provisions fixed-GID groups consistently across the
  MVTS Linux fleet. See `Group-MGMT/README.md`.
- **MVTS/** - installs the MVTS brand fonts system-wide. See
  `MVTS/README.md`.
- **Notifications/** - installs and configures an SMTP relay (via `msmtp`)
  so a host can send alert emails, independent of any other tool. See
  `Notifications/README.md`.
- **Updates/** - automated OS patching with email alerting, deployed as a
  cron job. See `Updates/README.md`.

## Quick Start

Each subfolder is independently installable with its own one-line curl
command; see that subfolder's README for the exact command. To work with
more than one, clone the whole repo instead:

```bash
git clone https://github.com/MVTS-Corp/Scripts.git
cd Scripts/Linux
```

## After Install Configuration

See the relevant subfolder's README - configuration is specific to each
tool.

## Troubleshooting

See the relevant subfolder's README - logs and error conditions are
specific to each tool.
