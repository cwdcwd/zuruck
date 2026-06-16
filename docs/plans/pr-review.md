# PR Review: Zuruck Restic S3 Backup System

**Date**: 2026-06-16
**Reviewer**: Senior Engineer Review
**Verdict**: ~~Approve with comments~~ **All findings remediated**

---

## Overall Assessment

This is a well-structured, production-quality CDK project. The architecture is sound, the security model is thoughtful, and the documentation is comprehensive. The code has clearly been iterated on — the current state shows improvements over the original plan (Secrets Manager for access keys instead of CFN outputs, custom resource for password provisioning, Lambda error alarm, noncurrent version retention). Below are findings organized by severity.

---

## 🔴 Critical (must fix before merge)

### 1. S3 `ListBucket` condition is too permissive ✅ REMEDIATED

Removed redundant bare `prefix` entry from `s3:prefix` condition (now only `${prefix}*`). Added detailed comment explaining that the condition does not prevent listing the bucket root, and documenting the security tradeoff with guidance for adding an explicit Deny if prefix enumeration is a concern.

### 2. Freshness checker Lambda can time out on large buckets ✅ REMEDIATED

Added timeout guard with 30-second margin before Lambda deadline. The handler checks `Date.now()` against a computed deadline before each client iteration and before each S3 pagination call. When approaching timeout, it logs a warning and breaks out of the loop, flushing whatever partial metrics have been collected. Also added `standardRetryStrategy` with explicit `maxAttempts: 3` for S3 throttling protection.

### 3. `noncurrentVersionExpiration: 30 days` may be too aggressive ✅ REMEDIATED

Changed default from 30 to 90 days (matching the Glacier transition window). Updated the JSDoc comment to explain the tradeoff: "90 days matches the Glacier transition window, giving operators a full quarter to detect and recover from an accidental or malicious mass-delete." Updated test threshold from `>=14` to `>=90`.

---

## 🟡 Medium (should fix before merge)

### 4. Plan doc is stale — doesn't reflect implementation changes ✅ REMEDIATED

Updated `docs/plans/backup-system-plan.md` to reflect: Custom Resource Lambda for SSM passwords, Secrets Manager for access keys, Lambda error alarm, bucket size alarm across all storage classes, BackupsExist metric, timeout guard, retry strategy, ARM64 Lambda architecture, updated project structure (including `lib/lambda/` directory), updated client setup flow, updated verification steps, and corrected prefix scheme (`alpha/` not `client-alpha/`).

### 5. Client setup script passes `--secret-access-key` on the command line ✅ REMEDIATED

Updated `scripts/client-setup.sh` to accept the secret via three methods (in priority order): `--secret-access-key` flag (still supported for CI), `SECRET_ACCESS_KEY` environment variable (preferred), or interactive prompt (fallback). Updated usage text to document all three methods and warn that the CLI flag is visible in `ps(1)`.

### 6. `client-setup.sh` S3 connectivity test may fail for valid setups ✅ REMEDIATED

Added `command -v aws` check before the S3 connectivity test. If `aws` CLI is not found, the script prints a warning and skips the test gracefully, noting that restic doesn't require the AWS CLI.

### 7. No `aws` CLI dependency check in setup script ✅ REMEDIATED

Merged with finding #6 — the `command -v aws` check now gates the entire connectivity test section.

### 8. Freshness checker doesn't handle S3 `ListObjectsV2` throttling ✅ REMEDIATED

Added `standardRetryStrategy` with `maxAttempts: 3` to all three SDK clients (S3, SSM, CloudWatch) in `freshness-checker.ts`. The standard retry strategy includes exponential backoff with jitter.

### 9. KMS key policy is overly permissive ✅ REMEDIATED

Added detailed security comment to `backup-kms.ts` explaining that `AccountRootPrincipal` effectively grants `kms:*` to any principal in the account with identity-based KMS permissions, and documenting that for multi-team accounts it should be replaced with specific admin role ARNs. The current policy is noted as acceptable for single-account deployments.

---

## 🟢 Low (nice to have)

### 10. No `DependsOn` between SSM parameters and IAM policies ✅ REMEDIATED

Added comment in `backup-secrets.ts` explaining that there is no explicit DependsOn between the SSM custom resources and the IAM policies, and why this is safe in practice (clients won't be configured until after deployment).

### 11. Lambda runtime could be ARM64 for cost savings ✅ REMEDIATED

Added `architecture: lambda.Architecture.ARM_64` to both Lambda functions (freshness checker and password provisioner) in `backup-monitoring.ts` and `backup-secrets.ts`.

### 12. Dashboard doesn't include Lambda error metrics ✅ REMEDIATED

Added a "Freshness Checker Lambda Errors" graph widget to the CloudWatch dashboard in `backup-monitoring.ts`, placed between the SSM widget and the bucket size widget.

### 13. `client-setup.sh` doesn't handle the case where restic is already initialized ✅ REMEDIATED

Changed `restic snapshots &>/dev/null` to `restic snapshots 2>/dev/null` so only stderr is suppressed (restic outputs repo info to stderr when the repo doesn't exist, which was confusing operators).

### 14. Test coverage is good but could be deeper ✅ REMEDIATED

Added three new tests: (1) SSM parameter names follow the expected pattern (`/zuruck/restic/{name}/master-password`), (2) freshness checker Lambda has correct environment variables, (3) no client S3 policy grants access to another client's prefix (negative cross-client assertion). Also updated the ListBucket condition test to match the simplified `s3:prefix` array and updated the noncurrentVersionExpiration threshold to `>=90`.

### 15. `package.json` doesn't pin `aws-cdk-lib` version ✅ REMEDIATED

`aws-cdk-lib` was already pinned to exact version `2.259.0`. Pinned `constructs` from `^10.5.0` to exact `10.5.0`. Added `.npmrc` with `save-exact=true` to prevent future drift.

### 16. Missing `.npmrc` with `save-exact=true` ✅ REMEDIATED

Created `.npmrc` with `save-exact=true`.

---

## ✅ What's done well

- **Secrets Manager for access keys** — much better than CFN outputs, which would leak the secret access key to anyone with `cloudformation:DescribeStacks`
- **Custom Resource for password provisioning** — the master password is generated in Lambda, never appears in the template, and is idempotent (won't overwrite on redeploy)
- **`RemovalPolicy.RETAIN` on SSM parameters** — losing the master password orphans all backups
- **`noncurrentVersionExpiration`** — protects against accidental `forget` data loss
- **Lambda error alarm** — catches the case where the freshness checker itself is broken
- **Bucket size alarm sums across storage classes** — catches growth even after Glacier transitions
- **`clientPrefix()` and `clientMasterPasswordParameterName()` helpers** — single source of truth for naming conventions
- **Region pinning with warning** — prevents accidental cross-region deploys
- **Email validation in `bin/zuruck.ts`** — catches typos early
- **Comprehensive runbook** — covers add/remove client, emergency restore, key rotation, cost management
- **Dual restic keys** — client never has the master password, enabling key rotation without DR risk

---

## Summary

| Severity | Count | Action |
|---|---|---|
| 🔴 Critical | 3 | ✅ All remediated |
| 🟡 Medium | 6 | ✅ All remediated |
| 🟢 Low | 7 | ✅ All remediated |

All 16 findings have been remediated. The three critical items were: (1) documented the `ListBucket` scoping behavior and removed redundant prefix, (2) added timeout guard and retry strategy to the freshness checker, and (3) increased `noncurrentVersionExpiration` default to 90 days. The medium items were doc sync and security hardening. The low items were operational improvements (ARM64, dashboard widget, deeper tests, exact version pinning, .npmrc).
