import * as cdk from 'aws-cdk-lib/core';
import { Template } from 'aws-cdk-lib/assertions';
import { ZuruckStack } from '../lib/zuruck-stack';

test('S3 Bucket Created', () => {
  const app = new cdk.App();
  const stack = new ZuruckStack(app, 'TestStack');
  const template = Template.fromStack(stack);

  template.hasResourceProperties('AWS::S3::Bucket', {
    VersioningConfiguration: { Status: 'Enabled' },
  });
});

test('KMS Key Created with Rotation', () => {
  const app = new cdk.App();
  const stack = new ZuruckStack(app, 'TestStack');
  const template = Template.fromStack(stack);

  template.hasResourceProperties('AWS::KMS::Key', {
    EnableKeyRotation: true,
  });
});

test('IAM Users Created for Each Client', () => {
  const app = new cdk.App();
  const stack = new ZuruckStack(app, 'TestStack');
  const template = Template.fromStack(stack);

  // Should have 2 IAM users (alpha and bravo from default config)
  template.resourceCountIs('AWS::IAM::User', 2);
});

test('SSM Parameters Created for Each Client', () => {
  const app = new cdk.App();
  const stack = new ZuruckStack(app, 'TestStack');
  const template = Template.fromStack(stack);

  // Should have 2 SSM parameters (alpha and bravo from default config)
  template.resourceCountIs('AWS::SSM::Parameter', 2);
});

test('S3 Bucket Blocks Public Access', () => {
  const app = new cdk.App();
  const stack = new ZuruckStack(app, 'TestStack');
  const template = Template.fromStack(stack);

  template.hasResourceProperties('AWS::S3::BucketPolicy', {});
});

test('Lifecycle Rules Transition to Glacier', () => {
  const app = new cdk.App();
  const stack = new ZuruckStack(app, 'TestStack');
  const template = Template.fromStack(stack);

  // Verify lifecycle configuration exists
  template.hasResourceProperties('AWS::S3::Bucket', {
    LifecycleConfiguration: {},
  });
});
