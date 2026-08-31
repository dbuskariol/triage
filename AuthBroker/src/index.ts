const PROTOCOL_VERSION = 1;
const MAX_REQUEST_BYTES = 16 * 1024;
const MAX_RESPONSE_BYTES = 32 * 1024;
const REQUEST_LIFETIME_MS = 60_000;
const GITHUB_TOKEN_ENDPOINT = "https://github.com/login/oauth/access_token";
const PKCE_VERIFIER = /^[A-Za-z0-9\-._~]{43,128}$/;
const REQUEST_NONCE = /^[A-Za-z0-9_-]{43,128}$/;
const APPLICATION_VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

interface RequestGuardNamespace {
  idFromName(name: string): unknown;
  get(id: unknown): {
    fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>;
  };
}

export interface Env {
  GITHUB_OAUTH_CLIENT_ID: string;
  GITHUB_OAUTH_CLIENT_SECRET: string;
  ALLOWED_REDIRECT_URI: string;
  MINIMUM_APPLICATION_VERSION: string;
  REQUEST_RATE_LIMIT_PER_MINUTE: string;
  IP_RATE_LIMIT_PER_MINUTE: string;
  REQUEST_CONTROL_HASH_KEY: string;
  OAUTH_REQUEST_GUARD: RequestGuardNamespace;
  CORS_ALLOWED_ORIGINS?: string;
}

type FailureCode =
  | "invalidRequest"
  | "authorizationDenied"
  | "invalidGrant"
  | "invalidClient"
  | "temporarilyUnavailable"
  | "unavailable";

interface Failure {
  version: typeof PROTOCOL_VERSION;
  code: FailureCode;
  recoveryDescription: string;
}

interface BrokerConfiguration {
  clientID: string;
  clientSecret: string;
  redirectURI: string;
  minimumApplicationVersion: ApplicationVersion;
  requestRateLimitPerMinute: number;
  ipRateLimitPerMinute: number;
  corsOrigins: Set<string>;
}

interface ApplicationVersion {
  major: number;
  minor: number;
  patch: number;
}

interface RequestControl {
  nonce: string;
  issuedAt: number;
  expiresAt: number;
}

interface GitHubTokenResponse {
  access_token: string;
  refresh_token?: string;
  token_type: string;
  scope?: string;
  expires_in?: number;
  refresh_token_expires_in?: number;
}

class RequestProblem extends Error {
  constructor(
    readonly status: number,
    readonly code: FailureCode,
    readonly recoveryDescription: string,
  ) {
    super(code);
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env);
  },
} satisfies ExportedHandler<Env>;

export async function handleRequest(request: Request, env: Env): Promise<Response> {
  const requestURL = new URL(request.url);
  let corsOrigins = new Set<string>();

  try {
    corsOrigins = parseCORSOrigins(env.CORS_ALLOWED_ORIGINS);
    if (requestURL.protocol !== "https:") {
      throw invalidRequest("The request must use HTTPS.");
    }

    if (requestURL.search || requestURL.hash) {
      throw invalidRequest("The request is invalid or unsupported.");
    }

    if (request.method === "OPTIONS") {
      return handlePreflight(request, requestURL.pathname, corsOrigins);
    }

    if (requestURL.pathname === "/health") {
      if (request.method !== "GET") {
        return failureResponse(
          new RequestProblem(405, "invalidRequest", "The request is invalid or unsupported."),
          corsOrigins,
          request,
          "GET",
        );
      }

      const configuration = readConfiguration(env, corsOrigins);
      if (!configuration || !(await isRequestGuardAvailable(env))) {
        return healthResponse("unavailable", corsOrigins, request, 503);
      }
      return healthResponse("ok", corsOrigins, request);
    }

    if (requestURL.pathname !== "/oauth/exchange" && requestURL.pathname !== "/oauth/refresh") {
      throw invalidRequest("The request is invalid or unsupported.", 404);
    }
    if (request.method !== "POST") {
      return failureResponse(
        new RequestProblem(405, "invalidRequest", "The request is invalid or unsupported."),
        corsOrigins,
        request,
        "POST",
      );
    }
    if (request.headers.has("cookie")) {
      throw invalidRequest("The request is invalid or unsupported.");
    }
    if (!isJSONContentType(request.headers.get("content-type"))) {
      throw invalidRequest("The request content type must be application/json.");
    }

    const configuration = readConfiguration(env, corsOrigins);
    if (!configuration) {
      throw new RequestProblem(
        502,
        "invalidClient",
        "OAuth broker configuration is unavailable.",
      );
    }

    const input = await parseJSONBody(request);
    const applicationVersion = requireApplicationVersion(
      request.headers.get("x-triage-application-version"),
      configuration.minimumApplicationVersion,
    );
    const control = requestControl(input);
    const form =
      requestURL.pathname === "/oauth/exchange"
        ? exchangeForm(input, configuration, control)
        : refreshForm(input, configuration, control);
    await consumeRequestControl(
      env,
      request,
      requestURL.pathname,
      applicationVersion,
      control,
      configuration,
    );
    const token = await exchangeWithGitHub(form);

    return tokenResponse(token, corsOrigins, request);
  } catch (error) {
    if (error instanceof RequestProblem) {
      return failureResponse(error, corsOrigins, request);
    }

    return failureResponse(
      new RequestProblem(503, "unavailable", "The OAuth service is unavailable. Try again later."),
      corsOrigins,
      request,
    );
  }
}

