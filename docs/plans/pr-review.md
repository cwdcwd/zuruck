# PR Review: Zuruck Restic S3 Backup System

**Date**: 2026-06-16
**Reviewer**: Senior Engineer Review
**Verdict**: **Approve with comments**

---

## Overall Assessment

This is a well-structured, production-quality CDK project. The architecture is sound, the security model is thoughtful, and the documentation is comprehensive. The code has clearly been iterated on — the current state shows improvements over the original plan (Secrets Manager for access keys instead of CFN outputs, custom resource for password provisioning, Lambda error alarm, noncurrent version retention). Below are findings organized by severity.

---

## 🔴 Critical (must fix before merge)

### 1. S3 `ListBucket` condition is too permissive

In `backup-iam.ts`, the `s3:ListBucket` condition uses:

```typescript
conditions: {
  StringLike: {
    's3:prefix': [prefix, `${prefix}*`],
  },
},
```

The `prefix` value is `alpha/` (from `clientPrefix()`). The condition `s3:prefix: alpha/` allows listing the prefix itself (returns just the "folder" marker), while `alpha/*` allows listing everything under it. However, `StringLike` is case-insensitive and uses `*` as a glob. The value `alpha/*` is correct, but the bare `alpha/` entry is redundant — `alpha/*` already covers it. More importantly, this condition **does not prevent listing the bucket root** — a `ListBucket` call without a prefix parameter will still succeed (it just won't return objects outside the allowed prefix). This is actually fine for restic (which always specifies a prefix), but it's worth documenting that the client can enumerate all prefix names in the bucket. If you want to prevent even that, add `s3:ListBucket` with `Deny` for prefix-less calls. **Low risk in practice, but worth a comment.**

### 2. Freshness checker Lambda can time out on large buckets

The `freshness-checker.ts` iterates all objects under each client prefix using `ListObjectsV2` with pagination. For a client with millions of objects, this can easily exceed the 5-minute Lambda timeout. Consider:

- Adding a `MaxKeys` limit per page (currently defaults to 1000, which is fine)
- Adding a time-check inside the loop — if approaching timeout, emit a partial metric and bail
- Or: use S3 `ListObjectVersions` with a `MaxKeys=1` and `Prefix` to just check the latest object, rather than paginating through everything

### 3. `noncurrentVersionExpiration: 30 days` may be too aggressive

The bucket has `noncurrentVersionExpiration: cdk.Duration.days(30)` (default). Since restic uses `DeleteObject` during `forget --prune`, and the bucket is versioned, deleted objects become noncurrent versions. With a 30-day expiry, any accidentally-deleted snapshot data is irrecoverable after 30 days. The comment says this is intentional ("long enough for an operator to notice"), but 30 days is tight for a backup system — consider defaulting to 90 days (matching the Glacier transition) and documenting the tradeoff.

---

## 🟡 Medium (should fix before merge)

### 4. Plan doc is stale — doesn't reflect implementation changes

The plan at `docs/plans/backup-system-plan.md` still references:

- "SSM Parameter Store (SecureString) per client" as a `StringParameter` / `CfnParameter` — the implementation now uses a **Custom Resource with Lambda** for password provisioning
- "Per-client IAM user (programmatic access only)" with `AccessKey` + CFN output — the implementation now uses **Secrets Manager** for the secret access key
- The architecture diagram doesn't show Secrets Manager at all
- The project structure doesn't list `lib/lambda/master-password-provisioner.ts`
- The implementation steps don't mention the Lambda error alarm or the `BackupsExist` metric

**Recommendation**: Update the plan doc to match the implementation, or add a note that it's the original plan and the implementation diverges (with a summary of changes).

### 5. Client setup script passes `--secret-access-key` on the command line

`scripts/client-setup.sh` accepts `--secret-access-key` as a CLI argument. This means the secret appears in the process list (`ps aux`) and shell history. The runbook correctly uses Secrets Manager to retrieve keys, but the setup script doesn't.

**Recommendation**: Accept the secret via an environment variable or prompt instead:

```bash
SECRET_ACCESS_KEY="${SECRET_ACCESS_KEY:-}" 
[[ -z "$SECRET_ACCESS_KEY" ]] && read -rs SECRET_ACCESS_KEY </dev/tty
```

### 6. `client-setup.sh` S3 connectivity test may fail for valid setups

The test `aws s3 ls "s3://${BUCKET_NAME}/${CLIENT_NAME}/"` will fail if the `aws` CLI isn't installed on the client machine. Restic doesn't require the AWS CLI — it uses its own S3 client. The script should check for `aws` first and skip the test gracefully.

### 7. No `aws` CLI dependency check in setup script

The script uses `aws s3 ls` for connectivity testing but doesn't verify `aws` is installed. Add a check at the top.

### 8. Freshness checker doesn't handle S3 `ListObjectsV2` throttling

For 6–20 clients, the Lambda makes 6–20 paginated `ListObjectsV2` calls per invocation. If the bucket is large, this could hit S3 request rate limits. Consider adding `MaxKeys=1000` explicitly and adding retry/backoff with `@aws-sdk/middleware-retry`.

### 9. KMS key policy is overly permissive

The KMS key policy grants `kms:*` to the account root. While this is standard practice, the comment says "admin = deploying account" but the policy actually grants full access to **any** principal in the account that can assume a role. Consider narrowing to specific admin roles.

---

## 🟢 Low (nice to have)

### 10. No `DependsOn` between SSM parameters and IAM policies

The custom resource that creates SSM parameters and the IAM policies that grant `ssm:GetParameter` on those parameters are created independently. In theory, a client could try to access the parameter before it exists. In practice, the client won't be configured until after deployment, so this is a non-issue — but worth a comment.

### 11. Lambda runtime could be ARM64 for cost savings

The freshness checker Lambda uses `NODEJS_20_X` on x86_64. Switching to `arm64` would reduce cost by ~20% with no performance impact for this workload. Add `architecture: lambda.Architecture.ARM_64`.

### 12. Dashboard doesn't include Lambda error metrics

The CloudWatch dashboard includes freshness and SSM accessibility widgets but doesn't show the Lambda error alarm metric. Adding a widget for `Errors` on the Lambda function would make the dashboard a single pane of glass.

### 13. `client-setup.sh` doesn't handle the case where restic is already initialized

The script checks `restic snapshots` but if the repo doesn't exist, restic returns a non-zero exit code, which triggers the `set -e` and prints the warning. This is fine, but the error output from `restic snapshots` goes to stderr and may confuse operators. Consider redirecting: `restic snapshots 2>/dev/null`.

### 14. Test coverage is good but could be deeper

The tests verify resource counts and property existence, which is great. Consider adding:

- A test that verifies no client can access another client's S3 prefix (negative assertion)
- A test that verifies the SSM parameter names match the expected pattern
- A test that verifies the Lambda environment variables are set correctly

### 15. `package.json` doesn't pin `aws-cdk-lib` version

The dependency is `"aws-cdk-lib": "^2.259.0"` which allows minor version bumps. For infrastructure code, consider pinning to an exact version to prevent unexpected breaking changes.

### 16. Missing `.npmrc` with `save-exact=true`

The project structure in the plan lists `.npmrc` but it doesn't exist. For infrastructure code, pinning exact dependency versions is a best practice.

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
| 🔴 Critical | 3 | Fix before merge |
| 🟡 Medium | 6 | Should fix before merge |
| 🟢 Low | 7 | Nice to have |

The three critical items are: (1) document the `ListBucket` scoping behavior, (2) add a timeout guard to the freshness checker, and (3) consider increasing `noncurrentVersionExpiration` default. The medium items are mostly doc sync and security hardening. Overall this is solid infrastructure code.
