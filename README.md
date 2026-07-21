# Zuruck — Restic S3 Backup System

AWS CDK project that provisions an S3-based backup backend for [restic](https://restic.net/) with per-client IAM isolation, KMS encryption, lifecycle-based cold storage, and CloudWatch monitoring.

## Architecture

```mermaid
graph TB
    subgraph AWS["AWS Account (us-west-2)"]
        subgraph Clients["Client IAM Users"]
            CA["Client A<br/>IAM User"]
            CB["Client B<br/>IAM User"]
            CN["Client N<br/>IAM User"]
        end

        subgraph Storage["S3 Bucket: zuruck-backup"]
            PA["alpha/"]
            PB["bravo/"]
            PN["charlie/"]
        end

        KMS["KMS CMK<br/>(auto-rotation)"]

        subgraph Secrets["SSM Parameter Store"]
            SA["/zuruck/restic/alpha/<br/>master-password"]
            SB["/zuruck/restic/bravo/<br/>master-password"]
            SN["/zuruck/restic/charlie/<br/>master-password"]
        end

        subgraph AccessKeys["Secrets Manager"]
            AK1["zuruck/clients/alpha/<br/>access-key"]
            AK2["zuruck/clients/bravo/<br/>access-key"]
            AKN["zuruck/clients/charlie/<br/>access-key"]
        end

        subgraph Monitoring["Monitoring Stack"]
            EB["EventBridge<br/>(1h schedule)"]
            Lambda["Lambda<br/>Freshness Checker"]
            CW["CloudWatch<br/>Alarms"]
            SNS["SNS Topic<br/>backup-alerts"]
            Dash["CloudWatch<br/>Dashboard"]
        end
    end

    CA -->|S3 scoped to alpha/*| PA
    CB -->|S3 scoped to bravo/*| PB
    CN -->|S3 scoped to charlie/*| PN
    CA -->|ssm:GetParameter| SA
    CB -->|ssm:GetParameter| SB
    CN -->|ssm:GetParameter| SN
    KMS -.->|SSE-KMS| Storage
    KMS -.->|SecureString| Secrets
    KMS -.->|Encrypt| AccessKeys
    EB --> Lambda
    Lambda --> CW
    CW --> SNS
    Lambda --> Dash
    Lambda --> Secrets
    Lambda --> Storage
```

## Quick Start

### Prerequisites

- Node.js 18+
- AWS CLI configured with appropriate credentials
- CDK CLI: `npm install -g aws-cdk`

### Deploy

```bash
# Install dependencies
npm install

# Bootstrap CDK (first time only)
npx cdk bootstrap aws://<ACCOUNT_ID>/us-west-2

# Deploy with alert emails
npx cdk deploy -c alertEmails=you@example.com,team@example.com

# Recommended for new deployments — scope the KMS admin principal to a
# named role. (S3 Object Lock is already ON by default; see the flag table.)
npx cdk deploy \
  -c alertEmails=you@example.com \
  -c kmsAdminRoleArns=arn:aws:iam::<account>:role/<your-admin-role>

# Or deploy without alerts
npx cdk deploy
```

> ⚠️ **Object Lock is enabled by default (30-day GOVERNANCE retention).** It is
> irreversible at bucket creation — you cannot turn it off later without
> recreating the bucket. Deploy with `-c objectLockRetentionDays=0` if you
> explicitly do **not** want it. See the flag table and
> [Backup Strategy](docs/backup-strategy.md#object-lock) for the storage-cost
> implications.

#### Deploy-time context flags

| Flag | Default | Description |
|---|---|---|
| `alertEmails` | none | Comma-separated email addresses for the SNS alert topic |
| `region` | `CDK_DEFAULT_REGION` or `us-west-2` | AWS region (warns on drift) |
| `objectLockRetentionDays` | `30` (enabled) | S3 Object Lock default Governance retention, in days. **On by default**; pass `0` to disable. Must be set at bucket creation — it cannot be enabled *or disabled* later without recreating the bucket. Because the bucket is versioned and clients lack `s3:DeleteObjectVersion`, `restic prune` still **succeeds** under Object Lock (it writes delete markers) — but pruned data lingers as noncurrent versions until the ~90-day lifecycle rule expires it, so plan storage accordingly. See [Backup Strategy](docs/backup-strategy.md#object-lock). |
| `kmsAdminRoleArns` | account root | Comma-separated IAM role ARNs allowed to administer the KMS CMK. When set, every other principal — including account-admins — is denied `kms:ScheduleKeyDeletion` and `kms:DisableKey`. `kms:PutKeyPolicy` is also denied to non-admins, **except the account root**, which retains it as break-glass so the key policy can never become permanently unrepairable. |
| `enableAuditTrail` | `true` | Provision a dedicated CloudTrail trail (management write events → a private, retained log bucket) so the bucket-config-change alarm has a live event source. Set `false` if an org-wide trail already covers this account+region. |
| `auditS3DataEvents` | `false` | When the audit trail is enabled, also record S3 object-level (data) events for the backup bucket. Billed per event; useful for forensic queries, not alerting. |

### Add a New Client

1. Edit `lib/config/clients.ts` and add your client:

```typescript
{
  name: 'charlie',
  description: 'Charlie database server',
  freshnessThresholdHours: 12,
}
```

2. Redeploy: `npx cdk deploy`

3. Retrieve the client's access key:

```bash
# AccessKeyId is in the secret's description; SecretAccessKey is the secret value.
aws secretsmanager describe-secret --secret-id zuruck/clients/charlie/access-key
aws secretsmanager get-secret-value --secret-id zuruck/clients/charlie/access-key --query SecretString --output text
```

4. Run the client setup script on the target machine:

```bash
# Preferred: pass the secret via env var (not visible in ps(1) or shell history)
export SECRET_ACCESS_KEY=<secret-access-key>
sudo ./scripts/client-setup.sh \
  --client-name charlie \
  --bucket zuruck-backup-<account-id>-<region> \
  --access-key-id AKIA... \
  --region us-west-2 \
  --install-restic
```

> The script also accepts `--secret-access-key` for CI, or will prompt
> interactively if neither flag nor env var is set.

5. Initialize the restic repository using the master password from SSM

## Project Structure

```
zuruck/
├── bin/zuruck.ts                    # CDK app entry point
├── lib/
│   ├── zuruck-stack.ts              # Main stack (orchestrates constructs)
│   ├── config/clients.ts            # Client definitions
│   ├── constructs/
│   │   ├── backup-bucket.ts         # S3 bucket + lifecycle + encryption
│   │   ├── backup-iam.ts            # IAM users, group, policies per client
│   │   ├── backup-kms.ts            # KMS key for SSE
│   │   ├── backup-secrets.ts        # Custom Resource Lambda for SSM master passwords
│   │   └── backup-monitoring.ts     # Lambda, CloudWatch, SNS, dashboard
│   └── lambda/
│       ├── freshness-checker.ts          # Hourly per-client backup freshness check
│       └── master-password-provisioner.ts # Custom-resource handler that idempotently provisions SSM master passwords at deploy time
├── scripts/                        # Client-side tooling (macOS/Linux)
│   ├── client-setup.sh             # Client onboarding (env, password, repo init)
│   ├── backup.sh                   # restic backup wrapper (paths, excludes, retention)
│   ├── install-schedule.sh         # macOS launchd scheduler installer
│   ├── zuruck-runner.c             # dedicated FDA wrapper the schedule runs through
│   ├── status.sh                   # local status: terminal / JSON / HTML dashboard
│   ├── restore.sh                  # guided recovery (list/browse/dump/restore/mount/stage)
│   └── restic-excludes.txt         # default exclude patterns
├── docs/
│   ├── plans/backup-system-plan.md  # Architecture plan
│   ├── backup-strategy.md           # Retention + cold storage strategy
│   ├── client-setup-guide.md        # Step-by-step client instructions
│   └── runbook.md                   # Operational runbook
└── test/
    └── zuruck.test.ts
```

## Key Features

| Feature | Implementation |
|---|---|
| **Encryption** | SSE-KMS with customer-managed CMK (auto-rotation, max 30-day pending-delete window) |
| **KMS administration** | Optional `kmsAdminRoleArns` context scopes `kms:*` to named roles; `ScheduleKeyDeletion`/`DisableKey`/`PutKeyPolicy` explicitly denied to everyone else |
| **Isolation** | Per-client IAM users with prefix-scoped S3 policies, plus a bucket-policy backstop tied to `${aws:PrincipalTag/Client}` (defense in depth) |
| **Immutability** | Optional S3 Object Lock (Governance, opt-in via `objectLockRetentionDays` context) — a compromised client cannot wipe objects within the lock window |
| **Cold Storage** | S3 Standard → Glacier Flexible Retrieval (90d) → Deep Archive (365d) |
| **Retention** | GFS: 7 daily / 4 weekly / 6 monthly / 2 yearly; noncurrent versions retained 90 days |
| **Master passwords** | SSM Parameter Store (SecureString), generated server-side at deploy time and `RETAIN`ed across `cdk destroy`. Provisioner Lambda has no `kms:Decrypt` and `reservedConcurrentExecutions=1` |
| **Client access keys** | Secrets Manager (`zuruck/clients/{client}/access-key`) — never in CloudFormation outputs; tagged `RotationCadenceDays=90` |
| **Client S3 permissions** | `GetObject`, `PutObject`, `DeleteObject` on `<prefix>/*` only — no `DeleteObjectVersion`, so version history survives credential compromise |
| **Restic keys** | Dual: client password local to each machine, master password in SSM for DR |
| **Monitoring** | Hourly Lambda freshness checker; alarms for stale backups, Lambda errors, bucket-size growth across all storage classes, and bucket-config changes via CloudTrail |
| **Transport security** | `enforceSSL` on the bucket; SNS topic denies non-TLS publish/subscribe |
| **Dashboard** | Per-client freshness, SSM accessibility, Lambda errors, and bucket size by storage class |

## Useful Commands

| Command | Description |
|---|---|
| `npm run build` | Compile TypeScript to JS |
| `npm run watch` | Watch for changes and compile |
| `npm run test` | Run Jest unit tests |
| `npx cdk synth` | Generate CloudFormation template |
| `npx cdk diff` | Compare deployed stack with current state |
| `npx cdk deploy` | Deploy stack to AWS |
| `npx cdk destroy` | Tear down the stack |

### On a client machine

| Command | Description |
|---|---|
| `./scripts/backup.sh --forget` | Run a backup + apply retention/prune |
| `./scripts/install-schedule.sh` | Install the launchd schedule (see [FDA note](docs/client-setup-guide.md#option-c-macos-launchd-use-scriptsinstall-schedulesh)) |
| `./scripts/install-schedule.sh --status` | Is the schedule loaded / when did it last run |
| `./scripts/status.sh` | Local backup health (add `--html --open` for the dashboard) |
| `./scripts/restore.sh list` | List snapshots (then `restore` / `dump` / `browse` — see [runbook](docs/runbook.md#recovery-quickstart)) |

## Documentation

- [Backup Strategy](docs/backup-strategy.md) — Retention policies, cold storage, and restore procedures
- [Client Setup Guide](docs/client-setup-guide.md) — Step-by-step instructions for client machines
- [Operational Runbook](docs/runbook.md) — Adding/removing clients, emergency restore, key rotation
- [Architecture Plan](docs/plans/backup-system-plan.md) — Full design document with decisions
