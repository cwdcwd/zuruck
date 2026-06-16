import { randomBytes } from 'node:crypto';
import {
  SSMClient,
  GetParameterCommand,
  PutParameterCommand,
  ParameterNotFound,
} from '@aws-sdk/client-ssm';

interface ResourceProperties {
  ParameterName: string;
  KeyArn: string;
  Description: string;
  ClientName: string;
}

interface CloudFormationCustomResourceEvent {
  RequestType: 'Create' | 'Update' | 'Delete';
  ResourceProperties: ResourceProperties & { ServiceToken: string };
  PhysicalResourceId?: string;
}

interface CloudFormationCustomResourceResponse {
  PhysicalResourceId: string;
  Data?: Record<string, string>;
}

const ssm = new SSMClient({});

/**
 * Custom-resource handler that provisions a one-time SSM SecureString holding
 * a randomly-generated master restic password. Idempotent: if the parameter
 * already exists (operator rotation, prior deploy) the existing value is left
 * untouched. Delete is a deliberate no-op — losing the master password
 * orphans every backup older than the local client password's lifetime.
 */
export const handler = async (
  event: CloudFormationCustomResourceEvent,
): Promise<CloudFormationCustomResourceResponse> => {
  const props = event.ResourceProperties;
  const physicalResourceId = props.ParameterName;

  if (event.RequestType === 'Delete') {
    return { PhysicalResourceId: physicalResourceId };
  }

  // Both Create and Update follow the same path: only put the parameter if
  // it doesn't already exist. Update is therefore safe across redeploys —
  // an operator who rotated the password via the runbook keeps their value.
  try {
    await ssm.send(new GetParameterCommand({
      Name: props.ParameterName,
      WithDecryption: false,
    }));
    console.log(`Parameter ${props.ParameterName} already exists — leaving untouched.`);
    return { PhysicalResourceId: physicalResourceId };
  } catch (err) {
    if (!(err instanceof ParameterNotFound) && (err as { name?: string }).name !== 'ParameterNotFound') {
      throw err;
    }
  }

  const value = `zk-${props.ClientName}-${randomBytes(32).toString('base64url')}`;
  await ssm.send(new PutParameterCommand({
    Name: props.ParameterName,
    Description: props.Description,
    Type: 'SecureString',
    KeyId: props.KeyArn,
    Value: value,
    Overwrite: false,
    Tags: [
      { Key: 'Purpose', Value: 'restic-master-password' },
      { Key: 'Client', Value: props.ClientName },
    ],
  }));

  console.log(`Provisioned new master password parameter for client ${props.ClientName}`);
  return { PhysicalResourceId: physicalResourceId };
};