function parseCORSOrigins(value: string | undefined): Set<string> {
  if (!value || !value.trim()) {
    return new Set();
  }

  const origins = new Set<string>();
  for (const item of value.split(",")) {
    const origin = item.trim();
    let url: URL;
    try {
      url = new URL(origin);
    } catch {
      throw new RequestProblem(503, "unavailable", "The OAuth service is unavailable. Try again later.");
    }
    if (
      url.protocol !== "https:" ||
      url.origin !== origin ||
      url.username ||
      url.password
    ) {
      throw new RequestProblem(503, "unavailable", "The OAuth service is unavailable. Try again later.");
    }
    origins.add(origin);
  }
  return origins;
}

function readConfiguration(env: Env, corsOrigins: Set<string>): BrokerConfiguration | undefined {
  if (
    !isSafeBinding(env.GITHUB_OAUTH_CLIENT_ID, 512) ||
    !isSafeBinding(env.GITHUB_OAUTH_CLIENT_SECRET, 512) ||
    !isValidConfiguredRedirectURI(env.ALLOWED_REDIRECT_URI) ||
    !parseApplicationVersion(env.MINIMUM_APPLICATION_VERSION) ||
    !parsePositiveInteger(env.REQUEST_RATE_LIMIT_PER_MINUTE, 10_000) ||
    !parsePositiveInteger(env.IP_RATE_LIMIT_PER_MINUTE, 1_000) ||
    !isValidRequestControlHashKey(env.REQUEST_CONTROL_HASH_KEY) ||
    !env.OAUTH_REQUEST_GUARD
  ) {
    return undefined;
  }

  return {
    clientID: env.GITHUB_OAUTH_CLIENT_ID,
    clientSecret: env.GITHUB_OAUTH_CLIENT_SECRET,
    redirectURI: env.ALLOWED_REDIRECT_URI,
    minimumApplicationVersion: parseApplicationVersion(env.MINIMUM_APPLICATION_VERSION)!,
    requestRateLimitPerMinute: parsePositiveInteger(env.REQUEST_RATE_LIMIT_PER_MINUTE, 10_000)!,
    ipRateLimitPerMinute: parsePositiveInteger(env.IP_RATE_LIMIT_PER_MINUTE, 1_000)!,
    corsOrigins,
  };
}

function isSafeBinding(value: string | undefined, maximumLength: number): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= maximumLength &&
    !/[\u0000-\u001F\u007F]/.test(value)
  );
}

function isValidRequestControlHashKey(value: string | undefined): value is string {
  return isSafeBinding(value, 512) && value.length >= 32;
}

function isValidConfiguredRedirectURI(value: string | undefined): value is string {
  if (!isSafeBinding(value, 2_048)) {
    return false;
  }

  try {
    const url = new URL(value);
    return (
      (url.protocol === "https:" || url.protocol === "triage:") &&
      Boolean(url.hostname) &&
      !url.username &&
      !url.password &&
      !url.port &&
      !url.hash
    );
  } catch {
    return false;
  }
}

