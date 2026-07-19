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

> **Important**: Run `forget` with `--prune` so restic repacks and drops
> unreferenced data. Note that on this versioned bucket `--prune` does not
> immediately free *S3* space — see [Object Lock](#object-lock) below for why
> pruned data lingers as noncurrent versions until the lifecycle rule expires
> it (~90 days).

## Object Lock

Object Lock is **enabled by default** (30-day Governance retention) — a no-flag
`cdk deploy` turns it on. Raise it with `-c objectLockRetentionDays=60`, or
disable it entirely with `-c objectLockRetentionDays=0`. **It must be set at
bucket creation** — Object Lock cannot be toggled on or off later without a
manual bucket recreation, so decide before the first deploy.

### Why

Versioning + 90-day noncurrent retention is recoverable but *not immutable*.
A compromised client credential or an insider with `cdk deploy` could wait
out the noncurrent window or shorten the retention and then wipe everything.
Object Lock breaks both paths — within the lock window, even an account-admin
cannot delete a current or noncurrent object version without the
`s3:BypassGovernanceRetention` permission, which the CDK stack does not
grant to anyone.

### Trade-off: `prune` succeeds, but space is not reclaimed for ~90 days

This is a common misconception worth stating precisely. On this **versioned**
bucket, the client credential is granted `s3:DeleteObject` but **not**
`s3:DeleteObjectVersion` (intentional — see the IAM construct). When
`restic prune` deletes an obsolete pack file, `DeleteObject` (with no version
id) writes a **delete marker** and leaves the underlying version in place:

- The call **succeeds** — it does *not* return `403`, even with Object Lock
  active, because the locked version is never actually removed. restic sees
  the object as gone and considers the prune complete.
- The real data survives as a **noncurrent version** and is only removed when
  the noncurrent-version-expiration lifecycle rule fires (90 days). Object
  Lock (30 days by default) simply guarantees that early-expiry can't happen
  inside the lock window; since the lock is shorter than the noncurrent
  window, the two compose cleanly and lifecycle reclaims the space once both
  have elapsed.

**Operational consequence — plan for it:** actual S3 storage is meaningfully
larger than what `restic stats` reports, because every pruned pack lingers as
a noncurrent version for up to the 90-day retention window. This is the
deliberate price of surviving a client compromise. Budget storage for the
full noncurrent-retention window, not just the live snapshot size. Lowering
`noncurrentVersionRetentionDays` reduces cost but shortens your
recover-from-compromise window; don't set it below your incident-detection
time.

A reasonable schedule is `forget` daily and `prune` weekly/monthly — but note
that `prune`'s frequency changes *when* delete markers are written, not *when*
storage is freed, which is governed entirely by the lifecycle rule above.

### Effect on Glacier transitions

Object Lock and Glacier lifecycle transitions compose normally — locked
objects still transition into Glacier and Deep Archive on schedule. The
lock travels with the object across storage classes.

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

### Additional Lifecycle Rules

| Rule | Default | Description |
|---|---|---|
| **Noncurrent version expiration** | 90 days | Deletes previous object versions 90 days after they become non-current. Protects against accidental `forget` data loss for ~3 months while limiting storage cost from version proliferation. |
| **Abort incomplete multipart uploads** | 7 days | Cleans up multipart uploads that were never completed (e.g., from a crashed restic process), preventing orphaned storage charges. |

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

Replace `RESTIC_BIN` below with the absolute path from `command -v restic`
(usually `/usr/bin/restic` on Debian/Ubuntu, `/usr/local/bin/restic` for
manual installs). systemd does not expand shell substitutions in unit files.

```ini
# /etc/systemd/system/restic-backup.service
[Unit]
Description=Restic Backup
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/env
ExecStart=RESTIC_BIN backup /data --tag auto
ExecStart=RESTIC_BIN forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 2 --prune

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

All metrics are in the `Zuruck/Backup` namespace, dimensioned by `Client`.

| Metric | Description |
|---|---|
| `BackupFreshness` | 1 = fresh, 0 = stale (vs. the client's `freshnessThresholdHours`) |
| `BackupsExist` | 1 if any objects exist under the prefix, 0 otherwise |
| `HoursSinceLastBackup` | Hours since the most recent object write (only published when `BackupsExist=1`) |
| `ObjectCount` | Number of objects under the client prefix |
| `SSMParameterAccessible` | 1 = master-password parameter decryptable by the checker, 0 = error |

### CloudWatch Alarms

| Alarm | Trigger | Action |
|---|---|---|
| `zuruck-stale-backup-{client}` | `BackupFreshness < 1` for one 1h period, OR the freshness checker is silent (missing data) | SNS → email |
| `zuruck-freshness-checker-errors` | Lambda errors ≥ 1 in any 1h window — distinguishes "stale data" from "monitoring is broken" | SNS → email |
| `zuruck-bucket-size-anomaly` | Sum of `BucketSizeBytes` across `StandardStorage`, `GlacierStorage`, and `DeepArchiveStorage` > 100 GiB | SNS → email |

### Dashboard

The `zuruck-backup-health` CloudWatch dashboard shows:
- Per-client `BackupFreshness` and `HoursSinceLastBackup` graphs
- Per-client `SSMParameterAccessible` status
- Freshness checker Lambda errors
- Bucket size by storage class (Standard / Glacier / Deep Archive)

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

Access keys are stored in Secrets Manager (`zuruck/clients/{client}/access-key`),
not in CloudFormation outputs. See the runbook's "Rotate IAM Access Keys"
procedure for the full sequence: `aws iam create-access-key`, then
`aws secretsmanager put-secret-value`, update the client env, delete the old
IAM key.

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