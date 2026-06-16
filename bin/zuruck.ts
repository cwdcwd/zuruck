#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib/core';
import { ZuruckStack } from '../lib/zuruck-stack';

const app = new cdk.App();

// Configure alert emails via context: cdk deploy -c alertEmails=you@example.com,team@example.com
const alertEmails = app.node.tryGetContext('alertEmails') as string | undefined;

new ZuruckStack(app, 'ZuruckStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
  description: 'Restic S3 backup system — bucket, IAM, KMS, SSM, monitoring',
  alertEmails: alertEmails?.split(',').map(e => e.trim()),
  tags: {
    Project: 'zuruck',
    Purpose: 'restic-backup',
    ManagedBy: 'cdk',
  },
});