async function handlePreflight(
  request: Request,
  pathname: string,
  corsOrigins: Set<string>,
): Promise<Response> {
  const origin = request.headers.get("origin");
  const requestedMethod = request.headers.get("access-control-request-method");
  const requestedHeaders = request.headers.get("access-control-request-headers");

  if (
    (pathname !== "/oauth/exchange" && pathname !== "/oauth/refresh") ||
    !origin ||
    !corsOrigins.has(origin) ||
    requestedMethod?.toUpperCase() !== "POST" ||
    !requestedHeadersAreAllowed(requestedHeaders)
  ) {
    return failureResponse(
      new RequestProblem(403, "invalidRequest", "The request is invalid or unsupported."),
      corsOrigins,
      request,
    );
  }

  const headers = responseHeaders(corsOrigins, request);
  headers.set("Access-Control-Allow-Methods", "POST");
  headers.set("Access-Control-Allow-Headers", "Content-Type, X-Triage-Application-Version");
  headers.set("Access-Control-Max-Age", "600");
  return new Response(null, { status: 204, headers });
}

function requestedHeadersAreAllowed(value: string | null): boolean {
  if (!value || !value.trim()) {
    return true;
  }
  return value
    .split(",")
    .every((header) => {
      const normalized = header.trim().toLowerCase();
      return normalized === "content-type" || normalized === "x-triage-application-version";
    });
}

function isJSONContentType(value: string | null): boolean {
  return value?.split(";", 1)[0]?.trim().toLowerCase() === "application/json";
}

async function parseJSONBody(request: Request): Promise<Record<string, unknown>> {
  const contentLength = request.headers.get("content-length");
  if (contentLength !== null && !/^\d+$/.test(contentLength)) {
    throw invalidRequest("The request is invalid or unsupported.");
  }
  if (contentLength !== null && Number(contentLength) > MAX_REQUEST_BYTES) {
    throw new RequestProblem(413, "invalidRequest", "The request body is too large.");
  }

  const bytes = await readBoundedBody(request.body, MAX_REQUEST_BYTES, 413, "The request body is too large.");
  if (bytes.byteLength === 0) {
    throw invalidRequest("The request body is required.");
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(
      new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes),
    );
  } catch {
    throw invalidRequest("The request body must be valid JSON.");
  }

  if (!isRecord(parsed)) {
    throw invalidRequest("The request is invalid or unsupported.");
  }
  return parsed;
}

async function readBoundedBody(
  body: ReadableStream<Uint8Array> | null,
  maximumBytes: number,
  status: number,
  description: string,
): Promise<Uint8Array> {
  if (!body) {
    return new Uint8Array();
  }

  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      total += value.byteLength;
      if (total > maximumBytes) {
        await reader.cancel();
        throw new RequestProblem(status, "invalidRequest", description);
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

function exchangeForm(
  input: Record<string, unknown>,
  config: BrokerConfiguration,
  control: RequestControl,
): URLSearchParams {
  requireExactKeys(input, [
    "version", "authorizationCode", "codeVerifier", "redirectURI", "nonce", "issuedAt", "expiresAt",
  ]);
  requireVersion(input.version);
  requireRequestControl(input, control);
  const authorizationCode = requireSecret(input.authorizationCode);
  const codeVerifier = requireString(input.codeVerifier, 128);
  const redirectURI = requireRedirectURI(input.redirectURI, config.redirectURI);

  if (!PKCE_VERIFIER.test(codeVerifier)) {
    throw invalidRequest("The PKCE verifier is invalid.");
  }

  return new URLSearchParams({
    client_id: config.clientID,
    client_secret: config.clientSecret,
    code: authorizationCode,
    code_verifier: codeVerifier,
    redirect_uri: redirectURI,
  });
}

function refreshForm(
  input: Record<string, unknown>,
  config: BrokerConfiguration,
  control: RequestControl,
): URLSearchParams {
  requireExactKeys(input, ["version", "refreshToken", "nonce", "issuedAt", "expiresAt"]);
  requireVersion(input.version);
  requireRequestControl(input, control);
  const refreshToken = requireSecret(input.refreshToken);

  return new URLSearchParams({
    client_id: config.clientID,
    client_secret: config.clientSecret,
    grant_type: "refresh_token",
    refresh_token: refreshToken,
  });
}

function requireExactKeys(input: Record<string, unknown>, expected: string[]): void {
  const keys = Object.keys(input).sort();
  const expectedKeys = [...expected].sort();
  if (
    keys.length !== expectedKeys.length ||
    keys.some((key, index) => key !== expectedKeys[index])
  ) {
    throw invalidRequest("The request is invalid or unsupported.");
  }
}

function requireVersion(value: unknown): void {
  if (value !== PROTOCOL_VERSION) {
    throw invalidRequest("The request version is unsupported.");
  }
}

function requestControl(input: Record<string, unknown>): RequestControl {
  const nonce = requireString(input.nonce, 128);
  const issuedAt = requireTimestamp(input.issuedAt);
  const expiresAt = requireTimestamp(input.expiresAt);
  if (!REQUEST_NONCE.test(nonce)) {
    throw invalidRequest("The request is invalid or unsupported.");
  }
  return { nonce, issuedAt, expiresAt };
}

function requireRequestControl(input: Record<string, unknown>, control: RequestControl): void {
  if (
    input.nonce !== control.nonce ||
    input.issuedAt !== control.issuedAt ||
    input.expiresAt !== control.expiresAt
  ) {
    throw invalidRequest("The request is invalid or unsupported.");
  }
}

function requireTimestamp(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) <= 0) {
    throw invalidRequest("The request is invalid or unsupported.");
  }
  return value as number;
}

