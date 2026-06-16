import * as cdk from 'aws-cdk-lib/core';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as kms from 'aws-cdk-lib/aws-kms';
import { Construct } from 'constructs';
import { ClientConfig } from '../config/clients';

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

export class BackupSecrets extends Construct {
  /**
   * Map of client name to secret resources.
   */
  public readonly clientSecrets: Map<string, ClientSecretResources> = new Map();

  constructor(scope: Construct, id: string, props: BackupSecretsProps) {
    super(scope, id);

    for (const client of props.clients) {
      const parameterName = `/zuruck/restic/${client.name}/master-password`;

      // IMPORTANT: CloudFormation's AWS::SSM::Parameter supports KeyId for SecureString,
      // but the CDK L2 construct (StringParameter) doesn't expose it.
      // We use CfnParameter (L1) with a type override to set the KMS key.
      const parameter = new ssm.CfnParameter(this, `MasterPassword-${client.name}`, {
        type: 'SecureString',
        value: `CHANGE-ME-${client.name}-restic-master-password`,
        description: `Restic master password for client '${client.name}' (${client.description})`,
        name: parameterName,
      });

      // Add the KeyId property via CloudFormation escape hatch.
      // CloudFormation supports KeyId on AWS::SSM::Parameter for SecureString types.
      // See: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-ssm-parameter.html
      parameter.addPropertyOverride('KeyId', props.encryptionKey.keyArn);

      // Tag for discoverability
      cdk.Tags.of(parameter).add('Purpose', 'restic-master-password');
      cdk.Tags.of(parameter).add('Client', client.name);

      this.clientSecrets.set(client.name, { parameterName });
    }
  }
}