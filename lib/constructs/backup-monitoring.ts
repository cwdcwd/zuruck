import * as cdk from 'aws-cdk-lib/core';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as lambdaNodejs from 'aws-cdk-lib/aws-lambda-nodejs';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as snsSubscriptions from 'aws-cdk-lib/aws-sns-subscriptions';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as cloudwatchActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import { Construct } from 'constructs';
import { ClientConfig, DEFAULT_FRESHNESS_THRESHOLD_HOURS, clientPrefix } from '../config/clients';

export interface BackupMonitoringProps {
  /**
   * The S3 bucket being monitored.
   */
  readonly bucket: s3.Bucket;

  /**
   * The KMS key for decrypting SSM parameters.
   */
  readonly encryptionKey: kms.Key;

  /**
   * Client configurations.
   */
  readonly clients: ClientConfig[];

  /**
   * Email addresses to subscribe to the backup alerts SNS topic.
   */
  readonly alertEmails?: string[];

  /**
   * Bucket size (bytes) above which the size-anomaly alarm fires.
   * @default 100 GiB
   */
  readonly bucketSizeAlarmBytes?: number;
}

export class BackupMonitoring extends Construct {
  /**
   * The SNS topic for backup alerts.
   */
  public readonly alertTopic: sns.Topic;

  /**
   * The CloudWatch dashboard for backup health.
   */
  public readonly dashboard: cloudwatch.Dashboard;

  /**
   * The Lambda function that checks backup freshness.
   */
  public readonly freshnessChecker: lambda.IFunction;

