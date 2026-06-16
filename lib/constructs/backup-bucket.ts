import * as cdk from 'aws-cdk-lib/core';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as kms from 'aws-cdk-lib/aws-kms';
import { Construct } from 'constructs';

export interface BackupBucketProps {
  /**
   * The KMS key used for SSE-KMS encryption.
   */
  readonly encryptionKey: kms.Key;

  /**
   * The number of days before transitioning objects to Glacier Flexible Retrieval.
   * @default 90
   */
  readonly glacierTransitionDays?: number;

  /**
   * The number of days before transitioning objects to Glacier Deep Archive.
   * @default 365
   */
  readonly deepArchiveTransitionDays?: number;

  /**
   * The number of days before aborting incomplete multipart uploads.
   * @default 7
   */
  readonly abortIncompleteUploadsDays?: number;
}

export class BackupBucket extends Construct {
  /**
   * The S3 bucket for restic backups.
   */
  public readonly bucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: BackupBucketProps) {
    super(scope, id);

    const glacierDays = props.glacierTransitionDays ?? 90;
    const deepArchiveDays = props.deepArchiveTransitionDays ?? 365;
    const abortDays = props.abortIncompleteUploadsDays ?? 7;

    this.bucket = new s3.Bucket(this, 'Bucket', {
      bucketName: `zuruck-backup-${cdk.Aws.ACCOUNT_ID}-${cdk.Aws.REGION}`,
      versioned: true,
      encryption: s3.BucketEncryption.KMS,
      encryptionKey: props.encryptionKey,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      lifecycleRules: [
        // Transition to Glacier Flexible Retrieval
        {
          transitions: [
            {
              storageClass: s3.StorageClass.GLACIER,
              transitionAfter: cdk.Duration.days(glacierDays),
            },
          ],
        },
        // Transition to Glacier Deep Archive
        {
          transitions: [
            {
              storageClass: s3.StorageClass.DEEP_ARCHIVE,
              transitionAfter: cdk.Duration.days(deepArchiveDays),
            },
          ],
        },
        // Clean up deleted markers and incomplete uploads
        {
          expiredObjectDeleteMarker: true,
          noncurrentVersionExpiration: cdk.Duration.days(1),
          abortIncompleteMultipartUploadAfter: cdk.Duration.days(abortDays),
        },
      ],
      // Removal policy: RETAIN — never delete the backup bucket
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // Tag the bucket for easy identification
    cdk.Tags.of(this.bucket).add('Purpose', 'restic-backup');
    cdk.Tags.of(this.bucket).add('ManagedBy', 'cdk');
  }
}