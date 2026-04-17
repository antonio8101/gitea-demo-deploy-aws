import * as cdk from 'aws-cdk-lib';
import * as s3  from 'aws-cdk-lib/aws-s3';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

export interface StorageStackProps extends cdk.StackProps {
  bucketName: string;
}

export class StorageStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: StorageStackProps) {
    super(scope, id, props);

    // ── S3 Bucket ─────────────────────────────────────────────────────────────
    const bucket = new s3.Bucket(this, 'AILandingsDemoDeploymentArtifacts', {
      bucketName:        props.bucketName,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption:        s3.BucketEncryption.S3_MANAGED,
      versioned:         false,
      removalPolicy:     cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // ── IAM user scoped to this bucket only ───────────────────────────────────
    const user = new iam.User(this, 'AILandingsDemoS3User', {
      userName: `ailandings-demo-s3-${props.bucketName}`,
    });

    bucket.grantReadWrite(user);

    const accessKey = new iam.AccessKey(this, 'AILandingsDemoS3AccessKey', { user });

    // ── IAM user for CI/CD pipeline ───────────────────────────────────────────
    const ciUser = new iam.User(this, 'AILandingsDemoCIPipelineUser', {
      userName: 'ailandings-demo-ci-pipeline',
    });

    // S3: upload artifacts to the bucket
    bucket.grantPut(ciUser);

    // SSM: write the deployed version parameter
    ciUser.addToPolicy(new iam.PolicyStatement({
      actions:   ['ssm:PutParameter'],
      resources: [`arn:aws:ssm:${this.region}:${this.account}:parameter/ai-landings/demo-app/*`],
    }));

    const ciAccessKey = new iam.AccessKey(this, 'AILandingsDemoCIPipelineAccessKey', { user: ciUser });

    // ── IAM role for EC2 instances (instance profile) ─────────────────────────
    const ec2Role = new iam.Role(this, 'AILandingsDemoEC2Role', {
      roleName:    'ailandings-demo-ec2-role',
      assumedBy:   new iam.ServicePrincipal('ec2.amazonaws.com'),
      description: 'Allows EC2 instances to download deployment artifacts from S3 and read SSM parameters',
    });

    // S3: read artifacts from the bucket
    bucket.grantRead(ec2Role);

    // SSM: read app parameters (e.g. current version)
    ec2Role.addToPolicy(new iam.PolicyStatement({
      actions:   ['ssm:GetParameter', 'ssm:GetParameters', 'ssm:GetParametersByPath'],
      resources: [`arn:aws:ssm:${this.region}:${this.account}:parameter/ai-landings/demo-app/*`],
    }));

    // Instance profile — attached to the Launch Template
    const instanceProfile = new iam.CfnInstanceProfile(this, 'AILandingsDemoEC2InstanceProfile', {
      instanceProfileName: 'ailandings-demo-ec2-instance-profile',
      roles:               [ec2Role.roleName],
    });

    // ── Outputs (read by setup-demo.ps1 to populate .env) ─────────────────────
    new cdk.CfnOutput(this, 'BucketName',           { value: bucket.bucketName });
    new cdk.CfnOutput(this, 'BucketRegion',         { value: this.region });
    new cdk.CfnOutput(this, 'AccessKeyId',          { value: accessKey.accessKeyId });
    new cdk.CfnOutput(this, 'SecretAccessKey',      { value: accessKey.secretAccessKey.unsafeUnwrap() });
    new cdk.CfnOutput(this, 'CIAccessKeyId',        { value: ciAccessKey.accessKeyId });
    new cdk.CfnOutput(this, 'CISecretAccessKey',    { value: ciAccessKey.secretAccessKey.unsafeUnwrap() });
    new cdk.CfnOutput(this, 'EC2RoleName',          { value: ec2Role.roleName });
    new cdk.CfnOutput(this, 'EC2InstanceProfile',   { value: instanceProfile.instanceProfileName! });
  }
}
