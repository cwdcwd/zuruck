#!/usr/bin/env bash
#
# Zuruck — restic backup wrapper
#
# Runs a restic backup of a sensible set of paths using the client's
# /etc/restic/env (repository + AWS creds + password file) and the repo's
# exclude list. Meant to be run manually or from cron/launchd/systemd.
#
# Usage:
#   ./scripts/backup.sh                      # back up the default path set
#   ./scripts/backup.sh ~/Documents ~/code   # back up only these paths
#   ./scripts/backup.sh --forget             # back up, then apply retention + prune
#   ./scripts/backup.sh --dry-run            # show what would be backed up
#   ./scripts/backup.sh --tag nightly        # custom snapshot tag
#
# What gets backed up:
#   - Paths passed as arguments, OR
#   - Paths listed in /etc/restic/include (one per line, # comments allowed), OR
#   - A default home-directory set (real data + config/secrets), below.
# Non-existent paths are skipped with a warning so restic doesn't abort.
#
# What gets excluded:
#   - /etc/restic/excludes if present, else scripts/restic-excludes.txt.
#   - Plus --exclude-caches (any dir tagged CACHEDIR.TAG).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/env}"
TAG="auto"
DRY_RUN=false
DO_FORGET=false

# Retention when --forget is passed (matches the systemd unit in client-setup.sh).
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
KEEP_YEARLY=2

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ── Parse args (flags first, then any explicit paths) ─────────────────────
PATHS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --forget)  DO_FORGET=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --tag)     TAG="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*)        echo "Unknown option: $1" >&2; exit 1 ;;
    *)         PATHS+=("$1"); shift ;;
  esac
done

