#!/usr/bin/env bash
#
# Zuruck Restic Backup - Client Setup Script
#
# This script helps configure a client machine for restic S3 backups.
# It should be run on the client machine after the CDK stack has been deployed.
#
# Two modes:
#   System mode (default): config in /etc/restic, system systemd timer, uses sudo.
#     sudo ./client-setup.sh --client-name alpha --bucket zuruck-backup-123456789012-us-west-2 \
#       --access-key-id AKIA... --region us-west-2
#
#   User mode (--user-mode): no sudo anywhere. Config in ~/.config/zuruck (0700),
#   restic in ~/.local/bin, a systemd *user* timer that runs scripts/backup.sh.
#     export SECRET_ACCESS_KEY=... ZURUCK_INGEST_TOKEN=...
#     ./client-setup.sh --user-mode --client-name alpha --bucket ... --access-key-id AKIA... \
#       --restic-version 0.18.1 --restic-sha256 <sha> --backup-path ~/.hermes \
#       --ingest-url http://collector:8790/api/ingest
#
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Defaults
CLIENT_NAME=""
BUCKET_NAME=""
ACCESS_KEY_ID=""
# Preserve a SECRET_ACCESS_KEY exported into the environment — do NOT blank an
# inherited value, or the documented `export SECRET_ACCESS_KEY=...` workflow
# silently falls through to the interactive prompt. (Review finding #2.)
SECRET_ACCESS_KEY="${SECRET_ACCESS_KEY:-}"
SECRET_FROM_ARGV=false
SECRET_STDIN=false
REGION="us-west-2"
BACKUP_PATHS=()
INSTALL_RESTIC=false
RESTIC_VERSION_PIN=""
RESTIC_SHA256=""
USER_MODE=false
INSTALL_PATH=""
INGEST_URL=""
ROOT_BACKUP=false
FRESHNESS_HOURS=""
NO_TIMER=false

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Required:
  --client-name NAME         Client name (e.g., alpha, bravo)
  --bucket BUCKET            S3 bucket name (from CDK output)
  --access-key-id KEY        AWS Access Key ID for the client IAM user

Secret access key (provide via ONE of these — never as a CLI arg):
  SECRET_ACCESS_KEY env var  Preferred: export SECRET_ACCESS_KEY=... before running
  --secret-stdin             Read the secret from stdin (first line)
  Interactive prompt          If none of the above is set, you'll be prompted
  --secret-access-key KEY    System mode only, legacy (visible in ps/history);
                             refused in --user-mode

Mode:
  --user-mode                No sudo: config in ~/.config/zuruck, restic in
                             ~/.local/bin, systemd user timer (Linux)
  --install-path DIR         Where to install restic (default: ~/.local/bin in
                             user mode, /usr/local/bin in system mode)

Optional:
  --region REGION            AWS region (default: us-west-2)
  --backup-path PATH         Path to back up (can be specified multiple times)
  --install-restic           Install restic if not found
  --restic-version VERSION   Pin a specific upstream restic version
                             (e.g., 0.17.3). Overrides apt/yum. Required for
                             installs in --user-mode.
  --restic-sha256 SHA256     Required when --restic-version is used. The
                             SHA256 of the upstream tarball — verified
                             before install. See:
                             https://github.com/restic/restic/releases
  --ingest-url URL           Report status to a collector after each run.
                             Token via ZURUCK_INGEST_TOKEN env or prompt —
                             never as an argument.
  --root-backup              (user mode) Also run the owner-installed root-scope
                             backup (sudo -n /usr/local/sbin/zuruck-root-backup)
                             after each run. See install-root-backup.sh.
  --freshness-hours N        Freshness window for status.sh (default 24)
  --no-timer                 (user mode) Write config but don't install the timer
  -h, --help                 Show this help message

