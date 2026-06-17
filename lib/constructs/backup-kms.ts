import * as cdk from 'aws-cdk-lib/core';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

export interface BackupKmsProps {
  /**
   * Description for the KMS key.
   */
  readonly description?: string;

  /**
   * IAM role ARNs allowed to administer the key (`kms:*`). When unset, the
   * key falls back to `AccountRootPrincipal` — fine for single-team accounts,
   * a footgun for shared ones. (Security-review finding S3.)
   */
  readonly adminRoleArns?: string[];
}

/**
 * KMS CMK for S3 SSE and SSM SecureString encryption, plus the IAM group used
 * for backup clients. The key policy is locked down so that:
 *  - Only named admin roles (or the account root, in fallback mode) can
 *    administer the key.
 *  - `ScheduleKeyDeletion` and `DisableKey` are explicitly denied to every
 *    principal that isn't an admin role — losing the key strands every backup.
 *  - Pending-deletion window is the maximum (30 days) so an accidental
 *    `ScheduleKeyDeletion` is recoverable.
 */
export class BackupKms extends Construct {
  public readonly key: kms.Key;
  public readonly clientGroup: iam.Group;

  constructor(scope: Construct, id: string, props?: BackupKmsProps) {
    super(scope, id);

    this.clientGroup = new iam.Group(this, 'ClientGroup', {
      groupName: 'restic-backup-clients',
    });

    const adminRoleArns = props?.adminRoleArns ?? [];
    const adminPrincipals: iam.IPrincipal[] = adminRoleArns.length > 0
      ? adminRoleArns.map(arn => new iam.ArnPrincipal(arn))
      : [new iam.AccountRootPrincipal()];

    const policy = new iam.PolicyDocument({
      statements: [
        // Admins get kms:*. In single-account mode this is the account root;
        // in scoped mode it's the explicit role list.
        new iam.PolicyStatement({
          sid: 'AllowAdmins',
          effect: iam.Effect.ALLOW,
          principals: adminPrincipals,
          actions: ['kms:*'],
          resources: ['*'],
        }),
      ],
    });

    // Belt-and-suspenders Deny on key-destroying actions for everyone who
    // isn't a configured admin. Even if some other identity-based policy
    // grants kms:ScheduleKeyDeletion, the explicit Deny here wins.
    if (adminRoleArns.length > 0) {
      policy.addStatements(
        new iam.PolicyStatement({
          sid: 'DenyDestructiveActionsToNonAdmins',
          effect: iam.Effect.DENY,
          principals: [new iam.AnyPrincipal()],
          actions: [
            'kms:ScheduleKeyDeletion',
            'kms:DisableKey',
            'kms:PutKeyPolicy',
          ],
          resources: ['*'],
          conditions: {
            StringNotEquals: { 'aws:PrincipalArn': adminRoleArns },
          },
        }),
      );
    }

    this.key = new kms.Key(this, 'Key', {
      description: props?.description ?? 'Restic S3 backup encryption key',
      enableKeyRotation: true,
      keyUsage: kms.KeyUsage.ENCRYPT_DECRYPT,
      keySpec: kms.KeySpec.SYMMETRIC_DEFAULT,
      // Maximum pending-deletion window — gives a 30-day grace period to
      // recover from an accidental ScheduleKeyDeletion before the key is
      // permanently gone.
      pendingWindow: cdk.Duration.days(30),
      policy,
    });

    // Identity-based grant for the client group (encrypt/decrypt only).
    this.key.grantEncryptDecrypt(this.clientGroup);
  }
}
