#!/usr/bin/env bash
#
# Zuruck — deploy helper
#
# Deploys the ZuruckStack into us-west-2 using the "zuruck" profile, which is
# authenticated with `aws login` (browser console sign-in, short-lived creds).
# Extra args pass straight through to `cdk deploy`, e.g.:
#
#   ./scripts/deploy.sh -c alertEmails=you@example.com
#   ./scripts/deploy.sh -c objectLockRetentionDays=0        # disable Object Lock
#   ./scripts/deploy.sh --hotswap                           # fast dev iteration
#
# Auth model: `aws login` (AWS CLI >= 2.32) signs you in with a *console*
# identity (root / console IAM user / federation) and manages temporary
# credentials for up to 12h. This script triggers login automatically when
# there's no valid session, then exports the resulting creds into the
# environment so CDK's bundled SDK uses them regardless of whether it
# understands the new login-session credential type.
#
# STS note: this network's local DNS sinkholes `sts.us-west-2.amazonaws.com`,
# so we route STS to its global endpoint (AWS_STS_REGIONAL_ENDPOINTS=legacy +
# explicit --endpoint-url for CLI checks). The real fix is your DNS server.
#
set -euo pipefail

PROFILE="${ZURUCK_PROFILE:-zuruck}"
REGION="${ZURUCK_REGION:-us-west-2}"
STS_GLOBAL="https://sts.amazonaws.com"
MIN_CLI="2.32.0"   # `aws login` requires >= 2.32.0

export AWS_STS_REGIONAL_ENDPOINTS=legacy
cd "$(dirname "$0")/.."

# ── AWS CLI version guard (aws login) ─────────────────────────────────────
VER=$(aws --version 2>&1 | sed -n 's#.*aws-cli/\([0-9.]*\).*#\1#p')
if [ -z "${VER:-}" ] || [ "$(printf '%s\n%s\n' "$MIN_CLI" "$VER" | sort -V | head -1)" != "$MIN_CLI" ]; then
  echo "ERROR: AWS CLI ${MIN_CLI}+ is required for 'aws login' (found ${VER:-unknown})." >&2
  echo "       Upgrade (macOS):" >&2
  echo "         curl -fsSL https://awscli.amazonaws.com/AWSCLIV2.pkg -o /tmp/AWSCLIV2.pkg" >&2
  echo "         sudo installer -pkg /tmp/AWSCLIV2.pkg -target /" >&2
  echo "       Then re-run this script." >&2
  exit 1
fi

echo "==> Profile: ${PROFILE}   Region: ${REGION}   CLI: ${VER}   (STS via global endpoint)"

# Global STS is served from us-east-1, so it must be signed for us-east-1.
have_session() {
  aws sts get-caller-identity \
    --profile "${PROFILE}" --region us-east-1 --endpoint-url "${STS_GLOBAL}" >/dev/null 2>&1
}

# ── Ensure a valid session (aws login on demand) ──────────────────────────
if ! have_session; then
  echo "==> No valid session for '${PROFILE}'. Opening browser sign-in (aws login)..."
  echo "    (headless/SSH? cancel and run:  aws login --remote --profile ${PROFILE})"
  aws login --profile "${PROFILE}"
  have_session || { echo "ERROR: still no valid session after 'aws login'." >&2; exit 1; }
fi

ACCOUNT=$(aws sts get-caller-identity \
  --profile "${PROFILE}" --region us-east-1 --endpoint-url "${STS_GLOBAL}" \
  --query Account --output text)
echo "==> Authenticated to account ${ACCOUNT}"

# ── Hand short-lived creds to CDK via the environment ─────────────────────
# Export the profile's current credentials as env vars. This is SDK-agnostic:
# CDK's bundled SDK gets plain AWS_ACCESS_KEY_ID/SECRET/SESSION_TOKEN instead of
# having to resolve the new login-session credential type itself.
CREDS_ENV="$(aws configure export-credentials --profile "${PROFILE}" --format env)" || {
  echo "ERROR: could not export credentials for '${PROFILE}'." >&2; exit 1; }
eval "${CREDS_ENV}"

# Use those env creds directly; drop AWS_PROFILE so nothing re-resolves it.
unset AWS_PROFILE
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"
export CDK_DEFAULT_ACCOUNT="${ACCOUNT}"
export CDK_DEFAULT_REGION="${REGION}"

# ── Bootstrap check ───────────────────────────────────────────────────────
if ! aws ssm get-parameter --name /cdk-bootstrap/hnb659fds/version \
      --region "${REGION}" >/dev/null 2>&1; then
  echo "==> Environment aws://${ACCOUNT}/${REGION} is not bootstrapped — bootstrapping now..."
  npx cdk bootstrap "aws://${ACCOUNT}/${REGION}"
else
  echo "==> Bootstrap present for aws://${ACCOUNT}/${REGION}"
fi

echo "==> npx cdk deploy -c region=${REGION} $*"
npx cdk deploy -c region="${REGION}" "$@"
