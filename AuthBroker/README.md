# Triage Auth Broker

This deployable Cloudflare Worker is the minimal OAuth boundary for Triage. It exchanges GitHub OAuth authorization codes and refresh tokens without putting the GitHub OAuth client secret in the macOS app.

## API contract

All successful JSON responses and failures include `version: 1`. Responses are `application/json`, `Cache-Control: no-store`, and never set cookies.

| Endpoint | JSON input |
| --- | --- |
| `POST /oauth/exchange` | `{ "version": 1, "authorizationCode": "...", "codeVerifier": "...", "redirectURI": "triage://oauth-callback" }` |
| `POST /oauth/refresh` | `{ "version": 1, "refreshToken": "..." }` |
| `GET /health` | No body; returns `{ "version": 1, "status": "ok" }` when configuration is valid. |

The exchange endpoint requires an RFC 7636 verifier: 43–128 ASCII characters from `[A-Za-z0-9-._~]`. The supplied redirect URI must byte-for-byte match `ALLOWED_REDIRECT_URI`; the configured URI must be an `https` or `triage` URI with a host, no credentials, port, or fragment.

GitHub token fields are mapped from snake case to the Triage app's camel-case protocol:

```json
{
  "version": 1,
  "accessToken": "...",
  "refreshToken": "...",
  "tokenType": "bearer",
  "scope": "repo read:org",
  "expiresIn": 28800,
  "refreshTokenExpiresIn": 15552000
}
```

Errors have only stable, non-sensitive codes: `invalidRequest`, `authorizationDenied`, `invalidGrant`, `invalidClient`, `temporarilyUnavailable`, or `unavailable`. Upstream error text is never returned.

## Deploying

1. Copy `wrangler.toml.template` to `wrangler.toml`, set a unique Worker name and the exact callback URI, then uncomment and replace the production `routes` entry.
2. Configure bindings outside source control:

   ```sh
   cd AuthBroker
   wrangler secret put GITHUB_OAUTH_CLIENT_ID
   wrangler secret put GITHUB_OAUTH_CLIENT_SECRET
   ```

   The client ID is not confidential, but a secret binding prevents environment-specific configuration from entering the repository. The client secret **must** be a Cloudflare secret binding.
3. Deploy with `npm run deploy`.

Use a dedicated GitHub OAuth App. Its Authorization callback URL must exactly equal `ALLOWED_REDIRECT_URI`, including the `triage` scheme, host, path, and any casing. Triage initiates Authorization Code + PKCE with S256, state validation, and `offline_access`; this Worker only performs the token-side exchange. Do not register a Worker URL as the callback unless that exact HTTPS URL is the configured application callback.

The Worker itself enforces HTTPS, strict paths and methods, JSON content type, a 16 KiB request limit, strict schema/version/value validation, a 32 KiB upstream/output limit, and makes only explicit form-encoded `POST` requests to GitHub's token endpoint with `Accept: application/json`.

## Required perimeter controls

This Worker is stateless, so it cannot do one-use nonce storage or durable per-IP counters. Before production deployment, configure Cloudflare WAF/rate-limiting rules for `POST /oauth/exchange` and `POST /oauth/refresh`:

- Rate-limit by client IP and apply a separate tighter rule for malformed/abusive traffic.
- Permit only HTTPS at the zone/edge and enable Cloudflare managed WAF rules.
- Restrict Worker routes to its intended hostname; do not expose a development `workers.dev` route.
- Monitor only aggregate platform health counters. Configure log sinks and WAF/Worker observability to redact request URLs, headers, and bodies; never retain authorization codes, PKCE verifiers, refresh tokens, access tokens, `client_secret`, or IP-derived analytics identifiers.

CORS is disabled by default because Triage is a native client. If `CORS_ALLOWED_ORIGINS` is configured as a comma-separated list of exact HTTPS browser origins, matching origins receive only `POST` and `Content-Type` CORS permission. CORS is not authentication and non-matching browser requests must not be considered blocked at the network layer.

## Threat model and limitations

The Worker keeps no database, KV/D1/R2 storage, durable queue, sessions, cookies, tokens, GitHub content, analytics IDs, or request-body logs. It forwards only protocol fields plus the server-held GitHub credentials. It deliberately has no public-client attestation mechanism: a distributed macOS public client cannot safely keep a shared secret, signing key, or device assertion. PKCE binds an intercepted authorization code to its verifier, but it does **not** authenticate a caller to this broker or prevent a determined party from invoking the public endpoint.

Consequently, the Worker protects the OAuth client secret and applies strict protocol handling; Cloudflare edge rate limits/WAF protect availability. It cannot revoke leaked public-client requests, persist replay state, replace the app's PKCE/state/callback validation, or make browser CORS a security boundary. Rotate the GitHub client secret through Cloudflare bindings if compromise is suspected.

## Local verification

Requires Node.js and npm:

```sh
cd AuthBroker
npm install
npm run typecheck
npm test
```
