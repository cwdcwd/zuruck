import * as cdk from 'aws-cdk-lib/core';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { ZuruckStack } from '../lib/zuruck-stack';
import { CLIENTS, clientPrefix } from '../lib/config/clients';

const synth = (): Template => {
  const app = new cdk.App();
  const stack = new ZuruckStack(app, 'TestStack');
  return Template.fromStack(stack);
};

describe('ZuruckStack', () => {
  test('S3 bucket is versioned', () => {
    synth().hasResourceProperties('AWS::S3::Bucket', {
      VersioningConfiguration: { Status: 'Enabled' },
    });
  });

  test('S3 bucket retains noncurrent versions long enough to recover from a credential compromise', () => {
    const template = synth();
    const buckets = template.findResources('AWS::S3::Bucket');
    const bucket = Object.values(buckets)[0] as { Properties: { LifecycleConfiguration: { Rules: Array<Record<string, unknown>> } } };
    const cleanupRule = bucket.Properties.LifecycleConfiguration.Rules.find(
      (r) => (r as { NoncurrentVersionExpiration?: { NoncurrentDays: number } }).NoncurrentVersionExpiration,
    ) as { NoncurrentVersionExpiration: { NoncurrentDays: number } };
    expect(cleanupRule.NoncurrentVersionExpiration.NoncurrentDays).toBeGreaterThanOrEqual(14);
  });

  test('KMS key has rotation enabled', () => {
    synth().hasResourceProperties('AWS::KMS::Key', {
      EnableKeyRotation: true,
    });
  });

  test('one IAM user per client', () => {
    synth().resourceCountIs('AWS::IAM::User', CLIENTS.length);
  });

  test('S3 bucket blocks public access', () => {
    synth().hasResourceProperties('AWS::S3::Bucket', {
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true,
      },
    });
  });

  test('lifecycle rules transition to Glacier and Deep Archive', () => {
    synth().hasResourceProperties('AWS::S3::Bucket', {
      LifecycleConfiguration: {
        Rules: Match.arrayWith([
          Match.objectLike({
            Transitions: Match.arrayWith([
              Match.objectLike({ StorageClass: 'GLACIER' }),
            ]),
          }),
          Match.objectLike({
            Transitions: Match.arrayWith([
              Match.objectLike({ StorageClass: 'DEEP_ARCHIVE' }),
            ]),
          }),
        ]),
      },
    });
  });

  test.each(CLIENTS)('client $name S3 policy is scoped to its own prefix', (client) => {
    const prefix = clientPrefix(client.name);
    const template = synth();

    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyName: `restic-s3-${client.name}`,
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Action: 's3:ListBucket',
            Condition: {
              StringLike: {
                's3:prefix': [prefix, `${prefix}*`],
              },
            },
          }),
          Match.objectLike({
            Action: Match.arrayWith([
              's3:GetObject',
              's3:PutObject',
              's3:DeleteObject',
              's3:AbortMultipartUpload',
              's3:ListMultipartUploadParts',
            ]),
            Resource: Match.objectLike({
              'Fn::Join': Match.arrayWith([
                '',
                Match.arrayWith([`/${prefix}*`]),
              ]),
            }),
          }),
        ]),
      },
    });
  });

  test.each(CLIENTS)('client $name SSM policy is scoped to its own parameter only', (client) => {
    const template = synth();

    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyName: `restic-ssm-${client.name}`,
      PolicyDocument: {
        Statement: [
          Match.objectLike({
            Action: 'ssm:GetParameter',
            Resource: Match.objectLike({
              'Fn::Join': Match.arrayWith([
                '',
                Match.arrayWith([
                  `:parameter/zuruck/restic/${client.name}/master-password`,
                ]),
              ]),
            }),
          }),
        ],
      },
    });
  });

  test('stale-backup alarms trigger on data, not just on missing data', () => {
    const template = synth();
    const alarms = template.findResources('AWS::CloudWatch::Alarm', {
      Properties: { AlarmName: Match.stringLikeRegexp('zuruck-stale-backup-') },
    });
    expect(Object.keys(alarms).length).toBeGreaterThan(0);
    for (const alarm of Object.values(alarms)) {
      const props = (alarm as { Properties: { Threshold: number; ComparisonOperator: string } }).Properties;
      // Threshold must allow the published value (0 or 1) to actually breach it.
      // Threshold=0 with LessThanThreshold is the bug we just fixed.
      const isTriggerable =
        (props.Threshold === 1 && props.ComparisonOperator === 'LessThanThreshold') ||
        (props.Threshold === 0 && props.ComparisonOperator === 'LessThanOrEqualToThreshold');
      expect(isTriggerable).toBe(true);
    }
  });

  test('Lambda error alarm exists', () => {
    synth().hasResourceProperties('AWS::CloudWatch::Alarm', {
      AlarmName: 'zuruck-freshness-checker-errors',
    });
  });

  test('master-password parameters are not present in the synthesized template', () => {
    // We provision them via a custom resource so the value is never in the
    // template. A plain SSM::Parameter with `CHANGE-ME-` is the regression
    // we fixed.
    const template = synth().toJSON();
    const json = JSON.stringify(template);
    expect(json).not.toMatch(/CHANGE-ME-/);
    // No raw SSM::Parameter resources for master passwords.
    const ssm = synth().findResources('AWS::SSM::Parameter');
    for (const params of Object.values(ssm)) {
      const props = (params as { Properties: { Name?: string } }).Properties;
      expect(props.Name).not.toMatch(/master-password$/);
    }
  });

  test('access keys are not exposed as CFN outputs', () => {
    const outputs = synth().findOutputs('*');
    for (const [name, def] of Object.entries(outputs)) {
      // We accept outputs that point at Secrets Manager ARNs; we reject any
      // output whose value is the raw CFN intrinsic for an access key secret.
      const valueJson = JSON.stringify((def as { Value: unknown }).Value);
      expect(valueJson).not.toMatch(/SecretAccessKey/);
      // Output names referring to a "SecretAccessKey-..." would be a regression.
      expect(name).not.toMatch(/^SecretAccessKey-/);
    }
  });

  test('one Secrets Manager secret per client for the access key', () => {
    const template = synth();
    for (const client of CLIENTS) {
      template.hasResourceProperties('AWS::SecretsManager::Secret', {
        Name: `zuruck/clients/${client.name}/access-key`,
      });
    }
  });
});
