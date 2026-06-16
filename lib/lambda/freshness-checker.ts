import { S3Client, ListObjectsV2Command } from '@aws-sdk/client-s3';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { CloudWatchClient, PutMetricDataCommand, MetricDatum } from '@aws-sdk/client-cloudwatch';
import { standardRetryStrategy } from '@aws-sdk/middleware-retry';

interface ClientConfig {
  name: string;
  prefix: string;
  thresholdHours: number;
}

// Use the standard retry strategy with backoff for S3 throttling protection.
// The SDK v3 default is 3 retries; we keep that but make it explicit.
const retryStrategy = standardRetryStrategy({ maxAttempts: 3 });

const s3 = new S3Client({ retryStrategy });
const ssm = new SSMClient({ retryStrategy });
const cw = new CloudWatchClient({ retryStrategy });

// Timeout guard: Lambda has a 5-minute hard limit. We bail out 30 seconds
// early so we can still flush whatever metrics we've collected so far.
const TIMEOUT_MARGIN_MS = 30_000;
const LAMBDA_TIMEOUT_MS = 5 * 60 * 1000;

export const handler = async (): Promise<void> => {
  const bucketName = process.env.BUCKET_NAME!;
  const namespace = process.env.METRIC_NAMESPACE ?? 'Zuruck/Backup';
  const clients: ClientConfig[] = JSON.parse(process.env.CLIENTS!);
  const now = Date.now();
  const deadline = now + LAMBDA_TIMEOUT_MS - TIMEOUT_MARGIN_MS;

  const metricData: MetricDatum[] = [];
  const stamp = new Date();
  const dimsFor = (clientName: string) => [{ Name: 'Client', Value: clientName }];

  for (const client of clients) {
    // Timeout guard: if we're approaching the Lambda deadline, stop iterating
    // and flush whatever metrics we have. This prevents a total metric blackout
    // when one client has millions of objects and paginating takes too long.
    if (Date.now() > deadline) {
      console.warn(
        `Approaching Lambda timeout — skipping remaining clients after ${client.name}. ` +
          `Partial metrics will be published. Consider increasing Lambda timeout or ` +
          `reducing the number of objects per prefix.`,
      );
      break;
    }

    console.log(`Checking freshness for client: ${client.name}`);

    // ── List objects under the client prefix ──────────────────────────
    let latestTimestamp = 0;
    let objectCount = 0;
    try {
      let continuationToken: string | undefined;
      do {
        // Inner timeout guard: check before each pagination call.
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
      console.error(`Error listing objects for ${client.name}:`, err);
      // Keep going to publish a 0 freshness signal — that pages the operator
      // via the Lambda-error alarm, not via stale data.
      throw err;
    }

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
      // No objects yet for this client (newly onboarded, or wiped). Publish
      // BackupFreshness=0 so the alarm trips, but skip HoursSinceLastBackup
      // — a sentinel like 9999 would skew anomaly detection.
      metricData.push({
        MetricName: 'BackupFreshness',
        Dimensions: dimsFor(client.name),
        Value: 0,
        Unit: 'None',
        Timestamp: stamp,
      });

      console.log(`Client ${client.name}: no backups found yet (objectCount=0)`);
    }

    // ── Verify SSM master-password parameter is decryptable ───────────
    try {
      await ssm.send(new GetParameterCommand({
        Name: `/zuruck/restic/${client.name}/master-password`,
        WithDecryption: true,
      }));
      metricData.push({
        MetricName: 'SSMParameterAccessible',
        Dimensions: dimsFor(client.name),
        Value: 1,
        Unit: 'None',
        Timestamp: stamp,
      });
    } catch (err) {
      console.error(`SSM parameter check failed for ${client.name}:`, err);
      metricData.push({
        MetricName: 'SSMParameterAccessible',
        Dimensions: dimsFor(client.name),
        Value: 0,
        Unit: 'None',
        Timestamp: stamp,
      });
    }
  }

  // CloudWatch limits: 20 metrics per PutMetricData call.
  for (let i = 0; i < metricData.length; i += 20) {
    await cw.send(new PutMetricDataCommand({
      Namespace: namespace,
      MetricData: metricData.slice(i, i + 20),
    }));
  }

  console.log(`Published ${metricData.length} metric data points`);
};