  constructor(scope: Construct, id: string, props: BackupMonitoringProps) {
    super(scope, id);

    const namespace = 'Zuruck/Backup';

    // ── SNS Topic for alerts ──────────────────────────────────────────
    this.alertTopic = new sns.Topic(this, 'AlertTopic', {
      topicName: 'zuruck-backup-alerts',
      displayName: 'Restic Backup Alerts',
      masterKey: props.encryptionKey,
    });

    for (const email of props.alertEmails ?? []) {
      this.alertTopic.addSubscription(new snsSubscriptions.EmailSubscription(email));
    }

    // ── Lambda: Freshness Checker ─────────────────────────────────────
    const freshnessLogGroup = new logs.LogGroup(this, 'FreshnessCheckerLogs', {
      retention: logs.RetentionDays.THREE_MONTHS,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    this.freshnessChecker = new lambdaNodejs.NodejsFunction(this, 'FreshnessChecker', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'handler',
      entry: `${__dirname}/../lambda/freshness-checker.ts`,
      timeout: cdk.Duration.minutes(5),
      memorySize: 256,
      logGroup: freshnessLogGroup,
      environment: {
        BUCKET_NAME: props.bucket.bucketName,
        CLIENTS: JSON.stringify(props.clients.map(c => ({
          name: c.name,
          prefix: clientPrefix(c.name),
          thresholdHours: c.freshnessThresholdHours ?? DEFAULT_FRESHNESS_THRESHOLD_HOURS,
        }))),
        REGION: cdk.Aws.REGION,
        METRIC_NAMESPACE: namespace,
      },
      bundling: {
        minify: true,
        sourceMap: true,
      },
    });

    props.bucket.grantRead(this.freshnessChecker);

    this.freshnessChecker.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['ssm:GetParameter'],
      resources: [
        `arn:aws:ssm:${cdk.Aws.REGION}:${cdk.Aws.ACCOUNT_ID}:parameter/zuruck/restic/*`,
      ],
    }));

    props.encryptionKey.grantDecrypt(this.freshnessChecker);

    this.freshnessChecker.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['cloudwatch:PutMetricData'],
      resources: ['*'],
      conditions: {
        StringEquals: {
          'cloudwatch:namespace': namespace,
        },
      },
    }));

    // ── EventBridge: Scheduled Rule ───────────────────────────────────
    const scheduleRule = new events.Rule(this, 'FreshnessCheckSchedule', {
      schedule: events.Schedule.rate(cdk.Duration.hours(1)),
      description: 'Trigger backup freshness check every hour',
    });

    scheduleRule.addTarget(new targets.LambdaFunction(this.freshnessChecker));

    // ── CloudWatch Alarms ─────────────────────────────────────────────
    const alarmAction = new cloudwatchActions.SnsAction(this.alertTopic);

    // Per-client freshness alarms.
    //
    // The freshness checker runs hourly and emits BackupFreshness as 0 (stale)
    // or 1 (fresh). We alarm on a single 1h period of value < 1 — i.e. the most
    // recent freshness signal indicated stale. Missing data is treated as
    // breaching so a silent Lambda failure also pages.
    for (const client of props.clients) {
      const thresholdHours = client.freshnessThresholdHours ?? DEFAULT_FRESHNESS_THRESHOLD_HOURS;

      const freshnessAlarm = new cloudwatch.Alarm(this, `StaleBackup-${client.name}`, {
        alarmName: `zuruck-stale-backup-${client.name}`,
        alarmDescription: `Backup for client '${client.name}' is older than ${thresholdHours} hours, or the freshness checker is failing`,
        metric: new cloudwatch.Metric({
          namespace,
          metricName: 'BackupFreshness',
          dimensionsMap: { Client: client.name },
          statistic: 'Maximum',
          period: cdk.Duration.hours(1),
        }),
        threshold: 1,
        evaluationPeriods: 1,
        treatMissingData: cloudwatch.TreatMissingData.BREACHING,
        comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
      });

      freshnessAlarm.addAlarmAction(alarmAction);
    }

    // Lambda error alarm — covers the case where the freshness checker itself
    // is broken (KMS denial, bad env, throttle). Without this the freshness
    // alarms can only ever fire via missing-data, which is too slow.
    const lambdaErrorAlarm = new cloudwatch.Alarm(this, 'FreshnessCheckerErrors', {
      alarmName: 'zuruck-freshness-checker-errors',
      alarmDescription: 'Backup freshness checker Lambda is failing',
      metric: this.freshnessChecker.metricErrors({
        period: cdk.Duration.hours(1),
        statistic: 'Sum',
      }),
      threshold: 1,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
    });
    lambdaErrorAlarm.addAlarmAction(alarmAction);

    // Bucket size anomaly — sums all storage classes so growth in Glacier/Deep
    // Archive isn't invisible after the 90/365 day lifecycle transitions.
    const sizeAlarmBytes = props.bucketSizeAlarmBytes ?? 100 * 1024 * 1024 * 1024;
    const standardSize = this.bucketSizeMetric(props.bucket, 'StandardStorage');
    const glacierSize = this.bucketSizeMetric(props.bucket, 'GlacierStorage');
    const deepArchiveSize = this.bucketSizeMetric(props.bucket, 'DeepArchiveStorage');

    const totalSize = new cloudwatch.MathExpression({
      expression: 'FILL(std,0) + FILL(glac,0) + FILL(deep,0)',
      usingMetrics: { std: standardSize, glac: glacierSize, deep: deepArchiveSize },
      label: 'Total bucket size (all classes)',
      period: cdk.Duration.days(1),
    });

    const bucketSizeAlarm = new cloudwatch.Alarm(this, 'BucketSizeAnomaly', {
      alarmName: 'zuruck-bucket-size-anomaly',
      alarmDescription: `Backup bucket size has exceeded ${sizeAlarmBytes} bytes across all storage classes`,
      metric: totalSize,
      threshold: sizeAlarmBytes,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
    });

    bucketSizeAlarm.addAlarmAction(alarmAction);

    // ── CloudWatch Dashboard ──────────────────────────────────────────
    this.dashboard = new cloudwatch.Dashboard(this, 'Dashboard', {
      dashboardName: 'zuruck-backup-health',
    });

    const freshnessWidgets: cloudwatch.IWidget[] = props.clients.map(client =>
      new cloudwatch.GraphWidget({
        title: `Backup Freshness: ${client.name}`,
        left: [
          new cloudwatch.Metric({
            namespace,
            metricName: 'BackupFreshness',
            dimensionsMap: { Client: client.name },
            statistic: 'Maximum',
            period: cdk.Duration.hours(1),
          }),
          new cloudwatch.Metric({
            namespace,
            metricName: 'HoursSinceLastBackup',
            dimensionsMap: { Client: client.name },
            statistic: 'Maximum',
            period: cdk.Duration.hours(1),
          }),
        ],
        width: 12,
        height: 6,
      })
    );

    const ssmWidget = new cloudwatch.GraphWidget({
      title: 'SSM Parameter Accessibility (per client)',
      left: props.clients.map(client =>
        new cloudwatch.Metric({
          namespace,
          metricName: 'SSMParameterAccessible',
          dimensionsMap: { Client: client.name },
          statistic: 'Minimum',
          period: cdk.Duration.hours(1),
          label: client.name,
        })
      ),
      width: 24,
      height: 6,
    });

    this.dashboard.addWidgets(
      new cloudwatch.TextWidget({
        markdown: '# Zuruck Backup Health Dashboard',
        width: 24,
        height: 2,
      }),
      ...freshnessWidgets,
      ssmWidget,
      new cloudwatch.GraphWidget({
        title: 'Bucket Size by Storage Class',
        left: [standardSize, glacierSize, deepArchiveSize],
        width: 24,
        height: 6,
      }),
    );
  }

  private bucketSizeMetric(bucket: s3.Bucket, storageType: string): cloudwatch.Metric {
    return new cloudwatch.Metric({
      namespace: 'AWS/S3',
      metricName: 'BucketSizeBytes',
      dimensionsMap: {
        BucketName: bucket.bucketName,
        StorageType: storageType,
      },
      statistic: 'Average',
      period: cdk.Duration.days(1),
      label: storageType,
    });
  }
}
