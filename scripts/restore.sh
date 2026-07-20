#!/usr/bin/env bash
#
# Zuruck — restore / recover data from the restic S3 repository
#
# Uses the same client env as backup.sh (/etc/restic/env or $RESTIC_ENV_FILE):
# repository + RESTIC_PASSWORD_FILE + AWS credentials. All verbs except `restore`
# are read-only.
#
# Usage:
#   ./scripts/restore.sh list                          # list snapshots (default)
#   ./scripts/restore.sh browse <id|latest> [PATH]     # list files inside a snapshot
#   ./scripts/restore.sh mount [MOUNTPOINT]            # browse the repo as a filesystem (needs macFUSE)
#   ./scripts/restore.sh dump  <id|latest> <FILE> [--out FILE]   # extract ONE file
#   ./scripts/restore.sh restore <id|latest> [options] # restore into a fresh directory
#         --target DIR        where to write (default ~/zuruck-restore-<timestamp>)
#         --include PATH      only restore this path (repeatable)
#         --path PATH         select snapshot by backed-up path
#         --host HOST         select snapshot by host
#         --dry-run           show what would be restored, write nothing
#         --verify            verify restored files against the repo
#         --yes               don't prompt for confirmation
#   ./scripts/restore.sh stage [PREFIX] [--days N] [--tier T]    # pre-restore Glacier/Deep Archive objects
#
# Safety: `restore` never writes into an existing non-empty directory in place;
# it targets a fresh directory and asks before running.
#
set -euo pipefail

# Needs bash >= 4 (arrays); macOS ships 3.2 at /bin/bash — re-exec if needed.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: restore.sh needs bash >= 4; install via 'brew install bash'." >&2; exit 1
fi

ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/env}"

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