function requireApplicationVersion(
  value: string | null,
  minimumVersion: ApplicationVersion,
): string {
  const version = typeof value === "string" ? parseApplicationVersion(value) : undefined;
  if (!version || compareApplicationVersions(version, minimumVersion) < 0) {
    throw invalidRequest("This version of Triage is not supported by the OAuth service.");
  }
  return value!;
}

function parseApplicationVersion(value: string | undefined): ApplicationVersion | undefined {
  if (!value || !APPLICATION_VERSION.test(value)) {
    return undefined;
  }
  const [major, minor, patch] = value.split(".").map(Number);
  if (![major, minor, patch].every(Number.isSafeInteger)) {
    return undefined;
  }
  return { major, minor, patch };
}

function compareApplicationVersions(left: ApplicationVersion, right: ApplicationVersion): number {
  if (left.major !== right.major) return left.major - right.major;
  if (left.minor !== right.minor) return left.minor - right.minor;
  return left.patch - right.patch;
}

function parsePositiveInteger(value: string | undefined, maximum: number): number | undefined {
  if (!value || !/^\d+$/.test(value)) {
    return undefined;
  }
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 && parsed <= maximum ? parsed : undefined;
}

async function isRequestGuardAvailable(env: Env): Promise<boolean> {
  try {
    const id = env.OAUTH_REQUEST_GUARD.idFromName("oauth-request-control-v1");
    const response = await env.OAUTH_REQUEST_GUARD.get(id).fetch("https://request-guard/health");
    return response.status === 204;
  } catch {
    return false;
  }
}

async function consumeRequestControl(
  env: Env,
  request: Request,
  endpoint: string,
  _applicationVersion: string,
  control: RequestControl,
  configuration: BrokerConfiguration,
): Promise<void> {
  const clientIP = trustedClientIP(request);
  const now = Date.now();
  if (
    control.issuedAt > now ||
    control.expiresAt <= now ||
    control.expiresAt <= control.issuedAt ||
    control.expiresAt - control.issuedAt > REQUEST_LIFETIME_MS
  ) {
    throw invalidRequest("The request has expired. Start GitHub sign-in again.");
  }

  const id = env.OAUTH_REQUEST_GUARD.idFromName("oauth-request-control-v1");
  let response: Response;
  try {
    response = await env.OAUTH_REQUEST_GUARD.get(id).fetch("https://request-guard/consume", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        nonce: control.nonce,
        expiresAt: control.expiresAt,
        clientIP,
        endpoint,
        now,
        requestRateLimitPerMinute: configuration.requestRateLimitPerMinute,
        ipRateLimitPerMinute: configuration.ipRateLimitPerMinute,
      }),
    });
  } catch {
    throw new RequestProblem(503, "unavailable", "The OAuth service is unavailable. Try again later.");
  }

  if (!response.ok) {
    if (response.status === 409) {
      throw invalidRequest("The request has already been used. Start GitHub sign-in again.");
    }
    if (response.status === 429) {
      throw new RequestProblem(429, "temporarilyUnavailable", "Too many OAuth requests. Try again later.");
    }
    throw new RequestProblem(503, "unavailable", "The OAuth service is unavailable. Try again later.");
  }
}

