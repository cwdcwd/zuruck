# Operational Runbook

## Overview

This runbook covers common operational procedures for the Zuruck restic S3 backup system.

## Initial Deployment Checklist

For a new account, deploy with both hardening flags enabled:

```bash
npx cdk deploy \
  -c alertEmails=ops@example.com,oncall@example.com \
  -c objectLockRetentionDays=30 \
  -c kmsAdminRoleArns=arn:aws:iam::<account>:role/<your-admin-role>
```

- **`objectLockRetentionDays=30`** enables S3 Object Lock (Governance, 30
  days default per object). Must be set at bucket creation; existing buckets
  need a manual recreation to gain Object Lock. See
  [Backup Strategy → Object Lock](./backup-strategy.md#object-lock).
- **`kmsAdminRoleArns=…`** restricts who can `ScheduleKeyDeletion`,
  `DisableKey`, or `PutKeyPolicy` on the backup CMK. When unset, the key
  policy falls back to `AccountRootPrincipal`, which means any IAM admin in
  the account can permanently brick every backup. For shared accounts, this
  is the highest-leverage hardening flag.
- The KMS key has the maximum **30-day pending-deletion window**, so an
  accidental `ScheduleKeyDeletion` is recoverable via `kms:CancelKeyDeletion`
  for a month before the key is permanently gone.

## Adding a New Client

1. Edit `lib/config/clients.ts` and add a new entry:

```typescript
{
  name: 'charlie',
  description: 'Charlie database server',
  freshnessThresholdHours: 12,
}
```

2. Deploy the stack:

```bash
npx cdk deploy
```

3. Retrieve the new client's access key from Secrets Manager. The
   `AccessKeyId` is in the secret's description; the `SecretAccessKey` is
   the secret's value. We never put the secret access key into a CFN
   output — outputs end up in any caller of `cloudformation:DescribeStacks`.

```bash
# AccessKeyId — embedded in the description (not sensitive on its own)
aws secretsmanager describe-secret \
  --secret-id zuruck/clients/charlie/access-key \
  --query Description --output text

# SecretAccessKey — the secret value
aws secretsmanager get-secret-value \
  --secret-id zuruck/clients/charlie/access-key \
  --query SecretString --output text
```

4. Retrieve the master password from SSM:

```bash
aws ssm get-parameter \
  --name "/zuruck/restic/charlie/master-password" \
  --with-decryption \
  --region us-west-2 \
  --query 'Parameter.Value' \
  --output text
```

5. Initialize the restic repository and add the client key (see [Client Setup Guide](./client-setup-guide.md))

6. Distribute the client password and access keys to the client machine

> **Note on the `Client` tag.** Every `restic-*` IAM user is tagged
> `Client=<name>`. The bucket policy (see [backup-bucket.ts]) denies any
> object operation by a `restic-*` principal to any path that doesn't
> match `${aws:PrincipalTag/Client}/*`. If you add the user to a different
> tag scheme or strip the `Client` tag, you'll lock the user out of the
> bucket entirely — that's the safe failure mode. To grant access to a
> different prefix, change the tag, don't widen the policy.

## Removing a Client

1. Remove the entry from `lib/config/clients.ts`
2. Deploy: `npx cdk deploy`
3. **Important**: The IAM user, the access-key Secrets Manager secret, and
   the freshness alarm are deleted. The S3 data and the SSM master-password
   parameter are **retained** by design — losing the master password
   strands every archived backup.
4. Optionally delete the client's S3 prefix:

```bash
aws s3 rm s3://zuruck-backup-<account-id>-<region>/charlie/ --recursive
```

5. Optionally delete the SSM master-password parameter — only after you have
   confirmed there is nothing recoverable from the prefix above:

```bash
aws ssm delete-parameter --name "/zuruck/restic/charlie/master-password"
```

## Emergency Restore

### Restore to a New Machine

1. Create a new IAM user or use the master password approach
2. Retrieve the master password from SSM (see "Adding a New Client")
3. Install restic on the new machine
4. Configure environment (see [Client Setup Guide](./client-setup-guide.md))
5. If data is in Glacier, initiate restore first:

```bash
# Bulk restore all objects under a prefix
for key in $(aws s3api list-objects-v2 \
  --bucket zuruck-backup-<account-id>-<region> \
  --prefix "alpha/" \
  --query 'Contents[].Key' \
  --output text); do
  aws s3api restore-object \
    --bucket zuruck-backup-<account-id>-<region> \
    --key "$key" \
    --restore-request '{"Days":7,"GlacierJobParameters":{"Tier":"Standard"}}'
done
```

6. Restore:

```bash
source /etc/restic/env
restic restore latest --target /data
```

### Restore Specific Files

```bash
# List available snapshots
restic snapshots

# Browse a specific snapshot
restic ls <snapshot-id>

# Restore specific paths.
# `--include` is restic ≥ 0.16; on older versions use `--include-pattern`
# or pass the path directly (no flag) to restrict the restore.
restic restore <snapshot-id> --target /data --include /path/to/file
```

## Monitoring Response

### Stale Backup Alarm

**Trigger**: No backup activity for a client in the configured threshold (default: 24 hours)

**Response**:
1. Check the CloudWatch dashboard for the affected client
2. SSH into the client machine and check:
   - Is the restic timer running? `systemctl status restic-backup.timer`
   - Are there recent logs? `journalctl -u restic-backup.service -n 50`
   - Can the client reach S3? `aws s3 ls s3://zuruck-backup-<account-id>-<region>/<client>/`
3. Common causes:
   - Network connectivity issues
   - Expired IAM access keys
   - Disk full on client (restic can't create temp files)
   - Restic process hung or crashed

### Bucket Size Anomaly

**Trigger**: Total bucket size (Standard + Glacier + Deep Archive, summed via
CloudWatch math) exceeds 100 GB

**Response**:
1. Check which client is consuming the most space:

```bash
aws s3api list-objects-v2 \
  --bucket zuruck-backup-<account-id>-<region> \
  --query 'Contents[].Size' \
  --prefix "alpha/" \
  --output text | awk '{sum+=$1} END {print sum/1024/1024/1024 " GB"}'
```

2. Run `restic forget --prune` on the client to clean up old snapshots
3. Consider adjusting the retention policy if the growth is expected

### SSM Parameter Inaccessible

**Trigger**: Lambda freshness checker reports `SSMParameterAccessible = 0`

The freshness checker calls `GetParameter` with `WithDecryption: false` —
existence-only check, no KMS involved. So a 0 means the parameter doesn't
exist (deleted, renamed, never deployed) or the Lambda's `ssm:GetParameter`
permission was revoked.

**Response**:
1. Verify the parameter still exists:

```bash
aws ssm get-parameter --name "/zuruck/restic/<client>/master-password"
```

2. If the parameter is missing, restore from the SSM parameter history:

```bash
aws ssm get-parameter-history --name "/zuruck/restic/<client>/master-password"
```

3. Verify the Lambda execution role still has `ssm:GetParameter` on
   `arn:aws:ssm:*:*:parameter/zuruck/restic/*`.
4. Check CloudWatch Logs for the Lambda function (sanitized log lines —
   the cleartext password is never logged or returned).

### Freshness Checker Lambda Errors

**Trigger**: `zuruck-freshness-checker-errors` alarm — Lambda invocation errors ≥ 1 in any 1-hour window

This alarm distinguishes "stale backup data" from "the monitoring system itself is broken."

**Response**:
1. Check CloudWatch Logs for the Lambda function (`/aws/lambda/zuruck-freshness-checker`):
   ```bash
   aws logs tail /aws/lambda/zuruck-freshness-checker --since 1h
   ```
2. Common causes:
   - Lambda timeout (the checker has a 30-second margin guard — check if the
     client list or S3 object count has grown beyond what a single invocation
     can process)
   - SDK throttling (the checker retries up to 3 times with standard backoff)
   - Permission changes to the Lambda execution role
3. If the error is transient, the next scheduled run (1 hour) should self-heal
4. If persistent, check the Lambda configuration and redeploy if necessary

### Bucket Configuration Changed

**Trigger**: `zuruck-bucket-config-changes` EventBridge rule — fires when
CloudTrail records `DeleteBucket*`, `PutBucketPolicy`, `PutBucketAcl`,
`PutBucketVersioning`, `PutBucketPublicAccessBlock`, `DeleteBucketEncryption`,
or `PutObjectLockConfiguration` for the backup bucket.

This is a **paging event in steady state** — none of these calls should
ever happen except via `cdk deploy`.

**Response**:
1. Identify the caller:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=PutBucketPolicy \
  --max-results 5
```

2. If the change wasn't authorized, immediately:
   - Revoke the caller's IAM credentials
   - Restore the previous bucket policy from CloudTrail history
   - Verify versioning is still enabled and Object Lock retention is intact
3. If the change was authorized (e.g., a planned `cdk deploy`), log the
   change in your audit trail and silence the alarm.

## Key Rotation

> **Cadence**: rotate IAM access keys every 90 days (tagged
> `RotationCadenceDays=90` on each `zuruck/clients/*/access-key` secret).
> Set a calendar reminder, or wire an AWS Config rule
> `iam-user-unused-credentials-check` with `maxCredentialUsageAge: 90`.
> (Security-review S10.)

### Rotate IAM Access Keys

The CDK-managed access key is replaced on the next deploy if you delete it
out of band — but to rotate cleanly without a redeploy, do it in IAM and
update the Secrets Manager copy by hand:

```bash
CLIENT=alpha

# 1. Create the new key
aws iam create-access-key --user-name restic-${CLIENT}
# Note the AccessKeyId / SecretAccessKey from the output.

# 2. Update Secrets Manager — value is the SecretAccessKey, AccessKeyId
#    lives in the secret's Description.
aws secretsmanager put-secret-value \
  --secret-id zuruck/clients/${CLIENT}/access-key \
  --secret-string "<new-secret-access-key>"
aws secretsmanager update-secret \
  --secret-id zuruck/clients/${CLIENT}/access-key \
  --description "IAM secret access key for restic client '${CLIENT}'. AccessKeyId=<new-id>. Rotate via the runbook."

# 3. Update the client's /etc/restic/env with the new credentials and
#    confirm a backup runs cleanly.

# 4. Delete the old key from IAM.
aws iam delete-access-key --user-name restic-${CLIENT} --access-key-id AKIA...
```

> Note: the Secrets Manager secret is the canonical source of truth for the
> access key — never put it in a CloudFormation output.

### Rotate Restic Client Password

On the client machine:

```bash
source /etc/restic/env
restic key add    # Enter new password
restic key list   # Note the old key ID
restic key remove <old-key-id>  # Remove old key
# Update /etc/restic/password with new password
```

### Rotate Master Password

1. Retrieve current master password from SSM
2. On any machine with repo access:

```bash
export RESTIC_PASSWORD="<current-master-password>"
restic key add    # Enter new master password
restic key remove <old-master-key-id>
```

3. Update SSM with the new master password:

```bash
aws ssm put-parameter \
  --name "/zuruck/restic/<client>/master-password" \
  --value "<new-master-password>" \
  --type SecureString \
  --key-id <kms-key-id> \
  --overwrite
```

> **Note**: SSM Parameter Store has no native rotation hook. If your
> compliance posture requires automatic master-password rotation, migrate
> the parameter to Secrets Manager (which has native rotation Lambdas)
> and update [backup-secrets.ts](../lib/constructs/backup-secrets.ts) and
> the client IAM policy accordingly. The cost delta is ~$0.40/secret/month.
> (Security-review S11.)

## Alerting Channels

Email is the only subscription wired up by default. For a backup system,
that's a single point of failure (mailbox full, employee turnover, holiday).
Add at least one of:

- **PagerDuty**: subscribe their HTTPS endpoint to the SNS topic
- **Slack**: subscribe a Lambda that posts to a Slack webhook
- **SMS**: SNS supports SMS subscriptions directly (region-dependent)

The SNS topic refuses non-TLS subscriptions and publishes by policy, so
subscriptions added later inherit the same in-transit guarantee.
(Security-review S15.)

## Cost Management

### Estimated Monthly Costs (per client)

| Resource | Cost |
|---|---|
| S3 Standard (0-89 days) | ~$0.023/GB |
| Glacier Flexible Retrieval (90-364 days) | ~$0.004/GB |
| Glacier Deep Archive (365+ days) | ~$0.00099/GB |
| SSM Parameter (SecureString) | ~$0.05/parameter |
| KMS Key | ~$1.00/key + $0.03/10K requests |
| CloudWatch Metrics | ~$0.30/metric/month |
| Lambda | Free tier covers most usage |

### Cost Optimization Tips

- Run `restic forget --prune` regularly to remove old snapshots
- Monitor Glacier retrieval costs (only restore when needed)
- Consider increasing `freshnessThresholdHours` for less critical clients to reduce Lambda invocations