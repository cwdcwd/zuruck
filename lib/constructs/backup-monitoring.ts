import * as cdk from 'aws-cdk-lib/core';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as lambdaNodejs from 'aws-cdk-lib/aws-lambda-nodejs';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as snsSubscriptions from 'aws-cdk-lib/aws-sns-subscriptions';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as cloudwatchActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import { Construct } from 'constructs';
import { ClientConfig, DEFAULT_FRESHNESS_THRESHOLD_HOURS } from '../config/clients';

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

    // ── SNS Topic for alerts ──────────────────────────────────────────
    this.alertTopic = new sns.Topic(this, 'AlertTopic', {
      topicName: 'zuruck-backup-alerts',
      displayName: 'Restic Backup Alerts',
      masterKey: props.encryptionKey,
    });

    // Subscribe email addresses
    for (const email of props.alertEmails ?? []) {
      this.alertTopic.addSubscription(new snsSubscriptions.EmailSubscription(email));
    }

    // ── Lambda: Freshness Checker ─────────────────────────────────────
    this.freshnessChecker = new lambdaNodejs.NodejsFunction(this, 'FreshnessChecker', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'handler',
      entry: `${__dirname}/../lambda/freshness-checker.ts`,
      timeout: cdk.Duration.minutes(5),
      memorySize: 256,
      environment: {
        BUCKET_NAME: props.bucket.bucketName,
        CLIENTS: JSON.stringify(props.clients.map(c => ({
          name: c.name,
          prefix: `${c.name}/`,
          thresholdHours: c.freshnessThresholdHours ?? DEFAULT_FRESHNESS_THRESHOLD_HOURS,
        }))),
        REGION: cdk.Aws.REGION,
      },
      bundling: {
        minify: true,
        sourceMap: true,
      },
    });

    // Grant Lambda permissions
    props.bucket.grantRead(this.freshnessChecker);

    // Grant Lambda permission to read and verify SSM parameters
    this.freshnessChecker.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['ssm:GetParameter'],
      resources: [
        `arn:aws:ssm:${cdk.Aws.REGION}:${cdk.Aws.ACCOUNT_ID}:parameter/zuruck/restic/*`,
      ],
    }));

    // Grant Lambda permission to decrypt with KMS (for SSM SecureString)
    props.encryptionKey.grantDecrypt(this.freshnessChecker);

    // Grant Lambda permission to publish CloudWatch metrics
    this.freshnessChecker.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['cloudwatch:PutMetricData'],
      resources: ['*'],
      conditions: {
        StringEquals: {
          'cloudwatch:namespace': 'Zuruck/Backup',
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
    const namespace = 'Zuruck/Backup';
    const alarmAction = new cloudwatchActions.SnsAction(this.alertTopic);

    // Per-client freshness alarms
    for (const client of props.clients) {
      const thresholdHours = client.freshnessThresholdHours ?? DEFAULT_FRESHNESS_THRESHOLD_HOURS;

      const freshnessAlarm = new cloudwatch.Alarm(this, `StaleBackup-${client.name}`, {
        alarmName: `zuruck-stale-backup-${client.name}`,
        alarmDescription: `No backup activity for client '${client.name}' in ${thresholdHours} hours`,
        metric: new cloudwatch.Metric({
          namespace,
          metricName: 'BackupFreshness',
          dimensionsMap: {
            Client: client.name,
          },
          statistic: 'Maximum',
          period: cdk.Duration.hours(1),
        }),
        threshold: 0, // 0 means no data point was published = stale
        evaluationPeriods: thresholdHours, // alarm after thresholdHours of no data
        treatMissingData: cloudwatch.TreatMissingData.BREACHING,
        comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
      });

      freshnessAlarm.addAlarmAction(alarmAction);
      freshnessAlarm.addOkAction(alarmAction);
    }

    // Bucket size anomaly alarm
    const bucketSizeAlarm = new cloudwatch.Alarm(this, 'BucketSizeAnomaly', {
      alarmName: 'zuruck-bucket-size-anomaly',
      alarmDescription: 'Backup bucket size has grown unexpectedly',
      metric: new cloudwatch.Metric({
        namespace: 'AWS/S3',
        metricName: 'BucketSizeBytes',
        dimensionsMap: {
          BucketName: props.bucket.bucketName,
          StorageType: 'StandardStorage',
        },
        statistic: 'Average',
        period: cdk.Duration.days(1),
      }),
      threshold: 100 * 1024 * 1024 * 1024, // 100 GB
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
    });

    bucketSizeAlarm.addAlarmAction(alarmAction);

    // ── CloudWatch Dashboard ──────────────────────────────────────────
    this.dashboard = new cloudwatch.Dashboard(this, 'Dashboard', {
      dashboardName: 'zuruck-backup-health',
    });

    // Add per-client freshness widgets
    const freshnessWidgets: cloudwatch.IWidget[] = props.clients.map(client => {
      return new cloudwatch.GraphWidget({
        title: `Backup Freshness: ${client.name}`,
        left: [
          new cloudwatch.Metric({
            namespace,
            metricName: 'BackupFreshness',
            dimensionsMap: { Client: client.name },
            statistic: 'Maximum',
            period: cdk.Duration.hours(1),
          }),
        ],
        width: 12,
        height: 6,
      });
    });

    this.dashboard.addWidgets(
      new cloudwatch.TextWidget({
        markdown: '# Zuruck Backup Health Dashboard',
        width: 24,
        height: 2,
      }),
      ...freshnessWidgets,
      new cloudwatch.GraphWidget({
        title: 'Bucket Size (Bytes)',
        left: [
          new cloudwatch.Metric({
            namespace: 'AWS/S3',
            metricName: 'BucketSizeBytes',
            dimensionsMap: {
              BucketName: props.bucket.bucketName,
              StorageType: 'StandardStorage',
            },
            statistic: 'Average',
            period: cdk.Duration.days(1),
          }),
        ],
        width: 24,
        height: 6,
      }),
    );
  }
}