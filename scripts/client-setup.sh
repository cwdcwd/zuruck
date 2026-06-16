#!/usr/bin/env bash
#
# Zuruck Restic Backup - Client Setup Script
#
# This script helps configure a client machine for restic S3 backups.
# It should be run on the client machine after the CDK stack has been deployed.
#
# Usage:
#   sudo ./client-setup.sh --client-name alpha --bucket zuruck-backup-123456789012-us-west-2 \
#     --access-key-id AKIA... --secret-access-key abc123... --region us-west-2
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

# Defaults
CLIENT_NAME=""
BUCKET_NAME=""
ACCESS_KEY_ID=""
SECRET_ACCESS_KEY=""
REGION="us-west-2"
BACKUP_PATHS=()
INSTALL_RESTIC=false

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Required:
  --client-name NAME         Client name (e.g., alpha, bravo)
  --bucket BUCKET            S3 bucket name (from CDK output)
  --access-key-id KEY        AWS Access Key ID for the client IAM user

Secret access key (provide via ONE of these — never as a CLI arg):
  --secret-access-key KEY    AWS Secret Access Key (use only in CI; visible in ps)
  SECRET_ACCESS_KEY env var  Preferred: export SECRET_ACCESS_KEY=... before running
  Interactive prompt          If neither flag nor env var is set, you'll be prompted

Optional:
  --region REGION            AWS region (default: us-west-2)
  --backup-path PATH         Path to back up (can be specified multiple times)
  --install-restic           Install restic if not found
  -h, --help                 Show this help message

Example:
  export SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
  $0 --client-name alpha \
     --bucket zuruck-backup-123456789012-us-west-2 \
     --access-key-id AKIAIOSFODNN7EXAMPLE \
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
    --secret-access-key) SECRET_ACCESS_KEY="$2"; shift 2 ;;
    --region)           REGION="$2"; shift 2 ;;
    --backup-path)      BACKUP_PATHS+=("$2"); shift 2 ;;
    --install-restic)   INSTALL_RESTIC=true; shift ;;
    -h|--help)          usage ;;
    *)                  error "Unknown option: $1" ;;
  esac
done

# Validate required arguments
[[ -z "$CLIENT_NAME" ]] && error "Missing required argument: --client-name"
[[ -z "$BUCKET_NAME" ]] && error "Missing required argument: --bucket"
[[ -z "$ACCESS_KEY_ID" ]] && error "Missing required argument: --access-key-id"

# Resolve secret access key: prefer env var > CLI arg > interactive prompt.
# SECURITY: --secret-access-key on the command line is visible in ps(1) and
# shell history. Prefer `export SECRET_ACCESS_KEY=...` before running this
# script, or omit it entirely to be prompted securely.
if [[ -z "$SECRET_ACCESS_KEY" ]]; then
  if [[ -n "${SECRET_ACCESS_KEY_ENV:-}" ]]; then
    SECRET_ACCESS_KEY="$SECRET_ACCESS_KEY_ENV"
  else
    warn "--secret-access-key not provided and SECRET_ACCESS_KEY env var not set."
    warn "You will be prompted for the secret access key (input hidden)."
    read -rs SECRET_ACCESS_KEY </dev/tty
    [[ -z "$SECRET_ACCESS_KEY" ]] && error "Secret access key is required."
  fi
fi

info "Setting up restic backup client: ${CLIENT_NAME}"

# ── Install restic ──────────────────────────────────────────────────────
if ! command -v restic &>/dev/null; then
  if [[ "$INSTALL_RESTIC" == true ]]; then
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
  else
    error "restic not found. Install it with --install-restic or manually: https://restic.readthedocs.io/en/stable/020_installation.html"
  fi
fi

RESTIC_BIN=$(command -v restic)
RESTIC_VERSION=$(restic version 2>&1 | head -1)
info "Using restic: ${RESTIC_VERSION} (${RESTIC_BIN})"

# ── Create configuration directory ──────────────────────────────────────
info "Creating /etc/restic directory..."
mkdir -p /etc/restic