# ── Load the client environment ───────────────────────────────────────────
[[ -r "$ENV_FILE" ]] || { echo "ERROR: cannot read $ENV_FILE — run client-setup.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY not set in $ENV_FILE}"

# ── S3 tuning + network readiness ─────────────────────────────────────────
# Optional: cap parallel S3 connections (restic default is 5). Lower it on a
# flaky/reconnecting link to reduce connect timeouts. Set S3_CONNECTIONS in
# /etc/restic/env or the environment.
RESTIC_OPTS=()
[[ -n "${S3_CONNECTIONS:-}" ]] && RESTIC_OPTS+=(-o "s3.connections=$S3_CONNECTIONS")

# On a laptop the scheduled run often fires right after wake, while Wi-Fi is
# still re-associating — a burst of S3 connect timeouts (restic retries through
# them, but it's noisy). Wait briefly for the S3 endpoint to answer first.
# Disable with ZURUCK_SKIP_NET_WAIT=1; tune attempts with NET_WAIT_TRIES.
wait_for_s3() {
  [[ "${ZURUCK_SKIP_NET_WAIT:-}" == 1 ]] && return 0
  [[ "$RESTIC_REPOSITORY" == s3:* ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local body="${RESTIC_REPOSITORY#s3:}" host tries="${NET_WAIT_TRIES:-12}" i
  host="${body%%/*}"
  for (( i=1; i<=tries; i++ )); do
    curl -s -o /dev/null --max-time 5 "https://$host/" && return 0
    echo "[net] $host not reachable yet (attempt $i/$tries); waiting 5s..." >&2
    sleep 5
  done
  echo "[net] proceeding without confirmed reachability; restic will retry." >&2
}
wait_for_s3

# Runtime watchdog: a wedged restic (dead-but-established S3 connection) would
# otherwise run forever and, because launchd won't start an overlapping run,
# silently block the whole schedule. Cap each restic invocation at MAX_RUNTIME_SECS
# (default 4h); raise it via /etc/restic/env for a slow initial seed. macOS has no
# `timeout`, so we run restic in the background with a killer subshell.
MAX_RUNTIME_SECS="${MAX_RUNTIME_SECS:-14400}"
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$! rc=0
  ( sleep "$secs" && kill -TERM "$pid" 2>/dev/null && sleep 15 && kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local wd=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill -TERM "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  if (( rc == 143 || rc == 137 )); then
    echo "[watchdog] restic exceeded ${secs}s and was terminated (exit $rc)." >&2
  fi
  return $rc
}

# Clear locks left behind by a killed run (e.g. the Mac slept mid-backup, or a
# scheduled job was force-stopped). `restic unlock` only removes STALE locks —
# a still-running backup's live lock is left untouched — so this is safe to run
# unconditionally and keeps the exclusive-lock `prune` step from failing later.
restic "${RESTIC_OPTS[@]}" unlock >/dev/null 2>&1 || true

# ── Resolve the exclude file ──────────────────────────────────────────────
EXCLUDE_FILE="${RESTIC_EXCLUDE_FILE:-}"
if [[ -z "$EXCLUDE_FILE" ]]; then
  if [[ -f /etc/restic/excludes ]]; then
    EXCLUDE_FILE=/etc/restic/excludes
  elif [[ -f "$SCRIPT_DIR/restic-excludes.txt" ]]; then
    EXCLUDE_FILE="$SCRIPT_DIR/restic-excludes.txt"
  fi
fi

# ── Resolve the set of paths to back up ───────────────────────────────────
if [[ ${#PATHS[@]} -eq 0 && -f /etc/restic/include ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && PATHS+=("${line/#\~/$HOME}")
  done < /etc/restic/include
fi
if [[ ${#PATHS[@]} -eq 0 ]]; then
  PATHS=(
    "$HOME/Desktop" "$HOME/Documents" "$HOME/Pictures" "$HOME/Movies" "$HOME/Music" "$HOME/bin"
    "$HOME/.ssh" "$HOME/.aws" "$HOME/.config"
    "$HOME/.claude" "$HOME/.claude-personal" "$HOME/.codex" "$HOME/.agents" "$HOME/.cagent"
    "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.gitconfig"
  )
fi

# Keep only paths that actually exist (restic aborts on a missing target).
EXISTING=()
for p in "${PATHS[@]}"; do
  if [[ -e "$p" ]]; then EXISTING+=("$p"); else echo "[skip] not found: $p" >&2; fi
done
[[ ${#EXISTING[@]} -gt 0 ]] || { echo "ERROR: none of the requested paths exist." >&2; exit 1; }

# ── Build restic args ─────────────────────────────────────────────────────
ARGS=(backup "${EXISTING[@]}" --tag "$TAG" --exclude-caches --one-file-system)
[[ -n "$EXCLUDE_FILE" ]] && ARGS+=(--exclude-file "$EXCLUDE_FILE")
$DRY_RUN && ARGS+=(--dry-run --verbose)

echo "==> Repository: $RESTIC_REPOSITORY"
echo "==> Excludes:   ${EXCLUDE_FILE:-<none>}"
echo "==> Backing up: ${EXISTING[*]}"
# restic exit codes: 0 = ok, 3 = snapshot created but some files were unreadable
# (locked/deleted mid-scan, permissions). Treat 3 as a warning so retention still
# runs and an unattended job isn't marked failed for a transient unreadable file.
set +e
run_with_timeout "$MAX_RUNTIME_SECS" restic "${RESTIC_OPTS[@]}" "${ARGS[@]}"
BACKUP_RC=$?
set -e
if [[ $BACKUP_RC -eq 3 ]]; then
  echo "WARNING: restic reported unreadable source files (exit 3); snapshot was still created — continuing." >&2
elif [[ $BACKUP_RC -ne 0 ]]; then
  echo "ERROR: restic backup failed (exit $BACKUP_RC)." >&2
  exit "$BACKUP_RC"
fi

# ── Optional retention ────────────────────────────────────────────────────
# NOTE: on this bucket (versioning + Object Lock) --prune writes delete markers
# but S3 space is only reclaimed once noncurrent versions age out (~90 days).
# See docs/backup-strategy.md.
if $DO_FORGET && ! $DRY_RUN; then
  echo "==> Applying retention (keep d=$KEEP_DAILY w=$KEEP_WEEKLY m=$KEEP_MONTHLY y=$KEEP_YEARLY) + prune"
  # The snapshot already succeeded by this point; don't let a retention/prune
  # hiccup (e.g. a lock we couldn't clear) mark the whole backup as failed.
  set +e
  run_with_timeout "$MAX_RUNTIME_SECS" restic "${RESTIC_OPTS[@]}" forget \
    --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" --keep-yearly "$KEEP_YEARLY" \
    --prune
  FORGET_RC=$?
  set -e
  [[ $FORGET_RC -ne 0 ]] && echo "WARNING: retention/prune failed (exit $FORGET_RC); snapshot is safe, will retry next run." >&2
fi

echo "==> Done. Snapshots:"
restic "${RESTIC_OPTS[@]}" snapshots --latest 5 2>/dev/null || true

# Refresh the local status dashboard (best-effort; never fail the backup over it).
if [[ -x "$SCRIPT_DIR/status.sh" ]]; then
  "$SCRIPT_DIR/status.sh" --html >/dev/null 2>&1 || true
fi
