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
  /**
   * The S3 bucket that clients will back up to.
   */
  readonly bucket: s3.Bucket;

  /**
   * The KMS key used for S3 encryption.
   */
  readonly encryptionKey: kms.Key;

  /**
   * The IAM group that backup client users belong to.
   */
  readonly clientGroup: iam.Group;

  /**
   * Client configurations.
   */
  readonly clients: ClientConfig[];
}

export interface ClientIamResources {
  /**
   * The IAM user for this client.
   */
  readonly user: iam.User;

  /**
   * Secrets Manager secret holding the client's access key id and secret in
   * the form `{"AccessKeyId":"...","SecretAccessKey":"..."}`. The secret
   * itself is the only sanctioned channel for retrieving the secret access
   * key — never via stack outputs.
   */
  readonly credentialsSecret: secretsmanager.Secret;

  /**
   * The S3 prefix for this client (e.g., "alpha/").
   */
  readonly prefix: string;
}

export class BackupIam extends Construct {
  /**
   * Map of client name to IAM resources.
   */
  public readonly clientResources: Map<string, ClientIamResources> = new Map();

  constructor(scope: Construct, id: string, props: BackupIamProps) {
    super(scope, id);

    for (const client of props.clients) {
      const prefix = clientPrefix(client.name);
      const bucketArn = props.bucket.bucketArn;
      const objectArnPrefix = `${bucketArn}/${prefix}`;

      // Create IAM user for this client
      const user = new iam.User(this, `User-${client.name}`, {
        userName: `restic-${client.name}`,
        groups: [props.clientGroup],
      });

      // S3 policy: scoped to this client's prefix only.
      const s3Policy = new iam.Policy(this, `S3Policy-${client.name}`, {
        policyName: `restic-s3-${client.name}`,
        statements: [
          new iam.PolicyStatement({
            effect: iam.Effect.ALLOW,
            actions: ['s3:ListBucket'],
            resources: [bucketArn],
            conditions: {
              StringLike: {
                's3:prefix': [prefix, `${prefix}*`],
              },
            },
          }),
          // CRUD on objects under their prefix. AbortMultipartUpload and
          // ListMultipartUploadParts are required by restic for files >100MB
          // — without them large uploads fail mid-stream and leak parts that
          // only the bucket lifecycle eventually reaps.
          new iam.PolicyStatement({
            effect: iam.Effect.ALLOW,
            actions: [
              's3:GetObject',
              's3:PutObject',
              's3:DeleteObject',
              's3:GetObjectVersion',
              's3:DeleteObjectVersion',
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

      // SSM policy: allow reading their own master password parameter.
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

      // Persist the access key into Secrets Manager rather than a CFN output.
      // Stack outputs land in the CloudFormation template (asset-staged to
      // S3) and in any process that prints them, so anyone with
      // `cloudformation:DescribeStacks` would read the secret access key.
      // We store only the SecretAccessKey in the secret value (the AccessKeyId
      // is not sensitive on its own) and pass the intrinsic directly so the
      // value is never materialized into the synthesized template.
      const credentialsSecret = new secretsmanager.Secret(this, `Credentials-${client.name}`, {
        secretName: `zuruck/clients/${client.name}/access-key`,
        description:
          `IAM secret access key for restic client '${client.name}'. ` +
          `AccessKeyId=${accessKey.accessKeyId}. Rotate via the runbook.`,
        encryptionKey: props.encryptionKey,
        secretStringValue: accessKey.secretAccessKey,
      });

      this.clientResources.set(client.name, {
        user,
        credentialsSecret,
        prefix,
      });
    }
  }
}
