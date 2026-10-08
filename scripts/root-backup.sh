#!/bin/bash
#
# Zuruck — root-scope backup wrapper (Linux)
#
# Installed by install-root-backup.sh as /usr/local/sbin/zuruck-root-backup,
# root-owned 0755, and granted to ONE unprivileged backup user through an
# exact-argv sudoers entry that permits it with NO arguments:
#
#   <user> ALL=(root) NOPASSWD: /usr/local/sbin/zuruck-root-backup ""
#
# The user's backup.sh calls `sudo -n /usr/local/sbin/zuruck-root-backup`
# after its own (user-scope) backup when ZURUCK_ROOT_BACKUP=1.
#
# Everything this script does is fixed by root-owned files; nothing comes from
# the caller:
#   /etc/zuruck-root/env        restic repo, AWS creds, RESTIC_PASSWORD_FILE (0600)
#   /etc/zuruck-root/paths      absolute paths to back up, one per line (0600)
#   /etc/zuruck-root/hooks.env  optional settings for hooks (0600)
#   /etc/zuruck-root/hooks/*    optional pre-backup hooks (root-owned executables)
#   /usr/local/sbin/restic-zuruck   root-owned restic binary (never ~/.local/bin)
#
# Hooks write consistent dumps (e.g. pg_dump) under $ZURUCK_SCRATCH/<hook>/.
# A failing hook's output is discarded — a partial dump is never backed up —
# and the run exits non-zero after backing up everything else.
#
# Snapshots are tagged "root" in the same per-host repository as the user
# scope, so CloudWatch freshness stays per machine and status.sh reports the
# two scopes separately. A run summary (no secrets) is written to
# /var/lib/zuruck-root/last-run.json, world-readable.
#
set -euo pipefail
umask 077
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset BASH_ENV ENV CDPATH

CONF=/etc/zuruck-root
RESTIC=/usr/local/sbin/restic-zuruck
STATE=/var/lib/zuruck-root
SCRATCH="$STATE/scratch"
LOCK=/run/zuruck-root-backup.lock
MAX_RUNTIME_SECS=14400

die() { echo "zuruck-root-backup: $*" >&2; exit 1; }

[[ $# -eq 0 ]] || die "takes no arguments"
[[ $EUID -eq 0 ]] || die "must run as root (via the sudoers grant)"

# A file or dir this script trusts must be root-owned, not a symlink, and not
# writable by group or other — otherwise the caller could steer root.
check_trusted() {
  local f="$1" owner mode
  [[ -e "$f" ]] || die "missing $f"
  [[ ! -L "$f" ]] || die "$f is a symlink"
  read -r owner mode < <(stat -c '%u %a' "$f")
  [[ "$owner" == 0 ]] || die "$f is not owned by root"
  (( (8#$mode & 8#022) == 0 )) || die "$f is group- or world-writable"
}
for f in "$CONF" "$CONF/env" "$CONF/paths" "$RESTIC"; do check_trusted "$f"; done

mkdir -p "$STATE"
chmod 755 "$STATE"
exec 9>"$LOCK"
flock -n 9 || die "another root-scope backup is running"

# shellcheck disable=SC1091
set -a; source "$CONF/env"; set +a
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY not set in $CONF/env}"
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE not set in $CONF/env}"
check_trusted "$RESTIC_PASSWORD_FILE"
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/zuruck-root}"
if [[ -e "$CONF/hooks.env" ]]; then
  check_trusted "$CONF/hooks.env"
  # shellcheck disable=SC1091
  set -a; source "$CONF/hooks.env"; set +a
fi

STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOOKS_OK=(); HOOKS_FAILED=()
RC=0

cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

write_last_run() {
  local tmp="$STATE/last-run.json.tmp"
  {
    printf '{"started_at":"%s","finished_at":"%s","exit_code":%d,' "$STARTED" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"
    printf '"hooks_ok":[%s],' "$(printf '"%s",' "${HOOKS_OK[@]+"${HOOKS_OK[@]}"}" | sed 's/,$//')"
    printf '"hooks_failed":[%s]}\n' "$(printf '"%s",' "${HOOKS_FAILED[@]+"${HOOKS_FAILED[@]}"}" | sed 's/,$//')"
  } >"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$STATE/last-run.json"
}

# ── Paths ─────────────────────────────────────────────────────────────────
PATHS=()
while IFS= read -r line; do
  line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && continue
  [[ "$line" == /* ]] || die "non-absolute path in $CONF/paths: $line"
  if [[ -e "$line" ]]; then PATHS+=("$line"); else echo "[skip] not found: $line" >&2; fi
done <"$CONF/paths"

# ── Hooks ─────────────────────────────────────────────────────────────────
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
chmod 700 "$SCRATCH"
export ZURUCK_SCRATCH="$SCRATCH"
if [[ -d "$CONF/hooks" ]]; then
  check_trusted "$CONF/hooks"
  for hook in "$CONF"/hooks/*; do
    [[ -f "$hook" && -x "$hook" ]] || continue
    name="$(basename "$hook")"
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "[hook] skipping oddly named $name" >&2; continue; }
    check_trusted "$hook"
    mkdir -p "$SCRATCH/$name"
    echo "==> Hook: $name"
    if ZURUCK_HOOK_OUT="$SCRATCH/$name" timeout 3600 "$hook"; then
      HOOKS_OK+=("$name")
    else
      echo "ERROR: hook $name failed; its output is discarded." >&2
      rm -rf "${SCRATCH:?}/$name"
      HOOKS_FAILED+=("$name")
      RC=1
    fi
  done
fi
if [[ -n "$(ls -A "$SCRATCH")" ]]; then PATHS+=("$SCRATCH"); fi

if [[ ${#PATHS[@]} -eq 0 ]]; then
  write_last_run 1
  die "nothing to back up"
fi

# ── Backup ────────────────────────────────────────────────────────────────
"$RESTIC" unlock >/dev/null 2>&1 || true
echo "==> Root scope: ${PATHS[*]}"
set +e
timeout --kill-after=15 "$MAX_RUNTIME_SECS" "$RESTIC" backup "${PATHS[@]}" \
  --tag root --exclude-caches --one-file-system
BRC=$?
set -e
if [[ $BRC -eq 3 ]]; then
  echo "WARNING: some root-scope files were unreadable (exit 3); snapshot was created." >&2
elif [[ $BRC -ne 0 ]]; then
  echo "ERROR: root-scope restic backup failed (exit $BRC)." >&2
  RC=$BRC
fi

write_last_run "$RC"
exit "$RC"