Example (system mode):
  export SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
  $0 --client-name alpha \\
     --bucket zuruck-backup-123456789012-us-west-2 \\
     --access-key-id AKIAIOSFODNN7EXAMPLE \\
     --region us-west-2 \\
     --backup-path /data \\
     --install-restic
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-name)      CLIENT_NAME="$2"; shift 2 ;;
    --bucket)           BUCKET_NAME="$2"; shift 2 ;;
    --access-key-id)    ACCESS_KEY_ID="$2"; shift 2 ;;
    --secret-access-key) SECRET_ACCESS_KEY="$2"; SECRET_FROM_ARGV=true; shift 2 ;;
    --secret-stdin)     SECRET_STDIN=true; shift ;;
    --region)           REGION="$2"; shift 2 ;;
    --backup-path)      BACKUP_PATHS+=("$2"); shift 2 ;;
    --install-restic)   INSTALL_RESTIC=true; shift ;;
    --restic-version)   RESTIC_VERSION_PIN="$2"; shift 2 ;;
    --restic-sha256)    RESTIC_SHA256="$2"; shift 2 ;;
    --user-mode)        USER_MODE=true; shift ;;
    --install-path)     INSTALL_PATH="$2"; shift 2 ;;
    --ingest-url)       INGEST_URL="$2"; shift 2 ;;
    --root-backup)      ROOT_BACKUP=true; shift ;;
    --freshness-hours)  FRESHNESS_HOURS="$2"; shift 2 ;;
    --no-timer)         NO_TIMER=true; shift ;;
    -h|--help)          usage ;;
    *)                  error "Unknown option: $1" ;;
  esac
done

# Validate required arguments
[[ -z "$CLIENT_NAME" ]] && error "Missing required argument: --client-name"
[[ -z "$BUCKET_NAME" ]] && error "Missing required argument: --bucket"
[[ -z "$ACCESS_KEY_ID" ]] && error "Missing required argument: --access-key-id"

# Validate client name shape — must match ClientConfig.name in clients.ts.
# (Security-review I1/I3.)
if [[ ! "$CLIENT_NAME" =~ ^[a-z][a-z0-9-]{1,32}$ ]]; then
  error "Invalid client name '$CLIENT_NAME': must match ^[a-z][a-z0-9-]{1,32}$"
fi
[[ "$REGION" =~ ^[a-z0-9-]+$ ]] || error "Invalid region '$REGION'"
[[ "$BUCKET_NAME" =~ ^[a-z0-9.-]+$ ]] || error "Invalid bucket name '$BUCKET_NAME'"
[[ "$ACCESS_KEY_ID" =~ ^[A-Z0-9]+$ ]] || error "Invalid access key id"
if [[ -n "$INGEST_URL" && ! "$INGEST_URL" =~ ^https?://[^[:space:]\"\'\$\`]+$ ]]; then
  error "--ingest-url must be a plain http(s) URL"
fi
if [[ -n "$FRESHNESS_HOURS" && ! "$FRESHNESS_HOURS" =~ ^[1-9][0-9]*$ ]]; then
  error "--freshness-hours must be a positive integer"
fi

# ── Mode setup ──────────────────────────────────────────────────────────
if $USER_MODE; then
  [[ $EUID -eq 0 ]] && error "--user-mode must be run as the backup user, not root (no sudo)."
  $SECRET_FROM_ARGV && error "--secret-access-key is refused in --user-mode (visible in ps and shell history). Use SECRET_ACCESS_KEY env or --secret-stdin."
  SUDO=()
  CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zuruck"
  [[ -z "$INSTALL_PATH" ]] && INSTALL_PATH="$HOME/.local/bin"
else
  $ROOT_BACKUP && error "--root-backup is a user-mode option (system mode already runs as root)."
  SUDO=(sudo)
  CONF_DIR="/etc/restic"
  [[ -z "$INSTALL_PATH" ]] && INSTALL_PATH="/usr/local/bin"
  if $SECRET_FROM_ARGV; then
    warn "--secret-access-key on the command line is visible in ps(1) and shell history."
  fi
fi
ENV_FILE="$CONF_DIR/env"
PASSWORD_FILE="$CONF_DIR/password"

# Resolve secret access key. Precedence: --secret-stdin, else the
# SECRET_ACCESS_KEY env var (or legacy flag), else an interactive prompt.
if $SECRET_STDIN; then
  IFS= read -r SECRET_ACCESS_KEY || true
fi
if [[ -z "$SECRET_ACCESS_KEY" ]]; then
  warn "SECRET_ACCESS_KEY env var not set."
  warn "You will be prompted for the secret access key (input hidden)."
  # Restore terminal echo on any exit path: an interrupted `read -rs` can
  # otherwise leave the user with a broken terminal. (Security-review S13.)
  trap 'stty echo 2>/dev/null || true' EXIT INT TERM
  read -rs SECRET_ACCESS_KEY </dev/tty
  trap - EXIT INT TERM
  echo
  [[ -z "$SECRET_ACCESS_KEY" ]] && error "Secret access key is required."
fi
[[ "$SECRET_ACCESS_KEY" =~ ^[A-Za-z0-9/+=]+$ ]] || error "Secret access key has unexpected characters."

# Ingest token (only when reporting is configured). Never an argument.
INGEST_TOKEN="${ZURUCK_INGEST_TOKEN:-}"
if [[ -n "$INGEST_URL" && -z "$INGEST_TOKEN" ]]; then
  warn "ZURUCK_INGEST_TOKEN not set; you will be prompted (input hidden)."
  trap 'stty echo 2>/dev/null || true' EXIT INT TERM
  read -rs INGEST_TOKEN </dev/tty
  trap - EXIT INT TERM
  echo
  [[ -z "$INGEST_TOKEN" ]] && error "Ingest token is required with --ingest-url."
fi

info "Setting up restic backup client: ${CLIENT_NAME} ($($USER_MODE && echo user || echo system) mode)"

# ── Install restic ──────────────────────────────────────────────────────
# When --restic-version + --restic-sha256 are passed, fetch the upstream
# binary and verify its SHA256 before installing. This is the recommended
# path: distro packages can lag behind upstream and don't expose a
# checksum-pinning workflow. (Security-review S14.)
install_restic_pinned() {
  local version="$1"
  local expected_sha="$2"
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv6l) arch="arm" ;;
    *) error "Unsupported architecture: $(uname -m)" ;;
  esac
  local os
  case "$(uname)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *) error "Unsupported OS: $(uname)" ;;
  esac
  local file="restic_${version}_${os}_${arch}.bz2"
  local url="https://github.com/restic/restic/releases/download/v${version}/${file}"
  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # expand $tmp now: it's a local
  trap "rm -rf '$tmp'" RETURN
  info "Downloading $url ..."
  curl -fsSL "$url" -o "$tmp/$file"
  local actual_sha
  actual_sha=$(sha256sum "$tmp/$file" 2>/dev/null | awk '{print $1}')
  if [[ -z "$actual_sha" ]]; then
    actual_sha=$(shasum -a 256 "$tmp/$file" | awk '{print $1}')
  fi
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    error "SHA256 mismatch for $file. Expected: $expected_sha. Got: $actual_sha"
  fi
  info "SHA256 verified: $actual_sha"
  bzip2 -d "$tmp/$file"
  local bin="${file%.bz2}"
  chmod 755 "$tmp/$bin"
  "${SUDO[@]}" mkdir -p "$INSTALL_PATH"
  "${SUDO[@]}" mv "$tmp/$bin" "$INSTALL_PATH/restic"
  trap - RETURN
}

