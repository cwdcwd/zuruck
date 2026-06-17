/**
 * Unit tests for the master-password provisioner Lambda.
 *
 * The single most important behavior is idempotency: a second `cdk deploy`
 * (CFN Update event) must not overwrite an operator-rotated parameter.
 * (Security-review I2.)
 */

const sendMock = jest.fn();

jest.mock('@aws-sdk/client-ssm', () => {
  class FakeError extends Error {
    constructor(name: string, message: string) {
      super(message);
      this.name = name;
    }
  }
  class ParameterNotFound extends FakeError {
    constructor(message = 'parameter not found') {
      super('ParameterNotFound', message);
    }
  }
  return {
    SSMClient: class {
      send = sendMock;
    },
    GetParameterCommand: class {
      readonly __type = 'GetParameter';
      constructor(public readonly input: unknown) {}
    },
    PutParameterCommand: class {
      readonly __type = 'PutParameter';
      constructor(public readonly input: unknown) {}
    },
    ParameterNotFound,
  };
});

// Import after the mock is registered.
import { handler } from '../lib/lambda/master-password-provisioner';

const baseEvent = {
  ResourceProperties: {
    ServiceToken: 'arn:aws:lambda:...',
    ParameterName: '/zuruck/restic/alpha/master-password',
    KeyArn: 'arn:aws:kms:us-west-2:123:key/abc',
    Description: 'Restic master password for client alpha',
    ClientName: 'alpha',
  },
};

describe('master-password-provisioner', () => {
  beforeEach(() => sendMock.mockReset());

  test('Create: parameter does not exist → PutParameter is called', async () => {
    sendMock
      .mockImplementationOnce(() => Promise.reject(Object.assign(new Error('not found'), { name: 'ParameterNotFound' })))
      .mockResolvedValueOnce({});

    const result = await handler({ ...baseEvent, RequestType: 'Create' } as never);

    expect(result.PhysicalResourceId).toBe('/zuruck/restic/alpha/master-password');
    expect(sendMock).toHaveBeenCalledTimes(2);

    const put = sendMock.mock.calls[1][0] as { __type: string; input: { Name: string; Type: string; Overwrite: boolean; Value: string } };
    expect(put.__type).toBe('PutParameter');
    expect(put.input.Type).toBe('SecureString');
    expect(put.input.Overwrite).toBe(false);
    // The token shape: zk-<client>-<base64url>. We don't check entropy
    // properties; we check the prefix is right and the suffix is non-trivial.
    expect(put.input.Value).toMatch(/^zk-alpha-[A-Za-z0-9_-]{20,}$/);
  });

  test('Update: parameter already exists → PutParameter is NOT called (idempotency)', async () => {
    sendMock.mockResolvedValueOnce({ Parameter: { Name: baseEvent.ResourceProperties.ParameterName } });

    const result = await handler({ ...baseEvent, RequestType: 'Update' } as never);

    expect(result.PhysicalResourceId).toBe('/zuruck/restic/alpha/master-password');
    expect(sendMock).toHaveBeenCalledTimes(1);
    const cmd = sendMock.mock.calls[0][0] as { __type: string };
    expect(cmd.__type).toBe('GetParameter');
    // Crucial: no PutParameter call, so an operator-rotated value is preserved.
    const types = sendMock.mock.calls.map(c => (c[0] as { __type: string }).__type);
    expect(types).not.toContain('PutParameter');
  });

  test('Delete: no SSM calls; parameter is RETAINed', async () => {
    const result = await handler({ ...baseEvent, RequestType: 'Delete' } as never);
    expect(result.PhysicalResourceId).toBe('/zuruck/restic/alpha/master-password');
    expect(sendMock).not.toHaveBeenCalled();
  });

  test('Create: GetParameter succeeds (already exists) → PutParameter is NOT called', async () => {
    sendMock.mockResolvedValueOnce({ Parameter: { Name: baseEvent.ResourceProperties.ParameterName } });

    await handler({ ...baseEvent, RequestType: 'Create' } as never);

    expect(sendMock).toHaveBeenCalledTimes(1);
    const types = sendMock.mock.calls.map(c => (c[0] as { __type: string }).__type);
    expect(types).not.toContain('PutParameter');
  });
});
