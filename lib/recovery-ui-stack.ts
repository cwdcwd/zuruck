import * as cdk from 'aws-cdk-lib/core';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as lambdaNodejs from 'aws-cdk-lib/aws-lambda-nodejs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import { Construct } from 'constructs';
import { clientPrefix, clientMasterPasswordParameterName, validateClientName } from './config/clients';

/**
 * Recovery UI cloud stack — SCAFFOLD, opt-in, deploy-later.
 *
 * Instantiated from bin/zuruck.ts ONLY when `-c deployRecoveryUi=true`, so the
 * core ZuruckStack and existing deploys are untouched by default (Plan A: a
 * separate, isolated stack rather than a construct inside the backup stack).
 *
 * It serves the browser SPA from S3+CloudFront and runs a restic Lambda (app/
 * lambda/handler.ts, restic from a layer) behind an IAM-authenticated Function URL.
 *
 * ⚠️ Blast radius: unlike the freshness checker — which was deliberately denied
 * s3:GetObject and kms:Decrypt (see lib/constructs/backup-monitoring.ts) — a
 * restic restore Lambda MUST read + decrypt objects and read the repo password.
 * We scope those grants to a single client prefix and keep the role restore/read
 * only (no Delete, no prune). The Function URL is AWS_IAM auth; the browser must
 * SigV4-sign (Cognito Identity Pool or similar) — that auth wiring is the one
 * TODO left open. Do NOT set the Function URL auth to NONE.
 */
export interface RecoveryUiStackProps extends cdk.StackProps {
  /** The backup bucket (imported from ZuruckStack). */
  readonly bucket: s3.IBucket;
  /** The bucket/SSM KMS key (imported from ZuruckStack). */
  readonly encryptionKey: kms.IKey;
  /** Which client's snapshots this UI can browse/restore. */
  readonly clientName: string;
}

export class RecoveryUiStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: RecoveryUiStackProps) {
    super(scope, id, props);
    validateClientName(props.clientName);

    const prefix = clientPrefix(props.clientName); // "<client>/"
    const repo = `s3:s3.${this.region}.amazonaws.com/${props.bucket.bucketName}/${props.clientName}`;

    // ── SPA hosting: private bucket behind CloudFront (OAC) ──────────────────
    const siteBucket = new s3.Bucket(this, 'SpaBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    const distribution = new cloudfront.Distribution(this, 'SpaCdn', {
      defaultRootObject: 'index.html',
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(siteBucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
      },
      comment: `Zuruck recovery UI (${props.clientName})`,
    });

    // The real SPA is `esbuild app/web/app.ts` → index.html; for the scaffold we
    // deploy a placeholder so `cdk synth` needs no prebuilt asset. The deploy
    // pipeline replaces this Source with the built site.
    new s3deploy.BucketDeployment(this, 'SpaDeploy', {
      destinationBucket: siteBucket,
      distribution,
      distributionPaths: ['/*'],
      sources: [
        s3deploy.Source.data(
          'index.html',
          '<!doctype html><title>Zuruck Recovery UI</title>' +
            '<p>Scaffold placeholder — build app/web and redeploy.</p>',
        ),
      ],
    });

    // ── restic binary as a Lambda layer (populated by app/lambda/fetch-restic.sh) ──
    const resticLayer = new lambda.LayerVersion(this, 'ResticLayer', {
      code: lambda.Code.fromAsset(`${__dirname}/../app/lambda/layer`),
      compatibleArchitectures: [lambda.Architecture.ARM_64],
      compatibleRuntimes: [lambda.Runtime.NODEJS_20_X],
      description: 'restic binary (linux/arm64) at /opt/bin/restic',
    });

    // ── restic API Lambda (reuses app/core via app/lambda/handler.ts) ────────
    const logGroup = new logs.LogGroup(this, 'ApiLogs', {
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const api = new lambdaNodejs.NodejsFunction(this, 'ResticApi', {
      runtime: lambda.Runtime.NODEJS_20_X,
      architecture: lambda.Architecture.ARM_64,
      handler: 'handler',
      entry: `${__dirname}/../app/lambda/handler.ts`,
      timeout: cdk.Duration.minutes(15),
      memorySize: 512,
      ephemeralStorageSize: cdk.Size.gibibytes(10), // headroom for future /tmp restores
      logGroup,
      layers: [resticLayer],
      environment: {
        RESTIC_REPOSITORY: repo,
        RESTIC_PW_PARAM: clientMasterPasswordParameterName(props.clientName),
        RESTIC_BIN: '/opt/bin/restic',
      },
      bundling: { minify: true, sourceMap: true },
    });

    // ── IAM: least-privilege, scoped to ONE client prefix, read/restore only ──
    api.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['s3:ListBucket'],
        resources: [props.bucket.bucketArn],
        conditions: { StringLike: { 's3:prefix': [`${prefix}*`] } },
      }),
    );
    api.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['s3:GetObject'],
        resources: [`${props.bucket.bucketArn}/${prefix}*`],
      }),
    );
    // Required to read+decrypt pack files and the SSM master password.
    props.encryptionKey.grantDecrypt(api);
    api.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['ssm:GetParameter'],
        resources: [
          `arn:aws:ssm:${this.region}:${this.account}:parameter${clientMasterPasswordParameterName(props.clientName)}`,
        ],
      }),
    );

    // ── IAM-authenticated Function URL (browser must SigV4-sign — see TODO) ──
    const fnUrl = api.addFunctionUrl({ authType: lambda.FunctionUrlAuthType.AWS_IAM });

    new cdk.CfnOutput(this, 'CloudFrontUrl', {
      value: `https://${distribution.distributionDomainName}`,
      description: 'Recovery UI (SPA) URL',
    });
    new cdk.CfnOutput(this, 'ApiFunctionUrl', {
      value: fnUrl.url,
      description: 'restic API Function URL (AWS_IAM auth)',
    });
  }
}
