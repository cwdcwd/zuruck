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
 *  - When scoped admin roles are supplied (`adminRoleArns`), `ScheduleKeyDeletion`
 *    and `DisableKey` are explicitly denied to every principal that isn't one of
 *    those roles — losing the key strands every backup. In the default
 *    (account-root) mode no such Deny is added; the account root retains full
 *    `kms:*`.
 *  - `PutKeyPolicy` is likewise denied to non-admins, BUT the account root is
 *    always exempted from that particular Deny. Freezing the key policy against
 *    every principal (including root) would make it permanently unrepairable if
 *    the admin roles were ever deleted or renamed — a classic KMS lockout. Root
 *    keeps PutKeyPolicy as break-glass.
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
      const accountRootArn = `arn:aws:iam::${cdk.Aws.ACCOUNT_ID}:root`;

      policy.addStatements(
        // Irreversible key-loss actions: denied to everyone but the scoped
        // admin roles. Root is intentionally NOT exempted here — accidental
        // `ScheduleKeyDeletion` by a broad admin is exactly what we're guarding
        // against, and the 30-day pending window plus these roles are enough to
        // recover.
        new iam.PolicyStatement({
          sid: 'DenyDestructiveActionsToNonAdmins',
          effect: iam.Effect.DENY,
          principals: [new iam.AnyPrincipal()],
          actions: [
            'kms:ScheduleKeyDeletion',
            'kms:DisableKey',
          ],
          resources: ['*'],
          conditions: {
            StringNotEquals: { 'aws:PrincipalArn': adminRoleArns },
          },
        }),
        // Policy mutation: denied to non-admins, but the account ROOT is always
        // exempt. Denying PutKeyPolicy to every principal including root would
        // permanently freeze this policy if the admin roles were ever deleted
        // or renamed — an unrecoverable KMS lockout. Root keeps PutKeyPolicy as
        // break-glass so the key is always governable. (Review finding #3.)
        new iam.PolicyStatement({
          sid: 'DenyKeyPolicyChangesToNonAdmins',
          effect: iam.Effect.DENY,
          principals: [new iam.AnyPrincipal()],
          actions: ['kms:PutKeyPolicy'],
          resources: ['*'],
          conditions: {
            StringNotEquals: {
              'aws:PrincipalArn': [...adminRoleArns, accountRootArn],
            },
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
