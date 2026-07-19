#!/usr/bin/env bash
#
# Zuruck — deploy helper
#
# Deploys the ZuruckStack into us-west-2 using the "zuruck" AWS profile.
# Any extra args are passed straight through to `cdk deploy`, so you can add
# context flags ad hoc, e.g.:
#
#   ./scripts/deploy.sh -c alertEmails=you@example.com
#   ./scripts/deploy.sh -c objectLockRetentionDays=0        # disable Object Lock
#   ./scripts/deploy.sh --hotswap                           # fast dev iteration
#
set -euo pipefail

PROFILE="${AWS_PROFILE:-zuruck}"
REGION="${AWS_REGION:-us-west-2}"

# Run from the repo root regardless of where the script is invoked from.
cd "$(dirname "$0")/.."

echo "==> Profile: ${PROFILE}   Region: ${REGION}"

# Fail early with a clear message if the profile's creds are missing/expired,
# rather than deep inside a CloudFormation call.
if ! aws sts get-caller-identity --profile "${PROFILE}" --region "${REGION}" >/tmp/zuruck-whoami.json 2>/tmp/zuruck-whoami.err; then
  echo "ERROR: could not authenticate with AWS profile '${PROFILE}'." >&2
  echo "       Configure it with: aws configure --profile ${PROFILE}" >&2
  echo "       (or 'aws sso login --profile ${PROFILE}' if it's an SSO profile)" >&2
  sed 's/^/       /' /tmp/zuruck-whoami.err >&2 || true
  exit 1
fi

ACCOUNT=$(python3 -c 'import json,sys;print(json.load(open("/tmp/zuruck-whoami.json"))["Account"])' 2>/dev/null \
  || aws sts get-caller-identity --profile "${PROFILE}" --region "${REGION}" --query Account --output text)
echo "==> Authenticated to account ${ACCOUNT}"

# CDK reads credentials from the standard AWS env/profile chain. Setting these
# also pins the account/region the app resolves at synth time.
export AWS_PROFILE="${PROFILE}"
export AWS_REGION="${REGION}"
export CDK_DEFAULT_ACCOUNT="${ACCOUNT}"
export CDK_DEFAULT_REGION="${REGION}"

echo "==> npx cdk deploy -c region=${REGION} $*"
npx cdk deploy \
  --profile "${PROFILE}" \
  -c region="${REGION}" \
  "$@"
