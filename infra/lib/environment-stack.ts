import * as path from "node:path";
import { fileURLToPath } from "node:url";
import * as cdk from "aws-cdk-lib";
import * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as authorizers from "aws-cdk-lib/aws-apigatewayv2-authorizers";
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
import { NoPermissionLambdaIntegration } from "./no-permission-lambda-integration.js";

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

    // New bucket: Object Lock can only be enabled at creation, so this is not
    // the existing data bucket. RETAIN because locked objects cannot be emptied
    // by a stack delete. The app role can put curated/* and cannot delete it.
    const curatedBucket = new s3.Bucket(this, "CuratedCsvBucket", {
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      versioned: true,
      objectLockEnabled: true,
      objectLockDefaultRetention: s3.ObjectLockRetention.governance(cdk.Duration.days(365)),
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    curatedBucket.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: "DenyCuratedDelete",
        effect: iam.Effect.DENY,
        principals: [new iam.AnyPrincipal()],
        actions: ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:BypassGovernanceRetention"],
        resources: [curatedBucket.arnForObjects("curated/*")],
      }),
    );

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
      sources: [
        s3deploy.Source.asset(path.join(here, "..", "..", "web"), {
          exclude: ["preview.html", "preview.js", "config.js"],
        }),
      ],
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
      description: "Sees the full banking console",
    });

    const webOrigin = `https://${distribution.distributionDomainName}`;
    const adminApi = new apigwv2.HttpApi(this, "AdminApi", {
      apiName: `${prefix}-admin`,
      corsPreflight: {
        allowOrigins: [webOrigin],
        allowMethods: [
          apigwv2.CorsHttpMethod.GET,
          apigwv2.CorsHttpMethod.PUT,
          apigwv2.CorsHttpMethod.POST,
          apigwv2.CorsHttpMethod.DELETE,
          apigwv2.CorsHttpMethod.OPTIONS,
        ],
        allowHeaders: ["authorization", "content-type"],
      },
    });
    const adminAuthorizer = new authorizers.HttpUserPoolAuthorizer("AdminAuthorizer", userPool, {
      userPoolClients: [userPoolClient],
    });

    const statementsFn = new nodejs.NodejsFunction(this, "StatementsApi", {
      entry: path.join(here, "..", "lambda", "statements.ts"),
      handler: "handler",
      runtime: lambda.Runtime.NODEJS_22_X,
      timeout: cdk.Duration.seconds(30),
      memorySize: 512,
      environment: {
        NEON_URL_PARAM: neonUrlParam,
        CURATED_BUCKET: curatedBucket.bucketName,
      },
      bundling: {
        format: nodejs.OutputFormat.CJS,
        minify: true,
        target: "node22",
      },
    });
    statementsFn.addToRolePolicy(
      new iam.PolicyStatement({
        sid: "ReadNeonUrlForStatements",
        actions: ["ssm:GetParameter"],
        resources: [`arn:aws:ssm:${this.region}:${this.account}:parameter${neonUrlParam}`],
      }),
    );
    curatedBucket.grantPut(statementsFn, "curated/*");
    curatedBucket.grantRead(statementsFn, "curated/*");
    const statementsIntegration = new NoPermissionLambdaIntegration(
      "StatementsIntegration",
      statementsFn,
    );
    statementsFn.addPermission("ApiInvokeAll", {
      principal: new iam.ServicePrincipal("apigateway.amazonaws.com"),
      sourceArn: `arn:${cdk.Aws.PARTITION}:execute-api:${cdk.Aws.REGION}:${cdk.Aws.ACCOUNT_ID}:${adminApi.apiId}/*/*/*`,
    });
    adminApi.addRoutes({
      path: "/statements",
      methods: [apigwv2.HttpMethod.GET],
      integration: statementsIntegration,
      authorizer: adminAuthorizer,
    });
    adminApi.addRoutes({
      path: "/accounts",
      methods: [apigwv2.HttpMethod.POST],
      integration: statementsIntegration,
      authorizer: adminAuthorizer,
    });
    adminApi.addRoutes({
      path: "/accounts/{accountId}/cutoff",
      methods: [apigwv2.HttpMethod.POST],
      integration: statementsIntegration,
      authorizer: adminAuthorizer,
    });
    adminApi.addRoutes({
      path: "/periods",
      methods: [apigwv2.HttpMethod.POST],
      integration: statementsIntegration,
      authorizer: adminAuthorizer,
    });
    adminApi.addRoutes({
      path: "/periods/{cutoffId}",
      methods: [apigwv2.HttpMethod.DELETE],
      integration: statementsIntegration,
      authorizer: adminAuthorizer,
    });
    adminApi.addRoutes({
      path: "/uploads",
      methods: [apigwv2.HttpMethod.POST],
      integration: statementsIntegration,
      authorizer: adminAuthorizer,
    });
    adminApi.addRoutes({
      path: "/uploads/{uploadId}",
      methods: [apigwv2.HttpMethod.DELETE],
      integration: statementsIntegration,
      authorizer: adminAuthorizer,
    });

    for (const [routePath, methods] of [
      ["/dimensions", [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.POST]],
      ["/dimensions/rows", [apigwv2.HttpMethod.GET]],
      ["/api-tokens", [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.POST]],
      ["/api-tokens/{tokenId}", [apigwv2.HttpMethod.DELETE]],
      // sql/016: attribute lists and transfer links.
      ["/lists", [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.POST]],
      ["/lists/{listId}", [apigwv2.HttpMethod.POST]],
      ["/lists/{listId}/nested", [apigwv2.HttpMethod.POST]],
      ["/lists/{listId}/items", [apigwv2.HttpMethod.POST]],
      ["/list-items/{itemId}", [apigwv2.HttpMethod.POST]],
      ["/attribute-settings", [apigwv2.HttpMethod.POST]],
      ["/transfers", [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.POST]],
      ["/transfers/detect", [apigwv2.HttpMethod.POST]],
      ["/transfers/settings", [apigwv2.HttpMethod.POST]],
      ["/transfers/partners", [apigwv2.HttpMethod.GET]],
      ["/transfers/{linkHash}", [apigwv2.HttpMethod.DELETE]],
      ["/transfers/{linkHash}/confirm", [apigwv2.HttpMethod.POST]],
      // sql/017: Investments & Assets page.
      ["/assets", [apigwv2.HttpMethod.GET]],
      ["/assets/balances", [apigwv2.HttpMethod.GET]],
      ["/assets/accounts", [apigwv2.HttpMethod.POST]],
      ["/assets/rows", [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.POST]],
      ["/assets/rows/{rowHash}", [apigwv2.HttpMethod.DELETE]],
      ["/assets/reconcile", [apigwv2.HttpMethod.POST]],
      ["/assets/preview", [apigwv2.HttpMethod.POST]],
      ["/assets/uploads", [apigwv2.HttpMethod.POST]],
      ["/assets/uploads/{uploadId}", [apigwv2.HttpMethod.DELETE]],
      ["/assets/templates/{templateId}", [apigwv2.HttpMethod.DELETE]],
      // sql/018: balances for any account, banks, account bank, statement column map.
      ["/balances/{accountId}", [apigwv2.HttpMethod.GET]],
      ["/balances/opening", [apigwv2.HttpMethod.POST]],
      ["/balances/reconcile", [apigwv2.HttpMethod.POST]],
      ["/balances/rows/{rowHash}", [apigwv2.HttpMethod.POST, apigwv2.HttpMethod.DELETE]],
      ["/banks", [apigwv2.HttpMethod.GET, apigwv2.HttpMethod.POST]],
      ["/banks/{bankId}", [apigwv2.HttpMethod.POST, apigwv2.HttpMethod.DELETE]],
      ["/accounts/{accountId}", [apigwv2.HttpMethod.DELETE]],
      ["/accounts/{accountId}/bank", [apigwv2.HttpMethod.POST]],
      ["/statements/preview", [apigwv2.HttpMethod.POST]],
    ] as const) {
      adminApi.addRoutes({
        path: routePath,
        methods: [...methods],
        integration: statementsIntegration,
        authorizer: adminAuthorizer,
      });
    }

    // sql/015: GraphQL for Google Sheets. No Cognito authorizer: the Lambda checks a
    // read-only API token and the plan quota. Throttled on its own route as a cost backstop.
    const graphqlFn = new nodejs.NodejsFunction(this, "GraphqlApi", {
      entry: path.join(here, "..", "lambda", "graphql.ts"),
      handler: "handler",
      runtime: lambda.Runtime.NODEJS_22_X,
      architecture: lambda.Architecture.ARM_64,
      timeout: cdk.Duration.seconds(20),
      memorySize: 512,
      environment: {
        NEON_URL_PARAM: neonUrlParam,
      },
      bundling: {
        format: nodejs.OutputFormat.CJS,
        minify: true,
        target: "node22",
      },
    });
    graphqlFn.addToRolePolicy(
      new iam.PolicyStatement({
        sid: "ReadNeonUrlForGraphql",
        actions: ["ssm:GetParameter"],
        resources: [`arn:aws:ssm:${this.region}:${this.account}:parameter${neonUrlParam}`],
      }),
    );
    const graphqlRoutes = adminApi.addRoutes({
      path: "/graphql",
      methods: [apigwv2.HttpMethod.POST],
      integration: new NoPermissionLambdaIntegration("GraphqlIntegration", graphqlFn),
    });
    graphqlFn.addPermission("ApiInvokeAll", {
      principal: new iam.ServicePrincipal("apigateway.amazonaws.com"),
      sourceArn: `arn:${cdk.Aws.PARTITION}:execute-api:${cdk.Aws.REGION}:${cdk.Aws.ACCOUNT_ID}:${adminApi.apiId}/*/*/*`,
    });
    const graphqlRate = Number(this.node.tryGetContext("graphqlRateLimit") ?? 5);
    const graphqlBurst = Number(this.node.tryGetContext("graphqlBurstLimit") ?? 10);
    const defaultStage = adminApi.defaultStage?.node.defaultChild as apigwv2.CfnStage | undefined;
    defaultStage?.addPropertyOverride("RouteSettings", {
      "POST /graphql": {
        ThrottlingRateLimit: graphqlRate,
        ThrottlingBurstLimit: graphqlBurst,
      },
    });
    // The stage's route throttling must wait until POST /graphql exists.
    for (const route of graphqlRoutes) defaultStage?.addDependency(route.node.defaultChild as cdk.CfnResource);

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
      "graphql-url": `${adminApi.apiEndpoint}/graphql`,
      "curated-bucket": curatedBucket.bucketName,
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
