#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib/core';
import { ZuruckStack } from '../lib/zuruck-stack';
import { CLIENTS, validateClientName } from '../lib/config/clients';

const app = new cdk.App();

const EXPECTED_REGION = 'us-west-2';

// Fail fast at synth time on a bad client name (security-review finding I3).
for (const c of CLIENTS) validateClientName(c.name);

// Configure alert emails via context: cdk deploy -c alertEmails=you@example.com,team@example.com
const rawAlertEmails = app.node.tryGetContext('alertEmails') as string | undefined;
const alertEmails = rawAlertEmails
  ?.split(',')
  .map(e => e.trim())
  .filter(e => e.length > 0 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e));

if (rawAlertEmails && (!alertEmails || alertEmails.length === 0)) {
  // eslint-disable-next-line no-console
  console.warn(
    `[zuruck] alertEmails context was set but yielded no valid addresses; ` +
      `no email subscriptions will be created.`,
  );
}

// Pin region: cross-account / cross-region drift via shell defaults is the
// most common way operators silently create a parallel stack in the wrong
// place. Allow override via -c region=… for legitimate multi-region setups.
const region =
  (app.node.tryGetContext('region') as string | undefined) ??
  process.env.CDK_DEFAULT_REGION ??
  EXPECTED_REGION;

if (region !== EXPECTED_REGION) {
  // eslint-disable-next-line no-console
  console.warn(
    `[zuruck] Deploying to region '${region}' which differs from the documented default '${EXPECTED_REGION}'. ` +
      `If this is intentional, update README and runbook references.`,
  );
}

// Optional: ARN of the role(s) allowed to administer the KMS key. Pass via
// `-c kmsAdminRoleArns=arn:aws:iam::123:role/A,arn:aws:iam::123:role/B`. When
// unset, the key falls back to AccountRootPrincipal (single-account mode).
// (Security-review finding S3.)
const rawKmsAdminRoleArns = app.node.tryGetContext('kmsAdminRoleArns') as string | undefined;
const kmsAdminRoleArns = rawKmsAdminRoleArns
  ?.split(',')
  .map(a => a.trim())
  .filter(a => a.length > 0);

// Optional: object-lock retention in days for new objects. Default 30 days
// gives ransomware/insider-wipe protection without making `restic prune`
// permanently impossible. (Security-review finding S2.)
const objectLockRetentionDaysCtx = app.node.tryGetContext('objectLockRetentionDays') as
  | string
  | number
  | undefined;
const objectLockRetentionDays =
  objectLockRetentionDaysCtx === undefined
    ? 30
    : Number(objectLockRetentionDaysCtx);

if (!Number.isFinite(objectLockRetentionDays) || objectLockRetentionDays < 0) {
  throw new Error(
    `objectLockRetentionDays must be a non-negative number, got '${objectLockRetentionDaysCtx}'`,
  );
}

// Audit trail: on by default so the bucket-config-change alarm has a live
// CloudTrail source. Disable with `-c enableAuditTrail=false` if an org-wide
// trail already covers this account+region. (Review finding #4.)
const enableAuditTrail =
  String(app.node.tryGetContext('enableAuditTrail') ?? 'true').toLowerCase() !== 'false';

// Optional: also capture S3 object-level data events (billed per event).
const auditS3DataEvents =
  String(app.node.tryGetContext('auditS3DataEvents') ?? 'false').toLowerCase() === 'true';

new ZuruckStack(app, 'ZuruckStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region,
  },
  description: 'Restic S3 backup system — bucket, IAM, KMS, SSM, monitoring',
  alertEmails,
  kmsAdminRoleArns,
  objectLockRetentionDays,
  enableAuditTrail,
  auditS3DataEvents,
  tags: {
    Project: 'zuruck',
    Purpose: 'restic-backup',
    ManagedBy: 'cdk',
  },
});
