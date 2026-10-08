#!/usr/bin/env bash
#
# Zuruck — configure (or rotate) collector reporting on an existing client
#
# Stores the ingest token in <config dir>/ingest-token (0600) and sets
# ZURUCK_INGEST_URL in the env file. Works for user mode (~/.config/zuruck)
# and system mode (/etc/restic, run with sudo).
#
# Usage:
#   ZURUCK_INGEST_TOKEN=... ./scripts/set-ingest.sh --url http://collector.lan:8790/api/ingest
#   ./scripts/set-ingest.sh --url URL            # prompts for the token (hidden)
#   ./scripts/set-ingest.sh --url URL --test     # also send one report now
#   ./scripts/set-ingest.sh --disable            # remove URL + token
#
# The token is never accepted as a command-line argument.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=zuruck-common.sh
source "$SCRIPT_DIR/zuruck-common.sh"

URL=""; TEST=false; DISABLE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)     URL="$2"; shift 2 ;;
    --test)    TEST=true; shift ;;
    --disable) DISABLE=true; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

ENV_FILE="$(zuruck_resolve_env_file)"
CONF_DIR="$(dirname "$ENV_FILE")"
[[ -w "$ENV_FILE" ]] || { echo "ERROR: cannot write $ENV_FILE (system mode needs sudo)." >&2; exit 1; }
TOKEN_FILE="$CONF_DIR/ingest-token"

# Rewrite the env file without any existing ZURUCK_INGEST_URL line, in place
# (keeps owner and mode).
strip_url_line() {
  local tmp
  tmp="$(mktemp)"
  grep -v '^export ZURUCK_INGEST_URL=' "$ENV_FILE" >"$tmp" || true
  cat "$tmp" >"$ENV_FILE"
  rm -f "$tmp"
}

if $DISABLE; then
  strip_url_line
  rm -f "$TOKEN_FILE"
  echo "==> Collector reporting disabled for $ENV_FILE"
  exit 0
fi

[[ -n "$URL" ]] || { echo "ERROR: --url is required." >&2; exit 1; }
[[ "$URL" =~ ^https?://[^[:space:]\"\'\$\`]+$ ]] || { echo "ERROR: --url must be a plain http(s) URL." >&2; exit 1; }

TOKEN="${ZURUCK_INGEST_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  [[ -t 0 ]] || { echo "ERROR: set ZURUCK_INGEST_TOKEN or run interactively." >&2; exit 1; }
  trap 'stty echo 2>/dev/null || true' EXIT INT TERM
  read -rs -p "Ingest token (input hidden): " TOKEN </dev/tty
  trap - EXIT INT TERM
  echo
fi
[[ -n "$TOKEN" ]] || { echo "ERROR: empty token." >&2; exit 1; }

( umask 077; printf '%s\n' "$TOKEN" >"$TOKEN_FILE" )
chmod 600 "$TOKEN_FILE"
# Match the env file's owner (system mode on macOS runs as the calling user).
if [[ $EUID -eq 0 ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then owner="$(stat -f %Su "$ENV_FILE")"; else owner="$(stat -c %U "$ENV_FILE")"; fi
  chown "$owner" "$TOKEN_FILE"
fi
unset TOKEN

strip_url_line
printf 'export ZURUCK_INGEST_URL="%s"\n' "$URL" >>"$ENV_FILE"
echo "==> Reporting to $URL (token in $TOKEN_FILE)"

if $TEST; then
  RESTIC_ENV_FILE="$ENV_FILE" "$SCRIPT_DIR/report.sh"
fi
