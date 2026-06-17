# Security Review: Zuruck — Restic S3 Backup System

## Context

Focused security review (separate from the earlier general PR review in [pr-review.md](./pr-review.md)). The codebase has already been hardened against the obvious bugs from that pass — secrets are no longer in CFN outputs, master passwords are RETAINed, alarm thresholds are correct. This review applies a **threat-model lens**: what would a determined attacker do, and where does the current design still leave them daylight?

Threat actors considered:
- **T1 — Compromised client machine.** Attacker has read+write to one client's `/etc/restic/env` and `/etc/restic/password` (both `chmod 600 root`).
- **T2 — Compromised AWS IAM principal in the account.** Read-only or low-priv role.
- **T3 — Insider with stack-deploy privileges.** Can run `cdk deploy` / `cdk destroy`.
- **T4 — Network observer / exfiltration channel.** No direct AWS creds, observes traffic or logs.

The intended security posture is: each client compromise should affect only that client's prefix; AWS account compromise should still leave backups recoverable (the master password is in SSM under a separate-from-clients key path); and the system as a whole should fail safe (alarms fire, deletions are reversible).

---

## Findings, by severity

### 🔴 Critical

#### S1. Compromised client can permanently destroy its own backup history
**Threat**: T1.

The client IAM policy ([backup-iam.ts:96-105](../../lib/constructs/backup-iam.ts#L96-L105)) grants `s3:DeleteObject` and **`s3:DeleteObjectVersion`** on `<prefix>/*`. Together with the bucket's 90-day `noncurrentVersionExpiration` ([backup-bucket.ts:84-87](../../lib/constructs/backup-bucket.ts#L84-L87)), this is *less* bad than it was (90 days to detect) but still permits a client compromise to wipe the entire current+noncurrent history of its own prefix in one `aws s3api delete-object --version-id` loop. Restic's `forget --prune` needs `DeleteObject` but does **not** need `DeleteObjectVersion`; granting the latter to a long-lived client credential is the single biggest residual risk.

**Recommendation:** Remove `s3:DeleteObjectVersion` from the client policy. `forget --prune` operates on current versions; noncurrent-version cleanup is a bucket-lifecycle responsibility. If a stronger guarantee is needed, layer S3 Object Lock (Governance mode, see S2) on top.

#### S2. No S3 Object Lock — ransomware/wiper has a clean kill path
**Threat**: T1, T3.

Versioning + a 90-day noncurrent retention is recoverable but not *immutable*. An attacker who controls a client credential **for 90 days** can wait out the noncurrent expiration; an insider with `cdk deploy` can shorten the retention to 1 day and then wipe. Object Lock in Governance mode is the only AWS-native control that breaks this.

**Recommendation:** Enable `objectLockEnabled: true` on the bucket and add a default retention rule (e.g. 30 days governance-mode for the `*/data/` keys restic creates). Document the trade-off: `restic prune` will fail on locked objects, and operators must use `forget --keep-...` without `--prune` until the lock window passes. This was already flagged in the original plan's "Further Considerations" — it's the single highest-leverage hardening still un-done.

---

### 🟠 High

#### S3. KMS key policy grants `kms:*` to AccountRootPrincipal
**Threat**: T2.

[backup-kms.ts:50-58](../../lib/constructs/backup-kms.ts#L50-L58) grants `kms:*` to `AccountRootPrincipal()`. The inline comment explicitly acknowledges this. In a single-account, single-team deployment that's fine; in any multi-team account, **every IAM admin in the account can `kms:ScheduleKeyDeletion`** the backup key, which (after the 7-day deletion window) renders every encrypted object and every SecureString permanently unrecoverable. This is the same blast radius as `cdk destroy` but available to a much larger pool of principals.

**Recommendation:** Replace `AccountRootPrincipal` with the deploy-role ARN(s) (passable via stack props), or add an explicit `Deny` for `kms:ScheduleKeyDeletion` and `kms:DisableKey` scoped to everyone except a named break-glass role. At minimum, set `pendingWindow: Duration.days(30)` (the maximum) on the key so a mistake is more reversible.

#### S4. SecureString cleartext is logged on Lambda errors
**Threat**: T2 (with `logs:GetLogEvents`), T4 (CloudWatch log exfil via misconfig).

[freshness-checker.ts:158-162](../../lib/lambda/freshness-checker.ts#L158-L162) wraps `GetParameterCommand({WithDecryption: true})` in a try/catch and logs the error object verbatim with `console.error(...err)`. AWS SDK errors stringify with the request body in some failure modes, and at the very least include the parameter name. Worse, the **success path** doesn't log the value — but a future contributor adding "log the parameter on success for debugging" is one diff away from leaking the master password into CloudWatch Logs (and the THREE_MONTHS retention).

There's also a subtler issue: the Lambda has `kms:Decrypt` on the same CMK that encrypts S3 objects. That decrypt grant is broader than required — to verify SSM accessibility, the function only needs to fetch and decrypt the `master-password` parameter. By scoping decrypt to *just* the SSM parameter ARN context (`kms:EncryptionContext:aws:ssm:parameterName`), you reduce the blast radius of a Lambda RCE.

**Recommendation:**
1. Replace `console.error(\`SSM parameter check failed for ${client.name}:\`, err)` with a sanitized log (`name`, `code`, no body).
2. Tighten the Lambda's `kms:Decrypt` to a `Condition: { StringEquals: { "kms:EncryptionContext:PARAMETER_ARN": "<arn>" } }` clause, or alternatively split into two CMKs (one for S3, one for SSM) so an exfiltrated Lambda role can't decrypt backup data.
3. Don't decrypt the parameter value on every poll — `WithDecryption: false` is enough to prove the parameter exists, and removes the value from the response payload entirely. The "is this decryptable" check could be done once a day with a separate canary.

#### S5. Master-password provisioner Lambda has overbroad SSM/KMS permissions
**Threat**: T2 (via Lambda RCE), T3.

[backup-secrets.ts:69-83](../../lib/constructs/backup-secrets.ts#L69-L83) grants the provisioner Lambda role:
- `ssm:GetParameter`, `ssm:PutParameter`, `ssm:AddTagsToResource` on `parameter/zuruck/restic/*`
- `kms:Encrypt`, `kms:GenerateDataKey`, **`kms:Decrypt`** on the bucket CMK

Two issues:
1. `kms:Decrypt` is unnecessary for `PutParameter` with `Type: SecureString` — only `Encrypt`/`GenerateDataKey` are needed. Decrypt lets a compromised provisioner role read every SSM master password and every S3 object.
2. The provisioner is invoked once per `cdk deploy` per client. The Lambda function lives forever. After deployment, the function is reachable by anyone in the account with `lambda:InvokeFunction` — and an arbitrary `ResourceProperties.ParameterName` lets them read or *overwrite* any `zuruck/restic/*` parameter, including the ones their account isn't supposed to touch.

**Recommendation:**
1. Drop `kms:Decrypt` from the provisioner role.
2. Either (a) gate invocation behind a resource policy that only allows the CloudFormation custom-resource provider to invoke it, or (b) set `provider.providerFunction.grantInvoke(...)` only to the CFN service. The current Provider construct does add a service principal grant by default, but verify in synth.
3. Set `reservedConcurrentExecutions: 1` on the provisioner so a runaway invoker can't flood SSM.

#### S6. SNS alert topic doesn't enforce TLS
**Threat**: T4.

[backup-monitoring.ts:67-72](../../lib/constructs/backup-monitoring.ts#L67-L72) creates the alert topic with a KMS master key (good) but no resource policy denying non-TLS publish/subscribe. AWS-managed encryption-at-rest is enabled, but in-transit can still be HTTP. Email subscriptions are out of band, but if anyone adds an HTTPS or Lambda subscription later, the topic should refuse plain HTTP from day one.

**Recommendation:** Add a `Deny` statement on `aws:SecureTransport=false`, mirroring the pattern `enforceSSL` does for S3.

---

### 🟡 Medium

#### S7. No bucket policy — defense relies entirely on identity-based policies
[backup-bucket.ts](../../lib/constructs/backup-bucket.ts) sets `enforceSSL: true` (which adds a `DenyInsecureTransport` bucket policy via CDK) but no other resource policy. Specifically, no `aws:SourceIp` / `aws:VpcSourceIp` restriction, no `kms:ViaService=s3` constraint, no explicit `Deny` for cross-client prefix access. All isolation is on the IAM-policy side. A misattached identity policy (e.g. an operator accidentally adding `s3:GetObject *` to the client group) silently breaks isolation. A bucket policy that *requires* the requester's tag/userid match the prefix would catch that.

**Recommendation:** Add a bucket policy with a per-prefix `Condition` that ties `aws:userid` to the path. This is belt-and-suspenders, but for a backup bucket the seatbelt is worth wearing.

#### S8. No GuardDuty / Macie / CloudTrail S3-data-event integration
The monitoring fires on freshness and bucket size. It does **not** fire on:
- Mass-delete events (`DeleteObjects` calls > N in a window)
- Unusual API-caller patterns (a client IAM user listing the bucket from a new geography)
- Public-access-block changes (someone disabling BPA)

GuardDuty's S3 protection covers the first two; AWS Config rules cover the third. Without these, the gap between "client wipe" and "noncurrent-version expiration" is the only detection window, and it relies on operators noticing the freshness alarm and acting before the 90 days elapse.

**Recommendation:** Either deploy GuardDuty + an EventBridge rule on `DeleteObjects` (route to the same SNS topic), or add an AWS Config rule for `s3-bucket-public-write-prohibited` and `s3-bucket-versioning-enabled`. Cheapest of the three: an EventBridge rule on CloudTrail for `eventName = DeleteObjects AND requestParameters.delete.objects.size > 100`.

#### S9. IAM `s3:ListBucket` lets each client enumerate other clients' prefix names
[backup-iam.ts:84-94](../../lib/constructs/backup-iam.ts#L84-L94) — the inline comment acknowledges this. The condition is `s3:prefix StringLike ["alpha/*"]`, which means a request without a prefix parameter will fail, but a request with `Prefix=""` and `Delimiter="/"` will fail too — *unless* the attacker probes prefixes. They can confirm whether `bravo/`, `gamma/`, etc. exist by listing each.

In practice this enables **lateral reconnaissance**: a compromised `alpha` client learns what other clients exist. It does not give them data access, but it informs which other targets to attack on the user's network.

**Recommendation:** No clean fix at the IAM level — this is how `s3:prefix` works. Mitigations: (a) name prefixes with non-guessable suffixes (`alpha-7f3a/`), or (b) accept the leakage and document it as an accepted risk.

#### S10. Long-lived static IAM access keys
[backup-iam.ts:130-132](../../lib/constructs/backup-iam.ts#L130-L132) creates an `AccessKey` that lives until manually rotated. The runbook documents rotation but nothing enforces it. Most credential-leak postmortems end with "the key had been valid for two years."

**Recommendation:** For Linux clients in EC2/ECS, use IAM Roles + IMDSv2. For laptops/static-machine clients (the use-case here), at least:
1. Add an AWS Config rule `iam-user-unused-credentials-check` with `maxCredentialUsageAge: 90`.
2. Tag the access keys with `RotationDue=YYYY-MM-DD` in description and add a CloudWatch event that pages 7 days before.
3. Better: use **IAM Roles Anywhere** with X.509 certs from a private CA — the cert is rotatable, revocable, and the long-lived material lives in the TPM/KeyChain rather than a flat file.

#### S11. Master-password parameter is never rotated; SSM has no rotation primitive
The system documents how to rotate (runbook §"Rotate Master Password") but provides no mechanism. SSM Parameter Store, unlike Secrets Manager, has no rotation Lambda hook. Combined with `Overwrite: false` in the provisioner ([master-password-provisioner.ts:69](../../lib/lambda/master-password-provisioner.ts#L69)), there's no path to rotation that doesn't involve bespoke runbook commands.

**Recommendation:** If rotation is a real requirement (it usually is for compliance), use Secrets Manager instead of SSM Parameter Store for the master password — the cost difference is $0.40/secret/month, trivial vs. compliance value, and you get native rotation. The earlier review's recommendation to keep SSM was a cost call; this is a security re-evaluation.

---

### 🟢 Low

#### S12. `client-setup.sh` writes the secret into `/etc/restic/env` as plain text
The file is `chmod 600 root:root` (good), but the secret access key is on disk in cleartext. Any backup, snapshot, or `dd` of the host filesystem captures it. For laptops especially, that's the same threat as a stolen device.

**Recommendation:** On Linux, wrap the env file in `systemd-creds encrypt` so only the systemd service can decrypt it. On macOS, store the secret in Keychain (`security add-generic-password`) and have the launchd job fetch it at runtime.

#### S13. `client-setup.sh` interactive prompt has no terminal-state guard
[client-setup.sh:99-108](../../scripts/client-setup.sh#L99-L108) — if the user pipes the script (`curl ... | sudo bash`), the `read -rs ... </dev/tty` works, but an aborted `read` mid-input could leave the terminal in `-echo` state. Add `trap 'stty echo' EXIT INT TERM` before the read.

#### S14. `restic` is installed via `apt-get install` without GPG verification
[client-setup.sh:113](../../scripts/client-setup.sh#L113) — relies on the distro's package signing. That's fine for Debian/Ubuntu, but `--install-restic` on a system with stale or compromised apt sources installs whatever apt says is `restic`. Pinning the version and verifying with a known SHA256 (the way `restic` upstream's own install instructions do) is more defensible.

#### S15. Email is the only alert channel
SNS → email is fragile (SPF/DMARC, mailbox full, holiday, individual employee turnover). For a backup system whose alarms are sometimes the only signal that data is being destroyed, a second channel (PagerDuty, Slack via Lambda, SMS) is justified.

**Recommendation:** Document the Slack/PagerDuty integration as "operator chooses one of these," not "email only."

#### S16. `npm audit` reports 18 moderate vulnerabilities in dev dependencies
Already noted on `npm install`. Most are likely transitive in jest/ts-jest. Review and pin where possible. None affect runtime, but supply-chain-attack scenarios on dev deps (CDK synth time) are a real category.

---

### ⚪ Informational

- **I1.** `client-setup.sh` does not validate the `--client-name` matches an existing CDK-deployed client. A typo silently sets up a config that points at a nonexistent prefix — backups go to S3, but no IAM user/SSM/freshness alarm exists for them. Add a `aws ssm get-parameter --name "/zuruck/restic/${CLIENT_NAME}/master-password" --with-decryption` precheck before writing config.
- **I2.** No tests around the provisioner Lambda's idempotency. The "leave existing parameter alone" path is the linchpin of B2 from the previous review and has no test coverage. Add a unit test that mocks `GetParameter` to return success and asserts `PutParameter` is **not** called.
- **I3.** The `clientPrefix(name)` helper accepts any string. If a client config uses `name: "../etc/passwd"` (improbable but cheap to defend against), the IAM policy ARN construction silently breaks. Add a `^[a-z][a-z0-9-]{1,32}$` regex check on `ClientConfig.name` at construction time.
- **I4.** The Lambda freshness checker uses `JSON.parse(process.env.CLIENTS!)`. If the env var is malformed, the Lambda crashes on every invocation and there's no signal except the Lambda-error alarm. A startup-time schema validation (zod, ajv, or hand-rolled) plus a deploy-time CDK assertion would surface the problem at synth.

---

## Summary

| Severity | Count | Theme |
|---|---|---|
| 🔴 Critical | 2 | Long-term immutability — versioning ≠ Object Lock; client can wipe its own history |
| 🟠 High | 4 | Blast-radius: KMS root grant, Lambda kms:Decrypt scope, SecureString logging, SNS TLS |
| 🟡 Medium | 5 | Defense-in-depth: bucket policy, GuardDuty, prefix recon, key rotation, SSM rotation |
| 🟢 Low | 5 | Client-side hardening + supply chain |
| ⚪ Info | 4 | Hygiene |

## Recommended action

Land **S1, S2, S5** as a single "harden master backup path" branch — they're the three controls that, missing, let one bad actor (compromised client, account-admin mistake, or insider) destroy the system's stated guarantees. **S3, S4, S6** in a follow-up. The rest are good follow-ups but not blocking.

## Verification plan

For each fix:
1. Add a unit test that asserts the IAM/policy structure (e.g. `Match.not(Match.objectLike({ Action: 's3:DeleteObjectVersion' }))` for S1).
2. `cdk synth` and grep the template for the absence of the removed permission and the presence of the added Deny.
3. For S2 (Object Lock), do a *staging* deploy and confirm `restic backup` works; then attempt `aws s3api delete-object --version-id ...` and confirm AccessDenied.
4. For S4, send a malformed parameter name and confirm the log line contains no body.
5. For S5, attempt to invoke the provisioner Lambda from a non-CFN principal — should be denied.