VERB="${1:-list}"; [[ $# -gt 0 ]] && shift || true
case "$VERB" in -h|--help|help) usage 0 ;; esac

# ── Load the client environment (repo + password + AWS creds) ──────────────
[[ -r "$ENV_FILE" ]] || { echo "ERROR: cannot read $ENV_FILE — run client-setup.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY not set in $ENV_FILE}"

# Parse the S3 repo URL into bucket/prefix/region (for the Glacier stage path).
# Form: s3:s3.<region>.amazonaws.com/<bucket>/<prefix>
repo_body="${RESTIC_REPOSITORY#s3:}"
repo_host="${repo_body%%/*}"
repo_path="${repo_body#*/}"
BUCKET="${repo_path%%/*}"
PREFIX="${repo_path#*/}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
if [[ "$repo_host" =~ ^s3[.-]([a-z0-9-]+)\.amazonaws\.com$ ]]; then REGION="${BASH_REMATCH[1]}"; fi

# ── Verbs ──────────────────────────────────────────────────────────────────
case "$VERB" in

  list)
    echo "Repository: $RESTIC_REPOSITORY"
    restic snapshots
    ;;

  browse)
    SNAP="${1:?usage: restore.sh browse <id|latest> [PATH]}"; shift || true
    restic ls -l "$SNAP" "$@"
    ;;

  mount)
    MP="${1:-$HOME/zuruck-mount}"
    if ! restic help mount >/dev/null 2>&1; then
      echo "ERROR: this restic build has no 'mount' command." >&2; exit 1
    fi
    # restic mount on macOS needs macFUSE.
    if ! (command -v mount_macfuse >/dev/null 2>&1 || [[ -e /Library/Filesystems/macfuse.fs ]] || [[ -e /usr/local/lib/libfuse.dylib ]]); then
      echo "macFUSE is required for 'restic mount' on macOS but was not found."
      echo "  Install it:  brew install --cask macfuse   (then reboot / approve the system extension)"
      echo "  Or browse without mounting:  ./scripts/restore.sh browse latest"
      exit 1
    fi
    mkdir -p "$MP"
    echo "Mounting repository at: $MP"
    echo "Browse it in Finder or a shell; press Ctrl-C here to unmount."
    exec restic mount "$MP"
    ;;

  dump)
    SNAP="${1:?usage: restore.sh dump <id|latest> <file-in-snapshot> [--out FILE]}"; shift || true
    FILE="${1:?missing <file-in-snapshot>}"; shift || true
    OUT=""
    while [[ $# -gt 0 ]]; do case "$1" in --out) OUT="$2"; shift 2 ;; *) echo "Unknown option: $1" >&2; exit 1 ;; esac; done
    if [[ -n "$OUT" ]]; then
      echo "Dumping $FILE from $SNAP → $OUT"
      restic dump "$SNAP" "$FILE" > "$OUT"
      echo "Wrote $(wc -c <"$OUT" | tr -d ' ') bytes to $OUT"
    else
      restic dump "$SNAP" "$FILE"
    fi
    ;;

  restore)
    SNAP="${1:?usage: restore.sh restore <id|latest> --target DIR [--include PATH]...}"; shift || true
    TARGET=""; DRY=false; VERIFY=false; YES=false
    INCLUDES=(); SELECT=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target)  TARGET="$2"; shift 2 ;;
        --include) INCLUDES+=("$2"); shift 2 ;;
        --path)    SELECT+=(--path "$2"); shift 2 ;;
        --host)    SELECT+=(--host "$2"); shift 2 ;;
        --dry-run) DRY=true; shift ;;
        --verify)  VERIFY=true; shift ;;
        --yes)     YES=true; shift ;;
        *)         echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done
    [[ -z "$TARGET" ]] && TARGET="$HOME/zuruck-restore-$(date +%Y%m%d-%H%M%S)"

    # Refuse to splat into a sensitive or non-empty existing directory.
    case "$(cd "$(dirname "$TARGET")" 2>/dev/null && pwd)/$(basename "$TARGET")" in
      "$HOME"|/|"") echo "ERROR: refusing to restore directly into '$TARGET'. Choose a fresh --target." >&2; exit 1 ;;
    esac
    if [[ -e "$TARGET" && -n "$(ls -A "$TARGET" 2>/dev/null)" ]]; then
      echo "ERROR: target '$TARGET' exists and is not empty. Choose a fresh --target." >&2; exit 1
    fi

    ARGS=(restore "$SNAP" --target "$TARGET" "${SELECT[@]}")
    for inc in "${INCLUDES[@]}"; do ARGS+=(--include "$inc"); done
    $VERIFY && ARGS+=(--verify)
    $DRY && ARGS+=(--dry-run --verbose)

    echo "Repository: $RESTIC_REPOSITORY"
    echo "Snapshot:   $SNAP"
    echo "Target:     $TARGET"
    [[ ${#INCLUDES[@]} -gt 0 ]] && echo "Include:    ${INCLUDES[*]}"
    $DRY && echo "Mode:       DRY RUN (no files written)"
    if ! $DRY && ! $YES; then
      if [[ -t 0 ]]; then
        read -r -p "Proceed with restore? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
      else
        echo "ERROR: refusing to restore non-interactively without --yes." >&2; exit 1
      fi
    fi
    mkdir -p "$TARGET"
    restic "${ARGS[@]}"
    $DRY || echo "==> Restored to $TARGET"
    ;;

  stage)
    # Pre-restore Glacier / Deep Archive objects so a later restic restore can read them.
    STAGE_PREFIX="${PREFIX}"; DAYS=7; TIER="Standard"
    [[ $# -gt 0 && "$1" != --* ]] && { STAGE_PREFIX="$1"; shift; }
    while [[ $# -gt 0 ]]; do case "$1" in
      --days) DAYS="$2"; shift 2 ;;
      --tier) TIER="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac; done
    command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found." >&2; exit 1; }
    echo "Staging s3://$BUCKET/$STAGE_PREFIX (region $REGION) for $DAYS days, tier $TIER..."
    requested=0; skipped=0
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      sc="$(aws s3api head-object --bucket "$BUCKET" --key "$key" --region "$REGION" \
              --query 'StorageClass' --output text 2>/dev/null || echo None)"
      case "$sc" in
        GLACIER|DEEP_ARCHIVE|GLACIER_IR)
          if aws s3api restore-object --bucket "$BUCKET" --key "$key" --region "$REGION" \
               --restore-request "{\"Days\":$DAYS,\"GlacierJobParameters\":{\"Tier\":\"$TIER\"}}" 2>/dev/null; then
            requested=$((requested+1))
          fi ;;
        *) skipped=$((skipped+1)) ;;   # already in Standard / STANDARD_IA / restored
      esac
    done < <(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$STAGE_PREFIX" --region "$REGION" \
               --query 'Contents[].Key' --output text 2>/dev/null | tr '\t' '\n')
    echo "Restore requested for $requested object(s); $skipped already warm."
    echo "Glacier retrieval typically completes in minutes (Standard tier) to hours (Bulk/Deep Archive)."
    echo "Check progress:  aws s3api head-object --bucket $BUCKET --key <key> --region $REGION --query Restore"
    echo "When warm, run:  ./scripts/restore.sh restore latest --target ~/zuruck-restore"
    ;;

  *)
    echo "Unknown verb: $VERB" >&2; usage 1 ;;
esac