function trustedClientIP(request: Request): string {
  // Cloudflare sets this header at its edge. Route deployment must keep
  // workers.dev disabled so callers cannot bypass the trusted edge.
  const value = request.headers.get("cf-connecting-ip");
  if (!value || value.length > 64 || !/^[0-9A-Fa-f:.]+$/.test(value)) {
    throw new RequestProblem(503, "unavailable", "The OAuth service is unavailable. Try again later.");
  }
  return value;
}

function requireSecret(value: unknown): string {
  return requireString(value, 4_096);
}

function requireString(value: unknown, maximumLength: number): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > maximumLength ||
    value.trim() !== value ||
    /[\u0000-\u001F\u007F]/.test(value)
  ) {
    throw invalidRequest("The request is invalid or unsupported.");
  }
  return value;
}

function requireRedirectURI(value: unknown, configuredURI: string): string {
  const redirectURI = requireString(value, 2_048);
  if (redirectURI !== configuredURI || !isValidConfiguredRedirectURI(redirectURI)) {
    throw invalidRequest("The redirect URI is not allowed.");
  }
  return redirectURI;
}

async function exchangeWithGitHub(form: URLSearchParams): Promise<GitHubTokenResponse> {
  let response: Response;
  try {
    response = await fetch(GITHUB_TOKEN_ENDPOINT, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form.toString(),
      redirect: "error",
    });
  } catch {
    throw new RequestProblem(
      503,
      "temporarilyUnavailable",
      "GitHub is temporarily unavailable. Try again.",
    );
  }

  if (response.status === 429 || response.status >= 500) {
    throw new RequestProblem(
      503,
      "temporarilyUnavailable",
      "GitHub is temporarily unavailable. Try again.",
    );
  }

  let payload: unknown;
  try {
    const bytes = await readBoundedBody(
      response.body,
      MAX_RESPONSE_BYTES,
      502,
      "The OAuth service is unavailable. Try again later.",
    );
    payload = JSON.parse(
      new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes),
    );
  } catch (error) {
    if (error instanceof RequestProblem) {
      throw new RequestProblem(502, "unavailable", "The OAuth service is unavailable. Try again later.");
    }
    throw new RequestProblem(502, "unavailable", "The OAuth service is unavailable. Try again later.");
  }

  if (isRecord(payload) && typeof payload.error === "string") {
    throw mapGitHubFailure(response.status, payload);
  }
  if (!response.ok) {
    throw mapGitHubFailure(response.status, payload);
  }
  return validateGitHubTokenResponse(payload);
}

function mapGitHubFailure(status: number, payload: unknown): RequestProblem {
  const error = isRecord(payload) && typeof payload.error === "string" ? payload.error : "";
  if (error === "access_denied" || status === 403) {
    return new RequestProblem(401, "authorizationDenied", "GitHub did not authorize this request.");
  }
  if (error === "incorrect_client_credentials" || error === "invalid_client" || status === 401) {
    return new RequestProblem(502, "invalidClient", "OAuth broker configuration is unavailable.");
  }
  if (error === "invalid_request") {
    return invalidRequest("The request is invalid or unsupported.");
  }
  if (error === "temporarily_unavailable") {
    return new RequestProblem(
      503,
      "temporarilyUnavailable",
      "GitHub is temporarily unavailable. Try again.",
    );
  }
  return new RequestProblem(400, "invalidGrant", "The authorization grant is invalid or has expired.");
}

function validateGitHubTokenResponse(payload: unknown): GitHubTokenResponse {
  if (!isRecord(payload)) {
    throw new RequestProblem(502, "unavailable", "The OAuth service is unavailable. Try again later.");
  }

  const accessToken = requireUpstreamString(payload.access_token, 16_384);
  const tokenType = requireUpstreamString(payload.token_type, 64);
  const refreshToken = optionalUpstreamString(payload.refresh_token, 16_384);
  const scope = optionalUpstreamString(payload.scope, 4_096);
  const expiresIn = optionalUpstreamExpiration(payload.expires_in);
  const refreshTokenExpiresIn = optionalUpstreamExpiration(payload.refresh_token_expires_in);

  return {
    access_token: accessToken,
    token_type: tokenType,
    ...(refreshToken ? { refresh_token: refreshToken } : {}),
    ...(scope ? { scope } : {}),
    ...(expiresIn !== undefined ? { expires_in: expiresIn } : {}),
    ...(refreshTokenExpiresIn !== undefined
      ? { refresh_token_expires_in: refreshTokenExpiresIn }
      : {}),
  };
}

