#!/bin/bash
#
# Zuruck — install the root-scope backup grant (owner runs this, with sudo)
#
# Gives ONE unprivileged backup user the ability to back up root-owned paths
# (/etc, docker volumes, ...) into its existing zuruck repository, without
# giving it a general root shell:
#
#   /usr/local/sbin/zuruck-root-backup   wrapper (scripts/root-backup.sh), root 0755
#   /usr/local/sbin/restic-zuruck        root-owned restic copy, 0755
#   /etc/zuruck-root/{env,password,paths,hooks.env,hooks/}   root-only config
#   /etc/sudoers.d/030-zuruck-root-backup  exact-argv, no-arguments grant
#
# Credentials are copied from the user's user-mode config
# (~<user>/.config/zuruck/env + password), so the root scope writes to the
# same per-host repository with tag "root".
#
# Usage:
#   sudo ./scripts/install-root-backup.sh --user cwd --path /etc \
#        [--path /var/lib/docker/volumes/foo] [--hook litellm-pg-dump] \
#        (--restic-binary /path/to/verified/restic | --restic-version 0.18.1 --restic-sha256 <sha>)
#   sudo ./scripts/install-root-backup.sh --user cwd --uninstall
#
# Re-running updates the wrapper, paths, hooks and credentials in place.
# hooks.env is created from a template once and never overwritten.
#
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF=/etc/zuruck-root
WRAPPER=/usr/local/sbin/zuruck-root-backup
RESTIC=/usr/local/sbin/restic-zuruck
SUDOERS=/etc/sudoers.d/030-zuruck-root-backup

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

TARGET_USER=""; PATHS=(); HOOKS=(); RESTIC_SRC=""; RESTIC_VERSION=""; RESTIC_SHA256=""; UNINSTALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)           TARGET_USER="$2"; shift 2 ;;
    --path)           PATHS+=("$2"); shift 2 ;;
    --hook)           HOOKS+=("$2"); shift 2 ;;
    --restic-binary)  RESTIC_SRC="$2"; shift 2 ;;
    --restic-version) RESTIC_VERSION="$2"; shift 2 ;;
    --restic-sha256)  RESTIC_SHA256="$2"; shift 2 ;;
    --uninstall)      UNINSTALL=true; shift ;;
    -h|--help)        sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "Unknown option: $1" ;;
  esac
done

