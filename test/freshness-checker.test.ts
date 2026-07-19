/**
 * Unit tests for the backup freshness-checker Lambda.
 *
 * Covers the input-validation surface (parseClients), the error-sanitizer
 * (safeError), and the handler's freshness math and — critically — its
 * behavior when one client's S3 listing fails: the other clients must still
 * get metrics, and the invocation must still fail so the Lambda-error alarm
 * fires. (Review finding #5.)
 */

const s3Send = jest.fn();
const ssmSend = jest.fn();
const cwSend = jest.fn();

jest.mock('@aws-sdk/client-s3', () => ({
  S3Client: class {
    send = s3Send;
  },
  ListObjectsV2Command: class {
    constructor(public readonly input: unknown) {}
  },
}));

jest.mock('@aws-sdk/client-ssm', () => ({
  SSMClient: class {
    send = ssmSend;
  },
  GetParameterCommand: class {
    constructor(public readonly input: unknown) {}
  },
}));

jest.mock('@aws-sdk/client-cloudwatch', () => ({
  CloudWatchClient: class {
    send = cwSend;
  },
  PutMetricDataCommand: class {
    constructor(public readonly input: { Namespace: string; MetricData: unknown[] }) {}
  },
}));

// Env must be set BEFORE the module loads — it calls parseClients at import
// time. Use require (not a hoisted `import`) so this assignment wins the race.
process.env.CLIENTS = JSON.stringify([
  { name: 'alpha', prefix: 'alpha/', thresholdHours: 24 },
  { name: 'bravo', prefix: 'bravo/', thresholdHours: 48 },
]);
process.env.BUCKET_NAME = 'test-bucket';
process.env.METRIC_NAMESPACE = 'Zuruck/Backup';

// eslint-disable-next-line @typescript-eslint/no-var-requires
const { handler, parseClients, safeError } = require('../lib/lambda/freshness-checker');

const HOUR_MS = 60 * 60 * 1000;

/** Flatten every MetricDatum published across all PutMetricData calls. */
function publishedMetrics(): Array<{ MetricName: string; Value: number; Dimensions: Array<{ Name: string; Value: string }> }> {
  return cwSend.mock.calls.flatMap((call) => (call[0] as { input: { MetricData: unknown[] } }).input.MetricData) as never;
}

function metricFor(name: string, client: string): number | undefined {
  const m = publishedMetrics().find(
    (d) => d.MetricName === name && d.Dimensions.some((dim) => dim.Name === 'Client' && dim.Value === client),
  );
  return m?.Value;
}

describe('parseClients', () => {
  test('throws when the env var is missing', () => {
    expect(() => parseClients(undefined)).toThrow(/missing/);
  });

  test('throws on invalid JSON', () => {
    expect(() => parseClients('{not json')).toThrow(/not valid JSON/);
  });

  test('throws when the payload is not an array', () => {
    expect(() => parseClients('{"name":"alpha"}')).toThrow(/must be a JSON array/);
  });

  test('throws on an invalid client name', () => {
    expect(() => parseClients(JSON.stringify([{ name: 'Bad Name', prefix: 'x/', thresholdHours: 24 }]))).toThrow(/name is missing or invalid/);
  });

  test('throws when prefix does not end with a slash', () => {
    expect(() => parseClients(JSON.stringify([{ name: 'alpha', prefix: 'alpha', thresholdHours: 24 }]))).toThrow(/does not end with/);
  });

  test('throws on a non-positive thresholdHours', () => {
    expect(() => parseClients(JSON.stringify([{ name: 'alpha', prefix: 'alpha/', thresholdHours: 0 }]))).toThrow(/positive number/);
  });

  test('returns a normalized array on valid input', () => {
    const result = parseClients(JSON.stringify([{ name: 'alpha', prefix: 'alpha/', thresholdHours: 12, extra: 'ignored' }]));
    expect(result).toEqual([{ name: 'alpha', prefix: 'alpha/', thresholdHours: 12 }]);
  });
});

describe('safeError', () => {
  test('extracts name and message from an Error', () => {
    const e = new Error('boom');
    e.name = 'AccessDenied';
    expect(safeError(e)).toMatchObject({ name: 'AccessDenied', message: 'boom' });
  });

  test('handles non-Error values without throwing', () => {
    expect(safeError('nope')).toEqual({ name: 'UnknownError', message: 'nope' });
  });
});

describe('freshness-checker handler', () => {
  beforeEach(() => {
    s3Send.mockReset();
    ssmSend.mockReset();
    cwSend.mockReset();
    ssmSend.mockResolvedValue({ Parameter: { Name: 'x' } });
    cwSend.mockResolvedValue({});
  });

  test('recent backups → BackupFreshness=1 for every client', async () => {
    s3Send.mockResolvedValue({ Contents: [{ LastModified: new Date(Date.now() - 1 * HOUR_MS) }] });

    await handler();

    expect(metricFor('BackupFreshness', 'alpha')).toBe(1);
    expect(metricFor('BackupFreshness', 'bravo')).toBe(1);
    expect(metricFor('BackupCheckFailed', 'alpha')).toBe(0);
  });

  test('old backups → BackupFreshness=0', async () => {
    // 100h ago exceeds both the 24h and 48h thresholds.
    s3Send.mockResolvedValue({ Contents: [{ LastModified: new Date(Date.now() - 100 * HOUR_MS) }] });

    await handler();

    expect(metricFor('BackupFreshness', 'alpha')).toBe(0);
    expect(metricFor('BackupFreshness', 'bravo')).toBe(0);
  });

  test('no objects → BackupsExist=0 and BackupFreshness=0', async () => {
    s3Send.mockResolvedValue({ Contents: [] });

    await handler();

    expect(metricFor('BackupsExist', 'alpha')).toBe(0);
    expect(metricFor('BackupFreshness', 'alpha')).toBe(0);
  });

  test('one client S3 failure: the other still gets metrics, and the invocation fails', async () => {
    // alpha (first) fails; bravo (second) succeeds.
    s3Send
      .mockRejectedValueOnce(Object.assign(new Error('denied'), { name: 'AccessDenied' }))
      .mockResolvedValueOnce({ Contents: [{ LastModified: new Date(Date.now() - 1 * HOUR_MS) }] });

    await expect(handler()).rejects.toThrow(/failed for 1 client\(s\): alpha/);

    // Metrics were published BEFORE the re-raise...
    expect(cwSend).toHaveBeenCalled();
    // ...bravo's real metrics are present...
    expect(metricFor('BackupFreshness', 'bravo')).toBe(1);
    // ...and alpha is flagged as failed rather than silently dropped.
    expect(metricFor('BackupCheckFailed', 'alpha')).toBe(1);
    // alpha, which we couldn't check, gets no BackupFreshness value (so
    // treatMissingData=BREACHING pages for it specifically).
    expect(metricFor('BackupFreshness', 'alpha')).toBeUndefined();
  });
});
