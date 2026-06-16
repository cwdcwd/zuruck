# Operational Runbook

## Overview

This runbook covers common operational procedures for the Zuruck restic S3 backup system.

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

**Response**:
1. Verify the KMS key is not disabled or scheduled for deletion:

```bash
aws kms describe-key --key-id <kms-key-id>
```

2. Verify the Lambda execution role has `ssm:GetParameter` and `kms:Decrypt` permissions
3. Check CloudWatch Logs for the Lambda function for detailed error messages

## Key Rotation

### Rotate IAM Access Keys

```bash
# Create new key
aws iam create-access-key --user-name restic-alpha

# Update the client's /etc/restic/env with new credentials

# Delete old key
aws iam delete-access-key --user-name restic-alpha --access-key-id AKIA...
```

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