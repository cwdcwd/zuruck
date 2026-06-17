import * as cdk from 'aws-cdk-lib/core';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as iam from 'aws-cdk-lib/aws-iam';
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

  /**
   * The number of days to retain noncurrent object versions before expiry.
   * @default 90
   */
  readonly noncurrentVersionRetentionDays?: number;

  /**
   * Object Lock default retention (Governance mode) in days. **Object Lock
   * can only be enabled at bucket creation time** — flipping this on an
   * existing deployment requires manually recreating the bucket. New
   * deployments should set this to 30+. (Security-review finding S2.)
   *
   * Trade-off: with Object Lock active, `restic forget --prune` will fail
   * with `403` on objects still inside the lock window. Operators should
   * run `restic forget --keep-…` (no `--prune`) during the lock window, and
   * `restic prune` only after objects age past it. See [docs/runbook.md].
   *
   * @default 0 (Object Lock disabled — opt in via `-c objectLockRetentionDays=30`)
   */
  readonly objectLockRetentionDays?: number;
}

/**
 * S3 bucket for restic backups.
 *
 * Hardening:
 *  - SSE-KMS with the project CMK
 *  - Versioning + 90-day noncurrent retention
 *  - Optional Object Lock (Governance, opt-in via stack context) so a
 *    compromised client credential cannot wipe history within the lock window.
 *  - Public access block, enforceSSL
 *  - RemovalPolicy.RETAIN
 *  - Resource-policy backstop: each `restic-*` IAM user is denied access to
 *    any object outside `${aws:PrincipalTag/Client}/*` (Security-review S7).
 *    The IAM construct sets the `Client` tag on each user so this policy
 *    enforces per-prefix isolation even if the identity-based policy is
 *    misconfigured.
 */
export class BackupBucket extends Construct {
  public readonly bucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: BackupBucketProps) {
    super(scope, id);

    const glacierDays = props.glacierTransitionDays ?? 90;
    const deepArchiveDays = props.deepArchiveTransitionDays ?? 365;
    const abortDays = props.abortIncompleteUploadsDays ?? 7;
    const noncurrentDays = props.noncurrentVersionRetentionDays ?? 90;
    const objectLockDays = props.objectLockRetentionDays ?? 0;

    this.bucket = new s3.Bucket(this, 'Bucket', {
      bucketName: `zuruck-backup-${cdk.Aws.ACCOUNT_ID}-${cdk.Aws.REGION}`,
      versioned: true,
      encryption: s3.BucketEncryption.KMS,
      encryptionKey: props.encryptionKey,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      objectLockEnabled: objectLockDays > 0,
      objectLockDefaultRetention: objectLockDays > 0
        ? s3.ObjectLockRetention.governance(cdk.Duration.days(objectLockDays))
        : undefined,
      lifecycleRules: [
        {
          transitions: [
            {
              storageClass: s3.StorageClass.GLACIER,
              transitionAfter: cdk.Duration.days(glacierDays),
            },
          ],
        },
        {
          transitions: [
            {
              storageClass: s3.StorageClass.DEEP_ARCHIVE,
              transitionAfter: cdk.Duration.days(deepArchiveDays),
            },
          ],
        },
        {
          expiredObjectDeleteMarker: true,
          noncurrentVersionExpiration: cdk.Duration.days(noncurrentDays),
          abortIncompleteMultipartUploadAfter: cdk.Duration.days(abortDays),
        },
      ],
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // Resource-policy backstop. For any IAM user whose ARN matches
    // `restic-*`, deny any S3 action whose resource is not the bucket itself
    // or the user's own `${aws:PrincipalTag/Client}/*` subtree. If the
    // principal has no `Client` tag the variable expands to nothing and the
    // NotResource list collapses to just the bucket ARN — every object
    // operation is denied, which is the safe default.
    //
    // Note: NotResource + Deny is the canonical "if you're a restic user, you
    // may only touch your own prefix" pattern. The identity-based policy
    // (BackupIam) is still the primary control; this is belt + suspenders.
    this.bucket.addToResourcePolicy(new iam.PolicyStatement({
      sid: 'DenyCrossClientPrefixAccess',
      effect: iam.Effect.DENY,
      principals: [new iam.AnyPrincipal()],
      actions: ['s3:*'],
      notResources: [
        this.bucket.bucketArn,
        `${this.bucket.bucketArn}/\${aws:PrincipalTag/Client}/*`,
      ],
      conditions: {
        StringLike: {
          'aws:PrincipalArn': `arn:aws:iam::${cdk.Aws.ACCOUNT_ID}:user/restic-*`,
        },
      },
    }));

    cdk.Tags.of(this.bucket).add('Purpose', 'restic-backup');
    cdk.Tags.of(this.bucket).add('ManagedBy', 'cdk');
  }
}
