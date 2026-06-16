import * as cdk from 'aws-cdk-lib/core';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as lambdaNodejs from 'aws-cdk-lib/aws-lambda-nodejs';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as customResources from 'aws-cdk-lib/custom-resources';
import { Construct } from 'constructs';
import {
  ClientConfig,
  clientMasterPasswordParameterName,
} from '../config/clients';

export interface BackupSecretsProps {
  /**
   * The KMS key used to encrypt SSM parameters.
   */
  readonly encryptionKey: kms.Key;

  /**
   * Client configurations.
   */
  readonly clients: ClientConfig[];
}

export interface ClientSecretResources {
  /**
   * The SSM parameter name holding the master restic password for this client.
   */
  readonly parameterName: string;
}

/**
 * Provisions per-client SSM SecureString parameters holding the master restic
 * password. The password is generated server-side in a Lambda — never present
 * in the synthesized CloudFormation template — and is left untouched on
 * every subsequent `cdk deploy` so operator-driven rotations survive.
 *
 * Parameters are RETAINed: losing them strands every archived backup older
 * than the local client password's lifetime.
 */
export class BackupSecrets extends Construct {
  public readonly clientSecrets: Map<string, ClientSecretResources> = new Map();

  constructor(scope: Construct, id: string, props: BackupSecretsProps) {
    super(scope, id);

    const onEventLogGroup = new logs.LogGroup(this, 'PasswordProvisionerLogs', {
      retention: logs.RetentionDays.THREE_MONTHS,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const onEventHandler = new lambdaNodejs.NodejsFunction(this, 'PasswordProvisionerFn', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'handler',
      entry: `${__dirname}/../lambda/master-password-provisioner.ts`,
      timeout: cdk.Duration.minutes(2),
      logGroup: onEventLogGroup,
      bundling: {
        minify: true,
        sourceMap: true,
      },
    });

    onEventHandler.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'ssm:GetParameter',
        'ssm:PutParameter',
        'ssm:AddTagsToResource',
      ],
      resources: [
        `arn:aws:ssm:${cdk.Aws.REGION}:${cdk.Aws.ACCOUNT_ID}:parameter/zuruck/restic/*`,
      ],
    }));

    onEventHandler.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['kms:Encrypt', 'kms:GenerateDataKey', 'kms:Decrypt'],
      resources: [props.encryptionKey.keyArn],
    }));

    const provider = new customResources.Provider(this, 'PasswordProvider', {
      onEventHandler,
    });

    for (const client of props.clients) {
      const parameterName = clientMasterPasswordParameterName(client.name);

      const resource = new cdk.CustomResource(this, `MasterPassword-${client.name}`, {
        serviceToken: provider.serviceToken,
        resourceType: 'Custom::ZuruckMasterPassword',
        properties: {
          ParameterName: parameterName,
          KeyArn: props.encryptionKey.keyArn,
          Description: `Restic master password for client '${client.name}' (${client.description})`,
          ClientName: client.name,
        },
      });

      // Hard guarantee: never let CloudFormation delete a master-password
      // parameter as a side-effect of stack delete or a logical-id rename.
      resource.applyRemovalPolicy(cdk.RemovalPolicy.RETAIN);

      this.clientSecrets.set(client.name, { parameterName });
    }
  }
}
