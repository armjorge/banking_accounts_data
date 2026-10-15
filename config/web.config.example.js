// Copy to web/config.js. Do not commit that copy.
// Prefer downloading the published file and changing only the two localhost lines:
//   curl -fsS "https://YOUR_DOMAIN.cloudfront.net/config.js" -o web/config.js
// Or fill these from Streamlit "Deployed outputs" (user-pool-id, user-pool-client-id, api-url).
// cognitoDomain is https://<prefix-without-underscores>auth.auth.<region>.amazoncognito.com
window.STRM_CONFIG = {
  region: "us-east-1",
  userPoolId: "us-east-1_XXXXXXXXX",
  clientId: "your-user-pool-client-id",
  identityPoolId: "",
  cognitoDomain: "https://strmbankdevauth.auth.us-east-1.amazoncognito.com",
  redirectUri: "http://localhost:5173/",
  logoutUri: "http://localhost:5173/",
  websiteBucket: "",
  webUrl: "http://localhost:5173",
  apiUrl: "https://xxxxxxxxxx.execute-api.us-east-1.amazonaws.com",
};
