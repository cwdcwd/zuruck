import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import { BackupKms } from './constructs/backup-kms';
import { BackupBucket } from './constructs/backup-bucket';
import { BackupIam } from './constructs/backup-iam';
import { BackupSecrets } from './constructs/backup-secrets';
import { BackupMonitoring } from './constructs/backup-monitoring';
import { BackupAudit } from './constructs/backup-audit';
import { CLIENTS } from './config/clients';

export interface ZuruckStackProps extends cdk.StackProps {
  /**
   * Email addresses to subscribe to backup alert notifications.
   */
  readonly alertEmails?: string[];

  /**
   * IAM role ARNs allowed to administer the KMS CMK. When unset, falls back
   * to the account root principal. (Security-review S3.)
   */
  readonly kmsAdminRoleArns?: string[];

  /**
   * Object Lock default retention in days. 0 disables Object Lock.
   * (Security-review S2.) Object Lock is only honored at bucket-creation
   * time — pre-existing deployments need a manual recreation to enable it.
   */
  readonly objectLockRetentionDays?: number;

  /**
   * Provision a CloudTrail trail so the bucket-config-change EventBridge rule
   * has a live event source. Disable when the account already runs an
   * org-wide trail. (Review finding #4.)
   *
   * @default true
   */
  readonly enableAuditTrail?: boolean;

  /**
   * When the audit trail is enabled, also capture S3 object-level (data)
   * events for the backup bucket. Billed per event; off by default.
   *
   * @default false
   */
  readonly auditS3DataEvents?: boolean;
}

export class ZuruckStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: ZuruckStackProps) {
    super(scope, id, props);

    const kms = new BackupKms(this, 'Kms', {
      description: 'Restic S3 backup encryption key',
      adminRoleArns: props?.kmsAdminRoleArns,
    });

    const bucket = new BackupBucket(this, 'Bucket', {
      encryptionKey: kms.key,
      objectLockRetentionDays: props?.objectLockRetentionDays,
    });

    const iam = new BackupIam(this, 'Iam', {
      bucket: bucket.bucket,
      encryptionKey: kms.key,
      clientGroup: kms.clientGroup,
      clients: CLIENTS,
    });

    new BackupSecrets(this, 'Secrets', {
      encryptionKey: kms.key,
      clients: CLIENTS,
    });

    const monitoring = new BackupMonitoring(this, 'Monitoring', {
      bucket: bucket.bucket,
      encryptionKey: kms.key,
      clients: CLIENTS,
      alertEmails: props?.alertEmails,
    });

    // CloudTrail trail feeding the bucket-config EventBridge rule. On by
    // default; disable when an org-wide trail already delivers these events.
    if (props?.enableAuditTrail !== false) {
      new BackupAudit(this, 'Audit', {
        bucket: bucket.bucket,
        includeS3DataEvents: props?.auditS3DataEvents,
      });
    }

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

    for (const [name, resources] of iam.clientResources) {
      new cdk.CfnOutput(this, `AccessKeyId-${name}`, {
        value: resources.credentialsSecret.secretArn,
        description:
          `Secrets Manager ARN holding the secret access key for client '${name}'. ` +
          `The AccessKeyId is in the secret's Description.`,
      });
    }
  }
}