# Prefer a restic already in the install path (user mode: ~/.local/bin).
if [[ -x "$INSTALL_PATH/restic" ]]; then
  PATH="$INSTALL_PATH:$PATH"
fi

if ! command -v restic &>/dev/null; then
  if [[ "$INSTALL_RESTIC" == true ]]; then
    if [[ -n "$RESTIC_VERSION_PIN" ]]; then
      [[ -z "$RESTIC_SHA256" ]] && error "--restic-version requires --restic-sha256 (look up at https://github.com/restic/restic/releases)"
      info "Installing restic ${RESTIC_VERSION_PIN} (SHA256-pinned) to ${INSTALL_PATH}..."
      install_restic_pinned "$RESTIC_VERSION_PIN" "$RESTIC_SHA256"
      PATH="$INSTALL_PATH:$PATH"
    elif $USER_MODE; then
      error "--user-mode can't use the system package manager (needs sudo). Pass --restic-version X.Y.Z --restic-sha256 <hash>."
    else
      warn "Installing restic via the system package manager — version is not pinned and apt/yum sources are trusted by this script."
      warn "For a hardened install, re-run with --restic-version X.Y.Z --restic-sha256 <hash>."
      info "Installing restic..."
      if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq restic
      elif command -v yum &>/dev/null; then
        yum install -y restic
      elif command -v brew &>/dev/null; then
        brew install restic
      else
        error "Cannot install restic automatically. Please install it manually: https://restic.readthedocs.io/en/stable/020_installation.html"
      fi
    fi
  else
    error "restic not found. Install it with --install-restic [--restic-version X.Y.Z --restic-sha256 <hash>] or manually: https://restic.readthedocs.io/en/stable/020_installation.html"
  fi
fi

