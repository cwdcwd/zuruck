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
    expect(cleanupRule.NoncurrentVersionExpiration.NoncurrentDays).toBeGreaterThanOrEqual(90);
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
                's3:prefix': [`${prefix}*`],
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

  test('SSM parameter names follow the expected pattern', () => {
    const template = synth();
    const customResources = template.findResources('Custom::ZuruckMasterPassword');
    for (const [, resource] of Object.entries(customResources)) {
      const props = (resource as { Properties: { ParameterName: string; ClientName: string } }).Properties;
      expect(props.ParameterName).toMatch(/^\/zuruck\/restic\/[^/]+\/master-password$/);
      expect(props.ParameterName).toContain(props.ClientName);
    }
  });

  test('freshness checker Lambda has correct environment variables', () => {
    synth().hasResourceProperties('AWS::Lambda::Function', {
      Environment: {
        Variables: Match.objectLike({
          BUCKET_NAME: Match.anyValue(),
          CLIENTS: Match.anyValue(),
          REGION: Match.anyValue(),
          METRIC_NAMESPACE: Match.anyValue(),
        }),
      },
    });
  });

  test('client S3 policy does NOT grant s3:DeleteObjectVersion (S1)', () => {
    const template = synth();
    const policies = template.findResources('AWS::IAM::Policy', {
      Properties: { PolicyName: Match.stringLikeRegexp('^restic-s3-') },
    });
    expect(Object.keys(policies).length).toBe(CLIENTS.length);
    for (const [, resource] of Object.entries(policies)) {
      const props = (resource as { Properties: { PolicyDocument: { Statement: Array<{ Action: string | string[] }> } } }).Properties;
      const allActions = props.PolicyDocument.Statement.flatMap(s =>
        Array.isArray(s.Action) ? s.Action : [s.Action],
      );
      expect(allActions).not.toContain('s3:DeleteObjectVersion');
    }
  });

  test('S3 bucket has Object Lock support enabled when objectLockRetentionDays > 0 (S2)', () => {
    const app = new cdk.App();
    const stack = new ZuruckStack(app, 'TestStack', { objectLockRetentionDays: 30 });
    const template = Template.fromStack(stack);
    template.hasResourceProperties('AWS::S3::Bucket', {
      ObjectLockEnabled: true,
      ObjectLockConfiguration: Match.objectLike({
        Rule: Match.objectLike({
          DefaultRetention: Match.objectLike({
            Mode: 'GOVERNANCE',
            Days: 30,
          }),
        }),
      }),
    });
  });

  test('KMS key has 30-day pendingWindow (S3)', () => {
    synth().hasResourceProperties('AWS::KMS::Key', {
      PendingWindowInDays: 30,
    });
  });

  test('KMS key adds explicit Deny on destructive actions when admin roles are scoped (S3)', () => {
    const app = new cdk.App();
    const stack = new ZuruckStack(app, 'TestStack', {
      kmsAdminRoleArns: ['arn:aws:iam::111111111111:role/ZuruckAdmin'],
    });
    const template = Template.fromStack(stack);
    const keys = template.findResources('AWS::KMS::Key');
    const policyJson = JSON.stringify(keys);
    expect(policyJson).toContain('DenyDestructiveActionsToNonAdmins');
    expect(policyJson).toContain('kms:ScheduleKeyDeletion');
  });

  test('SNS alert topic denies non-TLS publish/subscribe (S6)', () => {
    const template = synth();
    const policies = template.findResources('AWS::SNS::TopicPolicy');
    const policyJson = JSON.stringify(policies);
    expect(policyJson).toContain('DenyInsecureTransport');
    expect(policyJson).toContain('aws:SecureTransport');
  });

  test('S3 bucket policy includes cross-client deny backstop (S7)', () => {
    const template = synth();
    const policies = template.findResources('AWS::S3::BucketPolicy');
    const policyJson = JSON.stringify(policies);
    expect(policyJson).toContain('DenyCrossClientPrefixAccess');
    expect(policyJson).toContain('aws:PrincipalTag/Client');
  });

  test('IAM users are tagged with their Client name (S7)', () => {
    const template = synth();
    for (const client of CLIENTS) {
      template.hasResourceProperties('AWS::IAM::User', {
        UserName: `restic-${client.name}`,
        Tags: Match.arrayWith([
          Match.objectLike({ Key: 'Client', Value: client.name }),
        ]),
      });
    }
  });

  test('EventBridge rule pages on bucket-config changes (S8)', () => {
    synth().hasResourceProperties('AWS::Events::Rule', {
      Name: 'zuruck-bucket-config-changes',
      EventPattern: Match.objectLike({
        source: ['aws.s3'],
        detail: Match.objectLike({
          eventName: Match.arrayWith(['DeleteBucket', 'PutBucketPolicy']),
        }),
      }),
    });
  });

  test('provisioner Lambda has reservedConcurrentExecutions=1 (S5)', () => {
    const template = synth();
    const fns = template.findResources('AWS::Lambda::Function');
    const provisioner = Object.entries(fns).find(([k]) => k.includes('PasswordProvisioner'));
    expect(provisioner).toBeDefined();
    const props = (provisioner![1] as { Properties: { ReservedConcurrentExecutions?: number } }).Properties;
    expect(props.ReservedConcurrentExecutions).toBe(1);
  });

  test('provisioner Lambda role does NOT have kms:Decrypt (S5)', () => {
    const template = synth();
    const policies = template.findResources('AWS::IAM::Policy');
    // Find any policy attached to the provisioner role
    for (const [, resource] of Object.entries(policies)) {
      const props = (resource as { Properties: { Roles?: Array<{ Ref?: string }>; PolicyDocument: { Statement: Array<{ Action: string | string[]; Resource: unknown }> } } }).Properties;
      const rolesJson = JSON.stringify(props.Roles ?? []);
      if (!rolesJson.includes('PasswordProvisioner')) continue;
      const allActions = props.PolicyDocument.Statement.flatMap(s =>
        Array.isArray(s.Action) ? s.Action : [s.Action],
      );
      expect(allActions).not.toContain('kms:Decrypt');
    }
  });

  test('freshness checker role does NOT have kms:Decrypt on the bucket CMK (S4)', () => {
    const template = synth();
    const policies = template.findResources('AWS::IAM::Policy');
    for (const [, resource] of Object.entries(policies)) {
      const props = (resource as { Properties: { Roles?: Array<{ Ref?: string }>; PolicyDocument: { Statement: Array<{ Action: string | string[] }> } } }).Properties;
      const rolesJson = JSON.stringify(props.Roles ?? []);
      if (!rolesJson.includes('FreshnessChecker')) continue;
      const allActions = props.PolicyDocument.Statement.flatMap(s =>
        Array.isArray(s.Action) ? s.Action : [s.Action],
      );
      expect(allActions).not.toContain('kms:Decrypt');
    }
  });

  test('no client S3 policy grants access to another client prefix', () => {
    const template = synth();
    const policies = template.findResources('AWS::IAM::Policy', {
      Properties: { PolicyName: Match.stringLikeRegexp('^restic-s3-') },
    });
    for (const [, resource] of Object.entries(policies)) {
      const props = (resource as { Properties: { PolicyName: string; PolicyDocument: { Statement: Array<{ Action: string | string[]; Resource: unknown }> } } }).Properties;
      // Extract the client name from the policy name
      const clientName = props.PolicyName.replace('restic-s3-', '');
      for (const stmt of props.PolicyDocument.Statement) {
        // Object-level actions must only reference the client's own prefix
        if (Array.isArray(stmt.Action) && stmt.Action.includes('s3:GetObject')) {
          const resourceJson = JSON.stringify(stmt.Resource);
          // Ensure no other client prefix appears in the resource ARN
          for (const otherClient of CLIENTS) {
            if (otherClient.name === clientName) continue;
            const otherPrefix = clientPrefix(otherClient.name);
            expect(resourceJson).not.toContain(`/${otherPrefix}`);
          }
        }
      }
    }
  });
});
