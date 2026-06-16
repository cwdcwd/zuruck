import * as kms from 'aws-cdk-lib/aws-kms';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

export interface BackupKmsProps {
  /**
   * Description for the KMS key.
   */
  readonly description?: string;
}

export class BackupKms extends Construct {
  /**
   * The KMS key used for S3 SSE and SSM parameter encryption.
   */
  public readonly key: kms.Key;

  /**
   * The IAM group that backup client users belong to.
   * Granted encrypt/decrypt permissions on the key.
   */
  public readonly clientGroup: iam.Group;

  constructor(scope: Construct, id: string, props?: BackupKmsProps) {
    super(scope, id);

    // Create the IAM group for backup clients first (needed for key policy)
    this.clientGroup = new iam.Group(this, 'ClientGroup', {
      groupName: 'restic-backup-clients',
    });

    // Customer-managed KMS key for S3 SSE and SSM parameter encryption.
    // Note: IAM Groups cannot be used as principals in resource-based policies,
    // so we use the account root as principal and rely on identity-based
    // policies (attached to the group) for granting access.
    //
    // The account root principal in the key policy is standard practice but
    // effectively grants kms:* to any principal in the account that can assume
    // a role. For tighter control, replace AccountRootPrincipal with specific
    // admin role ARNs. The current policy is acceptable for single-account
    // deployments where the backup operator is the account admin.
    this.key = new kms.Key(this, 'Key', {
      description: props?.description ?? 'Restic S3 backup encryption key',
      enableKeyRotation: true,
      keyUsage: kms.KeyUsage.ENCRYPT_DECRYPT,
      keySpec: kms.KeySpec.SYMMETRIC_DEFAULT,
      policy: new iam.PolicyDocument({
        statements: [
          // Allow the account root to administer the key.
          // SECURITY: This grants kms:* to any principal in the account that
          // has identity-based KMS permissions. For multi-team accounts,
          // replace AccountRootPrincipal with specific admin role ARNs.
          new iam.PolicyStatement({
            effect: iam.Effect.ALLOW,
            principals: [new iam.AccountRootPrincipal()],
            actions: ['kms:*'],
            resources: ['*'],
          }),
        ],
      }),
    });

    // Grant the client group encrypt/decrypt on the key via identity-based policy.
    // This adds the necessary IAM permissions to the group.
    this.key.grantEncryptDecrypt(this.clientGroup);
  }
}