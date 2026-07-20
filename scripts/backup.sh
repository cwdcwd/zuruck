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
restic "${ARGS[@]}"
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
  restic forget \
    --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" --keep-yearly "$KEEP_YEARLY" \
    --prune
fi

echo "==> Done. Snapshots:"
restic snapshots --latest 5 2>/dev/null || true

# Refresh the local status dashboard (best-effort; never fail the backup over it).
if [[ -x "$SCRIPT_DIR/status.sh" ]]; then
  "$SCRIPT_DIR/status.sh" --html >/dev/null 2>&1 || true
fi
