import * as cdk from 'aws-cdk-lib/core';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as kms from 'aws-cdk-lib/aws-kms';
import { Construct } from 'constructs';
import { ClientConfig } from '../config/clients';

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
   * The access key for this client's IAM user.
   */
  readonly accessKey: iam.AccessKey;

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
      const prefix = `${client.name}/`;

      // Create IAM user for this client
      const user = new iam.User(this, `User-${client.name}`, {
        userName: `restic-${client.name}`,
        groups: [props.clientGroup],
      });

      // S3 policy: scoped to this client's prefix only
      // restic needs: GetObject, PutObject, DeleteObject, ListBucket, GetBucketLocation
      const s3Policy = new iam.Policy(this, `S3Policy-${client.name}`, {
        policyName: `restic-s3-${client.name}`,
        statements: [
          // Allow listing objects in the bucket (only under their prefix)
          new iam.PolicyStatement({
            effect: iam.Effect.ALLOW,
            actions: ['s3:ListBucket'],
            resources: [props.bucket.bucketArn],
            conditions: {
              StringLike: {
                's3:prefix': [prefix, `${prefix}*`],
              },
            },
          }),
          // Allow CRUD on objects under their prefix
          new iam.PolicyStatement({
            effect: iam.Effect.ALLOW,
            actions: [
              's3:GetObject',
              's3:PutObject',
              's3:DeleteObject',
              's3:GetObjectVersion',
              's3:DeleteObjectVersion',
            ],
            resources: [`${props.bucket.bucketArn}/${prefix}*`],
          }),
          // Allow getting bucket location (needed by restic)
          new iam.PolicyStatement({
            effect: iam.Effect.ALLOW,
            actions: ['s3:GetBucketLocation'],
            resources: [props.bucket.bucketArn],
          }),
        ],
      });
      s3Policy.attachToUser(user);

      // SSM policy: allow reading their own master password parameter
      const ssmPolicy = new iam.Policy(this, `SsmPolicy-${client.name}`, {
        policyName: `restic-ssm-${client.name}`,
        statements: [
          new iam.PolicyStatement({
            effect: iam.Effect.ALLOW,
            actions: ['ssm:GetParameter'],
            resources: [
              `arn:aws:ssm:${cdk.Aws.REGION}:${cdk.Aws.ACCOUNT_ID}:parameter/zuruck/restic/${client.name}/master-password`,
            ],
          }),
        ],
      });
      ssmPolicy.attachToUser(user);

      // Create access key for programmatic access
      const accessKey = new iam.AccessKey(this, `AccessKey-${client.name}`, {
        user: user,
      });

      this.clientResources.set(client.name, {
        user,
        accessKey,
        prefix,
      });
    }
  }
}