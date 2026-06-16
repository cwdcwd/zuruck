#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib/core';
import { ZuruckStack } from '../lib/zuruck-stack';

const app = new cdk.App();

const EXPECTED_REGION = 'us-west-2';

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

new ZuruckStack(app, 'ZuruckStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region,
  },
  description: 'Restic S3 backup system — bucket, IAM, KMS, SSM, monitoring',
  alertEmails,
  tags: {
    Project: 'zuruck',
    Purpose: 'restic-backup',
    ManagedBy: 'cdk',
  },
});
