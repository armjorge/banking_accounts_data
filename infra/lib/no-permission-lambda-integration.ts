import type { HttpRouteIntegrationBindOptions } from "aws-cdk-lib/aws-apigatewayv2";
import { HttpLambdaIntegration } from "aws-cdk-lib/aws-apigatewayv2-integrations";

/**
 * Same Lambda proxy integration as HttpLambdaIntegration, without a
 * AWS::Lambda::Permission per route. The stack grants one invoke permission
 * for the whole API; dozens of route permissions blow the 20 KB resource policy.
 */
export class NoPermissionLambdaIntegration extends HttpLambdaIntegration {
  protected completeBind(_options: HttpRouteIntegrationBindOptions): void {
    // HttpLambdaIntegration.completeBind calls handler.addPermission once per route.
  }
}
