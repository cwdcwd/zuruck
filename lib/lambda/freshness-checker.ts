import { S3Client, ListObjectsV2Command } from '@aws-sdk/client-s3';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { CloudWatchClient, PutMetricDataCommand, MetricDatum } from '@aws-sdk/client-cloudwatch';

interface ClientConfig {
  name: string;
  prefix: string;
  thresholdHours: number;
}

// SDK v3 retries with exponential backoff up to 3 attempts by default —
// adequate for S3 throttling protection on a once-per-hour invocation.
const s3 = new S3Client({ maxAttempts: 3 });
const ssm = new SSMClient({ maxAttempts: 3 });
const cw = new CloudWatchClient({ maxAttempts: 3 });

// Timeout guard: Lambda has a 5-minute hard limit. We bail out 30 seconds
// early so we can still flush whatever metrics we've collected so far.
const TIMEOUT_MARGIN_MS = 30_000;
const LAMBDA_TIMEOUT_MS = 5 * 60 * 1000;

const CLIENT_NAME_PATTERN = /^[a-z][a-z0-9-]{1,32}$/;

/**
 * Validate the CLIENTS env var at cold-start time. A schema mismatch fails
 * the cold start once and then the Lambda-error alarm pages the operator —
 * which is much louder than the previous behaviour, where a malformed env
 * var crashed every invocation silently.
 *
 * (Security-review finding I4.)
 */
export function parseClients(raw: string | undefined): ClientConfig[] {
  if (!raw) {
    throw new Error('CLIENTS env var is missing');
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new Error(`CLIENTS env var is not valid JSON: ${(err as Error).message}`);
  }
  if (!Array.isArray(parsed)) {
    throw new Error('CLIENTS env var must be a JSON array');
  }
  return parsed.map((entry, i) => {
    if (typeof entry !== 'object' || entry === null) {
      throw new Error(`CLIENTS[${i}] is not an object`);
    }
    const obj = entry as Record<string, unknown>;
    if (typeof obj.name !== 'string' || !CLIENT_NAME_PATTERN.test(obj.name)) {
      throw new Error(`CLIENTS[${i}].name is missing or invalid`);
    }
    if (typeof obj.prefix !== 'string' || !obj.prefix.endsWith('/')) {
      throw new Error(`CLIENTS[${i}].prefix is missing or does not end with '/'`);
    }
    if (typeof obj.thresholdHours !== 'number' || obj.thresholdHours <= 0) {
      throw new Error(`CLIENTS[${i}].thresholdHours must be a positive number`);
    }
    return {
      name: obj.name,
      prefix: obj.prefix,
      thresholdHours: obj.thresholdHours,
    };
  });
}

/**
 * Trim an SDK error to the bits that are safe to log. We deliberately do NOT
 * include the SDK's `$metadata` body or the request envelope — for SSM
 * SecureString errors that body can include the parameter name, and a
 * future logging diff that started serializing it would leak the master
 * password. (Security-review S4.)
 */
export function safeError(err: unknown): { name: string; message: string; code?: string } {
  if (err instanceof Error) {
    const codeful = err as Error & { name?: string; $metadata?: { httpStatusCode?: number } };
    return {
      name: codeful.name ?? 'Error',
      message: codeful.message ?? '',
      code: (err as { Code?: string }).Code,
    };
  }
  return { name: 'UnknownError', message: String(err) };
}

const clientsAtStartup = parseClients(process.env.CLIENTS);

