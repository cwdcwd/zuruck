import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import { BackupKms } from './constructs/backup-kms';
import { BackupBucket } from './constructs/backup-bucket';
import { BackupIam } from './constructs/backup-iam';
import { BackupSecrets } from './constructs/backup-secrets';
import { BackupMonitoring } from './constructs/backup-monitoring';
import { CLIENTS } from './config/clients';

export interface ZuruckStackProps extends cdk.StackProps {
  /**
   * Email addresses to subscribe to backup alert notifications.
   */
  readonly alertEmails?: string[];
}

export class ZuruckStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: ZuruckStackProps) {
    super(scope, id, props);

    // ── KMS Key + IAM Group ──────────────────────────────────────────
    const kms = new BackupKms(this, 'Kms', {
      description: 'Restic S3 backup encryption key',
    });

    // ── S3 Bucket ─────────────────────────────────────────────────────
    const bucket = new BackupBucket(this, 'Bucket', {
      encryptionKey: kms.key,
    });

    // ── IAM Users + Policies ──────────────────────────────────────────
    const iam = new BackupIam(this, 'Iam', {
      bucket: bucket.bucket,
      encryptionKey: kms.key,
      clientGroup: kms.clientGroup,
      clients: CLIENTS,
    });

    // ── SSM Parameter Store (Master Passwords) ────────────────────────
    const secrets = new BackupSecrets(this, 'Secrets', {
      encryptionKey: kms.key,
      clients: CLIENTS,
    });

    // ── Monitoring ─────────────────────────────────────────────────────
    const monitoring = new BackupMonitoring(this, 'Monitoring', {
      bucket: bucket.bucket,
      encryptionKey: kms.key,
      clients: CLIENTS,
      alertEmails: props?.alertEmails,
    });

    // ── Outputs ────────────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'BucketName', {
      value: bucket.bucket.bucketName,
      description: 'S3 bucket for restic backups',
    });

    new cdk.CfnOutput(this, 'KmsKeyArn', {
      value: kms.key.keyArn,
      description: 'KMS key ARN for S3 SSE and SSM encryption',
    });

    new cdk.CfnOutput(this, 'AlertTopicArn', {
      value: monitoring.alertTopic.topicArn,
      description: 'SNS topic ARN for backup alerts',
    });

    // Output access keys for each client (marked as sensitive)
    for (const [name, resources] of iam.clientResources) {
      new cdk.CfnOutput(this, `AccessKeyId-${name}`, {
        value: resources.accessKey.accessKeyId,
        description: `Access key ID for client '${name}'`,
      });

      new cdk.CfnOutput(this, `SecretAccessKey-${name}`, {
        value: resources.accessKey.secretAccessKey.unsafeUnwrap(),
        description: `Secret access key for client '${name}' (SENSITIVE)`,
      });
    }
  }
}