RESTIC_BIN=$(command -v restic)
RESTIC_VERSION=$(restic version 2>&1 | head -1)
info "Using restic: ${RESTIC_VERSION} (${RESTIC_BIN})"

command -v jq &>/dev/null || warn "jq not found — status.sh and report.sh need it (owner: install the jq package)."

# ── Create configuration directory ──────────────────────────────────────
info "Creating ${CONF_DIR} directory..."
if $USER_MODE; then
  mkdir -p "$CONF_DIR"
  chmod 700 "$CONF_DIR"
  RESTIC_OWNER="$(id -un)"
else
  sudo mkdir -p /etc/restic
  # Determine the user who will run restic. On Linux with systemd, that's root.
  # On macOS (or when run with sudo), use the calling user so they can source
  # the env file and read the password file.
  if [[ -n "${SUDO_USER:-}" ]]; then
    RESTIC_OWNER="${SUDO_USER}"
    info "Running with sudo — config files will be owned by ${RESTIC_OWNER}"
  else
    RESTIC_OWNER="root"
  fi
fi

# Write stdin to a config file with mode 600 and the right owner.
write_secret_file() {
  local dest="$1"
  if $USER_MODE; then
    ( umask 077; cat >"$dest" )
    chmod 600 "$dest"
  else
    sudo tee "$dest" >/dev/null
    sudo chmod 600 "$dest"
    if [[ "${RESTIC_OWNER}" == "root" ]]; then
      sudo chown root:root "$dest" 2>/dev/null || sudo chown root:wheel "$dest"
    else
      sudo chown "${RESTIC_OWNER}" "$dest"
    fi
  fi
}

# ── Client password ─────────────────────────────────────────────────────
# Never overwrite an existing password: re-running setup on an initialized
# repo would otherwise lock the client out of its own snapshots.
if [[ -s "$PASSWORD_FILE" ]] || { ! $USER_MODE && sudo test -s "$PASSWORD_FILE"; }; then
  info "Keeping existing client password at ${PASSWORD_FILE}"
else
  info "Generating client password..."
  CLIENT_PASSWORD=$(openssl rand -base64 32)
  printf '%s\n' "${CLIENT_PASSWORD}" | write_secret_file "$PASSWORD_FILE"
  unset CLIENT_PASSWORD
  info "Client password saved to ${PASSWORD_FILE}"
fi

# ── Create environment file ─────────────────────────────────────────────
info "Creating ${ENV_FILE}..."
{
  printf 'export AWS_ACCESS_KEY_ID="%s"\n' "${ACCESS_KEY_ID}"
  printf 'export AWS_SECRET_ACCESS_KEY="%s"\n' "${SECRET_ACCESS_KEY}"
  printf 'export RESTIC_REPOSITORY="%s"\n' "s3:s3.${REGION}.amazonaws.com/${BUCKET_NAME}/${CLIENT_NAME}"
  printf 'export RESTIC_PASSWORD_FILE="%s"\n' "${PASSWORD_FILE}"
  [[ -n "$INGEST_URL" ]] && printf 'export ZURUCK_INGEST_URL="%s"\n' "$INGEST_URL"
  $ROOT_BACKUP && printf 'export ZURUCK_ROOT_BACKUP=1\n'
  [[ -n "$FRESHNESS_HOURS" ]] && printf 'export ZURUCK_FRESHNESS_HOURS=%s\n' "$FRESHNESS_HOURS"
  true
} | write_secret_file "$ENV_FILE"
info "Environment file saved to ${ENV_FILE}"

if [[ -n "$INGEST_URL" ]]; then
  printf '%s\n' "$INGEST_TOKEN" | write_secret_file "$CONF_DIR/ingest-token"
  unset INGEST_TOKEN
  info "Ingest token saved to ${CONF_DIR}/ingest-token"
fi