# ── Generate client password ────────────────────────────────────────────
info "Generating client password..."
CLIENT_PASSWORD=$(openssl rand -base64 32)
echo "${CLIENT_PASSWORD}" > /etc/restic/password
chmod 600 /etc/restic/password
chown root:root /etc/restic/password 2>/dev/null || chown root:wheel /etc/restic/password
info "Client password saved to /etc/restic/password"

# ── Create environment file ─────────────────────────────────────────────
info "Creating /etc/restic/env..."
cat > /etc/restic/env <<EOF
export AWS_ACCESS_KEY_ID="${ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${SECRET_ACCESS_KEY}"
export RESTIC_REPOSITORY="s3:s3.${REGION}.amazonaws.com/${BUCKET_NAME}/${CLIENT_NAME}"
export RESTIC_PASSWORD_FILE="/etc/restic/password"
EOF
chmod 600 /etc/restic/env
chown root:root /etc/restic/env 2>/dev/null || chown root:wheel /etc/restic/env
info "Environment file saved to /etc/restic/env"

# ── Test connectivity ──────────────────────────────────────────────────
# The IAM policy gates s3:ListBucket on a prefix matching the client's own
# folder, so list with that prefix — listing the bucket root will always be
# AccessDenied for a healthy install.
if command -v aws &>/dev/null; then
  info "Testing S3 connectivity (aws CLI found)..."
  source /etc/restic/env
  if aws s3 ls "s3://${BUCKET_NAME}/${CLIENT_NAME}/" --region "${REGION}" &>/dev/null; then
    info "S3 connectivity OK"
  else
    warn "S3 connectivity test failed. Check credentials and bucket name."
    warn "Manual test: source /etc/restic/env && aws s3 ls s3://${BUCKET_NAME}/${CLIENT_NAME}/"
  fi
else
  warn "aws CLI not found — skipping S3 connectivity test."
  warn "Restic does not require the AWS CLI, but the test does."
  warn "Install the AWS CLI or test manually: source /etc/restic/env && restic snapshots"
fi

# ── Initialize repository (if not already initialized) ──────────────────
info "Checking if restic repository exists..."
if source /etc/restic/env && restic snapshots 2>/dev/null; then
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
  warn "     restic key add  # Enter the client password from /etc/restic/password"
  warn ""
  warn "  4. Remove the master key (optional, for security):"
  warn "     restic key list"
  warn "     restic key remove <master-key-id>"
fi

# ── Create systemd timer ────────────────────────────────────────────────
if [[ "$(uname)" == "Linux" ]] && command -v systemctl &>/dev/null; then
  if [[ ${#BACKUP_PATHS[@]} -eq 0 ]]; then
    BACKUP_PATHS=("/data")
  fi

  # Build a properly-quoted argv string for ExecStart= (paths can contain
  # spaces). systemd parses ExecStart with shell-like quoting rules.
  printf -v BACKUP_PATHS_QUOTED ' "%s"' "${BACKUP_PATHS[@]}"

  info "Creating systemd service and timer..."
  cat > /etc/systemd/system/restic-backup.service <<EOF
[Unit]
Description=Restic Backup for ${CLIENT_NAME}
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/env
ExecStartPre=${RESTIC_BIN} backup${BACKUP_PATHS_QUOTED} --tag auto
ExecStart=${RESTIC_BIN} forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 2 --prune
EOF

  cat > /etc/systemd/system/restic-backup.timer <<EOF
[Unit]
Description=Restic Backup Timer for ${CLIENT_NAME}

[Timer]
OnCalendar=*-*-* 00/4:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable restic-backup.timer
  systemctl start restic-backup.timer
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
info "  S3 bucket:      ${BUCKET_NAME}"
info "  Region:         ${REGION}"
info "  Repository:     s3:s3.${REGION}.amazonaws.com/${BUCKET_NAME}/${CLIENT_NAME}"
info "  Password file:  /etc/restic/password"
info "  Env file:       /etc/restic/env"
info ""
info "  Next steps:"
info "  1. Have the administrator initialize the repository (see above)"
info "  2. Test backup: source /etc/restic/env && restic backup /path/to/data"
info "  3. Verify in CloudWatch: https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=zuruck-backup-health"
info ""