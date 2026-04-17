#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { StorageStack } from '../lib/storage-stack';
import { ComputeStack  } from '../lib/compute-stack';

const app = new cdk.App();

const bucketName = app.node.tryGetContext('bucketName') ?? 'ailandings-demo-deployment-artifacts';
const region     = app.node.tryGetContext('region')     ?? 'eu-west-1';

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region,
};

const storageStack = new StorageStack(app, 'AILandingsDemoDeploymentArtifacts', {
  env,
  bucketName,
  description: 'S3 storage and IAM for AILandings demo deployment artifacts',
});

const computeStack = new ComputeStack(app, 'AILandingsDemoCompute', {
  env,
  bucketName,
  instanceProfileName: 'ailandings-demo-ec2-instance-profile',
  ssmParameterPath:    '/ai-landings/demo-app/version',
  description:         'Launch Template for AILandings demo EC2 instances',
});

// ComputeStack depends on the instance profile created in StorageStack
computeStack.addDependency(storageStack);