[[ "$(uname)" == "Linux" ]] || die "Linux only."
[[ $EUID -eq 0 ]] || die "run with sudo (this installs a sudoers grant)."
[[ -n "$TARGET_USER" ]] || die "--user is required."
[[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid user name '$TARGET_USER'."
id -u "$TARGET_USER" >/dev/null 2>&1 || die "no such user '$TARGET_USER'."
[[ "$(id -u "$TARGET_USER")" -ne 0 ]] || die "the grant is for an unprivileged user, not root."

if $UNINSTALL; then
  rm -f "$SUDOERS" "$WRAPPER" "$RESTIC"
  info "Removed the sudoers grant, wrapper and restic copy."
  info "Left $CONF and /var/lib/zuruck-root in place (delete by hand if wanted)."
  exit 0
fi

[[ ${#PATHS[@]} -gt 0 ]] || die "at least one --path is required."
for p in "${PATHS[@]}"; do
  [[ "$p" == /* ]] || die "--path must be absolute: $p"
  [[ "$p" != *$'\n'* ]] || die "--path contains a newline"
done
for h in "${HOOKS[@]+"${HOOKS[@]}"}"; do
  [[ "$h" =~ ^[a-z0-9][a-z0-9-]*$ && -f "$SCRIPT_DIR/root-hooks/$h" ]] || die "unknown hook '$h' (see scripts/root-hooks/)."
done
if [[ -z "$RESTIC_SRC" ]]; then
  [[ -n "$RESTIC_VERSION" && -n "$RESTIC_SHA256" ]] || die "pass --restic-binary PATH or --restic-version + --restic-sha256."
fi
command -v visudo >/dev/null || die "visudo not found."
command -v flock >/dev/null || die "flock not found (util-linux)."

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
USER_CONF="$USER_HOME/.config/zuruck"
[[ -r "$USER_CONF/env" && -r "$USER_CONF/password" ]] \
  || die "$USER_CONF/env and password not found — run client-setup.sh --user-mode as $TARGET_USER first."

# ── restic (root-owned copy; never the user's writable binary) ─────────────
if [[ -n "$RESTIC_SRC" ]]; then
  [[ -f "$RESTIC_SRC" ]] || die "no such file: $RESTIC_SRC"
  info "Installing restic from $RESTIC_SRC (sha256 $(sha256sum "$RESTIC_SRC" | cut -d' ' -f1))"
  install -o root -g root -m 0755 "$RESTIC_SRC" "$RESTIC"
else
  case "$(uname -m)" in
    x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; armv7l|armv6l) arch=arm ;;
    *) die "unsupported architecture $(uname -m)" ;;
  esac
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  file="restic_${RESTIC_VERSION}_linux_${arch}.bz2"
  info "Downloading $file"
  curl -fsSL "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/${file}" -o "$tmp/$file"
  [[ "$(sha256sum "$tmp/$file" | cut -d' ' -f1)" == "$RESTIC_SHA256" ]] || die "SHA256 mismatch for $file."
  bzip2 -d "$tmp/$file"
  install -o root -g root -m 0755 "$tmp/${file%.bz2}" "$RESTIC"
fi
"$RESTIC" version

# ── Wrapper ────────────────────────────────────────────────────────────────
install -o root -g root -m 0755 "$SCRIPT_DIR/root-backup.sh" "$WRAPPER"
info "Installed $WRAPPER"

# ── Config ─────────────────────────────────────────────────────────────────
install -d -o root -g root -m 0700 "$CONF"
# Pull the repo + AWS creds out of the user's env file in a subshell, so the
# user's file can't run code beyond setting variables in that subshell.
read_user_var() { ( set +u; # shellcheck disable=SC1091
                    source "$USER_CONF/env" >/dev/null 2>&1; printf '%s' "${!1:-}" ); }
REPO="$(read_user_var RESTIC_REPOSITORY)"
AKID="$(read_user_var AWS_ACCESS_KEY_ID)"
SAK="$(read_user_var AWS_SECRET_ACCESS_KEY)"
[[ "$REPO" =~ ^(s3:[A-Za-z0-9./:-]+|/[A-Za-z0-9._/-]+)$ ]] || die "unexpected RESTIC_REPOSITORY in $USER_CONF/env"
[[ "$AKID" =~ ^[A-Z0-9]+$ ]] || die "unexpected AWS_ACCESS_KEY_ID in $USER_CONF/env"
[[ "$SAK" =~ ^[A-Za-z0-9/+=]+$ ]] || die "unexpected AWS_SECRET_ACCESS_KEY in $USER_CONF/env"

install -o root -g root -m 0600 "$USER_CONF/password" "$CONF/password"
cat >"$CONF/env" <<EOF
# Written by install-root-backup.sh — root scope for user $TARGET_USER.
export RESTIC_REPOSITORY="$REPO"
export AWS_ACCESS_KEY_ID="$AKID"
export AWS_SECRET_ACCESS_KEY="$SAK"
export RESTIC_PASSWORD_FILE="$CONF/password"
export RESTIC_CACHE_DIR="/var/cache/zuruck-root"
EOF
chmod 600 "$CONF/env"; chown root:root "$CONF/env"
unset SAK

{ echo "# Root-scope paths (install-root-backup.sh). One absolute path per line."
  printf '%s\n' "${PATHS[@]}"; } >"$CONF/paths"
chmod 600 "$CONF/paths"; chown root:root "$CONF/paths"
info "Root-scope paths: ${PATHS[*]}"

install -d -o root -g root -m 0700 "$CONF/hooks"
for h in "${HOOKS[@]+"${HOOKS[@]}"}"; do
  install -o root -g root -m 0700 "$SCRIPT_DIR/root-hooks/$h" "$CONF/hooks/$h"
  info "Installed hook $h"
done
if [[ ${#HOOKS[@]} -gt 0 && ! -e "$CONF/hooks.env" ]]; then
  cat >"$CONF/hooks.env" <<'EOF'
# Settings for root-scope hooks. Fill these in, then run the wrapper once.
# litellm-pg-dump — check service/user/db names in /opt/litellm/docker-compose.yml
LITELLM_COMPOSE_DIR=/opt/litellm
LITELLM_PG_SERVICE=
LITELLM_PG_USER=
LITELLM_PG_DB=
EOF
  chmod 600 "$CONF/hooks.env"; chown root:root "$CONF/hooks.env"
  info "Created $CONF/hooks.env — fill in the hook settings before the first run."
fi

# ── sudoers: exact path, empty argument list ("" = no arguments allowed) ──
tmp_sudoers="$(mktemp)"
printf '# zuruck root-scope backup (install-root-backup.sh)\n%s ALL=(root) NOPASSWD: %s ""\n' \
  "$TARGET_USER" "$WRAPPER" >"$tmp_sudoers"
visudo -cf "$tmp_sudoers" >/dev/null || { rm -f "$tmp_sudoers"; die "generated sudoers failed visudo."; }
install -o root -g root -m 0440 "$tmp_sudoers" "$SUDOERS"
rm -f "$tmp_sudoers"
info "Installed $SUDOERS"

cat <<EOF

Done. Verify as $TARGET_USER:
  sudo -n -l                                  # lists exactly: $WRAPPER ""
  sudo -n id                                  # must FAIL (no general sudo)
  sudo -n $WRAPPER --anything                 # must FAIL (no arguments allowed)
  sudo -n $WRAPPER                            # first root-scope snapshot

Then set ZURUCK_ROOT_BACKUP=1 in $USER_CONF/env (or re-run client-setup.sh
--user-mode with --root-backup) so the scheduled backup includes the root scope.
EOF