# User mode: backup paths go in the include file that backup.sh reads.
if $USER_MODE && [[ ${#BACKUP_PATHS[@]} -gt 0 ]]; then
  printf '%s\n' "# Paths backed up by scripts/backup.sh (one per line; ~ expands)" "${BACKUP_PATHS[@]}" \
    | ( umask 077; cat >"$CONF_DIR/include" )
  info "Backup paths saved to ${CONF_DIR}/include"
fi

# ── Test connectivity ──────────────────────────────────────────────────
# The IAM policy gates s3:ListBucket on a prefix matching the client's own
# folder, so list with that prefix — listing the bucket root will always be
# AccessDenied for a healthy install.
load_env() {
  # shellcheck disable=SC1090
  if $USER_MODE; then source "$ENV_FILE"; else source <(sudo cat "$ENV_FILE"); fi
}
if command -v aws &>/dev/null; then
  info "Testing S3 connectivity (aws CLI found)..."
  load_env
  if aws s3 ls "s3://${BUCKET_NAME}/${CLIENT_NAME}/" --region "${REGION}" &>/dev/null; then
    info "S3 connectivity OK"
  else
    warn "S3 connectivity test failed. Check credentials and bucket name."
    warn "Manual test: source ${ENV_FILE} && aws s3 ls s3://${BUCKET_NAME}/${CLIENT_NAME}/"
  fi

  # Verify the client's SSM master-password parameter exists. If it doesn't,
  # the client name is almost certainly a typo or wasn't deployed via CDK.
  # We use --query 'Parameter.Name' (no decryption) so the cleartext value
  # never enters this shell. (Security-review I1.)
  info "Verifying CDK-side client registration..."
  if aws ssm get-parameter \
      --name "/zuruck/restic/${CLIENT_NAME}/master-password" \
      --region "${REGION}" \
      --query 'Parameter.Name' --output text &>/dev/null; then
    info "Client '${CLIENT_NAME}' is registered server-side."
  else
    warn "Could not find /zuruck/restic/${CLIENT_NAME}/master-password in SSM."
    warn "Either the client wasn't deployed via CDK, or this credential lacks ssm:GetParameter."
  fi
else
  warn "aws CLI not found — skipping S3 + SSM connectivity tests."
  warn "Restic does not require the AWS CLI, but these checks do."
  warn "Install the AWS CLI or test manually: source ${ENV_FILE} && restic snapshots"
fi

# ── Initialize repository (if not already initialized) ──────────────────
info "Checking if restic repository exists..."
if ( load_env && restic snapshots >/dev/null 2>&1 ); then
  info "Restic repository already initialized"
else
  warn "Restic repository not yet initialized."
  warn "The administrator should initialize the repository using the master password:"
  warn ""
  warn "  1. Retrieve the master password from SSM:"
  warn "     aws ssm get-parameter --name \"/zuruck/restic/${CLIENT_NAME}/master-password\" --with-decryption --region ${REGION} --query 'Parameter.Value' --output text"
  warn ""
  warn "  2. Initialize the repository with the master password:"
  warn "     export RESTIC_REPOSITORY=\"s3:s3.${REGION}.amazonaws.com/${BUCKET_NAME}/${CLIENT_NAME}\""
  warn "     export RESTIC_PASSWORD=\"<master-password>\""
  warn "     restic init"
  warn ""
  warn "  3. Add the client key:"
  warn "     restic key add  # Enter the client password from ${PASSWORD_FILE}"
  warn ""
  warn "  4. Remove the master key (optional, for security):"
  warn "     restic key list"
  warn "     restic key remove <master-key-id>"
fi

# ── Root-scope grant check (user mode) ──────────────────────────────────
if $ROOT_BACKUP; then
  if sudo -n -l /usr/local/sbin/zuruck-root-backup >/dev/null 2>&1; then
    info "Root-scope grant present: sudo -n /usr/local/sbin/zuruck-root-backup"
  else
    warn "Root-scope grant NOT present yet. Backups will report a root-scope failure until the"
    warn "owner runs: sudo ./scripts/install-root-backup.sh --user $(id -un) --path /etc ..."
  fi
fi

# ── Create systemd timer ────────────────────────────────────────────────
if $USER_MODE && [[ "$(uname)" == "Linux" ]] && ! $NO_TIMER && command -v systemctl &>/dev/null; then
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$UNIT_DIR"
  info "Creating systemd user service and timer in ${UNIT_DIR}..."
  cat >"$UNIT_DIR/zuruck-backup.service" <<EOF
[Unit]
Description=Zuruck backup (${CLIENT_NAME})
After=network-online.target

[Service]
Type=oneshot
Environment="RESTIC_ENV_FILE=${ENV_FILE}"
Environment="PATH=${INSTALL_PATH}:/usr/local/bin:/usr/bin:/bin"
ExecStart="${SCRIPT_DIR}/backup.sh" --forget --tag scheduled
Nice=10
IOSchedulingClass=idle
EOF

  cat >"$UNIT_DIR/zuruck-backup.timer" <<EOF
[Unit]
Description=Zuruck backup timer (${CLIENT_NAME})

[Timer]
OnCalendar=*-*-* 00/4:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  # Without lingering, user units stop when the user's last session ends.
  if [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo no)" != "yes" ]]; then
    if loginctl enable-linger "$(id -un)" 2>/dev/null; then
      info "Enabled lingering for $(id -un) (timer runs without a login session)."
    else
      warn "Could not enable lingering. Owner: sudo loginctl enable-linger $(id -un)"
      warn "Until then the timer only runs while $(id -un) has a session."
    fi
  fi

  if systemctl --user daemon-reload 2>/dev/null && systemctl --user enable --now zuruck-backup.timer; then
    info "Systemd user timer enabled. Backups will run every 4 hours."
    info "Check status: systemctl --user list-timers zuruck-backup.timer"
    info "Run manually: systemctl --user start zuruck-backup.service"
    info "Logs:         journalctl --user -u zuruck-backup.service"
  else
    warn "Could not reach the systemd user manager (no user session bus?)."
    warn "Units are written; enable them later with: systemctl --user enable --now zuruck-backup.timer"
  fi
elif ! $USER_MODE && [[ "$(uname)" == "Linux" ]] && command -v systemctl &>/dev/null; then
  if [[ ${#BACKUP_PATHS[@]} -eq 0 ]]; then
    BACKUP_PATHS=("/data")
  fi

  # Build a properly-quoted argv string for ExecStart= (paths can contain
  # spaces). systemd parses ExecStart with shell-like quoting rules.
  printf -v BACKUP_PATHS_QUOTED ' "%s"' "${BACKUP_PATHS[@]}"

  info "Creating systemd service and timer..."
  cat <<EOF | sudo tee /etc/systemd/system/restic-backup.service >/dev/null
[Unit]
Description=Restic Backup for ${CLIENT_NAME}
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/env
ExecStartPre=${RESTIC_BIN} backup${BACKUP_PATHS_QUOTED} --tag auto
ExecStart=${RESTIC_BIN} forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 2 --prune
EOF
  if [[ -n "$INGEST_URL" ]]; then
    # report.sh re-reads /etc/restic/env itself. $$ escapes systemd's own
    # variable expansion so the shell sees $SERVICE_RESULT.
    printf 'ExecStartPost=-%s/report.sh --exit-code 0\nExecStopPost=-/bin/sh -c '\''[ "$$SERVICE_RESULT" = success ] || "%s/report.sh" --exit-code 1'\''\n' \
      "$SCRIPT_DIR" "$SCRIPT_DIR" | sudo tee -a /etc/systemd/system/restic-backup.service >/dev/null
  fi

  cat <<EOF | sudo tee /etc/systemd/system/restic-backup.timer >/dev/null
[Unit]
Description=Restic Backup Timer for ${CLIENT_NAME}

[Timer]
OnCalendar=*-*-* 00/4:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable restic-backup.timer
  sudo systemctl start restic-backup.timer
  info "Systemd timer enabled. Backups will run every 4 hours."
  info "Check status: systemctl status restic-backup.timer"
  info "Run manually: systemctl start restic-backup.service"
fi

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
info "═══════════════════════════════════════════════════════════════"
info "  Zuruck Restic Backup Client Setup Complete!"
info "═══════════════════════════════════════════════════════════════"
info ""
info "  Client name:    ${CLIENT_NAME}"
info "  Mode:           $($USER_MODE && echo "user ($(id -un))" || echo system)"
info "  S3 bucket:      ${BUCKET_NAME}"
info "  Region:         ${REGION}"
info "  Repository:     s3:s3.${REGION}.amazonaws.com/${BUCKET_NAME}/${CLIENT_NAME}"
info "  Password file:  ${PASSWORD_FILE}"
info "  Env file:       ${ENV_FILE}"
[[ -n "$INGEST_URL" ]] && info "  Reporting to:   ${INGEST_URL}"
info ""
info "  Next steps:"
info "  1. Have the administrator initialize the repository (see above)"
if $USER_MODE; then
  info "  2. Test backup: ${SCRIPT_DIR}/backup.sh --tag first"
else
  info "  2. Test backup: source ${ENV_FILE} && restic backup /path/to/data"
fi
info "  3. Verify in CloudWatch: https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=zuruck-backup-health"
info ""
