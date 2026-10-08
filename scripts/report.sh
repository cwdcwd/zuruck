#!/usr/bin/env bash
#
# Zuruck — send a status report to a collector (e.g. thecollector's dashboard)
#
# POSTs `status.sh --json` plus a small `report` envelope to $ZURUCK_INGEST_URL,
# authenticated with the per-client token in <config dir>/ingest-token
# (override: $ZURUCK_INGEST_TOKEN_FILE). backup.sh calls this on every exit
# when ZURUCK_INGEST_URL is set in the env file.
#
# Usage:
#   ./scripts/report.sh                   # report current status, exit_code null
#   ./scripts/report.sh --exit-code 0     # include the backup run's exit code
#   ./scripts/report.sh --print           # print the payload, send nothing
#
# The token never appears in argv or the environment of child processes: it is
# written to a 0600 temp header file that curl reads with -H @file.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=zuruck-common.sh
source "$SCRIPT_DIR/zuruck-common.sh"
zuruck_add_user_bin_to_path

EXIT_CODE=""
PRINT_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exit-code) EXIT_CODE="$2"; shift 2 ;;
    --print)     PRINT_ONLY=true; shift ;;
    -h|--help)   sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ -z "$EXIT_CODE" || "$EXIT_CODE" =~ ^[0-9]+$ ]] || { echo "ERROR: --exit-code must be an integer." >&2; exit 1; }

ENV_FILE="$(zuruck_resolve_env_file)"
CONF_DIR="$(dirname "$ENV_FILE")"
[[ -r "$ENV_FILE" ]] || { echo "ERROR: cannot read $ENV_FILE — run client-setup.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
export RESTIC_ENV_FILE="$ENV_FILE"

command -v jq >/dev/null 2>&1 || { echo "ERROR: report.sh needs jq." >&2; exit 1; }

STATUS_JSON="$("$SCRIPT_DIR/status.sh" --json 2>/dev/null || echo '{}')"
[[ -z "$STATUS_JSON" ]] && STATUS_JSON='{}'

PAYLOAD="$(printf '%s' "$STATUS_JSON" | jq \
  --arg host "$(hostname)" \
  --arg client "$(zuruck_client_name)" \
  --arg sent "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg platform "$(uname -s | tr '[:upper:]' '[:lower:]')" \
  --arg rc "$EXIT_CODE" '
  . + { report: {
          schema: 1,
          host: $host,
          client: $client,
          platform: $platform,
          sent_at: $sent,
          exit_code: (if $rc == "" then null else ($rc | tonumber) end)
        } }')"

if $PRINT_ONLY; then printf '%s\n' "$PAYLOAD"; exit 0; fi

: "${ZURUCK_INGEST_URL:?ZURUCK_INGEST_URL not set in $ENV_FILE}"
case "$ZURUCK_INGEST_URL" in
  http://*|https://*) ;;
  *) echo "ERROR: ZURUCK_INGEST_URL must be an http(s) URL." >&2; exit 1 ;;
esac
TOKEN_FILE="${ZURUCK_INGEST_TOKEN_FILE:-$CONF_DIR/ingest-token}"
[[ -r "$TOKEN_FILE" ]] || { echo "ERROR: cannot read ingest token $TOKEN_FILE." >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
( umask 077
  printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' <"$TOKEN_FILE")" >"$TMP/headers"
  printf '%s' "$PAYLOAD" >"$TMP/payload" )

curl -fsS --max-time 20 --retry 2 --retry-delay 3 \
  -H @"$TMP/headers" \
  -H 'Content-Type: application/json' \
  --data-binary @"$TMP/payload" \
  "$ZURUCK_INGEST_URL" >/dev/null
echo "==> Reported status to $ZURUCK_INGEST_URL"
