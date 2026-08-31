# Triage Auth Broker

This deployable Cloudflare Worker is the minimal OAuth boundary for Triage. It exchanges GitHub OAuth authorization codes and refresh tokens without putting the GitHub OAuth client secret in the macOS app.

## API contract

All successful JSON responses and failures include `version: 1`. Responses are `application/json`, `Cache-Control: no-store`, and never set cookies.

| Endpoint | JSON input |
| --- | --- |
| `POST /oauth/exchange` | `{ "version": 1, "authorizationCode": "...", "codeVerifier": "...", "redirectURI": "triage://oauth-callback", "nonce": "...", "issuedAt": 0, "expiresAt": 0 }` |
| `POST /oauth/refresh` | `{ "version": 1, "refreshToken": "...", "nonce": "...", "issuedAt": 0, "expiresAt": 0 }` |
| `GET /health` | No body; returns `{ "version": 1, "status": "ok" }` when configuration is valid. |

The exchange endpoint requires an RFC 7636 verifier: 43–128 ASCII characters from `[A-Za-z0-9-._~]`. The supplied redirect URI must byte-for-byte match `ALLOWED_REDIRECT_URI`; the configured URI must be an `https` or `triage` URI with a host, no credentials, port, or fragment.

Every `POST` must also include `X-Triage-Application-Version` as a stable
`major.minor.patch` version at or above `MINIMUM_APPLICATION_VERSION`. The app
creates a fresh 256-bit base64url `nonce` for each request. `issuedAt` and
`expiresAt` are Unix milliseconds: the lifetime may not exceed 60 seconds,
expired/future requests are rejected, and an accepted nonce can never be used
again. A retry must create a new request control value.

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

1. Copy `wrangler.toml.template` to `wrangler.toml`, set a unique Worker name, the exact callback URI, the minimum supported app version, and the production route. Keep `workers_dev = false`; the Worker trusts Cloudflare's edge-provided client-IP header only on that route.
2. Configure bindings outside source control:

   ```sh
   cd AuthBroker
   wrangler secret put GITHUB_OAUTH_CLIENT_ID
   wrangler secret put GITHUB_OAUTH_CLIENT_SECRET
   wrangler secret put REQUEST_CONTROL_HASH_KEY
   ```

   The client ID is not confidential, but a secret binding prevents environment-specific configuration from entering the repository. The client secret **must** be a Cloudflare secret binding. `REQUEST_CONTROL_HASH_KEY` must be a distinct random secret; it derives opaque, short-lived rate bucket keys and must never be rotated casually while requests are in flight.
3. Deploy with `npm run deploy`.

Use a dedicated GitHub OAuth App. Its Authorization callback URL must exactly equal `ALLOWED_REDIRECT_URI`, including the `triage` scheme, host, path, and any casing. Triage initiates Authorization Code + PKCE with S256, state validation, and `offline_access`; this Worker only performs the token-side exchange. Do not register a Worker URL as the callback unless that exact HTTPS URL is the configured application callback.

The Worker itself enforces HTTPS, strict paths and methods, JSON content type, a 16 KiB request limit, application/protocol version validation, one-use expiring request controls, a 32 KiB upstream/output limit, and makes only explicit form-encoded `POST` requests to GitHub's token endpoint with `Accept: application/json`.

## Required deployment controls

`OAUTH_REQUEST_GUARD` is a mandatory Cloudflare Durable Object binding. It serializes nonce consumption and enforces the configured global request and per-IP minute limits. It keeps only nonce hashes and HMAC-derived IP bucket keys until their short expiry; it stores no OAuth payloads, tokens, raw IP addresses, or analytics. Missing, unreachable, or malformed guard configuration makes `/health` unavailable and both OAuth endpoints fail closed.

Before production deployment, configure Cloudflare WAF rules for `POST /oauth/exchange` and `POST /oauth/refresh`:

- Apply a separate tighter WAF/rate rule for malformed or abusive traffic; the Durable Object limits are the authoritative in-worker controls, not a substitute for edge DDoS protection.
- Permit only HTTPS at the zone/edge and enable Cloudflare managed WAF rules.
- Restrict Worker routes to its intended hostname; do not expose a development `workers.dev` route.
- Monitor only aggregate platform health counters. Configure log sinks and WAF/Worker observability to redact request URLs, headers, and bodies; never retain authorization codes, PKCE verifiers, refresh tokens, access tokens, `client_secret`, or IP-derived analytics identifiers.

CORS is disabled by default because Triage is a native client. If `CORS_ALLOWED_ORIGINS` is configured as a comma-separated list of exact HTTPS browser origins, matching origins receive CORS permission only for `POST` and the `Content-Type` and `X-Triage-Application-Version` headers. CORS is not authentication and non-matching browser requests must not be considered blocked at the network layer.

## Threat model and limitations

The Worker keeps no database, KV/D1/R2 storage, durable queue, sessions, cookies, tokens, GitHub content, analytics IDs, or request-body logs. Its one required Durable Object holds only the short-lived opaque anti-replay and rate-control keys described above. It forwards only protocol fields plus the server-held GitHub credentials. It deliberately has no public-client attestation mechanism: a distributed macOS public client cannot safely keep a shared secret, signing key, or device assertion. PKCE binds an intercepted authorization code to its verifier, but it does **not** authenticate a caller to this broker or prevent a determined party from invoking the public endpoint.

Consequently, the Worker protects the OAuth client secret, applies one-use request controls, and rate-limits its own protocol boundary; Cloudflare WAF protects broader edge availability. It cannot revoke leaked public-client requests, replace the app's PKCE/state/callback validation, or make browser CORS a security boundary. Rotate the GitHub client secret through Cloudflare bindings if compromise is suspected.

## Local verification

Requires Node.js and npm:

```sh
cd AuthBroker
npm install
npm run typecheck
npm test
```
