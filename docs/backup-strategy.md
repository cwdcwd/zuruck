# Backup Strategy

## Overview

This document describes the backup strategy for the Zuruck restic S3 backup system, including retention policies, cold storage transitions, and operational procedures.

## Retention Policy: Grandfather-Father-Son (GFS)

We use a **GFS rotation** strategy with restic's `forget` command:

| Retention Level | Keep | Description |
|---|---|---|
| **Daily** | 7 | Keep one backup per day for the last 7 days |
| **Weekly** | 4 | Keep one backup per week for the last 4 weeks |
| **Monthly** | 6 | Keep one backup per month for the last 6 months |
| **Yearly** | 2 | Keep one backup per year for the last 2 years |

### Restic Forget Command

Run this on each client machine as a scheduled task (e.g., daily after backup):

```bash
restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --keep-yearly 2 \
  --prune
```

> **Important**: Always run `forget` with `--prune` to actually free space. Without `--prune`, restic only marks snapshots for deletion but doesn't remove the data.

## Cold Storage Transitions

S3 lifecycle rules automatically transition backup data through storage tiers:

```
S3 Standard (0-89 days)
    │
    ▼ Transition after 90 days
Glacier Flexible Retrieval (90-364 days)
    │
    ▼ Transition after 365 days
Glacier Deep Archive (365+ days)
```

| Storage Tier | Retrieval Time | Cost per GB/month | Use Case |
|---|---|---|---|
| S3 Standard | Immediate | ~$0.023 | Recent backups (0-89 days) |
| Glacier Flexible Retrieval | 3-5 hours | ~$0.004 | Warm backups (90-364 days) |
| Glacier Deep Archive | 12-48 hours | ~$0.00099 | Compliance/archive (365+ days) |

### Important Notes on Glacier

- **Retrieval costs**: Restoring from Glacier incurs retrieval fees. Only restore when needed.
- **Minimum storage duration**: Glacier Flexible Retrieval has a 90-day minimum; Deep Archive has a 180-day minimum. Deleting before the minimum incurs early deletion charges.
- **Restic compatibility**: Restic handles Glacier transitions transparently. When you run `restic restore`, restic will need to wait for Glacier retrieval. Use `aws s3 restore-object` to initiate retrieval before running `restic restore` on Glacier-tier data.

### Restoring from Glacier

Before restoring from Glacier or Deep Archive, you must first restore the objects:

```bash
# Initiate a restore request (takes 3-5 hours for Flexible, 12-48h for Deep Archive)
aws s3api restore-object \
  --bucket zuruck-backup-<account-id>-<region> \
  --key "alpha/data/..." \
  --restore-request '{"Days":7,"GlacierJobParameters":{"Tier":"Standard"}}'
```

Or use the bulk restore script:

```bash
# Restore all objects under a client prefix
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

## Backup Schedule

### Recommended Client Schedule

| Client Type | Backup Frequency | Forget Schedule |
|---|---|---|
| Production servers | Every 4 hours | Daily (after midnight backup) |
| Staging servers | Daily (midnight) | Weekly (Sunday) |
| Database servers | Every 2 hours | Daily (after midnight backup) |
| Workstations | Daily (on login) | Weekly (Sunday) |

### Systemd Timer Example

```ini
# /etc/systemd/system/restic-backup.service
[Unit]
Description=Restic Backup
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/env
ExecStart=/usr/local/bin/restic backup /data --tag auto
ExecStart=/usr/local/bin/restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 2 --prune

# /etc/systemd/system/restic-backup.timer
[Unit]
Description=Restic Backup Timer

[Timer]
OnCalendar=*-*-* 00/4:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

Enable with:

```bash
sudo systemctl enable --now restic-backup.timer
```

## Monitoring

### CloudWatch Metrics

| Metric | Namespace | Description |
|---|---|---|
| `BackupFreshness` | `Zuruck/Backup` | 1 = fresh, 0 = stale |
| `HoursSinceLastBackup` | `Zuruck/Backup` | Hours since last object written |
| `ObjectCount` | `Zuruck/Backup` | Number of objects per client prefix |
| `SSMParameterAccessible` | `Zuruck/Backup` | 1 = accessible, 0 = error |

### CloudWatch Alarms

| Alarm | Trigger | Action |
|---|---|---|
| `zuruck-stale-backup-{client}` | No backup in 24h (configurable per client) | SNS → email |
| `zuruck-bucket-size-anomaly` | Bucket > 100 GB | SNS → email |

### Dashboard

The `zuruck-backup-health` CloudWatch dashboard shows:
- Per-client freshness graphs
- Bucket size over time
- SSM parameter accessibility status

## Key Rotation

### Restic Key Rotation

If a client key is compromised:

1. Generate a new client password: `openssl rand -base64 32`
2. On the client machine: `restic key add` (enter the new password)
3. Remove the old key: `restic key list` then `restic key remove <old-key-id>`
4. Update the local password file: `/etc/restic/password`

### KMS Key Rotation

- KMS automatic key rotation is enabled (annual rotation)
- Existing encrypted data remains decryptable with old key versions
- No action required — AWS handles key version management

### IAM Access Key Rotation

1. Create a new access key: `aws iam create-access-key --user-name restic-{client}`
2. Update the client's environment file
3. Delete the old key: `aws iam delete-access-key --user-name restic-{client} --access-key-id AKIA...`

## Disaster Recovery

### Full Client Recovery

1. Retrieve the master password from SSM:
   ```bash
   aws ssm get-parameter \
     --name "/zuruck/restic/{client}/master-password" \
     --with-decryption \
     --region us-west-2
   ```

2. Install restic on the new machine

3. Configure environment:
   ```bash
   export AWS_ACCESS_KEY_ID=<new-access-key>
   export AWS_SECRET_ACCESS_KEY=<new-secret-key>
   export RESTIC_REPOSITORY=s3:s3.us-west-2.amazonaws.com/zuruck-backup-<account-id>-<region>
   export RESTIC_PASSWORD_FILE=/etc/restic/password  # contains master password
   ```

4. If data is in Glacier, initiate restore first (see "Restoring from Glacier" above)

5. Restore:
   ```bash
   restic restore latest --target /data
   ```