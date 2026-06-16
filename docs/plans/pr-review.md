# PR Review: Zuruck — Restic S3 Backup System

Reviewed as a senior engineer on a pull request. The architecture is solid (per-client prefix isolation, KMS-CMK SSE, dual restic keys, Lambda freshness checker) and the documentation is unusually thorough. But there are **two correctness bugs that defeat core safety guarantees**, **one secrets-handling regression**, and **several cross-file inconsistencies that will burn the first operator who follows the runbook verbatim**.

File references use `path:line`.

---

## 🔴 Blocking — must fix before merge

### B1. Stale-backup alarm is dead — it cannot fire from data
[lib/constructs/backup-monitoring.ts:137-150](../../lib/constructs/backup-monitoring.ts#L137-L150)

```ts
metric: new cloudwatch.Metric({ ... statistic: 'Maximum', period: 1h }),
threshold: 0,
evaluationPeriods: thresholdHours,
treatMissingData: cloudwatch.TreatMissingData.BREACHING,
comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
```

`BackupFreshness` is published as `0` or `1` every hour. `0 < 0` is **false**, so no real data point can trigger the alarm. The only path to ALARM is `BREACHING` on missing data — i.e., the Lambda has to be silently dead for `thresholdHours` consecutive hours. The whole "no backup in 24h → page someone" promise is broken.

**Fix options (pick one):**
- Switch comparison to `LESS_THAN_OR_EQUAL_TO_THRESHOLD` with threshold `0` (cleanest).
- Or alarm on `HoursSinceLastBackup > thresholdHours` (more direct, doesn't conflate "stale" with "lambda dead").
- Either way, add a separate Lambda error alarm so operators can tell which is failing.

### B2. SSM master passwords are reset on every `cdk deploy`
[lib/constructs/backup-secrets.ts:41-46](../../lib/constructs/backup-secrets.ts#L41-L46)

```ts
const parameter = new ssm.CfnParameter(this, ..., {
  type: 'SecureString',
  value: `CHANGE-ME-${client.name}-restic-master-password`,  // ← committed string
  ...
});
```

Two problems compounded:
1. The "master password" is literally the string `CHANGE-ME-alpha-restic-master-password` after `cdk deploy`. If an operator forgets step 4 ("change the value after deploy"), the only DR credential is a string in git history.
2. **Worse:** every subsequent `cdk deploy` overwrites whatever the operator has rotated to back to the placeholder. There is no `ignoreChanges` and `CfnParameter`'s `value` is mutable. Silent password loss on routine redeploys.

**Fix:** generate the secret server-side (custom resource that calls `ssm:PutParameter` with `--overwrite=false`, or a Lambda-backed CR using `crypto.randomBytes`). At minimum, set `--overwrite=false` semantics via a `CfnIgnoreCondition`/`Aspect` and a giant `WARNING` in README. The current scheme is a footgun pointed at the only DR escape hatch.

### B3. Secret access keys are exposed in CloudFormation outputs
[lib/zuruck-stack.ts:76-79](../../lib/zuruck-stack.ts#L76-L79)

```ts
new cdk.CfnOutput(this, `SecretAccessKey-${name}`, {
  value: resources.accessKey.secretAccessKey.unsafeUnwrap(),
  ...
});
```

`unsafeUnwrap()` lives up to its name: the secret access key is now plaintext in:
- the CloudFormation template (synthesized to disk, asset-staged to S3)
- the deployed stack outputs (anyone with `cloudformation:DescribeStacks` reads it)
- CI logs from `cdk diff` / `cdk deploy`

**Fix:** Don't output the secret. Either:
- Write the access key into Secrets Manager / SSM SecureString and output the ARN (CDK has the `iam.AccessKey` → `SecretValue` pattern), or
- Remove the secret output entirely and instruct operators to fetch via `aws iam create-access-key` post-deploy (treat the CDK-created access key as one-time and rotate immediately).

### B4. SSM parameter has default removal policy → `cdk destroy` wipes the master passwords
[lib/constructs/backup-secrets.ts](../../lib/constructs/backup-secrets.ts)

The bucket is `RETAIN` (good), KMS key defaults to RETAIN (so ciphertext is recoverable), but **the master-password parameters are not protected**. A fat-fingered `cdk destroy`, or a stack rename, evaporates the only key that can decrypt the long-term archive. The whole DR story rests on these parameters.

**Fix:** `parameter.applyRemovalPolicy(RemovalPolicy.RETAIN)` on each `CfnParameter`.

---

## 🟠 Major

### M1. Prefix scheme is inconsistent across docs vs. code
- Code creates prefix `alpha/` ([backup-iam.ts:57](../../lib/constructs/backup-iam.ts#L57)).
- README diagram shows `client-a/`.
- `docs/runbook.md:80,139` and `docs/backup-strategy.md` use `client-alpha/` in `aws s3` examples.
- `docs/plans/backup-system-plan.md` uses `client-alpha/`.

Operators copy-pasting the runbook commands will silently get zero results (`--prefix client-alpha/` matches nothing in a bucket using `alpha/`). Worse, an admin doing a Glacier restore loop iterates over an empty list and reports "done" without restoring anything.

**Fix:** pick one (`alpha/` is what's deployed) and grep-replace across docs. Add a test that asserts the prefix from `clients.ts` matches what the runbook expects.

### M2. Connectivity test in client-setup.sh is guaranteed to false-warn
[scripts/client-setup.sh:132](../../scripts/client-setup.sh#L132)

```bash
aws s3 ls "s3://${BUCKET_NAME}/" --region "${REGION}" &>/dev/null
```

The IAM policy gates `s3:ListBucket` on `s3:prefix StringLike [client/, client/*]` ([backup-iam.ts:75-79](../../lib/constructs/backup-iam.ts#L75-L79)). Listing the bucket root has no prefix → access denied → warning fires for every healthy install. Operators will learn to ignore the warning, and the one time it's a real problem they'll miss it.

**Fix:** `aws s3 ls "s3://${BUCKET_NAME}/${CLIENT_NAME}/"`.

### M3. Systemd unit hardcodes `/usr/local/bin/restic`, but `apt install restic` writes to `/usr/bin/restic`
[scripts/client-setup.sh:176-177](../../scripts/client-setup.sh#L176-L177)

The script also auto-installs via `apt-get`, then writes a unit pointing at the wrong path. The timer fires, fails silently (status 203/EXEC), and the stale-backup alarm doesn't catch it for `thresholdHours` because of B1.

**Fix:** `RESTIC_BIN=$(command -v restic)` and substitute into the unit.

### M4. Backup paths with spaces silently break the systemd unit
[scripts/client-setup.sh:165,176](../../scripts/client-setup.sh#L165)

```bash
BACKUP_PATHS_STR="${BACKUP_PATHS[*]:-/data}"
ExecStartPre=/usr/local/bin/restic backup ${BACKUP_PATHS_STR} --tag auto
```

Array `[*]` joins with IFS (space), no quoting on the systemd side. `/var/log` and `/var/db` works; `/Users/Shared/My Documents` doesn't. Use `printf '%q '` and a quoted form, or write a wrapper script the unit invokes.

### M5. Aggressive `noncurrentVersionExpiration: 1 day` undermines versioning
[lib/constructs/backup-bucket.ts:73](../../lib/constructs/backup-bucket.ts#L73)

The bucket is versioned and clients have `s3:DeleteObject` + `s3:DeleteObjectVersion` (needed for `restic forget --prune`). Versioning is the only soft-delete recovery, and it's expired after 1 day. A compromised client credential can permanently destroy the entire backup in under 24 hours undetected.

**Fix:** lengthen to 14–30 days, or add S3 Object Lock (Governance mode) for true immutability — the plan's "Further Considerations" already flagged this; not implementing it leaves the system vulnerable to ransomware-style scenarios.

### M6. `BucketSizeBytes` alarm only watches `StandardStorage`
[lib/constructs/backup-monitoring.ts:160-174](../../lib/constructs/backup-monitoring.ts#L160-L174)

After 90 days, data transitions to Glacier and disappears from this alarm's view. Cost runaway in Glacier is invisible. Add a second alarm on `GlacierStorage` / `DeepArchiveStorage`, or use the sum across storage types via `metricMath`.

### M7. `aws-cdk-lib` is `^2.259` but `aws-cdk` (CLI) is pinned to `2.1127.0`
[package.json:13,23](../../package.json#L13)

CLI 2.1127 against lib 2.259 is fine in practice (forward-compatible), but pinning one and float-ranging the other invites drift. Pin both, or use a single CDK version through the CLI (`npx cdk@2.x`).

---

## 🟡 Minor

### m1. No Lambda error alarm
The freshness checker is the *only* monitoring. If it crashes (KMS denial, throttled S3 list, JSON.parse failure on bad env), there's no signal — see B1, where missing-data goes via the same alarm path. Add an alarm on `AWS/Lambda Errors > 0` for `freshnessChecker`.

### m2. No log retention on Lambda log group
`aws-cdk:useCdkManagedLogGroup` is enabled, but no `logRetention` is set → defaults to never expire. Cheap but accumulates indefinitely. Set `logRetention: RetentionDays.THREE_MONTHS` on the `NodejsFunction`.

### m3. Dashboard advertises `SSMParameterAccessible` but doesn't render it
[docs/backup-strategy.md:152](../backup-strategy.md#L152) claims "SSM parameter accessibility status" is on the dashboard. The construct only adds freshness widgets and bucket size ([backup-monitoring.ts:201-225](../../lib/constructs/backup-monitoring.ts#L201-L225)). Either add the widget or remove the claim.

### m4. IAM policy missing `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts`
[lib/constructs/backup-iam.ts:82-92](../../lib/constructs/backup-iam.ts#L82-L92)

Restic's S3 backend uses multipart for files >100MB. Without these actions, large file uploads can silently leak partial parts (the bucket's `abortIncompleteMultipartUploadAfter: 7 days` will eventually clean them up, but the upload itself can fail mid-way).

### m5. `9999` sentinel for "no backups found"
[lib/lambda/freshness-checker.ts:66](../../lib/lambda/freshness-checker.ts#L66) emits `HoursSinceLastBackup = 9999` when the prefix is empty. This will skew dashboards and any future anomaly detection. Better: don't publish the metric, or emit a separate `BackupsExist` boolean.

### m6. Region not pinned, README says us-west-2
[bin/zuruck.ts:13](../../bin/zuruck.ts#L13) uses `process.env.CDK_DEFAULT_REGION`. README hardcodes `us-west-2`. If a deployer's profile defaults to e.g. `us-east-1`, they'll create a parallel stack in the wrong region and not notice. Either pin region, or make region a required CDK context value with validation.

### m7. `--include` doesn't exist as a `restic restore` flag
[docs/runbook.md:107](../runbook.md#L107)

```bash
restic restore <snapshot-id> --target /data --include /path/to/file
```

Restic uses `--include` only on `restore` in v0.16+; older versions used `--include-pattern` or `--path`. Worth verifying against the version users are likely to install.

### m8. Tests don't validate IAM scoping
The plan's verification step 18 — "Unit test for IAM policy scoping (client A cannot access client B prefix)" — is not implemented. The current 6 tests check resource counts and a few properties; they wouldn't catch a one-character typo turning `${prefix}*` into `*`. Add a `Template.hasResourceProperties` assertion that the S3 policy's `Resource` arn ends with the right prefix.

### m9. Email subscription has no validation
[bin/zuruck.ts:16](../../bin/zuruck.ts#L16) splits and trims context but doesn't filter empty strings or validate format. `cdk deploy -c alertEmails=,foo@x.com` creates an empty subscription. Filter empties.

---

## ⚪ Nits

- **n1.** [package.json](../../package.json) has no `lint`, `synth`, or `cdk diff` script aliases. Common DX miss.
- **n2.** `noUnusedLocals` and `noUnusedParameters` set to `false` in [tsconfig.json:15-16](../../tsconfig.json#L15-L16). Strictness creep is cheaper to add now.
- **n3.** `@types/node@^24` against `NODEJS_20_X` runtime ([backup-monitoring.ts:71](../../lib/constructs/backup-monitoring.ts#L71)). Harmless here, but match major versions to avoid `node:`-prefix oddities.
- **n4.** `freshnessAlarm.addOkAction(alarmAction)` on every recovery means SNS noise on every transient blip. Consider OK action only on critical alarms.
- **n5.** Mixed `client.name` / `prefix` naming in [backup-iam.ts:57](../../lib/constructs/backup-iam.ts#L57) — extracting `clientPrefix(name)` once would prevent prefix drift across constructs.
- **n6.** `cdk.json` ships every recent feature flag set (good). Worth a brief comment in README that this was intentional vs. `cdk init` defaults.
- **n7.** `docs/client-setup-guide.md` Step 4 mixes admin and client responsibility in a single code block. Split into "Admin (one-time)" and "Client (one-time)".
- **n8.** `displayName` on SNS topic is rendered as the email "From" name — `Restic Backup Alerts` is fine, but consider including stack/region context for multi-environment deployments.

---

## Summary

| Severity | Count |
|---|---|
| Blocking | 4 |
| Major | 7 |
| Minor | 9 |
| Nits | 8 |

**Theme of the blockers**: the project's *promised* safety guarantees (alarm fires on stale backup, master password recoverable in DR, secrets handled hygienically) are each defeated by one specific bug. Each is small to fix individually but together they invert the threat model.

**Theme of the majors**: documentation drift and operator-experience landmines. The system will work for the original author but burn anyone else following the runbook on day one.

**Recommendation**: hold the merge on B1–B4 + M1. The rest can land as follow-ups.
