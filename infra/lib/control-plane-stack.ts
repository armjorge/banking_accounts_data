import * as cdk from "aws-cdk-lib";
import * as iam from "aws-cdk-lib/aws-iam";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as ssm from "aws-cdk-lib/aws-ssm";
import type { Construct } from "constructs";
import { CONTROL_PARAM_PREFIX, PROJECT } from "./names.js";

/**
 * One account-level config bucket. Streamlit is the editor; S3 is the durable store
 * so a new laptop only needs AWS credentials, not a local .env.
 */
export class ControlPlaneStack extends cdk.Stack {
  public readonly configBucket: s3.Bucket;

  public constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    this.configBucket = new s3.Bucket(this, "ConfigBucket", {
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      versioned: true,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      lifecycleRules: [
        {
          id: "AbortIncompleteUploads",
          abortIncompleteMultipartUploadAfter: cdk.Duration.days(7),
        },
      ],
    });

    cdk.Tags.of(this.configBucket).add("Project", PROJECT);
    cdk.Tags.of(this.configBucket).add("Role", "config");
    cdk.Tags.of(this).add("Project", PROJECT);
    cdk.Tags.of(this).add("Role", "control");

    new ssm.StringParameter(this, "ConfigBucketParam", {
      parameterName: `${CONTROL_PARAM_PREFIX}/config-bucket`,
      stringValue: this.configBucket.bucketName,
      tier: ssm.ParameterTier.STANDARD,
    });

    const operatorPolicy = new iam.ManagedPolicy(this, "OperatorPolicy", {
      managedPolicyName: "StrmBank-Control-Operator",
      description: "Streamlit operator: config bucket, SSM catalog, tagged inventory",
      statements: [
        new iam.PolicyStatement({
          sid: "ConfigBucket",
          actions: [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:GetObjectVersion",
            "s3:ListBucket",
            "s3:ListBucketVersions",
          ],
          resources: [this.configBucket.bucketArn, this.configBucket.arnForObjects("*")],
        }),
        new iam.PolicyStatement({
          sid: "ControlAndEnvParams",
          actions: [
            "ssm:GetParameter",
            "ssm:GetParameters",
            "ssm:GetParametersByPath",
            "ssm:PutParameter",
          ],
          resources: [
            `arn:aws:ssm:${this.region}:${this.account}:parameter/strm_bank`,
            `arn:aws:ssm:${this.region}:${this.account}:parameter/strm_bank/*`,
          ],
        }),
        new iam.PolicyStatement({
          sid: "ListTaggedResources",
          actions: ["tag:GetResources"],
          resources: ["*"],
        }),
      ],
    });

    new cdk.CfnOutput(this, "ConfigBucketName", { value: this.configBucket.bucketName });
    new cdk.CfnOutput(this, "OperatorPolicyArn", { value: operatorPolicy.managedPolicyArn });
    new cdk.CfnOutput(this, "SsmControlPrefix", { value: CONTROL_PARAM_PREFIX });
  }
}
