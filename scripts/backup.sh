#!/usr/bin/env bash
#
# Zuruck — restic backup wrapper
#
# Runs a restic backup of a sensible set of paths using the client's env file
# (repository + AWS creds + password file) and the repo's exclude list. Meant
# to be run manually or from cron/launchd/systemd.
#
# The env file is $RESTIC_ENV_FILE, else ~/.config/zuruck/env (user mode),
# else /etc/restic/env. include/excludes are read from the same directory.
#
# Usage:
#   ./scripts/backup.sh                      # back up the default path set
#   ./scripts/backup.sh ~/Documents ~/code   # back up only these paths
#   ./scripts/backup.sh --forget             # back up, then apply retention + prune
#   ./scripts/backup.sh --dry-run            # show what would be backed up
#   ./scripts/backup.sh --tag nightly        # custom snapshot tag
#   ./scripts/backup.sh --no-root            # skip the root-scope step for this run
#   ./scripts/backup.sh --no-report          # don't send the ingest report
#
# What gets backed up:
#   - Paths passed as arguments, OR
#   - Paths listed in <config dir>/include (one per line, # comments allowed), OR
#   - A default home-directory set (real data + config/secrets), below.
# Non-existent paths are skipped with a warning so restic doesn't abort.
#
# What gets excluded:
#   - <config dir>/excludes if present, else scripts/restic-excludes.txt.
#   - Plus --exclude-caches (any dir tagged CACHEDIR.TAG).
#
# Optional steps, switched on by the env file:
#   - ZURUCK_ROOT_BACKUP=1   after the user backup, run the root-scope backup
#                            via `sudo -n /usr/local/sbin/zuruck-root-backup`
#                            (installed by the owner: install-root-backup.sh)
#   - ZURUCK_INGEST_URL=...  on exit, POST status.sh --json + the exit code to
#                            the collector (report.sh), token in <config dir>/ingest-token
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=zuruck-common.sh
source "$SCRIPT_DIR/zuruck-common.sh"
zuruck_add_user_bin_to_path
ENV_FILE="$(zuruck_resolve_env_file)"
CONF_DIR="$(dirname "$ENV_FILE")"
TAG="auto"
DRY_RUN=false
DO_FORGET=false
DO_ROOT=auto
DO_REPORT=true
ROOT_WRAPPER=/usr/local/sbin/zuruck-root-backup

# Retention when --forget is passed (matches the systemd unit in client-setup.sh).
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
KEEP_YEARLY=2

usage() { sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ── Parse args (flags first, then any explicit paths) ─────────────────────
PATHS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --forget)  DO_FORGET=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --tag)     TAG="$2"; shift 2 ;;
    --no-root) DO_ROOT=false; shift ;;
    --no-report) DO_REPORT=false; shift ;;
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
export RESTIC_ENV_FILE="$ENV_FILE"   # so status.sh / report.sh read the same file

# ── Report to the collector on every exit, success or failure ─────────────
# Best-effort: a down collector never fails the backup. Dry runs don't report.
on_exit() {
  local rc=$?
  if $DO_REPORT && ! $DRY_RUN && [[ -n "${ZURUCK_INGEST_URL:-}" && -x "$SCRIPT_DIR/report.sh" ]]; then
    "$SCRIPT_DIR/report.sh" --exit-code "$rc" >&2 || echo "WARNING: ingest report failed (backup result unaffected)." >&2
  fi
  exit "$rc"
}
trap on_exit EXIT

# ── Keep the Mac awake for the whole backup ───────────────────────────────
# A laptop that idle-sleeps mid-backup tears down the GUI launchd session and
# SIGTERMs the job: observed on 2026-07-24 — restic was killed at ~2h with exit
# 130 ("signal terminated received") when the machine slept, even though the
# backup was healthy (0 timeouts, 0 watchdog fires). caffeinate holds a power
# assertion tied to THIS script's pid ($$): -i no idle sleep, -m no disk idle
# sleep, -s no system sleep (AC only), -w waits on $$ so it releases on exit.
# No effect if caffeinate is missing (e.g. Linux); the watchdog still bounds runtime.
if command -v caffeinate >/dev/null 2>&1; then
  caffeinate -imsw "$$" >/dev/null 2>&1 &
fi

# ── S3 tuning + network readiness ─────────────────────────────────────────
# Optional: cap parallel S3 connections (restic default is 5). Lower it on a
# flaky/reconnecting link to reduce connect timeouts. Set S3_CONNECTIONS in
# the env file or the environment.
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
# (default 4h); raise it via the env file for a slow initial seed. macOS has no
# `timeout`, so we run restic in the background with a killer subshell.
MAX_RUNTIME_SECS="${MAX_RUNTIME_SECS:-14400}"
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$! rc=0
  # The killer's own sleep is killed with it; otherwise every run leaks a
  # `sleep $secs` process that outlives the backup by hours.
  ( sleep "$secs" & sp=$!
    trap 'kill "$sp" 2>/dev/null; exit 0' TERM
    wait "$sp" || exit 0
    kill -TERM "$pid" 2>/dev/null && sleep 15 && kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
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
  if [[ -f "$CONF_DIR/excludes" ]]; then
    EXCLUDE_FILE="$CONF_DIR/excludes"
  elif [[ -f "$SCRIPT_DIR/restic-excludes.txt" ]]; then
    EXCLUDE_FILE="$SCRIPT_DIR/restic-excludes.txt"
  fi
fi

# ── Resolve the set of paths to back up ───────────────────────────────────
if [[ ${#PATHS[@]} -eq 0 && -f "$CONF_DIR/include" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && PATHS+=("${line/#\~/$HOME}")
  done < "$CONF_DIR/include"
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

# ── Optional root-scope backup (owner-installed, exact-argv sudo grant) ───
# Runs before retention so prune's exclusive lock never races it. The wrapper
# takes no arguments; sudo -n fails fast instead of prompting.
ROOT_RC=0
if [[ "$DO_ROOT" == auto ]]; then
  [[ "${ZURUCK_ROOT_BACKUP:-0}" == 1 ]] && DO_ROOT=true || DO_ROOT=false
fi
if $DO_ROOT && ! $DRY_RUN; then
  echo "==> Root scope: sudo -n $ROOT_WRAPPER"
  set +e
  sudo -n "$ROOT_WRAPPER"
  ROOT_RC=$?
  set -e
  if [[ $ROOT_RC -ne 0 ]]; then
    echo "ERROR: root-scope backup failed (exit $ROOT_RC); user-scope snapshot is safe." >&2
  fi
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

# A failed root scope fails the run (so the timer and the report show it),
# but only after retention and the status refresh have happened.
exit "$ROOT_RC"
