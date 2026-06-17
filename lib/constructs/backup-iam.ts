import * as cdk from 'aws-cdk-lib/core';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';
import {
  ClientConfig,
  clientPrefix,
  clientMasterPasswordParameterName,
} from '../config/clients';

export interface BackupIamProps {
  readonly bucket: s3.Bucket;
  readonly encryptionKey: kms.Key;
  readonly clientGroup: iam.Group;
  readonly clients: ClientConfig[];
}

export interface ClientIamResources {
  readonly user: iam.User;
  readonly credentialsSecret: secretsmanager.Secret;
  readonly prefix: string;
}

/**
 * Per-client IAM users + scoped policies.
 *
 * Each user is tagged `Client=<name>` so the bucket's resource-policy
 * backstop in BackupBucket can use `${aws:PrincipalTag/Client}` to enforce
 * per-prefix isolation independently of the identity-based policy here.
 *
 * The S3 policy intentionally does NOT include `s3:DeleteObjectVersion`:
 * `restic forget --prune` only needs `s3:DeleteObject` on current versions;
 * granting DeleteObjectVersion to a long-lived client credential would let
 * a compromised client wipe its full version history. (Security-review S1.)
 */
export class BackupIam extends Construct {
  public readonly clientResources: Map<string, ClientIamResources> = new Map();

  constructor(scope: Construct, id: string, props: BackupIamProps) {
    super(scope, id);

    for (const client of props.clients) {
      const prefix = clientPrefix(client.name);
      const bucketArn = props.bucket.bucketArn;
      const objectArnPrefix = `${bucketArn}/${prefix}`;

      const user = new iam.User(this, `User-${client.name}`, {
        userName: `restic-${client.name}`,
        groups: [props.clientGroup],
      });
      // The bucket's resource-policy backstop matches on `${aws:PrincipalTag/Client}`.
      cdk.Tags.of(user).add('Client', client.name);
      cdk.Tags.of(user).add('Purpose', 'restic-backup-client');

      const s3Policy = new iam.Policy(this, `S3Policy-${client.name}`, {
        policyName: `restic-s3-${client.name}`,
        statements: [
          // s3:ListBucket is conditioned on the client's prefix. Note this
          // does not prevent prefix-name reconnaissance: a client can probe
          // for the existence of `bravo/` etc. (Security-review S9 —
          // accepted risk; documented in pr-review.md.)
          new iam.PolicyStatement({
            effect: iam.Effect.ALLOW,
            actions: ['s3:ListBucket'],
            resources: [bucketArn],
            conditions: {
              StringLike: { 's3:prefix': [`${prefix}*`] },
            },
          }),
          // CRUD on objects under their prefix. NO DeleteObjectVersion —
          // versioning soft-delete must survive a client compromise.
          // AbortMultipartUpload / ListMultipartUploadParts are required by
          // restic for files >100MB.
          new iam.PolicyStatement({
            effect: iam.Effect.ALLOW,
            actions: [
              's3:GetObject',
              's3:PutObject',
              's3:DeleteObject',
              's3:GetObjectVersion',
              's3:AbortMultipartUpload',
              's3:ListMultipartUploadParts',
            ],
            resources: [`${objectArnPrefix}*`],
          }),
          new iam.PolicyStatement({
            effect: iam.Effect.ALLOW,
            actions: ['s3:GetBucketLocation'],
            resources: [bucketArn],
          }),
        ],
      });
      s3Policy.attachToUser(user);

      const ssmPolicy = new iam.Policy(this, `SsmPolicy-${client.name}`, {
        policyName: `restic-ssm-${client.name}`,
        statements: [
          new iam.PolicyStatement({
            effect: iam.Effect.ALLOW,
            actions: ['ssm:GetParameter'],
            resources: [
              `arn:aws:ssm:${cdk.Aws.REGION}:${cdk.Aws.ACCOUNT_ID}:parameter${clientMasterPasswordParameterName(client.name)}`,
            ],
          }),
        ],
      });
      ssmPolicy.attachToUser(user);

      const accessKey = new iam.AccessKey(this, `AccessKey-${client.name}`, {
        user: user,
      });

      // Persist the access key to Secrets Manager rather than to a CFN
      // output. Stack outputs are readable by anyone with
      // `cloudformation:DescribeStacks`; Secrets Manager has its own ACL
      // surface and audit trail. We store only the SecretAccessKey as the
      // secret value — the AccessKeyId itself is not sensitive on its own
      // and lives in the secret's Description for easy lookup.
      const credentialsSecret = new secretsmanager.Secret(this, `Credentials-${client.name}`, {
        secretName: `zuruck/clients/${client.name}/access-key`,
        description:
          `IAM secret access key for restic client '${client.name}'. ` +
          `AccessKeyId=${accessKey.accessKeyId}. ` +
          `RotationCadenceDays=90. Rotate via the runbook.`,
        encryptionKey: props.encryptionKey,
        secretStringValue: accessKey.secretAccessKey,
      });
      cdk.Tags.of(credentialsSecret).add('Client', client.name);
      cdk.Tags.of(credentialsSecret).add('RotationCadenceDays', '90');

      this.clientResources.set(client.name, {
        user,
        credentialsSecret,
        prefix,
      });
    }
  }
}