function requireUpstreamString(value: unknown, maximumLength: number): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > maximumLength ||
    /[\u0000-\u001F\u007F]/.test(value)
  ) {
    throw new RequestProblem(502, "unavailable", "The OAuth service is unavailable. Try again later.");
  }
  return value;
}

function optionalUpstreamString(value: unknown, maximumLength: number): string | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  return requireUpstreamString(value, maximumLength);
}

function optionalUpstreamExpiration(value: unknown): number | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new RequestProblem(502, "unavailable", "The OAuth service is unavailable. Try again later.");
  }
  return value;
}

function tokenResponse(
  token: GitHubTokenResponse,
  corsOrigins: Set<string>,
  request: Request,
): Response {
  const response = {
    version: PROTOCOL_VERSION,
    accessToken: token.access_token,
    tokenType: token.token_type,
    ...(token.refresh_token ? { refreshToken: token.refresh_token } : {}),
    ...(token.scope ? { scope: token.scope } : {}),
    ...(token.expires_in !== undefined ? { expiresIn: token.expires_in } : {}),
    ...(token.refresh_token_expires_in !== undefined
      ? { refreshTokenExpiresIn: token.refresh_token_expires_in }
      : {}),
  };
  return jsonResponse(response, 200, corsOrigins, request);
}

function healthResponse(
  status: "ok" | "unavailable",
  corsOrigins: Set<string>,
  request: Request,
  httpStatus = 200,
): Response {
  return jsonResponse({ version: PROTOCOL_VERSION, status }, httpStatus, corsOrigins, request);
}

function failureResponse(
  problem: RequestProblem,
  corsOrigins: Set<string>,
  request: Request,
  allow?: string,
): Response {
  const response = jsonResponse(
    {
      version: PROTOCOL_VERSION,
      code: problem.code,
      recoveryDescription: problem.recoveryDescription,
    } satisfies Failure,
    problem.status,
    corsOrigins,
    request,
  );
  if (allow) {
    response.headers.set("Allow", allow);
  }
  return response;
}

function jsonResponse(
  value: unknown,
  status: number,
  corsOrigins: Set<string>,
  request: Request,
): Response {
  const body = JSON.stringify(value);
  if (new TextEncoder().encode(body).byteLength > MAX_RESPONSE_BYTES) {
    return failureResponse(
      new RequestProblem(502, "unavailable", "The OAuth service is unavailable. Try again later."),
      corsOrigins,
      request,
    );
  }

  return new Response(body, {
    status,
    headers: responseHeaders(corsOrigins, request),
  });
}

function responseHeaders(corsOrigins: Set<string>, request: Request): Headers {
  const headers = new Headers({
    "Cache-Control": "no-store, no-cache, max-age=0, must-revalidate, private",
    "Content-Security-Policy": "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    "Content-Type": "application/json; charset=utf-8",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Resource-Policy": "same-origin",
    Expires: "0",
    Pragma: "no-cache",
    "Referrer-Policy": "no-referrer",
    "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
  });

  const origin = request.headers.get("origin");
  if (origin && corsOrigins.has(origin)) {
    headers.set("Access-Control-Allow-Origin", origin);
    headers.set("Vary", "Origin");
  }
  return headers;
}

