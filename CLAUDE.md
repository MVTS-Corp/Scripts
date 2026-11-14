CLAUDE.md v1.0.0 (Last Rev: 2026-11-14)

# Working In This Repo

Guidance for Claude Code (and anyone else) making changes here. Tool-specific
behavior belongs in that tool's own README, not in this file.

## Public Repository Rules (Read First)

This repository is **public**. Nothing committed here may identify a site,
customer, host, or person.

- No hostnames, FQDNs, domains, IP addresses (public, private, or tailnet),
  email addresses, usernames, account or ticket numbers, provider node names,
  keys, tokens, or passwords. Not in code, comments, examples, commit
  messages, or test fixtures.
- Examples use reserved values only: `example.com`, `host.example.com`,
  `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`, `2001:db8::/32`.
- Site values come from flags, environment variables, or a local config file
  (`.env`, `*.conf`) that is git-ignored. Ship an `.example` copy with
  `CHANGE-ME` placeholders instead.
- Deployment notes, handoff packages, and anything describing a specific
  environment stay out of the repo. Keep them in a local scratch area.
- Before every commit, review the staged diff for anything above. If unsure
  whether something is identifying, leave it out and ask.

## Layout

- `Linux/<Tool>/` and `Windows/<Tool>/`: one folder per tool, each with its
  own `README.md`. Each platform has an index `README.md` that lists its
  tools; update it when adding one.
- Each tool is independently clone-and-installable. Shared helpers (for
  example `lib/common.sh`) are copied into each tool on purpose, not shared
  across tools.
- Root `README.md` is an index plus the release channel rules. Read its
  "Releases and Channels" section before changing any self-updating tool.

## Script Conventions

### Bash

- `#!/usr/bin/env bash`, `set -euo pipefail` (or `-Eeuo`), LF line endings.
- Must be `shellcheck` clean.
- Header block: file name, date (YYYY-MM-DD), `Version: vX.Y.Z`, PURPOSE,
  CHANGELOG (newest first, explains why as well as what).
- Exit codes: `0` success, `1` failure, `3` completed but with items flagged
  for a human to review.
- Support `--yes` for unattended runs and `--dry-run` that prints the plan
  and changes nothing, where the tool changes system state.
- Every flag has a matching environment variable where practical.

### PowerShell

- CRLF line endings (see `.gitattributes`).
- Comment-based help block with `.SYNOPSIS`, `.DESCRIPTION`, and `.NOTES`
  carrying `Version: vX.Y.Z` and the last edit date.

### Behavior

- Fail closed: if authentication, verification, or config cannot be
  confirmed, stop and say why. Insecure options are opt-in, never default.
- Idempotent: a second run changes nothing and says so. Rewrite files only
  when content changes.
- Verify before changing, keep a dated backup of any edited system file, and
  validate configs before reloading (for example `nft -c`, `sshd -t`).
- Unattended runs must report their own failures, never fail silently.
- Never print secrets or private keys. Secret files are mode 600, root owned.
- Least privilege: one credential per purpose, scoped to what it needs.
- Query the system for facts (versions, paths, time zone) instead of
  assuming them.
- Pin exact versions for anything pulled (container images, packages,
  releases). Never `latest`.
- Never configure two firewalls on one host silently. Detect the active one
  and stop on a conflict.

## Documentation Conventions

- README first line: `README.md vX.Y.Z (Last Rev: YYYY-MM-DD)`.
- Sections: Overview, Files, Quick Start, then whatever the tool needs.
- Title Case headings. Standard American English.
- No em dashes or en dashes. Use a hyphen, a comma, or rewrite.
- Dates YYYY-MM-DD. Times in logs and files are 24-hour with a zone label.
- State plainly what has been tested and what is assumed.

## Versioning and Releases

- Bump the script header version and CHANGELOG on every edit; bump the
  README version when it changes.
- Release tags are `<tool>-vX.Y.Z` and follow the root README process. Do not
  move tags or rewind `stable`.

## Commits

- Commit messages explain why, not just what.
- Work on a branch; do not push to `main` or `stable` without approval.
