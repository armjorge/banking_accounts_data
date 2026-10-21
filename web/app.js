const STORAGE_KEY = "strm_tokens";

function config() {
  const cfg = window.STRM_CONFIG;
  if (!cfg || !cfg.clientId || !cfg.cognitoDomain) {
    throw new Error("config.js is missing Cognito settings. Publish the site from the control plane.");
  }
  return cfg;
}

function randomString(bytes = 32) {
  const array = new Uint8Array(bytes);
  crypto.getRandomValues(array);
  return Array.from(array, (value) => value.toString(16).padStart(2, "0")).join("");
}

function base64Url(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  bytes.forEach((value) => {
    binary += String.fromCharCode(value);
  });
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

async function sha256(input) {
  const data = new TextEncoder().encode(input);
  return crypto.subtle.digest("SHA-256", data);
}

function decodeJwt(token) {
  const payload = token.split(".")[1];
  const json = atob(payload.replace(/-/g, "+").replace(/_/g, "/"));
  return JSON.parse(json);
}

function saveTokens(tokens) {
  sessionStorage.setItem(STORAGE_KEY, JSON.stringify(tokens));
}

function readTokens() {
  const raw = sessionStorage.getItem(STORAGE_KEY);
  if (!raw) {
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function clearTokens() {
  sessionStorage.removeItem(STORAGE_KEY);
}

async function login() {
  const cfg = config();
  const verifier = randomString(32);
  sessionStorage.setItem("strm_pkce", verifier);
  const challenge = base64Url(await sha256(verifier));
  const params = new URLSearchParams({
    client_id: cfg.clientId,
    response_type: "code",
    scope: "openid email profile",
    redirect_uri: cfg.redirectUri,
    code_challenge: challenge,
    code_challenge_method: "S256",
  });
  window.location.assign(`${cfg.cognitoDomain}/login?${params.toString()}`);
}

function logout() {
  const cfg = config();
  clearTokens();
  const params = new URLSearchParams({
    client_id: cfg.clientId,
    logout_uri: cfg.logoutUri,
  });
  window.location.assign(`${cfg.cognitoDomain}/logout?${params.toString()}`);
}

async function exchangeCode(code) {
  const cfg = config();
  const verifier = sessionStorage.getItem("strm_pkce");
  if (!verifier) {
    throw new Error("Missing PKCE verifier. Start login from this site again.");
  }
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: cfg.clientId,
    code,
    redirect_uri: cfg.redirectUri,
    code_verifier: verifier,
  });
  const response = await fetch(`${cfg.cognitoDomain}/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!response.ok) {
    throw new Error(`Token exchange failed (${response.status})`);
  }
  const tokens = await response.json();
  saveTokens(tokens);
  sessionStorage.removeItem("strm_pkce");
  window.history.replaceState({}, document.title, "/");
}

function render(root, html) {
  root.innerHTML = html;
}

async function main() {
  const root = document.getElementById("app");
  try {
    config();
  } catch (error) {
    render(root, `<h1>Strm Bank</h1><p class="error">${error.message}</p>`);
    return;
  }

  const params = new URLSearchParams(window.location.search);
  if (params.get("code")) {
    render(root, "<p>Signing you in…</p>");
    try {
      await exchangeCode(params.get("code"));
    } catch (error) {
      render(
        root,
        `<h1>Sign-in failed</h1><p class="error">${error.message}</p><button id="retry">Try again</button>`,
      );
      document.getElementById("retry").addEventListener("click", login);
      return;
    }
  }

  const tokens = readTokens();
  if (!tokens?.id_token) {
    render(
      root,
      `<h1>Strm Bank</h1><p>Sign in with your environment Cognito user to continue.</p><p>If Cognito says the account is already confirmed, go back and sign in instead of entering another email code.</p><button id="login">Sign in</button>`,
    );
    document.getElementById("login").addEventListener("click", login);
    return;
  }

  const claims = decodeJwt(tokens.id_token);
  const name = claims.email || claims["cognito:username"] || claims.sub;
  if (window.isAdminClaim(claims)) {
    window.renderMasterBanking(root, { name, logout });
    return;
  }
  window.renderStatements(root, { name, logout, embedded: false });
}

main();
