#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { ControlPlaneStack } from "../lib/control-plane-stack.js";
import { EnvironmentStack } from "../lib/environment-stack.js";
import { assertEnvironmentName, objectPrefix, PROJECT } from "../lib/names.js";

const app = new cdk.App();

const account = process.env.CDK_DEFAULT_ACCOUNT;
const region = process.env.CDK_DEFAULT_REGION ?? "us-east-1";
const env = account ? { account, region } : { region };

new ControlPlaneStack(app, "StrmBank-Control", {
  env,
  description: "Shared Streamlit config bucket and operator policy",
  tags: { Project: PROJECT, Role: "control" },
});

const requested = app.node.tryGetContext("environment");
if (requested) {
  const environmentName = assertEnvironmentName(String(requested));
  const prefix = String(app.node.tryGetContext("prefix") ?? objectPrefix(environmentName));
  new EnvironmentStack(app, `StrmBank-${environmentName}`, {
    env,
    description: `${prefix} website + data buckets`,
    environmentName,
    prefix,
    tags: {
      Project: PROJECT,
      Environment: environmentName,
      EnvPrefix: prefix,
    },
  });
}
