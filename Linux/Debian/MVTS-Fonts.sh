#!/usr/bin/env bash
#
# MVTS-Fonts.sh — Install Google Fonts system-wide on Debian/Ubuntu.
#
# Pulls TTFs directly from the google/fonts GitHub repo (raw host), which is
# deterministic and not subject to the unofficial fonts.google.com/download
# endpoint's flakiness or to api.github.com's 60/hour unauthenticated limit.
#
# Every download is validated as a real font (sfnt magic bytes) before install,
# so an upstream rename surfaces as a clear error instead of a broken archive.
#
# Idempotent: families already present are skipped unless --force is given.
# Dependencies (curl, fontconfig) are installed automatically if missing.
#
# Usage:
#   sudo ./MVTS-Fonts.sh           # install missing families
#   sudo ./MVTS-Fonts.sh --force   # reinstall everything
#
set -euo pipefail

# --- Configuration ---------------------------------------------------------
# Pin REF to a commit SHA instead of "main" if you need byte-for-byte
# reproducibility across a fleet (protects against upstream file renames).
REF="main"
BASE="https://raw.githubusercontent.com/google/fonts/${REF}"
INSTALL_DIR="/usr/local/share/fonts/google"

# family name -> space-separated repo-relative TTF path(s).
# Inter and Outfit are variable fonts (all weights Thin->Black in one file);
# Permanent Marker and Archivo Black are single-weight display faces.
# Need discrete static weights instead? They live under each family's
# static/ subdir, e.g. ofl/inter/static/Inter-SemiBold.ttf
declare -A FONT_FILES=(
  ["Permanent Marker"]="apache/permanentmarker/PermanentMarker-Regular.ttf"
  ["Archivo Black"]="ofl/archivoblack/ArchivoBlack-Regular.ttf"
  ["Outfit"]="ofl/outfit/Outfit[wght].ttf"
  ["Inter"]="ofl/inter/Inter[opsz,wght].ttf ofl/inter/Inter-Italic[opsz,wght].ttf"
)

# --- Helpers ---------------------------------------------------------------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Exact, case-insensitive family-name match (avoids "Inter" vs "Inter Tight").
# Some variable fonts report a comma-separated multi-value family — e.g. Outfit's
# VF lists "Outfit,Outfit Thin" — so split on commas before matching tokens.
family_installed() { fc-list : family | tr ',' '\n' | grep -qix "$1"; }

# True if the file begins with a valid sfnt signature (TTF/OTF/true/collection).
is_font() {
  case "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" in
    00010000|4f54544f|74727565|74746366) return 0 ;;
    *) return 1 ;;
  esac
}

# Percent-encode the bracket characters used in variable-font filenames.
url_encode() { local s="${1//\[/%5B}"; printf '%s' "${s//\]/%5D}"; }

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

# --- Pre-flight ------------------------------------------------------------
[[ $EUID -eq 0 ]] || err "Please run as root (sudo)."

missing=false
for cmd in curl fc-cache fc-list od; do
  command -v "$cmd" >/dev/null 2>&1 || missing=true
done
if $missing; then
  log "Installing dependencies (curl, fontconfig)…"
  apt-get update -qq
  apt-get install -y -qq curl fontconfig
fi

# --- Install ---------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

changed=false
for fam in "${!FONT_FILES[@]}"; do
  if ! $FORCE && family_installed "$fam"; then
    log "Already installed: $fam (skipping; use --force to reinstall)"
    continue
  fi

  log "Fetching: $fam"
  for path in ${FONT_FILES[$fam]}; do
    fn="${path##*/}"
    out="$TMP/$fn"

    if ! curl -gfsSL -o "$out" "${BASE}/$(url_encode "$path")"; then
      warn "  download failed: $fn"
      continue
    fi
    if ! is_font "$out"; then
      warn "  not a valid font (upstream moved?): $fn"
      continue
    fi

    install -m 644 "$out" "$INSTALL_DIR/$fn"
    printf '    fetched %s (%s bytes)\n' "$fn" "$(stat -c%s "$out")"
    changed=true
  done
done

# --- Finalize --------------------------------------------------------------
if $changed; then
  log "Rebuilding font cache…"
  fc-cache -f "$INSTALL_DIR" >/dev/null
else
  log "No changes; font cache untouched."
fi

# --- Verify ----------------------------------------------------------------
log "Verifying:"
ok=true
for fam in "${!FONT_FILES[@]}"; do
  if family_installed "$fam"; then
    printf '    \033[1;32m✓\033[0m %s\n' "$fam"
  else
    printf '    \033[1;31m✗\033[0m %s (not found)\n' "$fam"
    ok=false
  fi
done

$ok || err "One or more families are missing — check the warnings above."
log "Done. Fonts installed to $INSTALL_DIR"
