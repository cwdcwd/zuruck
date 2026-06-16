import { S3Client, ListObjectsV2Command } from '@aws-sdk/client-s3';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { CloudWatchClient, PutMetricDataCommand, MetricDatum } from '@aws-sdk/client-cloudwatch';

interface ClientConfig {
  name: string;
  prefix: string;
  thresholdHours: number;
}

const s3 = new S3Client({});
const ssm = new SSMClient({});
const cw = new CloudWatchClient({});

export const handler = async (): Promise<void> => {
  const bucketName = process.env.BUCKET_NAME!;
  const namespace = process.env.METRIC_NAMESPACE ?? 'Zuruck/Backup';
  const clients: ClientConfig[] = JSON.parse(process.env.CLIENTS!);
  const now = Date.now();

  const metricData: MetricDatum[] = [];
  const stamp = new Date();
  const dimsFor = (clientName: string) => [{ Name: 'Client', Value: clientName }];

  for (const client of clients) {
    console.log(`Checking freshness for client: ${client.name}`);

    // ── List objects under the client prefix ──────────────────────────
    let latestTimestamp = 0;
    let objectCount = 0;
    try {
      let continuationToken: string | undefined;
      do {
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
