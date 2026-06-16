import { S3Client, ListObjectsV2Command } from '@aws-sdk/client-s3';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { CloudWatchClient, PutMetricDataCommand } from '@aws-sdk/client-cloudwatch';

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
  const region = process.env.REGION!;
  const clients: ClientConfig[] = JSON.parse(process.env.CLIENTS!);
  const namespace = 'Zuruck/Backup';
  const now = Date.now();

  const metricData: Array<{
    MetricName: string;
    Dimensions: Array<{ Name: string; Value: string }>;
    Value: number;
    Unit: string;
  }> = [];

  for (const client of clients) {
    console.log(`Checking freshness for client: ${client.name}`);

    // Check S3 last modified time under the client's prefix
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

        if (response.Contents) {
          for (const obj of response.Contents) {
            if (obj.LastModified) {
              const ts = obj.LastModified.getTime();
              if (ts > latestTimestamp) {
                latestTimestamp = ts;
              }
            }
            objectCount++;
          }
        }

        continuationToken = response.NextContinuationToken;
      } while (continuationToken);
    } catch (err) {
      console.error(`Error listing objects for ${client.name}:`, err);
    }

    // Calculate freshness: hours since last backup
    const hoursSinceLastBackup = latestTimestamp > 0
      ? (now - latestTimestamp) / (1000 * 60 * 60)
      : 9999; // No objects found = very stale

    const isFresh = hoursSinceLastBackup <= client.thresholdHours ? 1 : 0;

    metricData.push({
      MetricName: 'BackupFreshness',
      Dimensions: [{ Name: 'Client', Value: client.name }],
      Value: isFresh,
      Unit: 'None',
    });

    metricData.push({
      MetricName: 'HoursSinceLastBackup',
      Dimensions: [{ Name: 'Client', Value: client.name }],
      Value: Math.round(hoursSinceLastBackup * 100) / 100,
      Unit: 'None',
    });

    metricData.push({
      MetricName: 'ObjectCount',
      Dimensions: [{ Name: 'Client', Value: client.name }],
      Value: objectCount,
      Unit: 'None',
    });

    // Verify SSM parameter is accessible
    try {
      await ssm.send(new GetParameterCommand({
        Name: `/zuruck/restic/${client.name}/master-password`,
        WithDecryption: true,
      }));
      metricData.push({
        MetricName: 'SSMParameterAccessible',
        Dimensions: [{ Name: 'Client', Value: client.name }],
        Value: 1,
        Unit: 'None',
      });
    } catch (err) {
      console.error(`SSM parameter check failed for ${client.name}:`, err);
      metricData.push({
        MetricName: 'SSMParameterAccessible',
        Dimensions: [{ Name: 'Client', Value: client.name }],
        Value: 0,
        Unit: 'None',
      });
    }

    console.log(
      `Client ${client.name}: hoursSinceLastBackup=${hoursSinceLastBackup.toFixed(2)}, ` +
      `isFresh=${isFresh}, objectCount=${objectCount}`
    );
  }

  // Publish all metrics to CloudWatch
  // CloudWatch limits: 20 metrics per PutMetricData call
  for (let i = 0; i < metricData.length; i += 20) {
    const batch = metricData.slice(i, i + 20);
    await cw.send(new PutMetricDataCommand({
      Namespace: namespace,
      MetricData: batch.map(m => ({
        MetricName: m.MetricName,
        Dimensions: m.Dimensions,
        Value: m.Value,
        Unit: m.Unit as string,
        Timestamp: new Date(),
      })),
    }));
  }

  console.log(`Published ${metricData.length} metric data points`);
};