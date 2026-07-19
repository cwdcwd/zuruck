import * as cdk from 'aws-cdk-lib/core';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as cloudtrail from 'aws-cdk-lib/aws-cloudtrail';
import { Construct } from 'constructs';

export interface BackupAuditProps {
  /**
   * The backup bucket whose object-level events should be captured when
   * `includeS3DataEvents` is set.
   */
  readonly bucket: s3.Bucket;

  /**
   * Also record S3 **data events** (object-level `PutObject`/`DeleteObject`)
   * for the backup bucket. Off by default because data events are billed per
   * event and restic writes/deletes objects on every backup+prune cycle. Turn
   * this on when you want a forensic object-level audit trail (queryable via
   * Athena) — not for alerting, which would page on every legitimate prune.
   *
   * @default false
   */
  readonly includeS3DataEvents?: boolean;

  /**
   * Days to retain CloudTrail log objects before lifecycle expiry.
   * @default 400
   */
  readonly logRetentionDays?: number;
}

/**
 * CloudTrail trail that makes the monitoring stack's bucket-config EventBridge
 * rule actually functional.
 *
 * The `zuruck-bucket-config-changes` rule in BackupMonitoring matches
 * `"AWS API Call via CloudTrail"` events (DeleteBucket, PutBucketPolicy, …).
 * Those only reach the default EventBridge bus if a CloudTrail trail in this
 * account+region is logging management events. Without a trail the rule is
 * silently inert — the security control never fires. (Review finding #4.)
 *
 * This creates a dedicated, single-region trail logging management **write**
 * events to a private, retained, lifecycle-managed log bucket. Accounts that
 * already run an org-wide trail should disable this via
 * `-c enableAuditTrail=false` to avoid paying for a duplicate.
 */
export class BackupAudit extends Construct {
  public readonly trail: cloudtrail.Trail;
  public readonly logBucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: BackupAuditProps) {
    super(scope, id);

    const retentionDays = props.logRetentionDays ?? 400;

    this.logBucket = new s3.Bucket(this, 'AuditLogBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      // SSE-S3 (not the project CMK): CloudTrail log delivery would otherwise
      // need GenerateDataKey on the CMK, and this key's policy deliberately
      // grants kms:* only to admins. Keeping audit logs on S3-managed keys
      // avoids widening the CMK policy for a service principal.
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      lifecycleRules: [
        {
          expiration: cdk.Duration.days(retentionDays),
          abortIncompleteMultipartUploadAfter: cdk.Duration.days(7),
        },
      ],
    });

    this.trail = new cloudtrail.Trail(this, 'Trail', {
      trailName: 'zuruck-audit',
      bucket: this.logBucket,
      // Scope to this stack's region — additive to any existing org trail and
      // cheaper than multi-region for a single-region backend.
      isMultiRegionTrail: false,
      includeGlobalServiceEvents: false,
      // Write events are the ones that mutate/delete the bucket; reads add
      // volume and cost without helping the config-change detection.
      managementEvents: cloudtrail.ReadWriteType.WRITE_ONLY,
    });

    if (props.includeS3DataEvents) {
      this.trail.addS3EventSelector(
        [{ bucket: props.bucket }],
        { readWriteType: cloudtrail.ReadWriteType.WRITE_ONLY },
      );
    }

    cdk.Tags.of(this.logBucket).add('Purpose', 'restic-backup-audit');
    cdk.Tags.of(this.logBucket).add('ManagedBy', 'cdk');
  }
}