export const handler = async (): Promise<void> => {
  const bucketName = process.env.BUCKET_NAME!;
  const namespace = process.env.METRIC_NAMESPACE ?? 'Zuruck/Backup';
  const clients = clientsAtStartup;
  const now = Date.now();
  const deadline = now + LAMBDA_TIMEOUT_MS - TIMEOUT_MARGIN_MS;

  const metricData: MetricDatum[] = [];
  const stamp = new Date();
  const dimsFor = (clientName: string) => [{ Name: 'Client', Value: clientName }];

  // Collect per-client failures instead of aborting the whole run. A single
  // client's S3 error must not blind every other client's metrics for the
  // cycle. We publish everything we gathered, then re-raise at the end so the
  // Lambda-error alarm still fires on systemic problems. (Review finding #5.)
  const failedClients: string[] = [];

  for (const client of clients) {
    if (Date.now() > deadline) {
      console.warn(
        `Approaching Lambda timeout — skipping remaining clients after ${client.name}.`,
      );
      break;
    }

    console.log(`Checking freshness for client: ${client.name}`);

    let latestTimestamp = 0;
    let objectCount = 0;
    try {
      let continuationToken: string | undefined;
      do {
        if (Date.now() > deadline) {
          console.warn(
            `Timeout during pagination for ${client.name} — publishing partial objectCount=${objectCount}`,
          );
          break;
        }

        const response = await s3.send(new ListObjectsV2Command({
          Bucket: bucketName,
          Prefix: client.prefix,
          ContinuationToken: continuationToken,
        }));

        for (const obj of response.Contents ?? []) {
          if (obj.LastModified) {
            const ts = obj.LastModified.getTime();
            if (ts > latestTimestamp) latestTimestamp = ts;
          }
          objectCount++;
        }

        continuationToken = response.NextContinuationToken;
      } while (continuationToken);
    } catch (err) {
      // Record the failure, emit a signal for this client, and move on to the
      // next one. We deliberately do NOT publish a BackupFreshness metric for a
      // client we couldn't check — leaving it absent lets treatMissingData=
      // BREACHING page for that client specifically, while the others still get
      // accurate metrics.
      console.error(`S3 list failed for ${client.name}:`, safeError(err));
      failedClients.push(client.name);
      metricData.push({
        MetricName: 'BackupCheckFailed',
        Dimensions: dimsFor(client.name),
        Value: 1,
        Unit: 'None',
        Timestamp: stamp,
      });
      continue;
    }

    metricData.push({
      MetricName: 'BackupCheckFailed',
      Dimensions: dimsFor(client.name),
      Value: 0,
      Unit: 'None',
      Timestamp: stamp,
    });

    const backupsExist = objectCount > 0;
    metricData.push({
      MetricName: 'BackupsExist',
      Dimensions: dimsFor(client.name),
      Value: backupsExist ? 1 : 0,
      Unit: 'None',
      Timestamp: stamp,
    });
    metricData.push({
      MetricName: 'ObjectCount',
      Dimensions: dimsFor(client.name),
      Value: objectCount,
      Unit: 'Count',
      Timestamp: stamp,
    });

    if (backupsExist) {
      const hoursSinceLastBackup = (now - latestTimestamp) / (1000 * 60 * 60);
      const isFresh = hoursSinceLastBackup <= client.thresholdHours ? 1 : 0;
      metricData.push({
        MetricName: 'BackupFreshness',
        Dimensions: dimsFor(client.name),
        Value: isFresh,
        Unit: 'None',
        Timestamp: stamp,
      });
      metricData.push({
        MetricName: 'HoursSinceLastBackup',
        Dimensions: dimsFor(client.name),
        Value: Math.round(hoursSinceLastBackup * 100) / 100,
        Unit: 'None',
        Timestamp: stamp,
      });
      console.log(
        `Client ${client.name}: hoursSinceLastBackup=${hoursSinceLastBackup.toFixed(2)}, ` +
          `isFresh=${isFresh}, objectCount=${objectCount}`,
      );
    } else {
      metricData.push({
        MetricName: 'BackupFreshness',
        Dimensions: dimsFor(client.name),
        Value: 0,
        Unit: 'None',
        Timestamp: stamp,
      });
      console.log(`Client ${client.name}: no backups found yet (objectCount=0)`);
    }

    // Verify the SSM master-password parameter exists. We pass
    // `WithDecryption: false` so the cleartext value never enters the
    // Lambda's memory. Existence is enough to prove the parameter wasn't
    // accidentally deleted — full decryptability is a separate canary
    // problem. (Security-review S4.)
    try {
      await ssm.send(new GetParameterCommand({
        Name: `/zuruck/restic/${client.name}/master-password`,
        WithDecryption: false,
      }));
      metricData.push({
        MetricName: 'SSMParameterAccessible',
        Dimensions: dimsFor(client.name),
        Value: 1,
        Unit: 'None',
        Timestamp: stamp,
      });
    } catch (err) {
      console.error(`SSM parameter check failed for ${client.name}:`, safeError(err));
      metricData.push({
        MetricName: 'SSMParameterAccessible',
        Dimensions: dimsFor(client.name),
        Value: 0,
        Unit: 'None',
        Timestamp: stamp,
      });
    }
  }

  for (let i = 0; i < metricData.length; i += 20) {
    await cw.send(new PutMetricDataCommand({
      Namespace: namespace,
      MetricData: metricData.slice(i, i + 20),
    }));
  }

  console.log(`Published ${metricData.length} metric data points`);

  // Re-raise after metrics are safely published so the Lambda-error alarm
  // still fires on a systemic S3 problem — but only once every healthy
  // client's data is in CloudWatch. (Review finding #5.)
  if (failedClients.length > 0) {
    throw new Error(
      `Freshness check failed for ${failedClients.length} client(s): ${failedClients.join(', ')}`,
    );
  }
};