function invalidRequest(recoveryDescription: string, status = 400): RequestProblem {
  return new RequestProblem(status, "invalidRequest", recoveryDescription);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * A single Durable Object serializes OAuth nonce consumption and minute-window
 * counters. It persists only opaque nonce hashes and short-lived HMAC-derived
 * IP bucket keys; it never stores request bodies, tokens, or raw IP addresses.
 */
export class OAuthRequestGuard implements DurableObject {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {}

  async fetch(request: Request): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    if (request.method === "GET" && pathname === "/health") {
      // A no-op read verifies that the Durable Object can reach its backing
      // storage without persisting health-check state.
      await this.state.storage.get<number>("health");
      return new Response(null, { status: 204 });
    }
    if (request.method !== "POST" || pathname !== "/consume") {
      return new Response(null, { status: 404 });
    }

    let input: unknown;
    try {
      input = await request.json();
    } catch {
      return new Response(null, { status: 400 });
    }
    if (!isRecord(input) || !isValidGuardInput(input)) {
      return new Response(null, { status: 400 });
    }

    const nonceKey = `nonce:${await keyedHash(input.nonce, this.env.REQUEST_CONTROL_HASH_KEY)}`;
    const ipKey = `ip:${await keyedHash(input.clientIP, this.env.REQUEST_CONTROL_HASH_KEY)}`;
    const window = Math.floor(input.now / 60_000);
    const globalRateKey = `rate:global:${window}`;
    const ipRateKey = `rate:ip:${window}:${ipKey}`;

    const result = await this.state.storage.transaction(async (storage) => {
      const existingExpiry = await storage.get<number>(nonceKey);
      if (existingExpiry !== undefined && existingExpiry > input.now) {
        return 409;
      }
      if (existingExpiry !== undefined) {
        await storage.delete(nonceKey);
      }

      const globalCount = (await storage.get<number>(globalRateKey)) ?? 0;
      const ipCount = (await storage.get<number>(ipRateKey)) ?? 0;
      if (globalCount >= input.requestRateLimitPerMinute || ipCount >= input.ipRateLimitPerMinute) {
        return 429;
      }
      await storage.put({
        [nonceKey]: input.expiresAt,
        [globalRateKey]: globalCount + 1,
        [ipRateKey]: ipCount + 1,
      });
      return 204;
    });

    if (result === 204) {
      await this.scheduleCleanupAlarm(Math.min(input.expiresAt, rateBucketExpiry(window)));
    }
    return new Response(null, { status: result });
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    const stored = await this.state.storage.list<number>();
    let nextExpiry: number | undefined;
    const currentWindow = Math.floor(now / 60_000);
    for (const [key, value] of stored) {
      if (key.startsWith("nonce:") && value <= now) {
        await this.state.storage.delete(key);
      } else if (key.startsWith("rate:")) {
        const rateWindow = Number(key.split(":")[2]);
        if (!Number.isSafeInteger(rateWindow) || rateWindow < currentWindow) {
          await this.state.storage.delete(key);
        } else {
          nextExpiry = Math.min(nextExpiry ?? Number.MAX_SAFE_INTEGER, rateBucketExpiry(rateWindow));
        }
      } else if (key.startsWith("nonce:") && (nextExpiry === undefined || value < nextExpiry)) {
        nextExpiry = value;
      }
    }
    if (nextExpiry !== undefined) {
      // The alarm currently running may still be returned by getAlarm(), so
      // explicitly replace it with the next pending cleanup deadline.
      await this.state.storage.setAlarm(nextExpiry);
    }
  }

  private async scheduleCleanupAlarm(timestamp: number): Promise<void> {
    const currentAlarm = await this.state.storage.getAlarm();
    if (currentAlarm === null || currentAlarm > timestamp) {
      await this.state.storage.setAlarm(timestamp);
    }
  }
}

function rateBucketExpiry(window: number): number {
  return (window + 1) * 60_000;
}

function isValidGuardInput(input: Record<string, unknown>): input is {
  nonce: string;
  expiresAt: number;
  clientIP: string;
  endpoint: "/oauth/exchange" | "/oauth/refresh";
  now: number;
  requestRateLimitPerMinute: number;
  ipRateLimitPerMinute: number;
} {
  return (
    Object.keys(input).length === 7 &&
    REQUEST_NONCE.test(input.nonce as string) &&
    typeof input.expiresAt === "number" && Number.isSafeInteger(input.expiresAt) &&
    typeof input.clientIP === "string" && /^[0-9A-Fa-f:.]{1,64}$/.test(input.clientIP) &&
    (input.endpoint === "/oauth/exchange" || input.endpoint === "/oauth/refresh") &&
    typeof input.now === "number" && Number.isSafeInteger(input.now) &&
    typeof input.requestRateLimitPerMinute === "number" && Number.isSafeInteger(input.requestRateLimitPerMinute) && input.requestRateLimitPerMinute > 0 &&
    typeof input.ipRateLimitPerMinute === "number" && Number.isSafeInteger(input.ipRateLimitPerMinute) && input.ipRateLimitPerMinute > 0
  );
}

async function keyedHash(value: string, key: string): Promise<string> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(value));
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
