import * as path from "node:path";
import { fileURLToPath } from "node:url";
import * as cdk from "aws-cdk-lib";
import * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as authorizers from "aws-cdk-lib/aws-apigatewayv2-authorizers";
import * as integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as cloudfront from "aws-cdk-lib/aws-cloudfront";
import * as origins from "aws-cdk-lib/aws-cloudfront-origins";
import * as cognito from "aws-cdk-lib/aws-cognito";
import {
  IdentityPool,
  UserPoolAuthenticationProvider,
} from "aws-cdk-lib/aws-cognito-identitypool";
import * as iam from "aws-cdk-lib/aws-iam";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as nodejs from "aws-cdk-lib/aws-lambda-nodejs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as s3deploy from "aws-cdk-lib/aws-s3-deployment";
import * as ssm from "aws-cdk-lib/aws-ssm";
import type { Construct } from "constructs";
import { isProtectedEnvironment, objectPrefix, PROJECT } from "./names.js";

const here = path.dirname(fileURLToPath(import.meta.url));

export interface EnvironmentStackProps extends cdk.StackProps {
  readonly environmentName: string;
  readonly prefix?: string;
}

export class EnvironmentStack extends cdk.Stack {
  public constructor(scope: Construct, id: string, props: EnvironmentStackProps) {
    super(scope, id, props);

    const environmentName = props.environmentName;
    const prefix = props.prefix ?? objectPrefix(environmentName);
    const paramPrefix = `/${prefix}`;
    const protectedEnv = isProtectedEnvironment(environmentName);
    const removalPolicy = protectedEnv ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY;

    cdk.Tags.of(this).add("Project", PROJECT);
    cdk.Tags.of(this).add("Environment", environmentName);
    cdk.Tags.of(this).add("EnvPrefix", prefix);

    const websiteBucket = new s3.Bucket(this, "WebsiteBucket", {
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      versioned: true,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
      removalPolicy,
      autoDeleteObjects: !protectedEnv,
      lifecycleRules: [
        {
          id: "AbortIncompleteUploads",
          abortIncompleteMultipartUploadAfter: cdk.Duration.days(7),
        },
      ],
    });

    const dataBucket = new s3.Bucket(this, "DataBucket", {
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      versioned: true,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
      removalPolicy,
      autoDeleteObjects: !protectedEnv,
      cors: [
        {
          allowedMethods: [
            s3.HttpMethods.GET,
            s3.HttpMethods.PUT,
            s3.HttpMethods.HEAD,
            s3.HttpMethods.POST,
          ],
          allowedOrigins: ["*"],
          allowedHeaders: ["*"],
          exposedHeaders: ["ETag"],
        },
      ],
      lifecycleRules: [
        {
          id: "AbortIncompleteUploads",
          abortIncompleteMultipartUploadAfter: cdk.Duration.days(7),
        },
      ],
    });

    const distribution = new cloudfront.Distribution(this, "WebDistribution", {
      comment: `${prefix} static site`,
      defaultRootObject: "index.html",
      priceClass: cloudfront.PriceClass.PRICE_CLASS_100,
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(websiteBucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD,
      },
      errorResponses: [
        {
          httpStatus: 403,
          responseHttpStatus: 200,
          responsePagePath: "/index.html",
          ttl: cdk.Duration.minutes(1),
        },
        {
          httpStatus: 404,
          responseHttpStatus: 200,
          responsePagePath: "/index.html",
          ttl: cdk.Duration.minutes(1),
        },
      ],
    });

    new s3deploy.BucketDeployment(this, "WebPlaceholder", {
      sources: [s3deploy.Source.asset(path.join(here, "..", "..", "web"))],
      destinationBucket: websiteBucket,
      distribution,
      distributionPaths: ["/*"],
    });

    const userPool = new cognito.UserPool(this, "UserPool", {
      userPoolName: `${prefix}-users`,
      signInAliases: { email: true },
      selfSignUpEnabled: !protectedEnv,
      autoVerify: { email: true },
      featurePlan: cognito.FeaturePlan.LITE,
      mfa: protectedEnv ? cognito.Mfa.REQUIRED : cognito.Mfa.OPTIONAL,
      mfaSecondFactor: { sms: false, otp: true },
      passwordPolicy: {
        minLength: 12,
        requireLowercase: true,
        requireUppercase: true,
        requireDigits: true,
        requireSymbols: true,
      },
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
      removalPolicy,
    });

    const callbackUrls = [
      "http://localhost:5173/",
      "http://localhost:5173/callback",
      `https://${distribution.distributionDomainName}/`,
      `https://${distribution.distributionDomainName}/callback`,
    ];

    const userPoolClient = userPool.addClient("WebClient", {
      userPoolClientName: `${prefix}-web`,
      generateSecret: false,
      preventUserExistenceErrors: true,
      enableTokenRevocation: true,
      authFlows: { userSrp: true, userPassword: false },
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes: [
          cognito.OAuthScope.OPENID,
          cognito.OAuthScope.EMAIL,
          cognito.OAuthScope.PROFILE,
        ],
        callbackUrls,
        logoutUrls: ["http://localhost:5173/", `https://${distribution.distributionDomainName}/`],
      },
    });

    const domainPrefix =
      this.node.tryGetContext("cognitoDomainPrefix") ??
      `${prefix.replaceAll("_", "")}auth`.slice(0, 63);

    userPool.addDomain("AuthDomain", {
      cognitoDomain: { domainPrefix: String(domainPrefix) },
      // Lite cannot use Managed Login v2. Classic hosted UI stays on the free/Lite MAU path.
      managedLoginVersion: cognito.ManagedLoginVersion.CLASSIC_HOSTED_UI,
    });

