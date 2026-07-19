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
# Preserve a SECRET_ACCESS_KEY exported into the environment — do NOT blank an
# inherited value, or the documented `export SECRET_ACCESS_KEY=...` workflow
# silently falls through to the interactive prompt. (Review finding #2.)
SECRET_ACCESS_KEY="${SECRET_ACCESS_KEY:-}"
REGION="us-west-2"
BACKUP_PATHS=()
INSTALL_RESTIC=false
RESTIC_VERSION_PIN=""
RESTIC_SHA256=""

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
  --restic-version VERSION   Pin a specific upstream restic version
                             (e.g., 0.17.3). Overrides apt/yum.
  --restic-sha256 SHA256     Required when --restic-version is used. The
                             SHA256 of the upstream tarball — verified
                             before install. See:
                             https://github.com/restic/restic/releases
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
    --restic-version)   RESTIC_VERSION_PIN="$2"; shift 2 ;;
    --restic-sha256)    RESTIC_SHA256="$2"; shift 2 ;;
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

# Resolve secret access key. Precedence: the SECRET_ACCESS_KEY env var (set at
# the top from the inherited environment) or the --secret-access-key flag (which
# overrides it during arg parsing), else an interactive prompt.
# SECURITY: --secret-access-key on the command line is visible in ps(1) and
# shell history. Prefer `export SECRET_ACCESS_KEY=...` before running this
# script, or omit it entirely to be prompted securely.
if [[ -z "$SECRET_ACCESS_KEY" ]]; then
  warn "--secret-access-key not provided and SECRET_ACCESS_KEY env var not set."
  warn "You will be prompted for the secret access key (input hidden)."
  # Restore terminal echo on any exit path: an interrupted `read -rs` can
  # otherwise leave the user with a broken terminal. (Security-review S13.)
  trap 'stty echo 2>/dev/null || true' EXIT INT TERM
  read -rs SECRET_ACCESS_KEY </dev/tty
  trap - EXIT INT TERM
  echo
  [[ -z "$SECRET_ACCESS_KEY" ]] && error "Secret access key is required."
fi

info "Setting up restic backup client: ${CLIENT_NAME}"

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
  chmod +x "$tmp/$bin"
  sudo mv "$tmp/$bin" /usr/local/bin/restic
  trap - RETURN
}

if ! command -v restic &>/dev/null; then
  if [[ "$INSTALL_RESTIC" == true ]]; then
    if [[ -n "$RESTIC_VERSION_PIN" ]]; then
      [[ -z "$RESTIC_SHA256" ]] && error "--restic-version requires --restic-sha256 (look up at https://github.com/restic/restic/releases)"
      info "Installing restic ${RESTIC_VERSION_PIN} (SHA256-pinned)..."
      install_restic_pinned "$RESTIC_VERSION_PIN" "$RESTIC_SHA256"
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

# ── Create configuration directory ──────────────────────────────────────
info "Creating /etc/restic directory..."
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

# ── Generate client password ────────────────────────────────────────────
info "Generating client password..."
CLIENT_PASSWORD=$(openssl rand -base64 32)
echo "${CLIENT_PASSWORD}" | sudo tee /etc/restic/password >/dev/null
sudo chmod 600 /etc/restic/password
if [[ "${RESTIC_OWNER}" == "root" ]]; then
  sudo chown root:root /etc/restic/password 2>/dev/null || sudo chown root:wheel /etc/restic/password
else
  sudo chown "${RESTIC_OWNER}" /etc/restic/password
fi
info "Client password saved to /etc/restic/password"

# ── Create environment file ─────────────────────────────────────────────
info "Creating /etc/restic/env..."
cat <<EOF | sudo tee /etc/restic/env >/dev/null
export AWS_ACCESS_KEY_ID="${ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${SECRET_ACCESS_KEY}"
export RESTIC_REPOSITORY="s3:s3.${REGION}.amazonaws.com/${BUCKET_NAME}/${CLIENT_NAME}"
export RESTIC_PASSWORD_FILE="/etc/restic/password"
EOF
sudo chmod 600 /etc/restic/env
if [[ "${RESTIC_OWNER}" == "root" ]]; then
  sudo chown root:root /etc/restic/env 2>/dev/null || sudo chown root:wheel /etc/restic/env
else
  sudo chown "${RESTIC_OWNER}" /etc/restic/env
fi
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