    const neonUrlParam = `${paramPrefix}/neon_database_url`;
    const usersSchemaParam = `${paramPrefix}/neon_users_schema`;
    const upsertUser = new nodejs.NodejsFunction(this, "UpsertCognitoUser", {
      entry: path.join(here, "..", "lambda", "upsert-cognito-user.ts"),
      handler: "handler",
      runtime: lambda.Runtime.NODEJS_22_X,
      timeout: cdk.Duration.seconds(15),
      memorySize: 256,
      environment: {
        NEON_URL_PARAM: neonUrlParam,
        USERS_SCHEMA_PARAM: usersSchemaParam,
      },
      bundling: {
        format: nodejs.OutputFormat.CJS,
        minify: true,
        target: "node22",
      },
    });
    upsertUser.addToRolePolicy(
      new iam.PolicyStatement({
        sid: "ReadNeonParams",
        actions: ["ssm:GetParameter"],
        resources: [
          `arn:aws:ssm:${this.region}:${this.account}:parameter${neonUrlParam}`,
          `arn:aws:ssm:${this.region}:${this.account}:parameter${usersSchemaParam}`,
        ],
      }),
    );
    userPool.addTrigger(cognito.UserPoolOperation.POST_CONFIRMATION, upsertUser);
    userPool.addTrigger(cognito.UserPoolOperation.POST_AUTHENTICATION, upsertUser);

    new cognito.CfnUserPoolGroup(this, "AdminGroup", {
      userPoolId: userPool.userPoolId,
      groupName: "admin",
      description: "Can edit banks, account types, and statement templates",
    });

    const adminApiFn = new nodejs.NodejsFunction(this, "AdminDimensions", {
      entry: path.join(here, "..", "lambda", "admin-dimensions.ts"),
      handler: "handler",
      runtime: lambda.Runtime.NODEJS_22_X,
      timeout: cdk.Duration.seconds(15),
      memorySize: 256,
      environment: {
        NEON_URL_PARAM: neonUrlParam,
      },
      bundling: {
        format: nodejs.OutputFormat.CJS,
        minify: true,
        target: "node22",
      },
    });
    adminApiFn.addToRolePolicy(
      new iam.PolicyStatement({
        sid: "ReadNeonUrl",
        actions: ["ssm:GetParameter"],
        resources: [`arn:aws:ssm:${this.region}:${this.account}:parameter${neonUrlParam}`],
      }),
    );

    const webOrigin = `https://${distribution.distributionDomainName}`;
    const adminApi = new apigwv2.HttpApi(this, "AdminApi", {
      apiName: `${prefix}-admin`,
      corsPreflight: {
        allowOrigins: [webOrigin],
        allowMethods: [
          apigwv2.CorsHttpMethod.GET,
          apigwv2.CorsHttpMethod.PUT,
          apigwv2.CorsHttpMethod.DELETE,
          apigwv2.CorsHttpMethod.OPTIONS,
        ],
        allowHeaders: ["authorization", "content-type"],
      },
    });
    const adminAuthorizer = new authorizers.HttpUserPoolAuthorizer("AdminAuthorizer", userPool, {
      userPoolClients: [userPoolClient],
    });
    const adminIntegration = new integrations.HttpLambdaIntegration("AdminIntegration", adminApiFn);
    const adminMethods = [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.PUT, apigwv2.HttpMethod.DELETE];
    adminApi.addRoutes({
      path: "/admin",
      methods: [apigwv2.HttpMethod.GET],
      integration: adminIntegration,
      authorizer: adminAuthorizer,
    });
    adminApi.addRoutes({
      path: "/admin/{proxy+}",
      methods: adminMethods,
      integration: adminIntegration,
      authorizer: adminAuthorizer,
    });

    const identityPool = new IdentityPool(this, "IdentityPool", {
      identityPoolName: `${prefix}_identities`,
      allowUnauthenticatedIdentities: false,
      authenticationProviders: {
        userPools: [new UserPoolAuthenticationProvider({ userPool, userPoolClient })],
      },
    });

    dataBucket.grantReadWrite(
      identityPool.authenticatedRole,
      "private/${cognito-identity.amazonaws.com:sub}/*",
    );
    identityPool.authenticatedRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        sid: "ListOwnPrefix",
        actions: ["s3:ListBucket"],
        resources: [dataBucket.bucketArn],
        conditions: {
          StringLike: {
            "s3:prefix": ["private/${cognito-identity.amazonaws.com:sub}/*"],
          },
        },
      }),
    );

    const outputs: Record<string, string> = {
      "website-bucket": websiteBucket.bucketName,
      "data-bucket": dataBucket.bucketName,
      "web-domain": distribution.distributionDomainName,
      "user-pool-id": userPool.userPoolId,
      "user-pool-client-id": userPoolClient.userPoolClientId,
      "identity-pool-id": identityPool.identityPoolId,
      "api-url": adminApi.apiEndpoint,
      region: this.region,
      prefix,
    };

    for (const [key, value] of Object.entries(outputs)) {
      new ssm.StringParameter(this, `Param${toPascal(key)}`, {
        parameterName: `${paramPrefix}/${key}`,
        stringValue: value,
        tier: ssm.ParameterTier.STANDARD,
      });
    }

    new cdk.CfnOutput(this, "WebsiteBucketName", { value: websiteBucket.bucketName });
    new cdk.CfnOutput(this, "DataBucketName", { value: dataBucket.bucketName });
    new cdk.CfnOutput(this, "WebUrl", {
      value: `https://${distribution.distributionDomainName}`,
    });
    new cdk.CfnOutput(this, "EnvPrefix", { value: prefix });
    new cdk.CfnOutput(this, "SsmPrefix", { value: paramPrefix });
  }
}

function toPascal(value: string): string {
  return value
    .split(/[^a-zA-Z0-9]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join("");
}
